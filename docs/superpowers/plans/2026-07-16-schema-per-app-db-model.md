# Schema-per-app DB Model — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Nâng toolkit `docs/db-scripts/` lên mô hình schema-per-app: thêm `create-schema.sh`, vá `setup-group-roles.sh` (thêm `FOR ROLE <owner>`), thêm tool `perm` (overview quyền theo user), wire vào `axdb.sh`, cập nhật docs; kèm runbook di chuyển `licasi` và hạ superuser `db_dev` trên DevDB.

**Architecture:** Các script bash gọi PostgreSQL qua biến `PSQL_ADMIN` (đã có trong `_common.sh`, mặc định `sudo -u postgres psql`). Test tự động bằng container PostgreSQL 17 dùng-một-lần: set `PSQL_ADMIN="docker exec -i <container> psql -U postgres"` để trỏ script vào container, chạy assertion bằng bash. Phần thao tác trên DevDB thật (migrate licasi, fix db_dev) không tự động hóa — viết thành runbook copy-paste.

**Tech Stack:** Bash, PostgreSQL 17 (psql), Docker (chỉ dùng khi chạy test).

## Global Constraints

- **PostgreSQL 17** — image test `postgres:17` (khớp production).
- **Giao diện script = tiếng Anh** (prompt, echo, tiêu đề cột, lỗi). Docs = tiếng Việt.
- **KHÔNG đổi tên 4 bảng `licasi_*`** (code app đã dùng). Di chuyển schema phải giữ nguyên tên.
- Script mới/sửa phải tôn trọng override `PSQL_ADMIN` (không hardcode `sudo -u postgres`).
- Quy ước tên: schema = tên project thường không dấu; group = `<schema>_readonly` / `<schema>_readwrite`.
- Commit **không** có dòng attribution/co-author (repo đang tắt attribution).
- Tương thích ngược: script cũ đang dùng model `public` không được vỡ.

---

### Task 1: Test harness (Docker PostgreSQL)

**Files:**
- Create: `docs/db-scripts/tests/lib.sh`

**Interfaces:**
- Produces (dùng cho mọi task test sau):
  - `pg_up` — dựng container `postgres:17` tên `axdb-scripts-test`, chờ sẵn sàng, `export PSQL_ADMIN`.
  - `pg_down` — xóa container.
  - `psql_q "<-d db>" "<sql>"` (thực chất: `dq -d <db> -c "<sql>"`) — helper query trả `-tA` (không viền).
  - `dq [args...]` — `docker exec -i axdb-scripts-test psql -U postgres -tA [args...]`.
  - `assert_eq <actual> <expected> <msg>`, `assert_contains <haystack> <needle> <msg>`.
  - `finish` — in `PASS=n FAIL=m`, exit 0 nếu FAIL=0 ngược lại exit 1.

- [ ] **Step 1: Viết `tests/lib.sh`**

```bash
#!/usr/bin/env bash
# Shared test harness for db-scripts: an ephemeral PostgreSQL 17 container
# is used as the admin target via PSQL_ADMIN override.
set -euo pipefail

PG_IMAGE="postgres:17"
PG_CONTAINER="axdb-scripts-test"

# Point the db-scripts at the container instead of a local socket.
export PSQL_ADMIN="docker exec -i $PG_CONTAINER psql -U postgres"

dq() { docker exec -i "$PG_CONTAINER" psql -U postgres -tA "$@"; }

pg_up() {
  docker rm -f "$PG_CONTAINER" >/dev/null 2>&1 || true
  docker run -d --name "$PG_CONTAINER" -e POSTGRES_PASSWORD=postgres "$PG_IMAGE" >/dev/null
  # Wait for readiness (sleep runs INSIDE the container).
  docker exec "$PG_CONTAINER" bash -c 'for i in $(seq 1 60); do pg_isready -U postgres >/dev/null 2>&1 && exit 0; sleep 0.5; done; exit 1' \
    || { echo "postgres not ready" >&2; return 1; }
}

pg_down() { docker rm -f "$PG_CONTAINER" >/dev/null 2>&1 || true; }

PASS=0; FAIL=0
assert_eq() { # actual expected msg
  if [ "$1" = "$2" ]; then PASS=$((PASS+1)); echo "  ok: $3";
  else FAIL=$((FAIL+1)); echo "  FAIL: $3 (got '$1' want '$2')"; fi
}
assert_contains() { # haystack needle msg
  case "$1" in *"$2"*) PASS=$((PASS+1)); echo "  ok: $3";;
    *) FAIL=$((FAIL+1)); echo "  FAIL: $3 (missing '$2')";; esac
}
finish() { echo "== PASS=$PASS FAIL=$FAIL =="; [ "$FAIL" -eq 0 ]; }

# Arrange helper: a database owned by a fresh non-login owner role.
# Usage: make_db <dbname> <ownername>
make_db() {
  dq -c "CREATE ROLE $2 NOLOGIN;" >/dev/null
  dq -c "CREATE DATABASE $1 OWNER $2 ENCODING UTF8;" >/dev/null
}
```

