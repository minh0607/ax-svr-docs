# Runbook: move /data onto its dedicated disk (fix a forgotten mount)

> **Symptom:** `data_directory` is on the ROOT filesystem (`/`) because a dedicated data disk was never mounted. On AX-DB01 this was confirmed: data at `/data/postgresql/17/main` on `sda2` (`/`), while `/dev/sdb` (100G) is blank and unmounted.
> **Goal:** make the dedicated disk the mount point of `/data`, with the PostgreSQL data on it, across the whole Patroni cluster — no data loss.
> Run TESTS with `./axdb.sh check-storage` before and after. Verify each disk name per node (`lsblk`) — it may not be `/dev/sdb` everywhere.

## Golden rules
- **One node at a time. Never stop 2 of 3 nodes at once** (quorum).
- **Order: both REPLICAS first, then the PRIMARY** (switchover the primary to a replica first).
- **Never mount the new disk directly over a live `/data`** — it shadows the data and PG sees an empty dir. Always `mv /data /data.old` first.
- Keep `/data.old` until the node is verified healthy (that is your rollback).

## 0. Confirm the disk is blank (per node)
```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT | grep -Ei 'disk|part'   # find the empty ~100G disk -> <DISK> (e.g. /dev/sdb)
sudo wipefs <DISK>          # empty = clean
sudo blkid <DISK>*          # nothing = no filesystem
sudo sfdisk -d <DISK> 2>&1  # "does not contain a recognized partition table" = clean
```
Proceed only if blank.

## 1. Identify roles
```bash
patronictl -c /etc/patroni/patroni.yml list   # note the Leader; do replicas first, primary last
```

## Per-REPLICA procedure (do ax-db02, then ax-db03)

```bash
# a. leave the cluster (leader + other replica keep quorum)
sudo systemctl stop patroni

# b. partition + format the dedicated disk
sudo parted -s <DISK> mklabel gpt
sudo parted -s <DISK> mkpart primary ext4 0% 100%
sudo mkfs.ext4 -L pgdata <DISK>1

# c. move the on-root data aside, mount the new disk at /data
sudo mv /data /data.old
sudo mkdir /data
sudo mount <DISK>1 /data

# d. recreate the EMPTY data dir with correct ownership (Patroni will re-clone from the leader)
sudo mkdir -p /data/postgresql/17/main
sudo chown -R postgres:postgres /data/postgresql
sudo chmod 700 /data/postgresql/17/main

# e. persist in fstab (auto-mount on boot)
sudo blkid <DISK>1                        # copy the UUID
echo 'UUID=<uuid>  /data  ext4  defaults,noatime  0 2' | sudo tee -a /etc/fstab
sudo mount -a && findmnt /data            # /data must be the mount of <DISK>1

# f. start -> Patroni finds empty data dir -> reinitialises this replica from the leader
sudo systemctl start patroni
patronictl -c /etc/patroni/patroni.yml list      # wait for this node: role Replica, State running/streaming, Lag 0
#   if it does not auto-reinit:
#   patronictl -c /etc/patroni/patroni.yml reinit <cluster> <thisnode>

# g. verify, then reclaim root space
./axdb.sh check-storage                    # data_directory OK: on its own mount (/data)
df -h /data                                # <DISK>1 ~100G
sudo rm -rf /data.old                      # ONLY after the node is confirmed healthy
```

> Alternative to (d)+(f) if you prefer to copy instead of re-clone: after (c),
> `sudo rsync -aHAX /data.old/ /data/` then start patroni (no reinit needed).
> Re-clone is simpler for replicas; rsync avoids network transfer.

## PRIMARY procedure (ax-db01) — LAST

```bash
# switch leadership to an already-migrated node, so ax-db01 becomes a replica
patronictl -c /etc/patroni/patroni.yml switchover
patronictl -c /etc/patroni/patroni.yml list      # confirm ax-db01 is now Replica
# then apply the Per-REPLICA procedure (a..g) on ax-db01
```

## Rollback (single node, before deleting /data.old)
```bash
sudo systemctl stop patroni
sudo umount /data && sudo rmdir /data
sudo mv /data.old /data
sudo sed -i '\#[[:space:]]/data[[:space:]]#d' /etc/fstab   # remove the line we added
sudo systemctl start patroni
patronictl -c /etc/patroni/patroni.yml list
```

## Final check (whole cluster)
```bash
patronictl -c /etc/patroni/patroni.yml list   # 1 Leader + 1 Sync + 1 Replica, all running, Lag 0
# on each node:
./axdb.sh check-storage                        # storage OK on all three
```
