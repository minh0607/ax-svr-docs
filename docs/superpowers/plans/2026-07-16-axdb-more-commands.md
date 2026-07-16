# axdb.sh — Additional Commands Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Hoàn thiện `axdb.sh` (và script rời tương ứng) cho mô hình schema-per-app: thêm `grant-group`/`revoke-group`, `set-search-path`, `show schemas`, `set-schema`, `drop-schema`; và bổ sung menu + usage cho các subcommand `schema`/`perm` đã có nhưng chưa lên menu.

**Architecture:** Bám sát pattern sẵn có của `axdb.sh` — hàm `cmd_*`, dispatch `case`, entry trong `usage()` và `menu()`, dùng `$PSQL`/`role_exists`/`db_exists`/`die`. SQL có biến truyền qua STDIN heredoc; identifier động dùng `:"var"` (psql) hoặc bash-expand trong heredoc không-quote (đúng như `cmd_grant_revoke`/`cmd_create_table`). Test tự động qua Docker PostgreSQL 17 harness `docs/db-scripts/tests/lib.sh` (đã có).

**Tech Stack:** Bash, PostgreSQL 17, Docker (test).

## Global Constraints

- PostgreSQL 17 — test image `postgres:17`.
- Giao diện script (prompt, echo, tiêu đề cột, lỗi) = tiếng Anh. Docs = tiếng Việt (trừ `docs/db-scripts/README.md` đã là tiếng Anh).
- Honor `PSQL_ADMIN` override — không hardcode `sudo -u postgres`.
- Group naming `<schema>_readonly` / `<schema>_readwrite`.
- Commit messages KHÔNG có dòng attribution/co-author.
- `axdb.sh` là bản self-contained — thêm logic trực tiếp, KHÔNG source script rời (đúng quy ước bundle).
- KHÔNG sửa/đổi hành vi các subcommand cũ; chỉ thêm.
- Menu hiện có mục 0–18; thêm mục mới nối tiếp (19+) và cập nhật dải chọn.

---

### Task A: `grant-group` / `revoke-group` — cấp/thu group cho user đang có

**Files:**
- Modify: `docs/db-scripts/axdb.sh`
- Create: `docs/db-scripts/grant-group.sh`
- Test: `docs/db-scripts/tests/test-grant-group.sh`

**Interfaces:**
- Consumes: harness `tests/lib.sh` (`pg_up`,`pg_down`,`dq`,`make_db`,`assert_eq`,`finish`); `create-schema.sh` (arrange groups).
- Produces:
  - `axdb.sh grant-group <user> <group>` / `axdb.sh revoke-group <user> <group>`
  - `./grant-group.sh <grant|revoke> <user> <group>`

- [ ] **Step 1: Viết test thất bại `tests/test-grant-group.sh`**

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

# standalone script
./grant-group.sh grant prod_acc finance_readonly
assert_eq "$(dq -d appdb -tAc "SELECT has_table_privilege('prod_acc','finance.fi_cost','SELECT')")" "t" "standalone grant-group gives read"
./grant-group.sh revoke prod_acc finance_readonly
assert_eq "$(dq -d appdb -tAc "SELECT has_table_privilege('prod_acc','finance.fi_cost','SELECT')")" "f" "standalone revoke-group removes read"

# axdb.sh subcommands
./axdb.sh grant-group prod_acc finance_readonly
assert_eq "$(dq -d appdb -tAc "SELECT has_table_privilege('prod_acc','finance.fi_cost','SELECT')")" "t" "axdb grant-group gives read"
./axdb.sh revoke-group prod_acc finance_readonly
assert_eq "$(dq -d appdb -tAc "SELECT has_table_privilege('prod_acc','finance.fi_cost','SELECT')")" "f" "axdb revoke-group removes read"

# error: nonexistent group
if ./axdb.sh grant-group prod_acc nope_group 2>/dev/null; then
  assert_eq "ok" "fail" "grant-group should reject missing group"
else
  assert_eq "ok" "ok" "grant-group rejects missing group"
fi