- [ ] **Step 2: Self-test the harness**

Run:
```bash
cd docs/db-scripts && bash -c 'source tests/lib.sh; pg_up; dq -c "SELECT 1"; make_db t1 o1; dq -d t1 -tAc "SELECT current_database()"; pg_down' 2>&1 | tail -5
```
Expected: in ra `1` và `t1`, không lỗi. (Lần đầu sẽ pull image `postgres:17` — chờ vài chục giây.)

- [ ] **Step 3: Commit**

```bash
git add docs/db-scripts/tests/lib.sh
git commit -m "test(db): thêm harness Docker PostgreSQL cho db-scripts"
```

---

### Task 2: Vá `setup-group-roles.sh` — thêm `[owner]` + `FOR ROLE`

**Files:**
- Modify: `docs/db-scripts/setup-group-roles.sh`
- Test: `docs/db-scripts/tests/test-setup-group-roles.sh`

**Interfaces:**
- Consumes: `tests/lib.sh` (Task 1).
- Produces: `./setup-group-roles.sh <db> [owner]` — nếu `owner` không truyền, mặc định = owner của `<db>` (đọc từ `pg_database`). Tạo `<db>_readonly`/`<db>_readwrite` + `ALTER DEFAULT PRIVILEGES FOR ROLE <owner>`.

- [ ] **Step 1: Viết test thất bại `tests/test-setup-group-roles.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
trap pg_down EXIT
pg_up
make_db appdb appowner

./setup-group-roles.sh appdb            # owner mặc định = appowner (owner của appdb)

# groups tồn tại
assert_eq "$(dq -tAc "SELECT 1 FROM pg_roles WHERE rolname='appdb_readonly'")"  "1" "appdb_readonly created"
assert_eq "$(dq -tAc "SELECT 1 FROM pg_roles WHERE rolname='appdb_readwrite'")" "1" "appdb_readwrite created"

# default privileges FOR ROLE appowner: bảng owner tạo SAU phải tự có quyền cho group
dq -d appdb -c "SET ROLE appowner; CREATE TABLE t_future(id int);" >/dev/null
assert_eq "$(dq -d appdb -tAc "SELECT has_table_privilege('appdb_readwrite','t_future','INSERT')")" "t" "readwrite auto-INSERT on future table"
assert_eq "$(dq -d appdb -tAc "SELECT has_table_privilege('appdb_readonly','t_future','SELECT')")"  "t" "readonly auto-SELECT on future table"
assert_eq "$(dq -d appdb -tAc "SELECT has_table_privilege('appdb_readonly','t_future','INSERT')")"  "f" "readonly has NO insert"

finish
```

- [ ] **Step 2: Chạy test, xác nhận FAIL**

Run: `bash docs/db-scripts/tests/test-setup-group-roles.sh 2>&1 | tail -8`
Expected: FAIL ở "auto-INSERT on future table" (vì bản cũ thiếu `FOR ROLE`, bảng do `appowner` tạo không được cấp).

- [ ] **Step 3: Sửa `setup-group-roles.sh`**

Thay toàn bộ nội dung sau dòng shebang/comment bằng:

```bash
#!/usr/bin/env bash
# Create readonly/readwrite GROUP ROLEs for a database + DEFAULT PRIVILEGES
# so tables created LATER by <owner> are granted automatically.
# Usage: ./setup-group-roles.sh <dbname> [owner]
#   owner defaults to the database owner if omitted.
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

DB="${1:-}"; [ -n "$DB" ] || read -rp "Database name: " DB
db_exists "$DB" || die "Database '$DB' does not exist."

OWNER="${2:-}"
if [ -z "$OWNER" ]; then
  OWNER="$($PSQL -tAc "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='$DB'")"
  [ -n "$OWNER" ] || die "Cannot resolve owner of '$DB'."
  echo ">> owner not given, using database owner: $OWNER"
fi
role_exists "$OWNER" || die "Owner role '$OWNER' does not exist."

RO="${DB}_readonly"
RW="${DB}_readwrite"

for g in "$RO" "$RW"; do
  role_exists "$g" || $PSQL -v g="$g" <<'SQL'
CREATE ROLE :"g" NOLOGIN;
SQL
done

$PSQL -d "$DB" -v db="$DB" -v ro="$RO" -v rw="$RW" -v owner="$OWNER" <<'SQL'
GRANT CONNECT ON DATABASE :"db" TO :"ro", :"rw";
GRANT USAGE ON SCHEMA public TO :"ro", :"rw";

GRANT SELECT ON ALL TABLES IN SCHEMA public TO :"ro";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO :"rw";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO :"rw";

-- Tables created LATER by <owner> are auto-granted (FOR ROLE = key fix):
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA public
  GRANT SELECT ON TABLES TO :"ro";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"rw";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO :"rw";
SQL

echo ">> Created 2 groups for '$DB' (default privileges FOR ROLE $OWNER):"
echo "   - $RO  (read-only)"
echo "   - $RW  (read + write)"
echo "   NOTE: default privileges apply to tables created by '$OWNER'. Always create tables as $OWNER."
```

