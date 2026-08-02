# axdb.sh health — one-shot cluster health check

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add `axdb.sh health [db]` — a single command that prints the whole PostgreSQL HA cluster's health: services, etcd quorum, Patroni cluster/roles/lag, PostgreSQL role + replication + WAL archiver, the REAL data_directory + its disk usage, and pgBackRest backup status. It must **auto-discover** the data directory (via `SHOW data_directory`) and backup state (via `pgbackrest info`) instead of assuming `/data` or `/backup`, and must **degrade gracefully** when run somewhere the cluster tools (patronictl/etcdctl/pgbackrest/systemctl) are absent.

**Architecture:** New `cmd_health` in the self-contained `axdb.sh`, using the existing `$PSQL` for SQL and calling `patronictl`/`etcdctl`/`pgbackrest`/`systemctl` only when present (guarded by `command -v`). Runs best ON a DB node. Test the PostgreSQL-driven parts + the graceful-skip behavior against the Docker PostgreSQL 17 harness (which has psql but none of the cluster tools).

## Global Constraints
- PostgreSQL 17. Script interface ENGLISH. Honor `PSQL_ADMIN`. Commit messages NO attribution trailer; plain `git commit -m` (no `--no-verify`/`--amend`/`--no-edit`).
- `axdb.sh` self-contained; additive only — existing subcommands and menu items 1–29 unchanged (append 30, bump `Select [0-29]` → `[0-30]`).
- **`set -euo pipefail` safety:** every external call that may exit non-zero (etcdctl/patronictl/pgbackrest/systemctl/df, and any `... | sed` pipeline) MUST be guarded (`|| true`, `2>/dev/null`, or an `if command -v`), so `health` never aborts mid-report. This is the main risk and the test must exercise it (all cluster tools absent in the container).

---

### Task 1: `cmd_health` + test

**Files:**
- Modify: `docs/db-scripts/axdb.sh`
- Test: `docs/db-scripts/tests/test-health.sh`

**Interfaces:**
- Consumes: harness `tests/lib.sh` (`pg_up`,`pg_down`,`dq`,`make_db`,`assert_eq`,`assert_contains`,`finish`).
- Produces: `axdb.sh health [db]` (db defaults to `postgres`).

- [ ] **Step 1: Write failing test `tests/test-health.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
trap pg_down EXIT
pg_up
make_db appdb appowner

# health must run cleanly even though NONE of patronictl/etcdctl/pgbackrest/systemctl exist in the container,
# and must report the real data_directory + PRIMARY role from the live PostgreSQL.
OUT="$(./axdb.sh health appdb)"; RC=$?
assert_eq "$RC" "0" "health exits 0 even without cluster tools"
assert_contains "$OUT" "data_directory" "reports the real data_directory"
assert_contains "$OUT" "PRIMARY"        "detects primary role (pg_is_in_recovery=f)"
assert_contains "$OUT" "postgresql"     "has the postgresql section"
# graceful-skip lines for tools that are absent in the container
assert_contains "$OUT" "patroni"        "has a patroni section (skipped note ok)"
assert_contains "$OUT" "etcd"           "has an etcd section (skipped note ok)"

# default db (no arg) also works
./axdb.sh health >/dev/null && echo ok >/tmp/axdbhealth.$$ ; assert_eq "$(cat /tmp/axdbhealth.$$)" "ok" "health with no db arg works"; rm -f /tmp/axdbhealth.$$

finish
```

- [ ] **Step 2: Run test, confirm RED**

Run: `docker rm -f axdb-scripts-test >/dev/null 2>&1; bash docs/db-scripts/tests/test-health.sh 2>&1 | tail -10`
Expected: FAIL — "Invalid command: health".

- [ ] **Step 3: Add `cmd_health` to `axdb.sh`**

