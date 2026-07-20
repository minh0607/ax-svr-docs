# AX Svr — Operations & Runbooks

> **Source:** `docs/db-scripts/` + `docs/db-scripts/runbook-schema-migration.md` · **Status:** Live procedures.

Common day-to-day tasks, copy-paste ready. Run DB commands on the DB server as `sudo -u postgres`, or remotely with `PSQL_ADMIN` set to a `dbadmin` connection.

## Onboard a new application

```bash
cd docs/db-scripts
./axdb.sh schema finance AXDEV dbadmin        # schema + finance_readonly / finance_readwrite
```
Then create its users and give them the right group:
```bash
./axdb.sh create-user fi_user finance_readwrite
./axdb.sh set-search-path fi_user finance     # queries need no "finance." prefix
./axdb.sh bind-ip fi_user 10.1.1.50           # optional: pin the account to an IP
```
> Always create the app's tables **as the schema owner** so future tables auto-grant to the groups.

## Give a user read access to another project

```bash
./axdb.sh grant-group prod_acc finance_readonly     # all Finance tables, incl. future ones
# cross-schema queries must qualify the schema:
#   SELECT * FROM finance.fi_cost;
```
Remove it later with `./axdb.sh revoke-group prod_acc finance_readonly`.

## Audit who can touch what

```bash
./axdb.sh perm AXDEV            # every login user: attributes, groups, schema access
./axdb.sh perm AXDEV fi_user    # every table fi_user can reach + effective privileges
```

## Debug "permission denied for schema"

```bash
./axdb.sh schema-perm AXDEV finance          # does the role have USAGE? (effective, incl. via group)
./axdb.sh grant-schema <role> AXDEV finance USAGE   # grant it directly if needed
```

## Move an existing table into a schema without breaking the app

Full worked procedure: **`docs/db-scripts/runbook-schema-migration.md`** (used to move the `licasi_*` tables from `public` into a `licasi` schema). The pattern:
```bash
sudo -u postgres psql -d AXDEV -c "ALTER TABLE public.<t> SET SCHEMA <schema>;"   # name kept
./axdb.sh set-search-path <app_user> <schema>     # unqualified queries still resolve → no app change
```
Then verify **as the app role itself**:
```bash
psql -h 10.1.1.90 -U <app_user> -d AXDEV -c "SELECT count(*) FROM <table>;"
```

## Reset a password / pin an IP

```bash
./axdb.sh passwd <role>                       # prompts twice, hidden
./axdb.sh bind-ip <user> <ip[,ip2]>           # restrict logins to those IPs (auto-detects DevDB vs Patroni)
./axdb.sh bind-ip <user> --unpin              # remove the pin
```

## Check database cluster health / failover

```bash
sudo -u postgres patronictl -c /etc/patroni/patroni.yml list    # who is primary / replica lag
```
Apps use the multi-host connection string, so a Patroni-driven failover needs no app reconfiguration. See the **Database HA** page.

## Backup & restore

Backups run via pgBackRest on `ax-db03:/backup` (weekly full + daily diff + continuous WAL). Restore/PITR steps and the off-site (3-2-1) path are on the **Backup** page.

## Drop things safely

```bash
./axdb.sh drop-user <user> [reassign_to=dbadmin]   # reassigns owned objects first
./axdb.sh drop-schema <db> <schema> [--cascade]    # protected schemas refused; re-type to confirm
./axdb.sh drop-db <db>                              # re-type the exact name to confirm
```

## Related pages
Database Toolkit · Database HA · Security · Backup

---
*Confluence: paste as Markdown.*