- [ ] **Step 4: Chạy test, xác nhận PASS**

Run: `bash docs/db-scripts/tests/test-setup-group-roles.sh 2>&1 | tail -8`
Expected: `== PASS=5 FAIL=0 ==`

- [ ] **Step 5: Commit**

```bash
git add docs/db-scripts/setup-group-roles.sh docs/db-scripts/tests/test-setup-group-roles.sh
git commit -m "fix(db): setup-group-roles nhận [owner] + ALTER DEFAULT PRIVILEGES FOR ROLE"
```

---

### Task 3: `create-schema.sh` — schema + group + default privileges

**Files:**
- Create: `docs/db-scripts/create-schema.sh`
- Test: `docs/db-scripts/tests/test-create-schema.sh`

**Interfaces:**
- Consumes: `tests/lib.sh`.
- Produces: `./create-schema.sh <schema> <db> [owner]` — tạo schema `<schema>` trong `<db>` AUTHORIZATION `<owner>` (mặc định owner DB), group `<schema>_readonly`/`<schema>_readwrite` với USAGE + quyền bảng + default privileges `FOR ROLE <owner>` trong schema đó.

- [ ] **Step 1: Viết test thất bại `tests/test-create-schema.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
trap pg_down EXIT
pg_up
make_db appdb appowner

./create-schema.sh finance appdb appowner

# schema + groups
assert_eq "$(dq -d appdb -tAc "SELECT 1 FROM information_schema.schemata WHERE schema_name='finance'")" "1" "schema finance created"
assert_eq "$(dq -tAc "SELECT 1 FROM pg_roles WHERE rolname='finance_readonly'")"  "1" "finance_readonly created"
assert_eq "$(dq -tAc "SELECT 1 FROM pg_roles WHERE rolname='finance_readwrite'")" "1" "finance_readwrite created"

# bảng tạo trong schema bởi owner -> group tự có quyền
dq -d appdb -c "SET ROLE appowner; CREATE TABLE finance.fi_cost(id int);" >/dev/null
assert_eq "$(dq -d appdb -tAc "SELECT has_table_privilege('finance_readonly','finance.fi_cost','SELECT')")" "t" "readonly auto-SELECT in schema"
assert_eq "$(dq -d appdb -tAc "SELECT has_table_privilege('finance_readwrite','finance.fi_cost','INSERT')")" "t" "readwrite auto-INSERT in schema"

# cấp quyền chéo: user Production đọc toàn bộ Finance qua group
dq -c "CREATE ROLE prod_acc LOGIN PASSWORD 'x';" >/dev/null
dq -d appdb -c "GRANT finance_readonly TO prod_acc;" >/dev/null
assert_eq "$(dq -d appdb -tAc "SELECT has_table_privilege('prod_acc','finance.fi_cost','SELECT')")" "t" "prod_acc reads finance via group"
assert_eq "$(dq -d appdb -tAc "SELECT has_table_privilege('prod_acc','finance.fi_cost','INSERT')")" "f" "prod_acc cannot write finance"

finish
```

- [ ] **Step 2: Chạy test, xác nhận FAIL**

Run: `bash docs/db-scripts/tests/test-create-schema.sh 2>&1 | tail -8`
Expected: FAIL/err "No such file" hoặc script chưa tồn tại.

- [ ] **Step 3: Viết `create-schema.sh`**

