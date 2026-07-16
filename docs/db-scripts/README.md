# AX Svr — DB Scripts (PostgreSQL administration)

A set of scripts for creating roles/databases and managing privileges. Used for both **DevDB** and **Production** (Patroni).

## ⭐ ALL-IN-ONE script: `axdb.sh` (single file, everything combined)

If you want **a single script**, use `axdb.sh` (self-contained, no other files needed).

**Option 1 — Interactive MENU (easiest):** run with no arguments
```bash
./axdb.sh            # opens the menu, pick a number 0-18
```
```
============== AX DB MANAGER ==============
  1) Create DB admin   10) Drop user
  2) Create user admin 11) Drop database
  3) Create user       12) View roles/dbs/...
  4) Create database   13) Connection check
  5) Create group roles 14) Create table
  6) GRANT privileges  15) Set table owner
  7) REVOKE privileges 16) Set database owner
  8) Change password   17) Role dashboard
  9) Pin user to IP    18) Show / inspect
                        0) Exit
```

**Option 2 — Direct commands** (for scripts/automation):
```bash
./axdb.sh help                              # list all commands
./axdb.sh create-admin dbadmin
./axdb.sh create-db appdb dbadmin
./axdb.sh setup-groups appdb
./axdb.sh create-user dev_a appdb_readonly
./axdb.sh grant dev_a appdb orders "SELECT,INSERT"
./axdb.sh create-table appdb orders "id serial primary key, note text" dbadmin
./axdb.sh set-owner appdb orders dbadmin     # change TABLE owner
./axdb.sh set-db-owner appdb dbadmin         # change DATABASE owner
./axdb.sh passwd dev_a                        # reset/change password
./axdb.sh bind-ip a 1.1.1.1                  # auto-detects DevDB(file) or Patroni(DCS)
./axdb.sh drop-user dev_a
./axdb.sh drop-db appdb
./axdb.sh list roles

# Inspect / show (read-only)
./axdb.sh dashboard dev_a                     # everything a user/group can access
./axdb.sh show dbs                            # databases on the server (owner, size)
./axdb.sh show tables appdb                   # tables in a database (owner, size)
./axdb.sh show structure appdb orders         # table columns/indexes (\d)
./axdb.sh show owner appdb orders             # db/table owner
./axdb.sh show perms appdb orders             # privileges (\dp)
```
> `bind-ip` **auto-detects**: if `patronictl` + `/etc/patroni/patroni.yml` exist → use DCS; otherwise edit the file. Force with `--file` / `--patroni`.

The standalone scripts below still work (same logic) — pick either approach.

---

## Connecting with admin privileges

| Method | Command |
|---|---|
| **Run directly on the DB server** (default) | run the script as usual — connects via socket as `postgres` |
| **Run remotely** (via dbadmin) | `export PSQL_ADMIN="psql -h 107.118.210.90 -U dbadmin"` then run the script |

> Production (Patroni): run on the **Leader** node, or remotely via a multi-host connection pointing to `target_session_attrs=read-write`.

## Script list

| Script | Purpose |
|---|---|
| `create-db-admin.sh <name>` | Create a **DBA** (SUPERUSER) — remote administration, replaces the built-in `postgres` |
| `create-user-admin.sh <name>` | Create a **user admin** (CREATEROLE+CREATEDB, not superuser) |
| `create-user.sh <user> [group]` | Create a regular user, optionally assigned to a group |
| `create-database.sh <db> [owner]` | Create a database + revoke PUBLIC privileges |
| `setup-group-roles.sh <db>` | Create the `<db>_readonly` / `<db>_readwrite` groups + default privileges |
| `grant-table.sh <grant\|revoke> <role> <db> <table> <privs>` | Manage privileges per table |
| `reset-password.sh <role>` | Change a role's password (entered twice, hidden) |
| `bind-user-ip.sh <user> <ip[,ip2]>` / `<user> --unpin` | **Pin a user to specific IPs only** — **DevDB/standalone** (edits the pg_hba file) |
| `bind-user-ip-patroni.sh <user> <ip[,ip2]>` / `<user> --unpin` | **Pin a user to specific IPs only** — **Production Patroni** (via DCS/patronictl) |
| `drop-user.sh <user> [reassign_to]` | **Safely drop a user** — reassign objects to another owner, then drop |
| `drop-database.sh <db>` | **Safely drop a database** — prompts for backup + retype the name + FORCE |
| `list-access.sh <roles\|dbs\|members <g>\|grants <db>>` | View roles/dbs/privileges |

### Notes on the DROP scripts (destructive)
- `drop-user.sh`: blocks dropping protected roles (`postgres`, `dbadmin`, `useradmin`, `replicator`); reassigns owned objects to `reassign_to` (default `dbadmin`) across **every database** before DROP.
- `drop-database.sh`: blocks system databases; prints size + connection count; **requires retyping the exact name** before dropping; uses `WITH (FORCE)` to terminate connections. **Cannot be undone — back up first!**