finish
```

- [ ] **Step 2: Chạy test, xác nhận FAIL**

Run: `bash docs/db-scripts/tests/test-grant-group.sh 2>&1 | tail -8`
Expected: FAIL/err — `grant-group.sh` chưa tồn tại; `axdb.sh grant-group` là "Invalid command".

- [ ] **Step 3: Tạo `docs/db-scripts/grant-group.sh`**

```bash
#!/usr/bin/env bash
# Grant/revoke GROUP ROLE membership for a user (role membership — NOT table privileges).
# Use this to assign a user to a project group, or to give cross-project access.
# Usage: ./grant-group.sh <grant|revoke> <user> <group>
#   e.g.: ./grant-group.sh grant  dev_a finance_readonly
#         ./grant-group.sh revoke dev_a finance_readonly
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

ACTION="${1:-}"; USER_="${2:-}"; GROUP="${3:-}"
[ -n "$ACTION" ] && [ -n "$USER_" ] && [ -n "$GROUP" ] || die "Missing arguments. See usage at the top."
role_exists "$USER_" || die "Role '$USER_' does not exist."
role_exists "$GROUP" || die "Group role '$GROUP' does not exist."

case "$ACTION" in
  grant)
    $PSQL -v u="$USER_" -v g="$GROUP" <<'SQL'
GRANT :"g" TO :"u";
SQL
    echo ">> GRANT group $GROUP -> $USER_"
    ;;
  revoke)
    $PSQL -v u="$USER_" -v g="$GROUP" <<'SQL'
REVOKE :"g" FROM :"u";
SQL
    echo ">> REVOKE group $GROUP <- $USER_"
    ;;
  *) die "ACTION must be 'grant' or 'revoke'.";;
esac
```

Then: `chmod +x docs/db-scripts/grant-group.sh`

- [ ] **Step 4: Thêm `cmd_grant_group` vào `axdb.sh`**

Thêm hàm (đặt ngay sau `cmd_grant_revoke`, khoảng dòng 233):

```bash
cmd_grant_group() {             # <grant|revoke> <user> <group>
  local act="$1" user="${2:-}" grp="${3:-}"
  [ -n "$user" ] && [ -n "$grp" ] || die "Usage: axdb.sh {grant-group|revoke-group} <user> <group>"
  role_exists "$user" || die "Role '$user' does not exist."
  role_exists "$grp"  || die "Group role '$grp' does not exist."
  if [ "$act" = grant ]; then
    $PSQL -v u="$user" -v g="$grp" <<'SQL'
GRANT :"g" TO :"u";
SQL
    echo ">> GRANT group $grp -> $user"
  else
    $PSQL -v u="$user" -v g="$grp" <<'SQL'
REVOKE :"g" FROM :"u";
SQL
    echo ">> REVOKE group $grp <- $user"
  fi
}
```

Trong khối dispatch `case "$cmd" in` (khoảng dòng 610), thêm sau nhánh `revoke)`:

```bash
  grant-group)        cmd_grant_group grant "$@";;
  revoke-group)       cmd_grant_group revoke "$@";;
```

Trong `usage()`, thêm sau dòng `revoke ...`:

```
  grant-group  <user> <group>                 Add a user to a group (role membership: project / cross-project)
  revoke-group <user> <group>                 Remove a user from a group
```

Trong `menu()`, thêm mục mới (sau mục 18, trước `0) Exit`):

```
 19) Add / remove user to a group (grant-group / revoke-group)
```

và nhánh xử lý trong `case "$ch" in` (trước `0)`):

```bash
      19) read -rp "Action [grant/revoke]: " a; read -rp "User: " u; read -rp "Group: " g; _run cmd_grant_group "$a" "$u" "$g" ;;