```bash
#!/usr/bin/env bash
# Create a SCHEMA (per-app namespace) + readonly/readwrite group roles for it,
# with DEFAULT PRIVILEGES FOR ROLE <owner> so future tables are auto-granted.
# Usage: ./create-schema.sh <schema> <db> [owner]
#   owner defaults to the database owner if omitted.
#   e.g.: ./create-schema.sh finance appdb appowner
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

SCH="${1:-}"; [ -n "$SCH" ] || read -rp "Schema name: " SCH
DB="${2:-}";  [ -n "$DB" ]  || read -rp "Database name: " DB
db_exists "$DB" || die "Database '$DB' does not exist."

OWNER="${3:-}"
if [ -z "$OWNER" ]; then
  OWNER="$($PSQL -tAc "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='$DB'")"
  [ -n "$OWNER" ] || die "Cannot resolve owner of '$DB'."
  echo ">> owner not given, using database owner: $OWNER"
fi
role_exists "$OWNER" || die "Owner role '$OWNER' does not exist."

RO="${SCH}_readonly"
RW="${SCH}_readwrite"

for g in "$RO" "$RW"; do
  role_exists "$g" || $PSQL -v g="$g" <<'SQL'
CREATE ROLE :"g" NOLOGIN;
SQL
done

$PSQL -d "$DB" -v db="$DB" -v sch="$SCH" -v owner="$OWNER" -v ro="$RO" -v rw="$RW" <<'SQL'
CREATE SCHEMA IF NOT EXISTS :"sch" AUTHORIZATION :"owner";

GRANT CONNECT ON DATABASE :"db" TO :"ro", :"rw";
GRANT USAGE ON SCHEMA :"sch" TO :"ro", :"rw";

GRANT SELECT ON ALL TABLES IN SCHEMA :"sch" TO :"ro";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA :"sch" TO :"rw";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA :"sch" TO :"rw";

ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA :"sch"
  GRANT SELECT ON TABLES TO :"ro";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA :"sch"
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"rw";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA :"sch"
  GRANT USAGE, SELECT ON SEQUENCES TO :"rw";
SQL

echo ">> Created schema '$SCH' in '$DB' (owner: $OWNER) + groups:"
echo "   - $RO  (read-only)"
echo "   - $RW  (read + write)"
echo "   Assign a user:  GRANT $RW TO <user>;   and set  ALTER ROLE <user> SET search_path = $SCH, public;"
echo "   Cross-project read access:  GRANT $RO TO <other_user>;"
```

Sau đó cấp quyền chạy: `chmod +x docs/db-scripts/create-schema.sh`

- [ ] **Step 4: Chạy test, xác nhận PASS**

Run: `bash docs/db-scripts/tests/test-create-schema.sh 2>&1 | tail -8`
Expected: `== PASS=7 FAIL=0 ==`

- [ ] **Step 5: Commit**

```bash
git add docs/db-scripts/create-schema.sh docs/db-scripts/tests/test-create-schema.sh
git commit -m "feat(db): create-schema.sh — schema + group + default privileges per app"
```

---

### Task 4: Tool `perm` trong `list-access.sh` — overview theo user

**Files:**
- Modify: `docs/db-scripts/list-access.sh`
- Test: `docs/db-scripts/tests/test-perm.sh`

**Interfaces:**
- Consumes: `create-schema.sh` (Task 3), `tests/lib.sh`.
- Produces: `./list-access.sh perm <db> [user]` — không có `user`: bảng tóm tắt `role | super | groups | schema access`; có `user`: `schema | table | privileges` (quyền hiệu lực gồm kế thừa qua group).

- [ ] **Step 1: Viết test thất bại `tests/test-perm.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
trap pg_down EXIT
pg_up
make_db appdb appowner
./create-schema.sh finance appdb appowner
dq -d appdb -c "SET ROLE appowner; CREATE TABLE finance.fi_cost(id int);" >/dev/null
dq -c "CREATE ROLE prod_acc LOGIN PASSWORD 'x';" >/dev/null
dq -d appdb -c "GRANT finance_readonly TO prod_acc;" >/dev/null

SUM="$(./list-access.sh perm appdb)"
assert_contains "$SUM" "prod_acc" "summary lists prod_acc"
assert_contains "$SUM" "finance_readonly" "summary shows group"
assert_contains "$SUM" "finance: RO" "summary shows derived schema access"

DET="$(./list-access.sh perm appdb prod_acc)"
assert_contains "$DET" "finance" "drilldown shows schema finance"
assert_contains "$DET" "fi_cost" "drilldown shows table"
assert_contains "$DET" "SELECT" "drilldown shows SELECT priv"

finish
```

- [ ] **Step 2: Chạy test, xác nhận FAIL**

Run: `bash docs/db-scripts/tests/test-perm.sh 2>&1 | tail -8`
Expected: FAIL "Invalid command" (list-access chưa biết `perm`).

- [ ] **Step 3: Thêm nhánh `perm` vào `list-access.sh`**

Trong khối `case "$CMD" in`, thêm nhánh `perm)` ngay trước nhánh `*)`:

