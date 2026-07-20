# Schema-level privilege commands (grant/revoke/check)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add dedicated commands for **schema-level** privileges (USAGE / CREATE), which the toolkit currently only handles as a side effect: `grant-schema` / `revoke-schema` (grant or revoke USAGE/CREATE/ALL on a schema for a role) and `schema-perm` (list which roles actually hold USAGE/CREATE on a schema, read from `has_schema_privilege` — the check `perm` cannot do today).

**Architecture:** Bám pattern sẵn có (`grant-group`, `grant-table`, `perm`). New standalone `grant-schema.sh` mirrors `grant-table.sh`/`grant-group.sh`; `axdb.sh` gets `cmd_grant_schema` + `cmd_schema_perm` (self-contained bundle, copy logic, do NOT source standalones); the read-only `schema-perm` also goes into `list-access.sh` next to `perm`. Identifiers via psql `:"var"`. Test against ephemeral PostgreSQL 17 Docker via `tests/lib.sh`.

**Tech Stack:** Bash, PostgreSQL 17, Docker (test).

## Global Constraints
- PostgreSQL 17. Script interface + column headers ENGLISH; README English; `axsvr-phase1-db.md` Vietnamese; confluence pages English.
- Honor `PSQL_ADMIN` (works with `sudo -u postgres psql` and `docker exec -i ... psql`).
- Commit messages NO attribution trailer; do NOT use `--no-verify`/`--amend`/`--no-edit` — plain `git commit -m`.
- `axdb.sh` self-contained; additive only — existing subcommands and menu items 1–27 unchanged (only append 28+).
- Privilege keyword accepted case-insensitively: `USAGE` | `CREATE` | `ALL`.

---

### Task 1: `grant-schema` / `revoke-schema`

**Files:**
- Create: `docs/db-scripts/grant-schema.sh`
- Modify: `docs/db-scripts/axdb.sh`
- Test: `docs/db-scripts/tests/test-schema-privs.sh`

**Interfaces:**
- Consumes: harness `tests/lib.sh` (`pg_up`,`pg_down`,`dq`,`make_db`,`assert_eq`,`finish`); `create-schema.sh`.
- Produces:
  - `./grant-schema.sh <grant|revoke> <role> <db> <schema> <USAGE|CREATE|ALL>`
  - `axdb.sh grant-schema <role> <db> <schema> <priv>` / `axdb.sh revoke-schema <role> <db> <schema> <priv>`

- [ ] **Step 1: Viết test thất bại `tests/test-schema-privs.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
trap pg_down EXIT
pg_up
make_db appdb appowner
./create-schema.sh finance appdb appowner
dq -c "CREATE ROLE acc LOGIN PASSWORD 'x';" >/dev/null

# baseline: fresh role has neither USAGE nor CREATE on a private schema
assert_eq "$(dq -d appdb -tAc "SELECT has_schema_privilege('acc','finance','USAGE')")"  "f" "baseline: no USAGE"
assert_eq "$(dq -d appdb -tAc "SELECT has_schema_privilege('acc','finance','CREATE')")" "f" "baseline: no CREATE"

# standalone grant USAGE
./grant-schema.sh grant acc appdb finance USAGE
assert_eq "$(dq -d appdb -tAc "SELECT has_schema_privilege('acc','finance','USAGE')")" "t" "USAGE granted"

# axdb grant CREATE
./axdb.sh grant-schema acc appdb finance CREATE
assert_eq "$(dq -d appdb -tAc "SELECT has_schema_privilege('acc','finance','CREATE')")" "t" "CREATE granted via axdb"

# revoke CREATE only, USAGE stays
./axdb.sh revoke-schema acc appdb finance CREATE
assert_eq "$(dq -d appdb -tAc "SELECT has_schema_privilege('acc','finance','CREATE')")" "f" "CREATE revoked"
assert_eq "$(dq -d appdb -tAc "SELECT has_schema_privilege('acc','finance','USAGE')")"  "t" "USAGE still present"

# ALL grants both
dq -c "CREATE ROLE acc2 LOGIN PASSWORD 'x';" >/dev/null
./grant-schema.sh grant acc2 appdb finance ALL
assert_eq "$(dq -d appdb -tAc "SELECT has_schema_privilege('acc2','finance','USAGE')")"  "t" "ALL -> USAGE"
assert_eq "$(dq -d appdb -tAc "SELECT has_schema_privilege('acc2','finance','CREATE')")" "t" "ALL -> CREATE"

# invalid privilege rejected
if ./grant-schema.sh grant acc appdb finance SELECT 2>/dev/null; then
  assert_eq "x" "y" "should reject invalid schema privilege"
else
  assert_eq "x" "x" "rejects invalid schema privilege"
fi

finish
```

