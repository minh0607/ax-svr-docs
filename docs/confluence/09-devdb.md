# AX Svr — DevDB (Standalone PostgreSQL 17)

DevDB is the **standalone** (non-HA) PostgreSQL 17 server the Dev team connects to for day-to-day testing. Unlike the Production tier, it runs no Patroni/etcd — a single instance is enough for a dev environment, and it is also the one AX Svr host with normal **internet access**, so PGDG packages are installed straight from the public repo instead of an air-gapped mirror. Its data directory was deliberately relocated to `/data` using the standard Ubuntu tooling (`pg_dropcluster` + `pg_createcluster -d`), so it shares the exact same `/data/postgresql/17/main` layout Production (Phase 1) uses — the idea is that the same "recipe" (PG17 + `/data`) carries over cleanly when standing up Production later.

> Source: `docs/axsvr-devdb-setup.md` — status: implemented and handed off to the Dev team.

```
Disk layout:
  /data/postgresql/17/main   <- data_dir (includes pg_wal)
  /data/postgresql/logs      <- logs
```

## Host

| | |
|---|---|
| Hostname | `devdb` (also seen as `AX-DevDB-210`) |
| IP | `107.118.210.90` (WAN — Dev connects from personal machines in `107.118.210.0/24`) |
| OS | Ubuntu Server 24.04 |
| PostgreSQL | 17 (PGDG), standalone — no Patroni |
| Internet | **Yes** — unlike air-gapped Production, DevDB installs PGDG online normally |

## Step 1 — Add the PGDG repo and install PostgreSQL 17

```bash
sudo apt update && sudo apt install -y curl ca-certificates gnupg lsb-release
sudo install -d /usr/share/postgresql-common/pgdg
sudo curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail \
  https://www.postgresql.org/media/keys/ACCC4CF8.asc
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
  | sudo tee /etc/apt/sources.list.d/pgdg.list
sudo apt update
sudo apt install -y postgresql-17 postgresql-client-17 postgresql-contrib
```
> The `postgresql-17` package **auto-creates** the `postgres` user/group — do not create it by hand (avoids a mismatched `/var/lib/postgresql` home).

## Step 2 — Create `/data` and relocate the data dir (the "Ubuntu Way")

```bash
# Stop the service + drop the default cluster created on install
sudo systemctl stop postgresql
sudo pg_dropcluster --stop 17 main

# Create the target directories under /data (ideally a separate disk)
sudo mkdir -p /data/postgresql/17/main /data/postgresql/logs
sudo chown -R postgres:postgres /data/postgresql
sudo chmod 700 /data/postgresql/17/main
sudo chmod 750 /data/postgresql/logs

# Re-init the cluster pointing straight at /data
sudo pg_createcluster -d /data/postgresql/17/main 17 main
```
> **No AppArmor changes needed.** On Ubuntu 24.04, PostgreSQL is not confined by AppArmor by default, so `pg_createcluster -d` above just works. If startup fails, check `journalctl -u postgresql@17-main -e` (usually a directory-permission issue).

## Step 3 — Connection + logging (`postgresql.conf`)

```bash
sudo nano /etc/postgresql/17/main/postgresql.conf
```
Uncomment/set:
```ini
# --- Connections ---
listen_addresses = 'localhost,107.118.210.90'

# --- Logging into /data ---
logging_collector = on
log_directory = '/data/postgresql/logs'
log_filename = 'postgresql-%Y-%m-%d.log'
log_rotation_age = 1d
log_statement = 'all'          # Dev: convenient for debugging queries
```
> **Warning:** `log_statement = 'all'` generates a lot of log volume and can fill the disk. Acceptable on Dev, but paired with `log_rotation_age = 1d` and periodic cleanup. Production must **not** enable `all`.

## Three-layer access-control model

Dev has **many changing IPs + many users + per-table permissions**, so access control is split into three independent layers:

| Layer | Tool | Responsibility | When an IP/user changes |
|---|---|---|---|
| 1. Network (which IP can reach 5432) | **ufw** | Allow/deny by IP | Edit ufw |
| 2. Authentication (who has the right password) | **pg_hba.conf** | Enforce password auth | No change needed |
| 3. Authorization (what a user can do, on which table) | **GRANT/REVOKE** | Per-table privileges | Run SQL |

