# grant-table / axdb grant — auto-GRANT USAGE on the target schema

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Khi cấp quyền trực tiếp lên một bảng nằm trong schema riêng, tự cấp luôn `USAGE` trên schema đó — vì PostgreSQL đòi **CẢ HAI** (`USAGE` trên schema **AND** quyền trên bảng); thiếu USAGE thì user dính `permission denied for schema X` dù `\dp` hiển thị đủ quyền bảng.

**Architecture:** Vá `grant-table.sh` (standalone) và nhánh tương ứng `cmd_grant_revoke` trong `axdb.sh` (bundle self-contained). Xác định schema đích bằng chính cách PostgreSQL phân giải: `to_regclass()` (theo `search_path` hiện hành) cho tên bảng, và tách trực tiếp cho dạng `ALL TABLES IN SCHEMA <x>`. Chỉ áp cho `grant`; `revoke` KHÔNG đụng USAGE.

**Tech Stack:** Bash, PostgreSQL 17, Docker (test qua harness `tests/lib.sh`).

## Global Constraints

- PostgreSQL 17. Giao diện script tiếng Anh. Honor `PSQL_ADMIN`. Commit KHÔNG có attribution trailer; không dùng `--no-verify`/`--amend`/`--no-edit`.
- `axdb.sh` self-contained — copy logic, KHÔNG source script rời.
- CHỈ đổi đường `grant`. `revoke` giữ nguyên hành vi (chỉ thêm 1 dòng NOTE).
- Không đổi chữ ký lệnh: `grant-table.sh <grant|revoke> <role> <db> <table> <privs>`; `axdb.sh grant|revoke <role> <db> <table> "<privs>"`.
- Giữ nguyên dạng `ALL TABLES IN SCHEMA <x>` mà `$tbl` đang hỗ trợ.

## Vì sao revoke KHÔNG gỡ USAGE

Role có thể còn quyền trên **bảng khác** trong cùng schema. Gỡ USAGE sẽ chặn luôn các bảng đó — tác dụng phụ ngoài ý muốn. Cắt hẳn thì operator tự chạy `REVOKE USAGE ON SCHEMA x FROM role;`. Chỉ in NOTE nhắc.

---

### Task 1: auto-USAGE cho `grant-table.sh` + `axdb.sh`

**Files:**
- Modify: `docs/db-scripts/grant-table.sh`
- Modify: `docs/db-scripts/axdb.sh`
- Test: `docs/db-scripts/tests/test-grant-usage.sh`

**Interfaces:**
- Consumes: harness `tests/lib.sh` (`pg_up`,`pg_down`,`dq`,`make_db`,`assert_eq`,`finish`); `create-schema.sh`.
- Produces: `grant` giờ tự chạy `GRANT USAGE ON SCHEMA <schema-của-bảng> TO <role>` trước khi grant bảng, và in ra điều đó. `revoke` không đổi (thêm NOTE).