- [ ] **Step 2: Chạy test, xác nhận FAIL**

Run: `bash docs/db-scripts/tests/test-schema-privs.sh 2>&1 | tail -12`
Expected: FAIL/err — `grant-schema.sh` chưa tồn tại.

- [ ] **Step 3: Tạo `docs/db-scripts/grant-schema.sh`**

```bash
#!/usr/bin/env bash
# Grant/revoke SCHEMA-level privileges (USAGE / CREATE / ALL) for a role.
# USAGE = may "enter" the schema and reference objects in it (needed to reach its tables).
# CREATE = may create new objects (tables, etc.) inside the schema.
# Usage: ./grant-schema.sh <grant|revoke> <role> <db> <schema> <USAGE|CREATE|ALL>
#   e.g.: ./grant-schema.sh grant  dev_a appdb finance USAGE
#         ./grant-schema.sh revoke dev_a appdb finance CREATE
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

ACTION="${1:-}"; ROLE="${2:-}"; DB="${3:-}"; SCH="${4:-}"; PRIV="${5:-}"
[ -n "$ACTION" ] && [ -n "$ROLE" ] && [ -n "$DB" ] && [ -n "$SCH" ] && [ -n "$PRIV" ] \
  || die "Missing arguments. See usage at the top."
role_exists "$ROLE" || die "Role '$ROLE' does not exist."
db_exists "$DB"     || die "Database '$DB' does not exist."
[ "$($PSQL -d "$DB" -tAc "SELECT 1 FROM information_schema.schemata WHERE schema_name='$SCH'")" = "1" ] \
  || die "Schema '$SCH' does not exist in '$DB'."

# normalise + validate the privilege keyword
P="$(printf '%s' "$PRIV" | tr '[:lower:]' '[:upper:]')"
case "$P" in USAGE|CREATE|ALL) ;; *) die "Privilege must be USAGE, CREATE, or ALL (got '$PRIV').";; esac

case "$ACTION" in
  grant)
    $PSQL -d "$DB" -v r="$ROLE" -v s="$SCH" <<SQL
GRANT $P ON SCHEMA :"s" TO :"r";
SQL
    echo ">> GRANT $P ON SCHEMA $SCH  ->  $ROLE  (db: $DB)"
    ;;
  revoke)
    $PSQL -d "$DB" -v r="$ROLE" -v s="$SCH" <<SQL
REVOKE $P ON SCHEMA :"s" FROM :"r";
SQL
    echo ">> REVOKE $P ON SCHEMA $SCH  <-  $ROLE  (db: $DB)"
    ;;
  *) die "ACTION must be 'grant' or 'revoke'.";;
esac
```
Then `chmod +x docs/db-scripts/grant-schema.sh`.

Note: `$P` is validated to a fixed whitelist (USAGE/CREATE/ALL) before it is expanded into the heredoc — no free-text SQL reaches the statement; `:"s"`/`:"r"` are psql-quoted identifiers.

- [ ] **Step 4: Thêm `cmd_grant_schema` vào `axdb.sh`**