```

Cập nhật dòng `read -rp "Select [0-18]: "` → `Select [0-19]:`.

- [ ] **Step 5: Chạy test, xác nhận PASS**

Run: `bash docs/db-scripts/tests/test-grant-group.sh 2>&1 | tail -8`
Expected: `== PASS=5 FAIL=0 ==`

- [ ] **Step 6: Commit**

```bash
git add docs/db-scripts/axdb.sh docs/db-scripts/grant-group.sh docs/db-scripts/tests/test-grant-group.sh
git commit -m "feat(db): grant-group/revoke-group — cấp/thu group cho user (project + chéo project)"
```

---

### Task B: `set-search-path` — đặt search_path cho user

**Files:**
- Modify: `docs/db-scripts/axdb.sh`
- Test: `docs/db-scripts/tests/test-set-search-path.sh`

**Interfaces:**
- Consumes: harness.
- Produces: `axdb.sh set-search-path <user> <schema[,schema2]|--reset>` — set `ALTER ROLE <user> SET search_path = <schemas>, public` (tự thêm `public` nếu chưa có); `--reset` gỡ về mặc định.

- [ ] **Step 1: Viết test thất bại `tests/test-set-search-path.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
trap pg_down EXIT
pg_up
dq -c "CREATE ROLE app_user LOGIN PASSWORD 'x';" >/dev/null

# helper: the effective search_path string stored for the role (empty if none)
cfg() { dq -tAc "SELECT COALESCE(array_to_string(rolconfig,'|'),'') FROM pg_roles WHERE rolname='app_user'"; }

# single schema -> contains the schema AND public appended
./axdb.sh set-search-path app_user finance
V="$(cfg)"
assert_contains "$V" "search_path=" "single: search_path set"
assert_contains "$V" "finance" "single: contains schema finance"
assert_contains "$V" "public" "single: public auto-appended"

# public given explicitly -> still valid, contains hr + public (exactly one public)
./axdb.sh set-search-path app_user "hr,public"
V="$(cfg)"
assert_contains "$V" "hr" "multi: contains hr"
assert_eq "$(printf '%s' "$V" | grep -o public | wc -l | tr -d ' ')" "1" "multi: public not duplicated"

# reset -> no rolconfig
./axdb.sh set-search-path app_user --reset
assert_eq "$(cfg)" "" "reset clears search_path"

finish
```

- [ ] **Step 2: Chạy test, xác nhận FAIL**

Run: `bash docs/db-scripts/tests/test-set-search-path.sh 2>&1 | tail -8`
Expected: FAIL — "Invalid command: set-search-path".

- [ ] **Step 3: Thêm `cmd_set_search_path` vào `axdb.sh`**

Thêm hàm (đặt sau `cmd_grant_group`):

```bash
cmd_set_search_path() {         # <user> <schema[,schema2]|--reset>
  local user="${1:-}" path="${2:-}"
  [ -n "$user" ] && [ -n "$path" ] || die "Usage: axdb.sh set-search-path <user> <schema[,schema2]|--reset>"
  role_exists "$user" || die "Role '$user' does not exist."
  if [ "$path" = "--reset" ]; then
    $PSQL -v u="$user" <<'SQL'
ALTER ROLE :"u" RESET search_path;
SQL
    echo ">> search_path reset for $user"
    return 0
  fi
  # Build a quoted identifier list; append "public" if the caller did not include it.
  local -a parts=(); local p seen=0
  IFS=',' read -ra raw <<< "$path"
  for p in "${raw[@]}"; do
    p="${p// /}"; [ -z "$p" ] && continue
    [ "$p" = public ] && seen=1
    parts+=("\"$p\"")
  done
  [ "${#parts[@]}" -gt 0 ] || die "No schema given."
  [ "$seen" = 1 ] || parts+=('"public"')
  local joined; joined="$(IFS=,; echo "${parts[*]}")"
  # $joined is bash-expanded into the (unquoted) heredoc, like cmd_grant_revoke does with identifiers.
  $PSQL -v u="$user" <<SQL
ALTER ROLE :"u" SET search_path = $joined;
SQL
  echo ">> search_path for $user set to: $joined"
}
```

Dispatch (sau `revoke-group)`):

```bash
  set-search-path)    cmd_set_search_path "$@";;
```

`usage()` (sau dòng `revoke-group ...`):

```
  set-search-path <user> <schema[,schema2]|--reset>   Set a user's search_path (auto-appends public); --reset clears it
```

`menu()` — thêm mục:

```
 20) Set a user's search_path
```

nhánh case (trước `0)`):

```bash
      20) read -rp "User: " u; read -rp "search_path (e.g. finance  or  --reset): " p; _run cmd_set_search_path "$u" "$p" ;;