- [ ] **Step 1: Viết test thất bại `tests/test-grant-usage.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
trap pg_down EXIT
pg_up
make_db appdb appowner
./create-schema.sh finance appdb appowner
dq -d appdb -c "SET ROLE appowner; CREATE TABLE finance.fi_cost(id int); CREATE TABLE finance.fi_fee(id int); CREATE TABLE public.plain_t(id int);" >/dev/null
dq -c "CREATE ROLE acc LOGIN PASSWORD 'x';" >/dev/null

# baseline: a fresh role has NO usage on a private schema
assert_eq "$(dq -d appdb -tAc "SELECT has_schema_privilege('acc','finance','USAGE')")" "f" "baseline: no USAGE on finance"

# 1. schema-qualified table -> USAGE auto-granted
./grant-table.sh grant acc appdb finance.fi_cost SELECT
assert_eq "$(dq -d appdb -tAc "SELECT has_schema_privilege('acc','finance','USAGE')")" "t" "USAGE auto-granted on finance"
assert_eq "$(dq -d appdb -tAc "SELECT has_table_privilege('acc','finance.fi_cost','SELECT')")" "t" "table SELECT granted"

# 2. revoke leaves USAGE alone (role may need it for other tables)
./grant-table.sh revoke acc appdb finance.fi_cost SELECT
assert_eq "$(dq -d appdb -tAc "SELECT has_table_privilege('acc','finance.fi_cost','SELECT')")" "f" "table SELECT revoked"
assert_eq "$(dq -d appdb -tAc "SELECT has_schema_privilege('acc','finance','USAGE')")" "t" "revoke did NOT drop schema USAGE"

# 3. ALL TABLES IN SCHEMA form also grants USAGE
dq -c "CREATE ROLE acc2 LOGIN PASSWORD 'x';" >/dev/null
./grant-table.sh grant acc2 appdb "ALL TABLES IN SCHEMA finance" SELECT
assert_eq "$(dq -d appdb -tAc "SELECT has_schema_privilege('acc2','finance','USAGE')")" "t" "USAGE granted for ALL TABLES IN SCHEMA form"
assert_eq "$(dq -d appdb -tAc "SELECT has_table_privilege('acc2','finance.fi_fee','SELECT')")" "t" "ALL TABLES form granted fi_fee"

# 4. bare table name in public still works (resolved via search_path)
dq -c "CREATE ROLE acc3 LOGIN PASSWORD 'x';" >/dev/null
./grant-table.sh grant acc3 appdb plain_t SELECT
assert_eq "$(dq -d appdb -tAc "SELECT has_table_privilege('acc3','public.plain_t','SELECT')")" "t" "bare table name grant works"

# 5. axdb.sh path behaves the same
dq -c "CREATE ROLE acc4 LOGIN PASSWORD 'x';" >/dev/null
./axdb.sh grant acc4 appdb finance.fi_cost SELECT
assert_eq "$(dq -d appdb -tAc "SELECT has_schema_privilege('acc4','finance','USAGE')")" "t" "axdb grant auto-grants USAGE"
assert_eq "$(dq -d appdb -tAc "SELECT has_table_privilege('acc4','finance.fi_cost','SELECT')")" "t" "axdb grant granted table"

finish
```

- [ ] **Step 2: Chạy test, xác nhận FAIL**

Run: `bash docs/db-scripts/tests/test-grant-usage.sh 2>&1 | tail -12`
Expected: FAIL ở "USAGE auto-granted on finance" (bản hiện tại chỉ grant bảng, không grant USAGE).

- [ ] **Step 3: Vá `grant-table.sh`**

Thay phần sau `db_exists "$DB" || die ...` bằng:

```bash
# Resolve the schema the target lives in, so we can ensure USAGE on it.
# PostgreSQL requires BOTH: USAGE on the schema AND a privilege on the table.
# Echoes the schema name, or nothing if it cannot be resolved.
target_schema() {
  local db="$1" tbl="$2"
  if printf '%s' "$tbl" | grep -qiE '^[[:space:]]*ALL[[:space:]]+TABLES[[:space:]]+IN[[:space:]]+SCHEMA[[:space:]]+'; then
    printf '%s' "$tbl" | sed -E 's/^[[:space:]]*[Aa][Ll][Ll][[:space:]]+[Tt][Aa][Bb][Ll][Ee][Ss][[:space:]]+[Ii][Nn][[:space:]]+[Ss][Cc][Hh][Ee][Mm][Aa][[:space:]]+//; s/[[:space:]]*;?[[:space:]]*$//'
    return 0
  fi
  # to_regclass resolves exactly like the GRANT will (same search_path); NULL if absent
  $PSQL -d "$db" -tAc "SELECT n.nspname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.oid = to_regclass('$tbl')"
}

case "$ACTION" in
  grant)
    SCH="$(target_schema "$DB" "$TBL")"
    if [ -n "$SCH" ]; then
      $PSQL -d "$DB" -v r="$ROLE" -v s="$SCH" <<'SQL'
GRANT USAGE ON SCHEMA :"s" TO :"r";
SQL
      echo ">> GRANT USAGE ON SCHEMA $SCH  ->  $ROLE   (required to reach tables inside it)"
    fi
    $PSQL -d "$DB" -v r="$ROLE" <<SQL
GRANT $PRIVS ON $TBL TO :"r";
SQL
    echo ">> GRANT $PRIVS ON $TBL  ->  $ROLE  (db: $DB)"
    ;;
  revoke)
    $PSQL -d "$DB" -v r="$ROLE" <<SQL
REVOKE $PRIVS ON $TBL FROM :"r";
SQL
    echo ">> REVOKE $PRIVS ON $TBL  <-  $ROLE  (db: $DB)"
    echo "   NOTE: USAGE on the schema was left in place (the role may still need it for other tables)."
    echo "         To cut off the whole schema: REVOKE USAGE ON SCHEMA <schema> FROM $ROLE;"
    ;;
  *) die "ACTION must be 'grant' or 'revoke'.";;
esac
```