```bash
  perm)
    DB="${2:-}"; [ -n "$DB" ] || die "Missing db name."
    db_exists "$DB" || die "Database '$DB' does not exist."
    USER_ARG="${3:-}"
    if [ -z "$USER_ARG" ]; then
      # Level 1: summary of all login users
      $PSQL -d "$DB" <<'SQL'
SELECT r.rolname AS role,
       CASE WHEN r.rolsuper THEN 't' ELSE 'f' END AS super,
       COALESCE(string_agg(DISTINCT g.rolname, ', ' ORDER BY g.rolname), '(none)') AS groups,
       COALESCE(string_agg(DISTINCT
         CASE
           WHEN g.rolname LIKE '%\_readwrite' THEN regexp_replace(g.rolname,'_readwrite$','')||': RW'
           WHEN g.rolname LIKE '%\_readonly'  THEN regexp_replace(g.rolname,'_readonly$','') ||': RO'
         END, ', '), CASE WHEN r.rolsuper THEN 'ALL' ELSE '-' END) AS schema_access
FROM pg_roles r
LEFT JOIN pg_auth_members m ON m.member = r.oid
LEFT JOIN pg_roles g ON g.oid = m.roleid
WHERE r.rolcanlogin AND r.rolname NOT LIKE 'pg\_%'
GROUP BY r.rolname, r.rolsuper
ORDER BY r.rolsuper DESC, r.rolname;
SQL
    else
      # Level 2: effective per-table privileges for one user (incl. inherited via groups)
      role_exists "$USER_ARG" || die "Role '$USER_ARG' does not exist."
      $PSQL -d "$DB" -v u="$USER_ARG" <<'SQL'
SELECT n.nspname AS schema, c.relname AS "table",
       array_to_string(ARRAY[
         CASE WHEN has_table_privilege(:'u', c.oid, 'SELECT') THEN 'SELECT' END,
         CASE WHEN has_table_privilege(:'u', c.oid, 'INSERT') THEN 'INSERT' END,
         CASE WHEN has_table_privilege(:'u', c.oid, 'UPDATE') THEN 'UPDATE' END,
         CASE WHEN has_table_privilege(:'u', c.oid, 'DELETE') THEN 'DELETE' END
       ], ',') AS privileges
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog','information_schema')
  AND (has_table_privilege(:'u', c.oid,'SELECT') OR has_table_privilege(:'u', c.oid,'INSERT')
    OR has_table_privilege(:'u', c.oid,'UPDATE') OR has_table_privilege(:'u', c.oid,'DELETE'))
ORDER BY 1,2;
SQL
    fi
    ;;
```

Đồng thời cập nhật khối comment usage ở đầu file, thêm dòng:
```bash
#   ./list-access.sh perm <db> [user]  # permission overview (summary; or per-table drill-down for a user)
```

- [ ] **Step 4: Chạy test, xác nhận PASS**

Run: `bash docs/db-scripts/tests/test-perm.sh 2>&1 | tail -8`
Expected: `== PASS=6 FAIL=0 ==`

- [ ] **Step 5: Commit**

```bash
git add docs/db-scripts/list-access.sh docs/db-scripts/tests/test-perm.sh
git commit -m "feat(db): list-access perm — overview quyền theo user (tóm tắt + drill-down)"
```

---

### Task 5: Wire vào `axdb.sh` — subcommand `schema` + `perm`, vá group-setup owner

**Files:**
- Modify: `docs/db-scripts/axdb.sh`
- Test: `docs/db-scripts/tests/test-axdb.sh`

**Interfaces:**
- Consumes: `tests/lib.sh`.
- Produces: `axdb.sh schema <app> <db> [owner]`, `axdb.sh perm <db> [user]`; nhánh tạo group của axdb dùng `FOR ROLE <owner>` như Task 2.

- [ ] **Step 1: Đọc `axdb.sh` để định vị các nhánh**

Run:
```bash
grep -n "cmd_\|case \|ALTER DEFAULT PRIVILEGES\|usage\|dispatch\|\"schema\"\|\"perm\"\|setup-group\|groups" docs/db-scripts/axdb.sh | head -40
```
Expected: thấy hàm dispatch subcommand + nhánh tạo group (quanh dòng 131-137 theo spec). Ghi lại tên hàm/nhãn nhánh thực tế để chèn cho khớp style.

- [ ] **Step 2: Viết test smoke `tests/test-axdb.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
trap pg_down EXIT
pg_up
make_db appdb appowner

./axdb.sh schema hr appdb appowner
assert_eq "$(dq -d appdb -tAc "SELECT 1 FROM information_schema.schemata WHERE schema_name='hr'")" "1" "axdb schema hr created"
assert_eq "$(dq -tAc "SELECT 1 FROM pg_roles WHERE rolname='hr_readwrite'")" "1" "axdb hr_readwrite created"

# default privileges FOR ROLE owner qua axdb group setup
dq -d appdb -c "SET ROLE appowner; CREATE TABLE hr.emp(id int);" >/dev/null
assert_eq "$(dq -d appdb -tAc "SELECT has_table_privilege('hr_readwrite','hr.emp','INSERT')")" "t" "axdb schema default-priv works"

OUT="$(./axdb.sh perm appdb)"
assert_contains "$OUT" "appowner" "axdb perm lists roles"

finish
```

- [ ] **Step 3: Chạy test, xác nhận FAIL**