Add function after `cmd_grant_group` (mirror the standalone logic):
```bash
cmd_grant_schema() {            # <grant|revoke> <role> <db> <schema> <USAGE|CREATE|ALL>
  local act="$1" role="${2:-}" db="${3:-}" sch="${4:-}" priv="${5:-}"
  [ -n "$role" ] && [ -n "$db" ] && [ -n "$sch" ] && [ -n "$priv" ] \
    || die "Usage: axdb.sh {grant-schema|revoke-schema} <role> <db> <schema> <USAGE|CREATE|ALL>"
  role_exists "$role" || die "Role '$role' does not exist."
  db_exists "$db"     || die "Database '$db' does not exist."
  [ "$($PSQL -d "$db" -tAc "SELECT 1 FROM information_schema.schemata WHERE schema_name='$sch'")" = "1" ] \
    || die "Schema '$sch' does not exist in '$db'."
  local p; p="$(printf '%s' "$priv" | tr '[:lower:]' '[:upper:]')"
  case "$p" in USAGE|CREATE|ALL) ;; *) die "Privilege must be USAGE, CREATE, or ALL (got '$priv').";; esac
  if [ "$act" = grant ]; then
    $PSQL -d "$db" -v r="$role" -v s="$sch" <<SQL
GRANT $p ON SCHEMA :"s" TO :"r";
SQL
    echo ">> GRANT $p ON SCHEMA $sch -> $role (db: $db)"
  else
    $PSQL -d "$db" -v r="$role" -v s="$sch" <<SQL
REVOKE $p ON SCHEMA :"s" FROM :"r";
SQL
    echo ">> REVOKE $p ON SCHEMA $sch <- $role (db: $db)"
  fi
}
```

Dispatch (after the `revoke-group)` branch):
```bash
  grant-schema)       cmd_grant_schema grant "$@";;
  revoke-schema)      cmd_grant_schema revoke "$@";;
```

`usage()` — add after the `revoke-group` line:
```
  grant-schema  <role> <db> <schema> <USAGE|CREATE|ALL>   Grant a schema-level privilege to a role
  revoke-schema <role> <db> <schema> <USAGE|CREATE|ALL>   Revoke a schema-level privilege
```

Menu — read the real menu first, then append one entry after item 27 (grant-group-style action prompt):
```
 28) Grant / revoke a SCHEMA privilege (USAGE/CREATE)
```
case branch (before `0)`):
```bash
      28) read -rp "Action [grant/revoke]: " a; read -rp "Role: " r; read -rp "Database: " d; read -rp "Schema: " s; read -rp "Privilege [USAGE/CREATE/ALL]: " p; _run cmd_grant_schema "$a" "$r" "$d" "$s" "$p" ;;
```
Bump the prompt `Select [0-27]` → `Select [0-28]`.

- [ ] **Step 5: Chạy test, xác nhận PASS**

Run: `bash docs/db-scripts/tests/test-schema-privs.sh 2>&1 | tail -12`
Expected: `== PASS=10 FAIL=0 ==`

- [ ] **Step 6: `bash -n` + commit**

```bash
bash -n docs/db-scripts/axdb.sh && echo "syntax OK"
git add docs/db-scripts/grant-schema.sh docs/db-scripts/axdb.sh docs/db-scripts/tests/test-schema-privs.sh
git commit -m "feat(db): grant-schema/revoke-schema — quyền cấp-schema (USAGE/CREATE/ALL)"
```

---

### Task 2: `schema-perm` — who holds USAGE/CREATE on a schema

**Files:**
- Modify: `docs/db-scripts/axdb.sh`
- Modify: `docs/db-scripts/list-access.sh`
- Test: `docs/db-scripts/tests/test-schema-perm.sh`

**Interfaces:**
- Consumes: harness; `create-schema.sh`; Task 1's `grant-schema`.
- Produces:
  - `axdb.sh schema-perm <db> <schema>`
  - `./list-access.sh schema-perm <db> <schema>`
  Both list every non-superuser role that effectively holds USAGE or CREATE on the schema (incl. via group membership), read from `has_schema_privilege`.

- [ ] **Step 1: Viết test thất bại `tests/test-schema-perm.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
trap pg_down EXIT
pg_up
make_db appdb appowner
./create-schema.sh finance appdb appowner          # creates finance_readonly / finance_readwrite (both hold USAGE)
dq -c "CREATE ROLE fi_user LOGIN PASSWORD 'x';" >/dev/null
dq -d appdb -c "GRANT finance_readwrite TO fi_user;" >/dev/null   # inherits USAGE via the group
dq -c "CREATE ROLE builder LOGIN PASSWORD 'x';" >/dev/null
./grant-schema.sh grant builder appdb finance CREATE >/dev/null    # direct CREATE

OUT="$(./axdb.sh schema-perm appdb finance)"
assert_contains "$OUT" "finance_readwrite" "lists the group holding USAGE"
assert_contains "$OUT" "fi_user"           "lists user with inherited USAGE"
assert_contains "$OUT" "builder"           "lists user with direct CREATE"

# a role with nothing does NOT appear
dq -c "CREATE ROLE nobody LOGIN PASSWORD 'x';" >/dev/null
case "$(./axdb.sh schema-perm appdb finance)" in
  *nobody*) assert_eq "n" "y" "role with no schema priv must not be listed";;
  *)        assert_eq "n" "n" "role with no schema priv is not listed";;
esac

# list-access path works too
assert_contains "$(./list-access.sh schema-perm appdb finance)" "builder" "list-access schema-perm works"

finish
```