## Typical workflow (example database `appdb`)

```bash
# 1) DBA + user admin (once for the whole system)
./create-db-admin.sh   dbadmin
./create-user-admin.sh useradmin

# 2) Create the database + privilege groups
./create-database.sh    appdb dbadmin
./setup-group-roles.sh  appdb           # -> appdb_readonly, appdb_readwrite

# 3) Create users and assign groups
./create-user.sh dev_a appdb_readonly   # dev_a READ only
./create-user.sh dev_b appdb_readwrite  # dev_b READ+WRITE

# 4) Per-table privileges (for exceptions)
./grant-table.sh grant  dev_a appdb orders "SELECT,INSERT,UPDATE"
./grant-table.sh revoke dev_a appdb orders INSERT

# 5) Verify
./list-access.sh roles
./list-access.sh grants appdb
```

## Recommended privilege model (many users)

```
Attach privileges to a GROUP (group role), NOT directly to each user:
  appdb_readonly  ← dev_a, dev_c, reporting...
  appdb_readwrite ← dev_b, app_service...
=> adding/removing people only requires GRANT/REVOKE on the group; new table privileges apply automatically thanks to DEFAULT PRIVILEGES.
```

> `grant` / `revoke` work for **any role** — a user OR a group. Prefer granting to groups; use per-user grants only for exceptions.

## Multiple projects / multiple people: schema-per-app model

Each project = 1 schema; groups `<schema>_readonly` / `<schema>_readwrite`; each person = 1 login role assigned to a group.

Create a schema for 1 app:
```bash
./create-schema.sh finance appdb appowner
# or: ./axdb.sh schema finance appdb appowner
```

Assign a person to the project + let queries skip the schema qualifier:
```bash
GRANT finance_readwrite TO fi_user;
ALTER ROLE fi_user SET search_path = finance, public;
```

Grant cross-project access (Production reads all of Finance):
```bash
GRANT finance_readonly TO prod_acc;        -- includes future tables too
-- queries must qualify the schema: SELECT * FROM finance.fi_cost;
```

View the permission overview:
```bash
./list-access.sh perm appdb            # summary of all users
./list-access.sh perm appdb prod_acc   # per-table drill-down for one user
# equivalent: ./axdb.sh perm appdb [user]
```

Note: default privileges are tied to the owner — always create tables as the actual owner of the schema/DB.

## Pin an account to specific IPs (`bind-user-ip.sh`)

IPs are **not** set on the account — they are set in `pg_hba.conf`. This script manages that for you:
```bash
./bind-user-ip.sh app_svc 10.1.1.101          # app_svc ONLY from this IP
./bind-user-ip.sh dev_a   192.0.2.10,192.0.2.11  # multiple IPs
./bind-user-ip.sh dev_a   --unpin             # remove pin -> back to the general rule
```
- How it works: adds `include_if_exists pg_hba_peruser.conf` at the top of `pg_hba.conf`, writes an `allow <IP> + reject all other IPs` block for the user, then reloads + checks for errors.
- **Use when:** the account has a fixed IP (service account, server, DBA machine). **Avoid** pinning a dev laptop whose IP changes (you'd have to edit + reload every time).
- **3 layers:** ufw (global IP) · pg_hba/pin (per-user IP) · GRANT (table privileges).

### Pin IP — 2 variants (like MySQL `user@host`)
| Environment | Script | Mechanism |
|---|---|---|
| DevDB / standalone | `bind-user-ip.sh` | edits `pg_hba.conf` file + reload |
| Production Patroni | `bind-user-ip-patroni.sh` | updates DCS via `patronictl edit-config` + cluster reload |

```bash
# DevDB:
./bind-user-ip.sh a 1.1.1.1            # a can ONLY connect from 1.1.1.1, other IPs are rejected
# Production (run on one DB node):
./bind-user-ip-patroni.sh a 1.1.1.1
```
> ⚠️ **Do not** use `bind-user-ip.sh` (file edit) on a Patroni cluster — Patroni will overwrite it. Use the `-patroni` variant.
> Unlike MySQL: PG is **one role, one password**, with IP separated in pg_hba; if you need a different password per IP, create a separate role for each IP.

## Security notes

- Passwords are entered via a hidden prompt (not saved to shell history).
- If `log_statement='all'` (DevDB) → create/change-password commands may be logged. In Production keep `log_statement='ddl'`/`none`.
- The built-in `postgres` stays local-only; use `dbadmin` for remote administration.
- 3 control layers: **ufw** (IP) → **pg_hba** (password) → **these scripts** (role/table privileges).