Run: `bash docs/db-scripts/tests/test-axdb.sh 2>&1 | tail -8`
Expected: FAIL — axdb chưa có subcommand `schema`/`perm`.

- [ ] **Step 4: Thêm subcommand `schema` và `perm` vào `axdb.sh`**

Trong hàm dispatch (nơi `case` xử lý subcommand), thêm 2 nhánh mới, gọi các hàm `cmd_schema`/`cmd_perm`. Style bám theo các `cmd_*` hiện có trong file. Dùng biến `$PSQL` sẵn có của axdb.

Nhánh dispatch (thêm cạnh các nhánh subcommand khác):
```bash
    schema) shift; cmd_schema "$@" ;;
    perm)   shift; cmd_perm "$@" ;;
```

Hàm `cmd_schema` (đặt cạnh các hàm `cmd_*`, dùng logic giống `create-schema.sh` Task 3):
```bash
cmd_schema() {
  local SCH="${1:-}" DB="${2:-}" OWNER="${3:-}"
  [ -n "$SCH" ] && [ -n "$DB" ] || die "Usage: axdb.sh schema <app> <db> [owner]"
  db_exists "$DB" || die "Database '$DB' does not exist."
  if [ -z "$OWNER" ]; then
    OWNER="$($PSQL -tAc "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='$DB'")"
    [ -n "$OWNER" ] || die "Cannot resolve owner of '$DB'."
    echo ">> owner not given, using database owner: $OWNER"
  fi
  role_exists "$OWNER" || die "Owner role '$OWNER' does not exist."
  local RO="${SCH}_readonly" RW="${SCH}_readwrite"
  for g in "$RO" "$RW"; do
    role_exists "$g" || $PSQL -v g="$g" <<'SQL'
CREATE ROLE :"g" NOLOGIN;
SQL
  done
  $PSQL -d "$DB" -v db="$DB" -v sch="$SCH" -v owner="$OWNER" -v ro="$RO" -v rw="$RW" <<'SQL'
CREATE SCHEMA IF NOT EXISTS :"sch" AUTHORIZATION :"owner";
GRANT CONNECT ON DATABASE :"db" TO :"ro", :"rw";
GRANT USAGE ON SCHEMA :"sch" TO :"ro", :"rw";
GRANT SELECT ON ALL TABLES IN SCHEMA :"sch" TO :"ro";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA :"sch" TO :"rw";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA :"sch" TO :"rw";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA :"sch" GRANT SELECT ON TABLES TO :"ro";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA :"sch" GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"rw";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA :"sch" GRANT USAGE, SELECT ON SEQUENCES TO :"rw";
SQL
  echo ">> schema '$SCH' ready in '$DB' (owner $OWNER): $RO / $RW"
}
```

Hàm `cmd_perm` (logic giống Task 4):
```bash
cmd_perm() {
  local DB="${1:-}" U="${2:-}"
  [ -n "$DB" ] || die "Usage: axdb.sh perm <db> [user]"
  db_exists "$DB" || die "Database '$DB' does not exist."
  if [ -z "$U" ]; then
    $PSQL -d "$DB" <<'SQL'
SELECT r.rolname AS role,
       CASE WHEN r.rolsuper THEN 't' ELSE 'f' END AS super,
       COALESCE(string_agg(DISTINCT g.rolname, ', ' ORDER BY g.rolname), '(none)') AS groups,
       COALESCE(string_agg(DISTINCT
         CASE WHEN g.rolname LIKE '%\_readwrite' THEN regexp_replace(g.rolname,'_readwrite$','')||': RW'
              WHEN g.rolname LIKE '%\_readonly'  THEN regexp_replace(g.rolname,'_readonly$','') ||': RO' END,
         ', '), CASE WHEN r.rolsuper THEN 'ALL' ELSE '-' END) AS schema_access
FROM pg_roles r
LEFT JOIN pg_auth_members m ON m.member = r.oid
LEFT JOIN pg_roles g ON g.oid = m.roleid
WHERE r.rolcanlogin AND r.rolname NOT LIKE 'pg\_%'
GROUP BY r.rolname, r.rolsuper ORDER BY r.rolsuper DESC, r.rolname;
SQL
  else
    role_exists "$U" || die "Role '$U' does not exist."
    $PSQL -d "$DB" -v u="$U" <<'SQL'
SELECT n.nspname AS schema, c.relname AS "table",
       array_to_string(ARRAY[
         CASE WHEN has_table_privilege(:'u', c.oid,'SELECT') THEN 'SELECT' END,
         CASE WHEN has_table_privilege(:'u', c.oid,'INSERT') THEN 'INSERT' END,
         CASE WHEN has_table_privilege(:'u', c.oid,'UPDATE') THEN 'UPDATE' END,
         CASE WHEN has_table_privilege(:'u', c.oid,'DELETE') THEN 'DELETE' END], ',') AS privileges
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE c.relkind='r' AND n.nspname NOT IN ('pg_catalog','information_schema')
  AND (has_table_privilege(:'u', c.oid,'SELECT') OR has_table_privilege(:'u', c.oid,'INSERT')
    OR has_table_privilege(:'u', c.oid,'UPDATE') OR has_table_privilege(:'u', c.oid,'DELETE'))
ORDER BY 1,2;
SQL
  fi
}
```