```

Cập nhật dòng chọn: `Select [0-20]:`.

- [ ] **Step 4: Chạy test, xác nhận PASS**

Run: `bash docs/db-scripts/tests/test-set-search-path.sh 2>&1 | tail -8`
Expected: `== PASS=6 FAIL=0 ==`

- [ ] **Step 5: Commit**

```bash
git add docs/db-scripts/axdb.sh docs/db-scripts/tests/test-set-search-path.sh
git commit -m "feat(db): set-search-path — đặt search_path cho user (schema-per-app transparent)"
```

---

### Task C: `show schemas` + `set-schema` + `drop-schema`

**Files:**
- Modify: `docs/db-scripts/axdb.sh`
- Test: `docs/db-scripts/tests/test-schema-ops.sh`

**Interfaces:**
- Consumes: harness; `create-schema.sh`.
- Produces:
  - `axdb.sh show schemas <db>` — list schemas + owner.
  - `axdb.sh set-schema <db> <table> <schema>` — `ALTER TABLE <table> SET SCHEMA <schema>` (giữ nguyên tên bảng).
  - `axdb.sh drop-schema <db> <schema> [--cascade]` — DROP SCHEMA (RESTRICT mặc định), có re-type xác nhận.

- [ ] **Step 1: Viết test thất bại `tests/test-schema-ops.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
trap pg_down EXIT
pg_up
make_db appdb appowner
./create-schema.sh finance appdb appowner

# show schemas lists finance + owner
OUT="$(./axdb.sh show schemas appdb)"
assert_contains "$OUT" "finance" "show schemas lists finance"
assert_contains "$OUT" "appowner" "show schemas shows owner"

# set-schema moves a public table into finance, name unchanged
dq -d appdb -c "SET ROLE appowner; CREATE TABLE public.legacy_t(id int);" >/dev/null
./axdb.sh set-schema appdb public.legacy_t finance
assert_eq "$(dq -d appdb -tAc "SELECT schemaname FROM pg_tables WHERE tablename='legacy_t'")" "finance" "set-schema moved table to finance"
assert_eq "$(dq -d appdb -tAc "SELECT count(*) FROM pg_tables WHERE schemaname='finance' AND tablename='legacy_t'")" "1" "table name unchanged after move"

# drop-schema RESTRICT refuses when non-empty (feed confirmation via stdin)
if printf 'finance\n' | ./axdb.sh drop-schema appdb finance 2>/dev/null; then
  assert_eq "restrict" "blocked" "drop-schema RESTRICT should fail on non-empty schema"
else
  assert_eq "restrict" "restrict" "drop-schema RESTRICT blocks non-empty schema"
fi

# drop-schema --cascade removes it
printf 'finance\n' | ./axdb.sh drop-schema appdb finance --cascade
assert_eq "$(dq -d appdb -tAc "SELECT count(*) FROM information_schema.schemata WHERE schema_name='finance'")" "0" "drop-schema --cascade removed schema"

# protected schema refused
if printf 'public\n' | ./axdb.sh drop-schema appdb public 2>/dev/null; then
  assert_eq "prot" "blocked" "drop-schema should refuse public"
else
  assert_eq "prot" "prot" "drop-schema refuses public"
fi

finish
```

- [ ] **Step 2: Chạy test, xác nhận FAIL**

Run: `bash docs/db-scripts/tests/test-schema-ops.sh 2>&1 | tail -8`
Expected: FAIL — `show schemas` báo "Missing"/invalid, `set-schema`/`drop-schema` "Invalid command".

- [ ] **Step 3: Thêm code vào `axdb.sh`**

3a. Trong `cmd_show()`, thêm nhánh `schemas)` (ngay trước `dbs)` hoặc sau, cùng cấp trong `case "${1:-}" in`):

```bash
    schemas)
      local dsc="${2:-}"; [ -n "$dsc" ] || die "Missing database."; db_exists "$dsc" || die "Database '$dsc' does not exist."
      $PSQL -d "$dsc" <<'SQL'
SELECT n.nspname AS schema, pg_get_userbyid(n.nspowner) AS owner
FROM pg_namespace n
WHERE n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
ORDER BY 1;
SQL
      ;;