Insert after `cmd_schema_perm` (mirror the file's `cmd_*` style):

```bash
cmd_health() {                  # [db]   — one-shot cluster health (run on a DB node for full detail)
  local db="${1:-postgres}"
  local conf="${PATRONI_CONF:-/etc/patroni/patroni.yml}"
  echo "==================== AX DB cluster health ===================="
  echo "conn: $PSQL_ADMIN   ·   db: $db   ·   host: $(hostname 2>/dev/null || echo '?')"

  echo "-- services --"
  if command -v systemctl >/dev/null 2>&1; then
    for svc in etcd patroni; do printf "  %-8s : %s\n" "$svc" "$(systemctl is-active "$svc" 2>/dev/null || echo n/a)"; done
  else echo "  (systemctl not found — run on a DB node)"; fi

  echo "-- etcd (DCS quorum) --"
  if command -v etcdctl >/dev/null 2>&1; then
    local eps="${ETCD_ENDPOINTS:-}"
    if [ -z "$eps" ] && [ -f "$conf" ]; then
      eps="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:2379' "$conf" 2>/dev/null | sort -u | sed 's#^#http://#' | paste -sd, - || true)"
    fi
    if [ -n "$eps" ]; then etcdctl --endpoints="$eps" endpoint health 2>&1 | sed 's/^/  /' || true
    else echo "  (set ETCD_ENDPOINTS=http://ip:2379,... — could not derive from $conf)"; fi
  else echo "  (etcdctl not found — run on a DB node)"; fi

  echo "-- patroni --"
  if command -v patronictl >/dev/null 2>&1 && [ -f "$conf" ]; then
    patronictl -c "$conf" list 2>&1 | sed 's/^/  /' || true
    patronictl -c "$conf" show-config 2>/dev/null | grep -E 'synchronous_mode|synchronous_node_count' | sed 's/^/  cfg: /' || true
  else echo "  (patronictl/$conf not found — run on a DB node)"; fi

  echo "-- postgresql --"
  local inrec; inrec="$($PSQL -d "$db" -tAc 'SELECT pg_is_in_recovery()' 2>/dev/null || echo '?')"
  echo "  data_directory : $($PSQL -d "$db" -tAc 'SHOW data_directory' 2>/dev/null || echo '?')"
  echo "  version        : $($PSQL -d "$db" -tAc 'SHOW server_version' 2>/dev/null || echo '?')"
  if [ "$inrec" = f ]; then
    echo "  role           : PRIMARY (read-write)"
    echo "  replicas       :"
    $PSQL -d "$db" -tAc "SELECT '    '||application_name||'  '||state||'  '||sync_state||'  replay_lag='||COALESCE(replay_lag::text,'-') FROM pg_stat_replication ORDER BY sync_state" 2>/dev/null || true
    echo "  WAL archiver   :"
    $PSQL -d "$db" -tAc "SELECT '    archived='||archived_count||'  failed='||failed_count||'  last='||COALESCE(last_archived_time::text,'-') FROM pg_stat_archiver" 2>/dev/null || true
  elif [ "$inrec" = t ]; then
    echo "  role           : replica (read-only)"
  else
    echo "  role           : ? (cannot connect via \$PSQL — check PSQL_ADMIN)"
  fi

  echo "-- disk (data dir) --"
  local dd; dd="$($PSQL -d "$db" -tAc 'SHOW data_directory' 2>/dev/null || true)"
  if [ -n "$dd" ]; then df -h "$dd" 2>/dev/null | sed 's/^/  /' || true; else echo "  (data_directory unknown)"; fi

  echo "-- backup (pgBackRest) --"
  if command -v pgbackrest >/dev/null 2>&1; then
    { sudo -u postgres pgbackrest info 2>&1 || true; } | sed 's/^/  /'
  else echo "  (pgbackrest not found here — check on the node holding the backup repo)"; fi
  echo "=============================================================="
}
```

Dispatch — add after `schema-perm)`:
```bash
  health)             cmd_health "$@";;
```

`usage()` — add near `check`:
```
  health [db]                                 One-shot cluster health: services, etcd, patroni, replication, disk, backup
```

Menu — append after item 29 (read the real menu first):
```
 30) Cluster health check (health)
```
case branch (before `0)`):
```bash
      30) read -rp "Database (blank=postgres): " d; _run cmd_health "${d:-}" ;;
```
Bump the prompt `Select [0-29]` → `Select [0-30]`.

- [ ] **Step 4: Run test, confirm GREEN**

Run: `docker rm -f axdb-scripts-test >/dev/null 2>&1; bash docs/db-scripts/tests/test-health.sh 2>&1 | tail -10`
Expected: `== PASS=6 FAIL=0 ==`

- [ ] **Step 5: `bash -n` + full suite (no regression)**

```bash
bash -n docs/db-scripts/axdb.sh && echo "syntax OK"
for t in docs/db-scripts/tests/test-*.sh; do printf '%-40s ' "$(basename "$t")"; bash "$t" 2>&1 | tail -1; docker rm -f axdb-scripts-test >/dev/null 2>&1; done
```
Expected: 14 files, each `FAIL=0`.

- [ ] **Step 6: exec-bit + commit**

```bash
mapfile -t SH < <(git ls-files 'docs/db-scripts/*.sh'); git update-index --chmod=+x "${SH[@]}"
git add docs/db-scripts/axdb.sh docs/db-scripts/tests/test-health.sh
git commit -m "feat(db): axdb.sh health — kiểm tra sức khỏe cụm (services/etcd/patroni/replication/disk/backup)"
```

---

### Task 2: Docs

**Files:**
- Modify: `docs/db-scripts/README.md`
- Modify: `docs/confluence/08-db-toolkit.md` (command table row)
- Modify: `docs/confluence/10-operations.md` (a "Check cluster health" subsection)
- Modify: `docs/axsvr-phase1-db.md` (a short "Kiểm tra sức khỏe cụm" note, Vietnamese)

- [ ] **Step 1:** README (English) — add under a health/ops note:
```
Cluster health in one shot (run on a DB node):
    ./axdb.sh health              # services, etcd quorum, patroni roles/lag, replication, real data_directory + disk, pgBackRest
It auto-discovers the data directory and backup repo (no assumption about /data or /backup).
```
- [ ] **Step 2:** confluence 08 command table — add row: `Cluster health (one shot) | ./axdb.sh health [db]`.
- [ ] **Step 3:** confluence 10 — add subsection "Check cluster health" with `./axdb.sh health` and what each section means + note it must run on a DB node for the patroni/etcd/backup parts.
- [ ] **Step 4:** phase1-db (Vietnamese) — short note: `axdb.sh health` để xem nhanh trạng thái cụm; chạy trên DB node.
- [ ] **Step 5:** commit
```bash
git add docs/db-scripts/README.md docs/confluence/08-db-toolkit.md docs/confluence/10-operations.md docs/axsvr-phase1-db.md
git commit -m "docs(db): axdb.sh health"
```

---

## Ghi chú kiểm thử tổng
Sau Task 1, suite phải xanh (14 file). `health` chỉ test được phần PostgreSQL + nhánh graceful-skip trong container (không có patronictl/etcdctl/pgbackrest) — đó cũng chính là vùng rủi ro `set -e`, nên test phủ đúng chỗ cần.