- [ ] **Step 4: Vá `cmd_grant_revoke` trong `axdb.sh` giống hệt**

Thêm helper `_target_schema` cạnh các helper khác (sau `is_protected_role`):

```bash
# Resolve the schema a grant target lives in (for auto-USAGE). Echoes name or nothing.
_target_schema() {              # <db> <table-expr>
  local db="$1" tbl="$2"
  if printf '%s' "$tbl" | grep -qiE '^[[:space:]]*ALL[[:space:]]+TABLES[[:space:]]+IN[[:space:]]+SCHEMA[[:space:]]+'; then
    printf '%s' "$tbl" | sed -E 's/^[[:space:]]*[Aa][Ll][Ll][[:space:]]+[Tt][Aa][Bb][Ll][Ee][Ss][[:space:]]+[Ii][Nn][[:space:]]+[Ss][Cc][Hh][Ee][Mm][Aa][[:space:]]+//; s/[[:space:]]*;?[[:space:]]*$//'
    return 0
  fi
  $PSQL -d "$db" -tAc "SELECT n.nspname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.oid = to_regclass('$tbl')"
}
```

Trong `cmd_grant_revoke`, nhánh grant thêm phần USAGE trước khi grant bảng, nhánh revoke thêm 2 dòng NOTE — nội dung giống `grant-table.sh` ở Step 3 (dùng biến `$role`/`$db`/`$tbl`/`$privs` sẵn có của hàm).

- [ ] **Step 5: Chạy test, xác nhận PASS**

Run: `bash docs/db-scripts/tests/test-grant-usage.sh 2>&1 | tail -12`
Expected: `== PASS=10 FAIL=0 ==`

- [ ] **Step 6: Chạy toàn bộ suite (không hồi quy)**

Run:
```bash
for t in docs/db-scripts/tests/test-*.sh; do printf '%-40s ' "$(basename "$t")"; bash "$t" 2>&1 | tail -1; done
```
Expected: 11 file, mỗi file `FAIL=0`.

- [ ] **Step 7: Docs**

`docs/db-scripts/README.md` (English) — bổ sung vào mục schema-per-app:
```
Granting on a single table in a schema now also grants USAGE on that schema
(PostgreSQL needs BOTH — without USAGE you get "permission denied for schema x"
even though \dp shows the table privilege):
    ./axdb.sh grant acc AXDEV licasi.licasi_importlog SELECT
Revoking a table privilege does NOT drop the schema USAGE (the role may need it
for other tables). To cut off a whole schema: REVOKE USAGE ON SCHEMA x FROM acc;
```

`docs/axsvr-phase1-db.md` (Vietnamese) — đoạn tương đương tiếng Việt trong mục schema-per-app.

- [ ] **Step 8: Chuẩn hóa exec bit + commit**

```bash
mapfile -t SH < <(git ls-files 'docs/db-scripts/*.sh'); git update-index --chmod=+x "${SH[@]}"
git add docs/db-scripts/grant-table.sh docs/db-scripts/axdb.sh docs/db-scripts/tests/test-grant-usage.sh docs/db-scripts/README.md docs/axsvr-phase1-db.md
git commit -m "fix(db): grant tự cấp USAGE trên schema của bảng đích"
```