- [ ] **Step 2: Chạy test, xác nhận FAIL**

Run: `bash docs/db-scripts/tests/test-schema-perm.sh 2>&1 | tail -10`
Expected: FAIL — "Invalid command: schema-perm".

- [ ] **Step 3: Thêm `cmd_schema_perm` vào `axdb.sh`**

Add function after `cmd_grant_schema`:
```bash
cmd_schema_perm() {            # <db> <schema>
  local db="${1:-}" sch="${2:-}"
  [ -n "$db" ] && [ -n "$sch" ] || die "Usage: axdb.sh schema-perm <db> <schema>"
  db_exists "$db" || die "Database '$db' does not exist."
  [ "$($PSQL -d "$db" -tAc "SELECT 1 FROM information_schema.schemata WHERE schema_name='$sch'")" = "1" ] \
    || die "Schema '$sch' does not exist in '$db'."
  $PSQL -d "$db" -v s="$sch" <<'SQL'
SELECT r.rolname AS role,
       CASE WHEN r.rolcanlogin THEN 'login' ELSE 'group' END AS type,
       CASE WHEN has_schema_privilege(r.rolname, :'s', 'USAGE')  THEN 'yes' ELSE '-' END AS usage_priv,
       CASE WHEN has_schema_privilege(r.rolname, :'s', 'CREATE') THEN 'yes' ELSE '-' END AS create_priv
FROM pg_roles r
WHERE r.rolname NOT LIKE 'pg\_%' AND NOT r.rolsuper
  AND (has_schema_privilege(r.rolname, :'s','USAGE') OR has_schema_privilege(r.rolname, :'s','CREATE'))
ORDER BY r.rolcanlogin DESC, r.rolname;
SQL
  echo "(superusers omitted — they bypass schema ACL; 'yes' may be inherited via a group)"
}
```

Dispatch (after `revoke-schema)`):
```bash
  schema-perm)        cmd_schema_perm "$@";;
```

`usage()` — add after the `schema-perm`/rename lines group:
```
  schema-perm <db> <schema>                   Show which roles hold USAGE/CREATE on a schema (effective)
```

Menu — append after item 28:
```
 29) Schema privilege overview (schema-perm)
```
case branch:
```bash
      29) read -rp "Database: " d; read -rp "Schema: " s; _run cmd_schema_perm "$d" "$s" ;;
```
Bump prompt `Select [0-28]` → `Select [0-29]`.

- [ ] **Step 4: Thêm nhánh `schema-perm` vào `list-access.sh`**

Trong `case "$CMD" in`, thêm trước `*)`:
```bash
  schema-perm)
    DB="${2:-}"; SCH="${3:-}"
    [ -n "$DB" ] && [ -n "$SCH" ] || die "Usage: ./list-access.sh schema-perm <db> <schema>"
    db_exists "$DB" || die "Database '$DB' does not exist."
    [ "$($PSQL -d "$DB" -tAc "SELECT 1 FROM information_schema.schemata WHERE schema_name='$SCH'")" = "1" ] \
      || die "Schema '$SCH' does not exist in '$DB'."
    $PSQL -d "$DB" -v s="$SCH" <<'SQL'
SELECT r.rolname AS role,
       CASE WHEN r.rolcanlogin THEN 'login' ELSE 'group' END AS type,
       CASE WHEN has_schema_privilege(r.rolname, :'s', 'USAGE')  THEN 'yes' ELSE '-' END AS usage_priv,
       CASE WHEN has_schema_privilege(r.rolname, :'s', 'CREATE') THEN 'yes' ELSE '-' END AS create_priv
FROM pg_roles r
WHERE r.rolname NOT LIKE 'pg\_%' AND NOT r.rolsuper
  AND (has_schema_privilege(r.rolname, :'s','USAGE') OR has_schema_privilege(r.rolname, :'s','CREATE'))
ORDER BY r.rolcanlogin DESC, r.rolname;
SQL
    ;;
```
Also add a usage-comment line at the top of `list-access.sh`:
```bash
#   ./list-access.sh schema-perm <db> <schema>   # roles holding USAGE/CREATE on a schema
```