Nếu nhánh tạo group hiện có của axdb (theo Step 1, quanh dòng 131-137) chưa có `FOR ROLE`, vá y hệt Task 2: thêm tham số owner (mặc định owner DB) và chèn `FOR ROLE :"owner"` vào 3 câu `ALTER DEFAULT PRIVILEGES`. Cập nhật text `usage`/help của axdb để liệt kê `schema` và `perm`.

- [ ] **Step 5: Chạy test, xác nhận PASS**

Run: `bash docs/db-scripts/tests/test-axdb.sh 2>&1 | tail -8`
Expected: `== PASS=4 FAIL=0 ==`

- [ ] **Step 6: Chạy lại toàn bộ test để chắc không vỡ**

Run:
```bash
for t in docs/db-scripts/tests/test-*.sh; do echo "== $t =="; bash "$t" 2>&1 | tail -1; done
```
Expected: mỗi file in `== PASS=n FAIL=0 ==`.

- [ ] **Step 7: Commit**

```bash
git add docs/db-scripts/axdb.sh docs/db-scripts/tests/test-axdb.sh
git commit -m "feat(db): axdb.sh — subcommand schema + perm, group-setup dùng FOR ROLE owner"
```

---

### Task 6: Cập nhật docs (README + phase1-db)

**Files:**
- Modify: `docs/db-scripts/README.md`
- Modify: `docs/axsvr-phase1-db.md`

**Interfaces:** không có test tự động — nghiệm thu bằng đọc lại.

- [ ] **Step 1: Đọc 2 file để khớp cấu trúc/heading hiện có**

Run:
```bash
sed -n '1,60p' docs/db-scripts/README.md
grep -n "^#\|^##\|GRANT\|schema\|group" docs/axsvr-phase1-db.md | head -40
```

- [ ] **Step 2: Thêm mục "Schema-per-app" vào `docs/db-scripts/README.md`**

Chèn một mục mới (giữ văn phong tiếng Việt của file), nội dung tối thiểu:

```markdown
## Nhiều project / nhiều người: mô hình schema-per-app

Mỗi project = 1 schema; group `<schema>_readonly` / `<schema>_readwrite`; mỗi người = 1 login role gán vào group.

Tạo schema cho 1 app:
    ./create-schema.sh finance appdb appowner
    # hoặc: ./axdb.sh schema finance appdb appowner

Gán người vào project + để query khỏi ghi schema:
    GRANT finance_readwrite TO fi_user;
    ALTER ROLE fi_user SET search_path = finance, public;

Cấp quyền chéo project (Production đọc toàn bộ Finance):
    GRANT finance_readonly TO prod_acc;        -- gồm cả bảng mới sau này
    -- query phải ghi rõ schema: SELECT * FROM finance.fi_cost;

Xem tổng quan quyền:
    ./list-access.sh perm appdb            # tóm tắt toàn bộ user
    ./list-access.sh perm appdb prod_acc   # chi tiết từng bảng cho 1 user
    # tương đương: ./axdb.sh perm appdb [user]

Lưu ý: default-privileges gắn theo owner — luôn tạo bảng bằng đúng owner của schema/DB.
```

- [ ] **Step 3: Thêm mục tương ứng vào `docs/axsvr-phase1-db.md`**

Thêm một mục "Phân quyền nhiều project (schema-per-app)" với ví dụ Production/HR/Finance và bảng tra cấp quyền chéo (lấy từ spec mục 4). Bám heading/định dạng sẵn có của file.

- [ ] **Step 4: Commit**

```bash
git add docs/db-scripts/README.md docs/axsvr-phase1-db.md
git commit -m "docs(db): hướng dẫn schema-per-app, cấp quyền chéo, tool perm"
```

---

### Task 7: Runbook DevDB — di chuyển `licasi` + hạ `db_dev` (thao tác tay)

**Files:**
- Create: `docs/db-scripts/runbook-schema-migration.md`

**Interfaces:** đây là **thủ tục chạy trên DevDB thật** (`AXDEV`), không test tự động ở máy docs. Mỗi bước kèm truy vấn kiểm tra + kết quả kỳ vọng. Người vận hành (anh) chạy trực tiếp trên DB server.

- [ ] **Step 1: Viết `docs/db-scripts/runbook-schema-migration.md`**