```

Và cập nhật dòng `die "show <dbs|tables ...>"` để liệt kê `schemas <db>`.

3b. Thêm 2 hàm (sau `cmd_set_owner`):

```bash
cmd_set_schema() {              # <db> <table> <schema>
  local d="${1:-}" t="${2:-}" s="${3:-}"
  [ -n "$d" ] && [ -n "$t" ] && [ -n "$s" ] || die "Usage: axdb.sh set-schema <db> <table> <schema>"
  db_exists "$d" || die "Database '$d' does not exist."
  # $t bash-expands (may be schema-qualified, e.g. public.foo); :"s" is psql-interpolated
  $PSQL -d "$d" -v s="$s" <<SQL
ALTER TABLE $t SET SCHEMA :"s";
SQL
  echo ">> Moved table $t -> schema $s (db: $d). Table name unchanged."
}

cmd_drop_schema() {             # <db> <schema> [--cascade]
  local d="${1:-}" s="${2:-}" mode="${3:-}"
  [ -n "$d" ] && [ -n "$s" ] || die "Usage: axdb.sh drop-schema <db> <schema> [--cascade]"
  db_exists "$d" || die "Database '$d' does not exist."
  case "$s" in public|information_schema|pg_*) die "'$s' is a protected schema.";; esac
  local ntables; ntables="$($PSQL -d "$d" -tAc "SELECT count(*) FROM pg_tables WHERE schemaname='$s'")"
  echo "Schema: $s (db: $d) | tables: $ntables"
  [ "$mode" = "--cascade" ] && echo "⚠️  CASCADE — will also drop all $ntables table(s) in it."
  local typed; read -rp "Re-type the EXACT schema name to confirm: " typed
  [ "$typed" = "$s" ] || die "Does not match. Cancelled."
  if [ "$mode" = "--cascade" ]; then
    $PSQL -d "$d" -v s="$s" <<'SQL'
DROP SCHEMA :"s" CASCADE;
SQL
  else
    $PSQL -d "$d" -v s="$s" <<'SQL'
DROP SCHEMA :"s" RESTRICT;
SQL
  fi
  echo ">> Dropped schema: $s (group roles ${s}_readonly/${s}_readwrite remain — DROP ROLE them if unused)."
}
```

3c. Dispatch (sau `set-owner)`):

```bash
  set-schema)         cmd_set_schema "$@";;
  drop-schema)        cmd_drop_schema "$@";;
```

3d. `usage()` — thêm:

```
  set-schema  <db> <table> <schema>           Move a table into a schema (table name unchanged)
  drop-schema <db> <schema> [--cascade]       Drop a schema (RESTRICT by default; re-type to confirm)
```

và trong dòng `show ...` của usage, đổi để có `schemas <db>`:
```
  show schemas <db>                           List schemas (owner)
```

3e. `menu()` — thêm mục:

```
 21) Move table into a schema (set-schema)
 22) Drop schema (safe)
```

nhánh case (trước `0)`):

```bash
      21) read -rp "Database: " d; read -rp "Table (or schema.table): " t; read -rp "Target schema: " s; _run cmd_set_schema "$d" "$t" "$s" ;;
      22) read -rp "Database: " d; read -rp "Schema: " s; read -rp "Cascade? [Enter=no / --cascade]: " m; _run cmd_drop_schema "$d" "$s" "${m:-}" ;;
```

Và trong mục 18 (show submenu) thêm `schemas`:
```bash
            schemas)   read -rp "Database: " d; _run cmd_show schemas "$d";;