- [ ] **Step 5: Chạy test, xác nhận PASS**

Run: `bash docs/db-scripts/tests/test-schema-perm.sh 2>&1 | tail -10`
Expected: `== PASS=5 FAIL=0 ==`

- [ ] **Step 6: Toàn bộ suite + commit**

```bash
bash -n docs/db-scripts/axdb.sh && echo "syntax OK"
for t in docs/db-scripts/tests/test-*.sh; do printf '%-40s ' "$(basename "$t")"; bash "$t" 2>&1 | tail -1; done
git add docs/db-scripts/axdb.sh docs/db-scripts/list-access.sh docs/db-scripts/tests/test-schema-perm.sh
git commit -m "feat(db): schema-perm — liệt kê role có USAGE/CREATE trên schema (has_schema_privilege)"
```

---

### Task 3: Docs + exec-bit

**Files:**
- Modify: `docs/db-scripts/README.md`
- Modify: `docs/axsvr-phase1-db.md`
- Modify: `docs/confluence/08-db-toolkit.md`
- Modify: `docs/confluence/10-operations.md`

- [ ] **Step 1: Add the three commands to `docs/db-scripts/README.md`** (English), in the schema-per-app section:
```
Schema-level privileges (rarely needed directly — prefer groups — but available):
    ./axdb.sh grant-schema  builder appdb finance CREATE   # let a role create objects in a schema
    ./axdb.sh revoke-schema builder appdb finance CREATE
    ./axdb.sh schema-perm   appdb finance                  # who holds USAGE/CREATE on the schema (effective)
Note: `grant`/`grant-group` already handle USAGE for the normal flow; use grant-schema for CREATE
or for granting USAGE to a role outside the group model.
```

- [ ] **Step 2: `docs/axsvr-phase1-db.md`** (Vietnamese) — thêm đoạn tương đương trong mục schema-per-app: 3 lệnh + lưu ý (USAGE thường tự có qua group/grant; grant-schema dùng cho CREATE hoặc cấp USAGE ngoài group; schema-perm để debug `permission denied for schema`).

- [ ] **Step 3: `docs/confluence/08-db-toolkit.md`** — add rows to the command-reference table:
  - `Grant / revoke a schema-level privilege (USAGE/CREATE) | ./axdb.sh grant-schema <role> <db> <schema> <priv> · revoke-schema`
  - `Show who holds USAGE/CREATE on a schema | ./axdb.sh schema-perm <db> <schema>`

- [ ] **Step 4: `docs/confluence/10-operations.md`** — add a short "Debug 'permission denied for schema'" subsection:
```
./axdb.sh schema-perm AXDEV finance          # does the role have USAGE? (effective, incl. via group)
./axdb.sh grant-schema <role> AXDEV finance USAGE   # grant it directly if needed
```

- [ ] **Step 5: exec-bit + commit**

```bash
mapfile -t SH < <(git ls-files 'docs/db-scripts/*.sh'); git update-index --chmod=+x "${SH[@]}"
git add docs/db-scripts/README.md docs/axsvr-phase1-db.md docs/confluence/08-db-toolkit.md docs/confluence/10-operations.md
git commit -m "docs(db): grant-schema/revoke-schema/schema-perm (README, phase1-db, confluence)"
```

---

## Ghi chú kiểm thử tổng
Sau Task 2, suite phải xanh (12 file test):
```bash
for t in docs/db-scripts/tests/test-*.sh; do printf '%-40s ' "$(basename "$t")"; bash "$t" 2>&1 | tail -1; done
```
Kỳ vọng: mỗi file `FAIL=0` (thêm test-schema-privs, test-schema-perm).