Because **ufw already gates by IP**, `pg_hba` is kept **broad on IP** (no edits needed every time a dev's IP changes) and only enforces "password required." DBAs use a dedicated admin role (`dbadmin`), never the built-in `postgres` superuser.

## Step 4 — `pg_hba.conf` (layer 2: enforce password)

```bash
sudo nano /etc/postgresql/17/main/pg_hba.conf
```
Add (place these lines **before** the default host lines):
```text
# built-in postgres: local only, never over the network
local   all   postgres                  peer
# reject built-in postgres over the network (absolute safety net)
host    all   postgres   0.0.0.0/0      reject
# every other role (dbadmin, devuser...): over the network + password REQUIRED
# (IP is controlled by ufw — pg_hba stays broad)
host    all   all        0.0.0.0/0      scram-sha-256
```
> `0.0.0.0/0` does **not** mean "wide open" — **ufw is the real IP gate** (layer 1). `pg_hba` only guarantees anyone who connects must present a password. The built-in `postgres` role is `reject`ed, so it can never log in remotely.
> After editing: `sudo systemctl reload postgresql`

## Step 5 — Start the service + create roles (DBA + dev)

```bash
sudo systemctl enable --now postgresql

# (1) DBA login from remote — a SEPARATE admin role, NOT the built-in postgres:
sudo -u postgres psql -c "CREATE ROLE dbadmin LOGIN SUPERUSER PASSWORD '<DBA_STRONG_PASSWORD>';"

# (2) Dev user (just enough privilege, can create its own working DB):
sudo -u postgres psql -c "CREATE ROLE devuser LOGIN PASSWORD '<DEV_PASSWORD>' CREATEDB;"
```
> - `postgres` (built-in): kept local-only, never exposed to the network (`pg_hba` already `reject`s it).
> - `dbadmin`: superuser, used by the DBA for remote administration. Different name from `postgres`, strong password.
> - Both `dbadmin` and `devuser` match the `host all all scram-sha-256` line → reachable over the network (IP gated by ufw).

### Layer 3 — per-table authorization (later, via GRANT)
```sql
-- suggested: create group roles per privilege set, then assign users to the group
CREATE ROLE readonly NOLOGIN;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly;
GRANT readonly TO devuser;          -- devuser is read-only

-- or grant per-table privileges to a specific user:
GRANT SELECT, INSERT, UPDATE ON orders TO dev_a;
REVOKE INSERT ON orders FROM dev_a;
```

## Step 6 — Verify before handoff

```bash
sudo -u postgres psql -c "SHOW data_directory;"     # /data/postgresql/17/main
sudo -u postgres psql -c "SHOW log_directory;"      # /data/postgresql/logs
sudo -u postgres psql -c "SELECT version();"        # PostgreSQL 17.x

# Test a network connection as devuser (from another machine or the server itself):
psql "host=107.118.210.90 port=5432 user=devuser dbname=postgres"
```

## Firewall — Layer 1: ufw gates the IPs (where IP control actually happens)

```bash
# 5432: open for the dev RANGE (avoids editing per individual IP change) + the DBA's IP
sudo ufw allow from 107.118.210.0/24 to any port 5432 proto tcp   # dev range
sudo ufw allow from <DBA_IP> to any port 5432 proto tcp           # remote DBA
# 22: SSH restricted to admin only
sudo ufw allow from <ADMIN_IP> to any port 22 proto tcp
sudo ufw enable
```
Add/remove IPs as dev IPs change (no need to touch pg_hba):
```bash
sudo ufw allow from <new_IP> to any port 5432 proto tcp     # add
sudo ufw delete allow from <old_IP> to any port 5432 proto tcp  # remove
```
> Dev machines sit within a few fixed ranges → opened by **range** rather than per individual IP, to avoid constant edits.

## Dev team handoff info

| | |
|---|---|
| Host / IP | `107.118.210.90` |
| Port | `5432` |
| User | `devuser` (`CREATEDB` — can create its own working DB) |
| Password | *(set in Step 5)* |
| Suggested tools | DBeaver / pgAdmin / Navicat |

> Dev uses `devuser` to create its own working database; no superuser access needed.

## Params table

| Param | Value | Note |
|---|---|---|
| Data dir | `/data/postgresql/17/main` | Relocated off the default install path |
| Log dir | `/data/postgresql/logs` | `log_rotation_age = 1d` |
| `listen_addresses` | `localhost,107.118.210.90` | |
| `log_statement` | `all` | Dev-only; disabled in Production |
| `pg_hba` (role `postgres`) | `local peer` / `host ... reject` | Built-in superuser: local only, network access rejected |
| `pg_hba` (all other roles) | `host all all 0.0.0.0/0 scram-sha-256` | Broad on IP by design — ufw gates the actual IP range |
| DBA role | `dbadmin` (SUPERUSER, separate from `postgres`) | Password: `<DBA_STRONG_PASSWORD>` |
| Dev role | `devuser` (`CREATEDB`) | Password: `<DEV_PASSWORD>` |
| ufw port 5432 | Allowed from `107.118.210.0/24` + `<DBA_IP>` | Layer 1 (real IP gate) |
| ufw port 22 | Allowed from `<ADMIN_IP>` only | SSH |

## Relation to the db-scripts toolkit

DevDB uses the same `db-scripts` toolkit (`docs/db-scripts/`) as Production — role/database creation, GRANT/REVOKE, password resets, etc. are identical commands on both. The one place the toolkit branches is IP-pinning a user: `axdb.sh bind-ip` (and the standalone `bind-user-ip.sh` / `bind-user-ip-patroni.sh` scripts) **auto-detects** which backend to use — if `patronictl` + `/etc/patroni/patroni.yml` exist, it edits `pg_hba` via the Patroni DCS (`patronictl edit-config`); otherwise, as on DevDB, it edits the `pg_hba.conf` **file** directly and reloads. This can be forced explicitly with `--file` / `--patroni` if needed.

## Difference vs. Production (Phase 1)

| | DevDB | Production (Phase 1) |
|---|---|---|
| HA | ❌ standalone | ✅ Patroni + etcd, 3 nodes |
| Cluster install | `pg_createcluster` (Ubuntu Way) | Patroni runs its own `initdb` |
| Data dir | `/data/postgresql/17/main` | `/data/postgresql/17/main` (same) |
| Internet | ✅ yes (installs PGDG online) | ❌ air-gapped |
| `log_statement` | `all` (debug) | off (errors/slow queries only) |
| Access | Dev over WAN `107.118.210.x` | App over LAN `10.1.1.x` (multi-host) |
| `pg_hba` management | File, edited directly | Patroni DCS, via `patronictl` |

## Key decisions

- **Standalone vs. joining the HA cluster.** DevDB deliberately runs a single, non-Patroni PostgreSQL 17 instance instead of joining (or mirroring) the Production Patroni/etcd cluster. A dev/test environment doesn't need automatic failover, and adding Patroni would only add operational overhead without benefit here — simplicity was chosen over consistency with Production's HA topology.
- **`/data` relocation (the "Ubuntu Way").** Rather than leaving PostgreSQL on its default install path, the default cluster created by the package (`pg_dropcluster --stop 17 main`) is dropped and re-created with `pg_createcluster -d /data/postgresql/17/main 17 main`, pointing straight at `/data`. This was done specifically so the **same recipe** — PG17, same `/data/postgresql/17/main` layout — can be "carried over" to Production (Phase 1) without inventing a second convention.
- **DevDB has internet access; Production does not.** This is the one AX Svr host allowed to reach the public PGDG APT repo directly. It is explicitly not air-gapped like Production, which is why Step 1 installs PGDG online with no offline-mirror workaround.

## Related pages

- AX Svr — Architecture overview
- AX Svr — Database HA (Patroni)
- AX Svr — DB Scripts toolkit
- AX Svr — Backup & monitoring

---
Paste as Markdown; upload any referenced PNG as a page attachment.