Nội dung (copy-paste theo phong cách per-node, tên bảng giữ nguyên):

````markdown
# Runbook: di chuyển licasi sang schema + hạ superuser db_dev (DevDB AXDEV)

> Chạy TRÊN DB server, bằng `sudo -u postgres psql -d AXDEV` (hoặc `dbadmin`).
> KHÔNG đổi tên 4 bảng licasi_*. Có bước rollback.

## 0. Discovery — nắm hiện trạng
```sql
-- role app licasi + đang thuộc group nào
SELECT r.rolname AS role, r.rolcanlogin AS login,
       COALESCE(string_agg(g.rolname, ','), '(none)') AS groups
FROM pg_roles r
LEFT JOIN pg_auth_members m ON m.member=r.oid
LEFT JOIN pg_roles g ON g.oid=m.roleid
WHERE r.rolname NOT LIKE 'pg\_%'
GROUP BY 1,2 ORDER BY r.rolcanlogin DESC,1;

-- owner 4 bảng
SELECT tablename, tableowner FROM pg_tables WHERE tablename LIKE 'licasi_%';
```
Ghi lại: TÊN role app licasi (gọi là `<APP_USER>`) và OWNER 4 bảng (gọi là `<OWNER>`).

## 1. Tạo schema + group
```bash
cd /path/to/db-scripts
./create-schema.sh licasi AXDEV <OWNER>
```
Kiểm tra: `\dn` thấy `licasi`; `\du` thấy `licasi_readonly`, `licasi_readwrite`.

## 2. Chuyển 4 bảng vào schema (GIỮ NGUYÊN TÊN)
```sql
ALTER TABLE public.licasi_importlog        SET SCHEMA licasi;
ALTER TABLE public.licasi_production_lines SET SCHEMA licasi;
ALTER TABLE public.licasi_product_master   SET SCHEMA licasi;
ALTER TABLE public.licasi_weekly_data      SET SCHEMA licasi;
```
Kiểm tra: `SELECT tablename FROM pg_tables WHERE schemaname='licasi';` → 4 bảng.

## 3. Gán app user + search_path (để code KHÔNG phải sửa)
```sql
GRANT licasi_readwrite TO <APP_USER>;
ALTER ROLE <APP_USER> SET search_path = licasi, public;
```

## 4. Nghiệm thu bằng chính role app
```bash
psql -h <host> -U <APP_USER> -d AXDEV -c "SELECT count(*) FROM licasi_importlog;"
```
Kỳ vọng: chạy ra số dòng (query để trần vẫn thấy bảng nhờ search_path). Nếu lỗi "relation does not exist" → kiểm tra lại Bước 3.

## 5. Hạ superuser db_dev
> Chỉ làm sau khi chắc app KHÔNG kết nối bằng db_dev (xem Discovery).
```sql
ALTER ROLE db_dev NOSUPERUSER;         -- bỏ CREATEDB nếu không cần: ALTER ROLE db_dev NOCREATEDB;
```
Kiểm tra: `SELECT rolsuper FROM pg_roles WHERE rolname='db_dev';` → `f`.

## 6. Kiểm tra tổng quan
```bash
./list-access.sh perm AXDEV
./list-access.sh perm AXDEV <APP_USER>
```

## Rollback
```sql
-- đưa bảng về public
ALTER TABLE licasi.licasi_importlog        SET SCHEMA public;
ALTER TABLE licasi.licasi_production_lines SET SCHEMA public;
ALTER TABLE licasi.licasi_product_master   SET SCHEMA public;
ALTER TABLE licasi.licasi_weekly_data      SET SCHEMA public;
ALTER ROLE <APP_USER> RESET search_path;
-- khôi phục db_dev nếu cần: ALTER ROLE db_dev SUPERUSER;
```
````

- [ ] **Step 2: Commit**

```bash
git add docs/db-scripts/runbook-schema-migration.md
git commit -m "docs(db): runbook di chuyển licasi sang schema + hạ superuser db_dev (DevDB)"
```

- [ ] **Step 3 (thao tác tay, ngoài phiên code): anh chạy runbook trên DevDB**

Không tự động hóa được từ máy docs. Anh thực thi `runbook-schema-migration.md` trên DevDB theo thứ tự, dừng lại nếu bước nghiệm thu (4) hoặc (6) không đúng kỳ vọng.

---

## Dọn dẹp cuối

- [ ] **Xóa image test (tùy chọn)** nếu không muốn giữ:

```bash
docker rmi postgres:17 2>/dev/null || true
```

## Ghi chú kiểm thử tổng

Sau Task 5, toàn bộ suite phải xanh:
```bash
for t in docs/db-scripts/tests/test-*.sh; do echo "== $t =="; bash "$t" 2>&1 | tail -1; done
```
Kỳ vọng: 4 file, mỗi file `FAIL=0`.