```
cùng cập nhật prompt gợi ý của mục 18 để có `schemas`.

Cập nhật dòng chọn: `Select [0-22]:`.

- [ ] **Step 4: Chạy test, xác nhận PASS**

Run: `bash docs/db-scripts/tests/test-schema-ops.sh 2>&1 | tail -10`
Expected: `== PASS=7 FAIL=0 ==`

- [ ] **Step 5: Commit**

```bash
git add docs/db-scripts/axdb.sh docs/db-scripts/tests/test-schema-ops.sh
git commit -m "feat(db): show schemas + set-schema + drop-schema"
```

---

### Task D: Menu/usage cho `schema` & `perm` (mục 1) + docs

**Files:**
- Modify: `docs/db-scripts/axdb.sh` (menu + usage only)
- Modify: `docs/db-scripts/README.md`
- Modify: `docs/axsvr-phase1-db.md`
- Test: `docs/db-scripts/tests/test-axdb.sh` (thêm smoke cho menu entries không bắt buộc; nếu khó thì bỏ qua — xem Step)

**Interfaces:** không có logic mới; chỉ hoàn thiện UI + docs. `schema`/`perm` đã có subcommand từ nhánh trước.

- [ ] **Step 1: Thêm mục menu cho `schema` & `perm`**

Trong `menu()`, thêm 2 mục (đặt gần nhóm nhóm quyền/schema, ví dụ sau mục 5 "Create group roles" về mặt liệt kê — nhưng đánh số nối tiếp để không xáo trộn số cũ):

```
 23) Create schema for an app (schema)
 24) Permission overview (perm)
```

nhánh case (trước `0)`):

```bash
      23) read -rp "Schema/app name: " s; read -rp "Database: " d; read -rp "Owner (empty=db owner): " o; _run cmd_schema "$s" "$d" "$o" ;;
      24) read -rp "Database: " d; read -rp "User (empty=summary of all): " u; _run cmd_perm "$d" "$u" ;;
```

Cập nhật dòng chọn: `Select [0-24]:`.

(usage đã có `schema`/`perm` từ nhánh trước — kiểm tra và giữ nguyên; nếu thiếu thì bổ sung.)

- [ ] **Step 2: Smoke test menu bằng cách kiểm cú pháp + dispatch tồn tại**

Vì menu là tương tác, không viết test tự động cho lựa chọn menu. Thay vào đó xác minh:

Run:
```bash
bash -n docs/db-scripts/axdb.sh && echo "syntax OK"
./axdb.sh help | grep -E "schema|perm|grant-group|set-search-path|set-schema|drop-schema"
```
Expected: `syntax OK`, và các dòng usage liệt kê đủ các lệnh trên.

- [ ] **Step 3: Chạy lại TOÀN BỘ suite (đảm bảo không vỡ)**

Run:
```bash
for t in docs/db-scripts/tests/test-*.sh; do echo "== $t =="; bash "$t" 2>&1 | tail -1; done
```
Expected: mỗi file `FAIL=0`.

- [ ] **Step 4: Cập nhật docs**

`docs/db-scripts/README.md` (English) — trong mục schema-per-app đã có, thêm các lệnh mới vào phần ví dụ:
```
Assign a user to a project (or cross-project) — no raw SQL needed:
    ./axdb.sh grant-group  fi_user finance_readwrite
    ./axdb.sh set-search-path fi_user finance
    ./axdb.sh grant-group  prod_acc finance_readonly   # cross-project read
    ./axdb.sh revoke-group prod_acc finance_readonly

Inspect / manage schemas:
    ./axdb.sh show schemas appdb
    ./axdb.sh set-schema  appdb public.legacy_t finance   # move a table in, name kept
    ./axdb.sh drop-schema appdb finance [--cascade]
```

`docs/axsvr-phase1-db.md` (Vietnamese) — trong mục "Phân quyền nhiều project (schema-per-app)", thêm đoạn tương đương bằng tiếng Việt (gán user vào project bằng `grant-group` + `set-search-path`, quyền chéo bằng `grant-group`, và các lệnh quản lý schema). Bám heading/định dạng hiện có, chỉ thêm — không sửa nội dung cũ.

- [ ] **Step 5: Commit**

```bash
git add docs/db-scripts/axdb.sh docs/db-scripts/README.md docs/axsvr-phase1-db.md
git commit -m "feat(db): menu schema/perm + docs cho grant-group/set-search-path/schema-ops"
```

---

## Ghi chú kiểm thử tổng

Sau Task D, toàn bộ suite phải xanh (7 file test):
```bash
for t in docs/db-scripts/tests/test-*.sh; do echo "== $t =="; bash "$t" 2>&1 | tail -1; done
```
Kỳ vọng: mỗi file `FAIL=0` (test-axdb, test-create-schema, test-perm, test-setup-group-roles, test-grant-group, test-set-search-path, test-schema-ops).
