# Runbook: move /data onto its dedicated disk (fix a forgotten mount)

> **Symptom (confirmed on AX-DB01):** `data_directory = /data/postgresql/17/main` sits on the ROOT filesystem (`sda2`, `/`) because the dedicated disk `/dev/sdb` (100G) was never mounted. Same situation expected on all three nodes.
> **Goal:** make `/dev/sdb` the mount point of `/data` on every node, PostgreSQL data on it, no data loss.
> Assumes the empty disk is `/dev/sdb` and `data_dir = /data/postgresql/17/main` — **verify per node** (`lsblk`) before running.

## Golden rules
- **One node at a time. Never stop 2 of 3 nodes at once** (quorum).
- **Order: DB03 (async) → DB02 (sync) → DB01 (primary).** DB01 is switched over to a replica first.
- **Never mount the new disk over a live `/data`** — always `mv /data /data.old` first (a mount would shadow the data → PG sees an empty dir).
- Keep `/data.old` until the node is verified healthy — that is the rollback. Delete it only after `check-storage` OK + Lag 0.
- Between nodes: confirm `patronictl list` shows the cluster healthy (1 Leader + 1 Sync + 1 Replica, all running) before touching the next node.

## Sync vs async (why this order)
`synchronous_mode: true`, `synchronous_node_count: 1` → always exactly one **sync standby** (commits wait for it → zero data loss). The **async replica** may lag. Patroni auto-promotes an async replica to sync if the sync one leaves, so migrating the async node (DB03) first keeps a genuine sync standby available throughout.

---

## NODE 1 — DB03 (async replica) — do FIRST

```bash
# 0. verify role + that the empty 100G disk is /dev/sdb
patronictl -c /etc/patroni/patroni.yml list
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT | grep -Ei 'disk|part'

# 1. leave the cluster (leader + DB02 keep quorum)
sudo systemctl stop patroni

# 2. partition + format the dedicated disk
sudo parted -s /dev/sdb mklabel gpt
sudo parted -s /dev/sdb mkpart primary ext4 0% 100%
sudo mkfs.ext4 -L pgdata /dev/sdb1

# 3. move the on-root data aside, mount the new disk at /data
sudo mv /data /data.old
sudo mkdir /data
sudo mount /dev/sdb1 /data

# 4. empty data dir with correct ownership (Patroni re-clones from the leader)
sudo mkdir -p /data/postgresql/17/main
sudo chown -R postgres:postgres /data/postgresql
sudo chmod 700 /data/postgresql/17/main

# 5. persist in fstab
sudo blkid /dev/sdb1                       # copy the UUID
echo 'UUID=<uuid>  /data  ext4  defaults,noatime  0 2' | sudo tee -a /etc/fstab
sudo mount -a && findmnt /data            # /data must be the mount of /dev/sdb1

# 6. start -> Patroni finds empty data dir -> reinitialises DB03 from the leader
sudo systemctl start patroni
patronictl -c /etc/patroni/patroni.yml list      # DB03: role Replica, State running/streaming, Lag 0
#   if it does not auto-reinit:
#   patronictl -c /etc/patroni/patroni.yml reinit <cluster> <db03-name>

# 7. verify, then reclaim root space
./axdb.sh check-storage                    # "OK: data directory is on its own mount (/data)"
df -h /data
sudo rm -rf /data.old                      # ONLY after DB03 is confirmed healthy
```

---

## NODE 2 — DB02 (sync standby) — do SECOND

> When DB02 stops, Patroni promotes DB03 (already migrated) to sync — commits keep their zero-loss guarantee.

```bash
# 0. verify role + disk
patronictl -c /etc/patroni/patroni.yml list       # DB02 = Sync Standby; DB03 already healthy on its new disk
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT | grep -Ei 'disk|part'

# 1. leave the cluster (leader + DB03 keep quorum)
sudo systemctl stop patroni

# 2. partition + format
sudo parted -s /dev/sdb mklabel gpt
sudo parted -s /dev/sdb mkpart primary ext4 0% 100%
sudo mkfs.ext4 -L pgdata /dev/sdb1

# 3. move old data aside, mount new disk
sudo mv /data /data.old
sudo mkdir /data
sudo mount /dev/sdb1 /data

# 4. empty data dir + perms
sudo mkdir -p /data/postgresql/17/main
sudo chown -R postgres:postgres /data/postgresql
sudo chmod 700 /data/postgresql/17/main

# 5. fstab
sudo blkid /dev/sdb1
echo 'UUID=<uuid>  /data  ext4  defaults,noatime  0 2' | sudo tee -a /etc/fstab
sudo mount -a && findmnt /data

# 6. start -> re-clone from leader
sudo systemctl start patroni
patronictl -c /etc/patroni/patroni.yml list       # DB02 back, Lag 0

# 7. verify + reclaim
./axdb.sh check-storage
df -h /data
sudo rm -rf /data.old
```

---

## NODE 3 — DB01 (primary) — do LAST

> Switch leadership away first so DB01 becomes a replica; then the exact same steps.

```bash
# 0. hand over leadership to an already-migrated node (DB02 or DB03)
patronictl -c /etc/patroni/patroni.yml switchover
patronictl -c /etc/patroni/patroni.yml list       # confirm DB01 is now a Replica
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT | grep -Ei 'disk|part'

# 1. leave the cluster
sudo systemctl stop patroni

# 2. partition + format
sudo parted -s /dev/sdb mklabel gpt
sudo parted -s /dev/sdb mkpart primary ext4 0% 100%
sudo mkfs.ext4 -L pgdata /dev/sdb1

# 3. move old data aside, mount new disk
sudo mv /data /data.old
sudo mkdir /data
sudo mount /dev/sdb1 /data

# 4. empty data dir + perms
sudo mkdir -p /data/postgresql/17/main
sudo chown -R postgres:postgres /data/postgresql
sudo chmod 700 /data/postgresql/17/main

# 5. fstab
sudo blkid /dev/sdb1
echo 'UUID=<uuid>  /data  ext4  defaults,noatime  0 2' | sudo tee -a /etc/fstab
sudo mount -a && findmnt /data

# 6. start -> re-clone from the (new) leader
sudo systemctl start patroni
patronictl -c /etc/patroni/patroni.yml list       # DB01 back as Replica, Lag 0

# 7. verify + reclaim
./axdb.sh check-storage
df -h /data
sudo rm -rf /data.old
```

> Optional: after all three are on their disks, if you want DB01 to be the leader again, `patronictl switchover` back to it. Not required — any node can lead.

---

## Rollback (single node, before deleting /data.old)
```bash
sudo systemctl stop patroni
sudo umount /data && sudo rmdir /data
sudo mv /data.old /data
sudo sed -i '\#[[:space:]]/data[[:space:]]#d' /etc/fstab   # remove the fstab line we added
sudo systemctl start patroni
patronictl -c /etc/patroni/patroni.yml list
```

## Final check (whole cluster)
```bash
patronictl -c /etc/patroni/patroni.yml list   # 1 Leader + 1 Sync Standby + 1 Replica, all running, Lag 0
# on each node:
./axdb.sh check-storage                        # storage OK on all three
```
