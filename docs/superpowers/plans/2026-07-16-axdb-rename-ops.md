# axdb.sh — Rename Operations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Thêm nhóm rename "thông minh" vào `axdb.sh`: `rename-table`, `rename-schema` (kèm đổi tên 2 group + vá `search_path` các role trỏ schema cũ), `rename-user` (kèm di trú block ghim IP trong pg_hba); đồng thời sắp lại menu cho đúng luồng và sửa nhãn mục 18.

**Architecture:** Bám pattern `axdb.sh`: hàm `cmd_*`, dispatch `case`, `usage()`, `menu()`; dùng `$PSQL`/`role_exists`/`db_exists`/`die`/`is_protected_role`. Identifier động dùng psql `:"var"` khi được; chỗ bash-expand phải double-quote token (như `cmd_set_owner`/`cmd_set_schema` sẵn có). Test qua Docker PostgreSQL 17 harness `tests/lib.sh`.

**Tech Stack:** Bash, PostgreSQL 17, Docker (test).

## Global Constraints

- PostgreSQL 17 — test image `postgres:17`.
- Giao diện script (prompt, echo, tiêu đề cột, lỗi) = tiếng Anh. Docs: `README.md` tiếng Anh, `axsvr-phase1-db.md` tiếng Việt.
- Honor `PSQL_ADMIN` — chạy được với cả `sudo -u postgres psql` (prod) lẫn `docker exec -i ... psql` (test).
- Group naming `<schema>_readonly` / `<schema>_readwrite` — rename schema PHẢI giữ quy ước này.
- Commit messages KHÔNG có attribution/co-author. Không dùng `git commit --no-verify`/`--amend`/`--no-edit` (hook chặn) — chỉ `git commit -m`.
- `axdb.sh` self-contained — thêm logic trực tiếp, KHÔNG source script rời.
- CHỈ THÊM; không đổi hành vi subcommand cũ. Mục menu 1–18 giữ nguyên số; chỉ mục 19+ (thêm hôm nay) được sắp lại.
- Thao tác pg_hba (`bind-ip`) KHÔNG test được bằng Docker harness (nó `sudo sed` file trên host / patroni DCS) — code phải **skip sạch + báo rõ** khi không có file, và test chỉ phủ nhánh đó.

---

### Task 1: `rename-table <db> <table> <new_name>`

**Files:**
- Modify: `docs/db-scripts/axdb.sh`
- Test: `docs/db-scripts/tests/test-rename-table.sh`

**Interfaces:**
- Consumes: harness `tests/lib.sh` (`pg_up`,`pg_down`,`dq`,`make_db`,`assert_eq`,`finish`); `create-schema.sh`.
- Produces: `axdb.sh rename-table <db> <table> <new_name>` — `ALTER TABLE <table> RENAME TO <new_name>`. `<table>` có thể schema-qualified (`finance.fi_cost`); `<new_name>` PHẢI là tên trần (không chứa dấu chấm) vì PostgreSQL không cho schema-qualify vế RENAME TO.

- [ ] **Step 1: Viết test thất bại `tests/test-rename-table.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
trap pg_down EXIT
pg_up
make_db appdb appowner
./create-schema.sh finance appdb appowner
dq -d appdb -c "SET ROLE appowner; CREATE TABLE finance.fi_cost(id int); CREATE TABLE public.plain_t(id int);" >/dev/null

# rename inside a schema (schema-qualified source)
./axdb.sh rename-table appdb finance.fi_cost fi_expense
assert_eq "$(dq -d appdb -tAc "SELECT count(*) FROM pg_tables WHERE schemaname='finance' AND tablename='fi_expense'")" "1" "renamed table exists under new name"
assert_eq "$(dq -d appdb -tAc "SELECT count(*) FROM pg_tables WHERE schemaname='finance' AND tablename='fi_cost'")" "0" "old table name gone"
assert_eq "$(dq -d appdb -tAc "SELECT schemaname FROM pg_tables WHERE tablename='fi_expense'")" "finance" "table stayed in its schema"

# rename in public (bare source)
./axdb.sh rename-table appdb plain_t plain_renamed
assert_eq "$(dq -d appdb -tAc "SELECT count(*) FROM pg_tables WHERE tablename='plain_renamed'")" "1" "bare-name rename works"

# reject schema-qualified NEW name
if ./axdb.sh rename-table appdb finance.fi_expense other.newname 2>/dev/null; then
  assert_eq "x" "y" "should reject dotted new name"
else
  assert_eq "x" "x" "rejects schema-qualified new name"
fi

finish
```

- [ ] **Step 2: Chạy test, xác nhận FAIL**

Run: `bash docs/db-scripts/tests/test-rename-table.sh 2>&1 | tail -8`
Expected: FAIL — "Invalid command: rename-table".

- [ ] **Step 3: Thêm `cmd_rename_table` vào `axdb.sh`**

Đặt hàm ngay sau `cmd_set_schema`:

```bash
cmd_rename_table() {            # <db> <table> <new_name>
  local d="${1:-}" t="${2:-}" n="${3:-}"
  [ -n "$d" ] && [ -n "$t" ] && [ -n "$n" ] || die "Usage: axdb.sh rename-table <db> <table> <new_name>"
  db_exists "$d" || die "Database '$d' does not exist."
  case "$n" in *.*) die "New name must be a bare table name (no schema prefix). The table keeps its current schema.";; esac
  # $t bash-expands (may be schema-qualified); :"n" is psql-interpolated
  $PSQL -d "$d" -v n="$n" <<SQL
ALTER TABLE $t RENAME TO :"n";
SQL
  echo ">> Renamed table $t -> $n (db: $d). Schema unchanged."
  echo "   NOTE: application code referencing the old name must be updated."
}
```

Dispatch — thêm sau `set-schema)`:

```bash
  rename-table)       cmd_rename_table "$@";;
```

`usage()` — thêm sau dòng `set-schema ...`:

```
  rename-table <db> <table> <new_name>        Rename a table (schema unchanged; new name must be bare)
```

- [ ] **Step 4: Chạy test, xác nhận PASS**

Run: `bash docs/db-scripts/tests/test-rename-table.sh 2>&1 | tail -8`
Expected: `== PASS=5 FAIL=0 ==`

- [ ] **Step 5: Commit**

```bash
git add docs/db-scripts/axdb.sh docs/db-scripts/tests/test-rename-table.sh
git commit -m "feat(db): rename-table — đổi tên bảng, giữ nguyên schema"
```

---

### Task 2: `rename-schema <db> <old> <new>` — kèm đổi group + vá search_path

**Files:**
- Modify: `docs/db-scripts/axdb.sh`
- Test: `docs/db-scripts/tests/test-rename-schema.sh`

**Interfaces:**
- Consumes: harness; `create-schema.sh`; `axdb.sh set-search-path` (đã có).
- Produces: `axdb.sh rename-schema <db> <old> <new>` — làm 3 việc:
  1. `ALTER SCHEMA <old> RENAME TO <new>`.
  2. Đổi tên 2 group nếu tồn tại: `<old>_readonly` → `<new>_readonly`, `<old>_readwrite` → `<new>_readwrite` (giữ quy ước đặt tên).
  3. Vá `search_path` của mọi role đang trỏ tới `<old>`: thay token `"<old>"`/`<old>` thành `<new>` rồi `ALTER ROLE ... SET search_path = ...`.
  Từ chối schema hệ thống (`public|information_schema|pg_*`) và `<new>` có dấu chấm.

- [ ] **Step 1: Viết test thất bại `tests/test-rename-schema.sh`**

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
dq -c "CREATE ROLE fi_user LOGIN PASSWORD 'x';" >/dev/null
dq -d appdb -c "GRANT finance_readwrite TO fi_user;" >/dev/null
./axdb.sh set-search-path fi_user finance

./axdb.sh rename-schema appdb finance fin

# 1. schema renamed
assert_eq "$(dq -d appdb -tAc "SELECT count(*) FROM information_schema.schemata WHERE schema_name='fin'")" "1" "schema renamed to fin"
assert_eq "$(dq -d appdb -tAc "SELECT count(*) FROM information_schema.schemata WHERE schema_name='finance'")" "0" "old schema name gone"
assert_eq "$(dq -d appdb -tAc "SELECT count(*) FROM pg_tables WHERE schemaname='fin' AND tablename='fi_cost'")" "1" "table moved with schema"

# 2. groups renamed to keep the convention
assert_eq "$(dq -tAc "SELECT count(*) FROM pg_roles WHERE rolname='fin_readwrite'")" "1" "group readwrite renamed"
assert_eq "$(dq -tAc "SELECT count(*) FROM pg_roles WHERE rolname='fin_readonly'")"  "1" "group readonly renamed"
assert_eq "$(dq -tAc "SELECT count(*) FROM pg_roles WHERE rolname='finance_readwrite'")" "0" "old group name gone"

# 3. membership + privileges survive the group rename
assert_eq "$(dq -d appdb -tAc "SELECT has_table_privilege('fi_user','fin.fi_cost','INSERT')")" "t" "user keeps write via renamed group"

# 4. search_path patched to the new schema name
V="$(dq -tAc "SELECT COALESCE(array_to_string(rolconfig,'|'),'') FROM pg_roles WHERE rolname='fi_user'")"
assert_contains "$V" "fin" "search_path patched to new schema"
assert_eq "$(printf '%s' "$V" | grep -c finance || true)" "0" "search_path no longer mentions old name"

# 5. refuse protected schema
if ./axdb.sh rename-schema appdb public pub2 2>/dev/null; then
  assert_eq "p" "q" "should refuse renaming public"
else
  assert_eq "p" "p" "refuses renaming public"
fi

finish
```

- [ ] **Step 2: Chạy test, xác nhận FAIL**

Run: `bash docs/db-scripts/tests/test-rename-schema.sh 2>&1 | tail -12`
Expected: FAIL — "Invalid command: rename-schema".

- [ ] **Step 3: Thêm `cmd_rename_schema` vào `axdb.sh`**

Đặt hàm sau `cmd_rename_table`:

```bash
cmd_rename_schema() {           # <db> <old> <new>
  local d="${1:-}" o="${2:-}" n="${3:-}"
  [ -n "$d" ] && [ -n "$o" ] && [ -n "$n" ] || die "Usage: axdb.sh rename-schema <db> <old> <new>"
  db_exists "$d" || die "Database '$d' does not exist."
  case "$o" in public|information_schema|pg_*) die "'$o' is a protected schema.";; esac
  case "$n" in *.*) die "New schema name must not contain a dot.";; esac
  [ "$($PSQL -d "$d" -tAc "SELECT count(*) FROM information_schema.schemata WHERE schema_name='$o'")" = "1" ] \
    || die "Schema '$o' does not exist in '$d'."
  [ "$($PSQL -d "$d" -tAc "SELECT count(*) FROM information_schema.schemata WHERE schema_name='$n'")" = "0" ] \
    || die "Schema '$n' already exists in '$d'."

  # 1. rename the schema
  $PSQL -d "$d" -v o="$o" -v n="$n" <<'SQL'
ALTER SCHEMA :"o" RENAME TO :"n";
SQL
  echo ">> Renamed schema $o -> $n (db: $d)"

  # 2. keep the group-naming convention: <schema>_readonly / <schema>_readwrite
  local sfx og ng
  for sfx in readonly readwrite; do
    og="${o}_${sfx}"; ng="${n}_${sfx}"
    if role_exists "$og"; then
      if role_exists "$ng"; then
        echo "   WARNING: group '$ng' already exists — left '$og' untouched."
      else
        $PSQL -v og="$og" -v ng="$ng" <<'SQL'
ALTER ROLE :"og" RENAME TO :"ng";
SQL
        echo "   group renamed: $og -> $ng"
      fi
    fi
  done

  # 3. patch search_path of roles still pointing at the old schema name
  local roles r cur new_sp
  roles="$($PSQL -tAc "SELECT rolname FROM pg_roles WHERE rolconfig::text LIKE '%search_path%' AND rolconfig::text LIKE '%${o}%'")"
  for r in $roles; do
    cur="$($PSQL -tAc "SELECT c FROM pg_roles, unnest(rolconfig) c WHERE rolname='$r' AND c LIKE 'search_path=%'")"
    [ -n "$cur" ] || continue
    # Replace ONLY whole tokens: the quoted form (what set-search-path writes) and a
    # delimiter-bounded bare form. A plain substring replace would corrupt names that
    # merely contain the old name (e.g. renaming "finance" must not touch "myfinance").
    new_sp="$(printf '%s' "${cur#search_path=}" \
      | sed -E "s/\"${o}\"/\"${n}\"/g; s/(^|[[:space:],])${o}([[:space:],]|\$)/\1${n}\2/g")"
    $PSQL -v r="$r" <<SQL
ALTER ROLE :"r" SET search_path = $new_sp;
SQL
    echo "   search_path patched for role $r -> $new_sp"
    case "$new_sp" in *"$o"*) echo "   WARNING: role $r search_path still mentions '$o' — check manually: $new_sp";; esac
  done
  echo "   NOTE: application code hard-coding the old schema name must be updated."
}
```

Dispatch — thêm sau `rename-table)`:

```bash
  rename-schema)      cmd_rename_schema "$@";;
```

`usage()` — thêm:

```
  rename-schema <db> <old> <new>              Rename a schema + its <name>_readonly/_readwrite groups + patch role search_path
```

- [ ] **Step 4: Chạy test, xác nhận PASS**

Run: `bash docs/db-scripts/tests/test-rename-schema.sh 2>&1 | tail -12`
Expected: `== PASS=10 FAIL=0 ==`

- [ ] **Step 5: Commit**

```bash
git add docs/db-scripts/axdb.sh docs/db-scripts/tests/test-rename-schema.sh
git commit -m "feat(db): rename-schema — đổi tên schema + group + vá search_path"
```

---

### Task 3: `rename-user <old> <new>` — kèm di trú ghim IP pg_hba

**Files:**
- Modify: `docs/db-scripts/axdb.sh`
- Test: `docs/db-scripts/tests/test-rename-user.sh`

**Interfaces:**
- Consumes: harness; `axdb.sh` helpers `is_protected_role`, `cmd_bind_ip`/`_bind_file`.
- Produces: `axdb.sh rename-user <old> <new>` — `ALTER ROLE <old> RENAME TO <new>`; từ chối role được bảo vệ (`PROTECTED_ROLES`); sau khi đổi tên, **di trú block ghim IP** trong `pg_hba_peruser.conf` từ tên cũ sang tên mới (best-effort, chỉ chế độ file). Nếu không tìm thấy file pg_hba (ví dụ chạy remote/trong test) → bỏ qua sạch + in hướng dẫn. Nếu phát hiện Patroni → cảnh báo re-pin thủ công.

**Bối cảnh quan trọng:** `bind-ip` ghi pg_hba theo TÊN USER (`# >>> peruser:<user>` + `host all <user> <ip> scram-sha-256` + 2 dòng reject). Đổi tên role mà không sửa block này ⇒ user mới không có rule, rule cũ nằm lại ⇒ **đăng nhập hỏng**.

- [ ] **Step 1: Viết test thất bại `tests/test-rename-user.sh`**

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
dq -c "CREATE ROLE old_user LOGIN PASSWORD 'x';" >/dev/null
dq -d appdb -c "GRANT finance_readonly TO old_user;" >/dev/null

# no pg_hba file in this environment -> must still rename cleanly and say so
HBA=/nonexistent/pg_hba.conf ./axdb.sh rename-user old_user new_user

assert_eq "$(dq -tAc "SELECT count(*) FROM pg_roles WHERE rolname='new_user'")" "1" "role renamed"
assert_eq "$(dq -tAc "SELECT count(*) FROM pg_roles WHERE rolname='old_user'")" "0" "old role name gone"
# group membership survives a role rename
assert_eq "$(dq -d appdb -tAc "SELECT has_table_privilege('new_user','finance.fi_cost','SELECT')")" "t" "membership/privileges survive rename"

# protected role refused
if ./axdb.sh rename-user postgres pg2 2>/dev/null; then
  assert_eq "a" "b" "should refuse protected role"
else
  assert_eq "a" "a" "refuses protected role"
fi

# missing target/duplicate name refused
dq -c "CREATE ROLE taken_name LOGIN PASSWORD 'x';" >/dev/null
if HBA=/nonexistent/pg_hba.conf ./axdb.sh rename-user new_user taken_name 2>/dev/null; then
  assert_eq "c" "d" "should refuse existing new name"
else
  assert_eq "c" "c" "refuses new name that already exists"
fi

finish
```

- [ ] **Step 2: Chạy test, xác nhận FAIL**

Run: `bash docs/db-scripts/tests/test-rename-user.sh 2>&1 | tail -8`
Expected: FAIL — "Invalid command: rename-user".

- [ ] **Step 3: Thêm `_migrate_peruser_hba` + `cmd_rename_user` vào `axdb.sh`**

Đặt sau `_bind_patroni`:

```bash
# Best-effort migration of a bind-ip pin when a role is renamed (file mode only).
_migrate_peruser_hba() {        # <old> <new>
  local old="$1" new="$2"
  local hba="${HBA:-/etc/postgresql/${PG_VER:-17}/main/pg_hba.conf}"
  if { command -v patronictl >/dev/null && [ -f "${PATRONI_CONF:-/etc/patroni/patroni.yml}" ]; }; then
    echo "   WARNING: Patroni detected. Per-user pg_hba lives in the DCS — re-pin manually:"
    echo "            ./axdb.sh bind-ip $new <ip[,ip2]> --patroni    (and unpin the old name)"
    return 0
  fi
  if [ ! -f "$hba" ]; then
    echo "   (no pg_hba at $hba — skipped IP-pin migration; re-pin manually if this user was pinned)"
    return 0
  fi
  local peruser; peruser="$(dirname "$hba")/pg_hba_peruser.conf"
  if [ ! -f "$peruser" ] || ! grep -q "^# >>> peruser:$old$" "$peruser" 2>/dev/null; then
    echo "   (no IP pin found for '$old' — nothing to migrate)"
    return 0
  fi
  local ips
  ips="$(sed -n "/^# >>> peruser:$old$/,/^# <<< peruser:$old$/p" "$peruser" \
        | awk -v u="$old" '$1=="host" && $3==u && $5=="scram-sha-256" {printf "%s%s", sep, $4; sep=","}')"
  sudo sed -i "/^# >>> peruser:$old$/,/^# <<< peruser:$old$/d" "$peruser"
  if [ -n "$ips" ]; then
    cmd_bind_ip "$new" "$ips" --file
    echo "   migrated IP pin: $old -> $new ($ips)"
  else
    echo "   removed stale pin block for '$old' (no allowed IPs found)"
  fi
}

cmd_rename_user() {             # <old> <new>
  local o="${1:-}" n="${2:-}"
  [ -n "$o" ] && [ -n "$n" ] || die "Usage: axdb.sh rename-user <old> <new>"
  is_protected_role "$o" && die "'$o' is a protected role, cannot rename."
  role_exists "$o" || die "Role '$o' does not exist."
  role_exists "$n" && die "Role '$n' already exists."
  $PSQL -v o="$o" -v n="$n" <<'SQL'
ALTER ROLE :"o" RENAME TO :"n";
SQL
  echo ">> Renamed role $o -> $n"
  _migrate_peruser_hba "$o" "$n"
  echo "   NOTE: update any application connection string using the old username."
}
```

Dispatch — thêm sau `rename-schema)`:

```bash
  rename-user)        cmd_rename_user "$@";;
```

`usage()` — thêm:

```
  rename-user <old> <new>                     Rename a role + migrate its bind-ip pg_hba pin (file mode)
```

- [ ] **Step 4: Chạy test, xác nhận PASS**

Run: `bash docs/db-scripts/tests/test-rename-user.sh 2>&1 | tail -8`
Expected: `== PASS=5 FAIL=0 ==`

- [ ] **Step 5: Commit**

```bash
git add docs/db-scripts/axdb.sh docs/db-scripts/tests/test-rename-user.sh
git commit -m "feat(db): rename-user — đổi tên role + di trú ghim IP pg_hba"
```

---

### Task 4: Sắp lại menu + nhãn mục 18 + docs

**Files:**
- Modify: `docs/db-scripts/axdb.sh` (menu only)
- Modify: `docs/db-scripts/README.md`
- Modify: `docs/axsvr-phase1-db.md`

**Interfaces:** không có logic mới — chỉ UI + docs.

- [ ] **Step 1: Sửa nhãn mục 18**

Đổi dòng menu:
```
 18) Show / inspect (dbs/tables/structure/owner/perms)
```
thành:
```
 18) Show / inspect (dbs/tables/structure/owner/perms/schemas)
```
(submenu đã hỗ trợ `schemas` — chỉ nhãn thiếu.)

- [ ] **Step 2: Sắp lại mục 19+ theo luồng logic và thêm 3 mục rename**

Thay khối liệt kê mục 19–24 hiện tại bằng:

```
 19) Create schema for an app (schema)
 20) Move table into a schema (set-schema)
 21) Rename schema (+groups, +search_path)
 22) Drop schema (safe)
 23) Rename table
 24) Add / remove user to a group (grant-group / revoke-group)
 25) Set a user's search_path
 26) Rename user (+migrate IP pin)
 27) Permission overview (perm)
```

và thay các nhánh `case "$ch" in` tương ứng (19–24 cũ) bằng:

```bash
      19) read -rp "Schema/app name: " s; read -rp "Database: " d; read -rp "Owner (empty=db owner): " o; _run cmd_schema "$s" "$d" "$o" ;;
      20) read -rp "Database: " d; read -rp "Table (or schema.table): " t; read -rp "Target schema: " s; _run cmd_set_schema "$d" "$t" "$s" ;;
      21) read -rp "Database: " d; read -rp "Old schema: " o; read -rp "New schema: " n; _run cmd_rename_schema "$d" "$o" "$n" ;;
      22) read -rp "Database: " d; read -rp "Schema: " s; read -rp "Cascade? [Enter=no / --cascade]: " m; _run cmd_drop_schema "$d" "$s" "${m:-}" ;;
      23) read -rp "Database: " d; read -rp "Table (or schema.table): " t; read -rp "New table name: " n; _run cmd_rename_table "$d" "$t" "$n" ;;
      24) read -rp "Action [grant/revoke]: " a; read -rp "User: " u; read -rp "Group: " g; _run cmd_grant_group "$a" "$u" "$g" ;;
      25) read -rp "User: " u; read -rp "search_path (e.g. finance  or  --reset): " p; _run cmd_set_search_path "$u" "$p" ;;
      26) read -rp "Old username: " o; read -rp "New username: " n; _run cmd_rename_user "$o" "$n" ;;
      27) read -rp "Database: " d; read -rp "User (empty=summary of all): " u; _run cmd_perm "$d" "$u" ;;
```

Cập nhật dòng chọn thành `Select [0-27]:`. **Không đụng mục 1–18.**

- [ ] **Step 3: Xác minh**

Run:
```bash
bash -n docs/db-scripts/axdb.sh && echo "syntax OK"
./axdb.sh help | grep -E "rename-table|rename-schema|rename-user"
sed -n '/AX DB MANAGER/,/^M$/p' docs/db-scripts/axdb.sh
```
Expected: `syntax OK`; usage liệt kê 3 lệnh rename; menu in ra 0–27 đúng thứ tự trên, mục 18 có nhãn `schemas`.

- [ ] **Step 4: Chạy TOÀN BỘ suite**

Run:
```bash
for t in docs/db-scripts/tests/test-*.sh; do printf '%-40s ' "$(basename "$t")"; bash "$t" 2>&1 | tail -1; docker rm -f axdb-scripts-test >/dev/null 2>&1 || true; done
```
Expected: 10 file, mỗi file `FAIL=0`.

- [ ] **Step 5: Docs**

`docs/db-scripts/README.md` (English) — trong mục schema-per-app, thêm:
```
Rename things (each also fixes what depends on the name):
    ./axdb.sh rename-table  appdb finance.fi_cost fi_expense   # table only; schema kept
    ./axdb.sh rename-schema appdb finance fin                  # also renames fin_readonly/fin_readwrite + patches role search_path
    ./axdb.sh rename-user   old_user new_user                  # also migrates the bind-ip pg_hba pin (file mode)
Caveat: renaming does NOT update application code / connection strings — update those yourself.
```

`docs/axsvr-phase1-db.md` (Vietnamese) — thêm đoạn tương đương tiếng Việt vào mục "Phân quyền nhiều project (schema-per-app)", nêu rõ 3 hệ quả được xử lý tự động (group, search_path, ghim IP) và cái KHÔNG tự xử lý (code app).

- [ ] **Step 6: Commit**

```bash
git add docs/db-scripts/axdb.sh docs/db-scripts/README.md docs/axsvr-phase1-db.md
git commit -m "feat(db): sắp lại menu theo luồng + 3 mục rename + nhãn schemas; docs rename"
```

---

## Ghi chú kiểm thử tổng

Sau Task 4, 10 file test phải xanh:
test-axdb, test-create-schema, test-grant-group, test-perm, test-rename-schema, test-rename-table, test-rename-user, test-schema-ops, test-set-search-path, test-setup-group-roles.

Sau cùng: chuẩn hóa exec bit cho file test mới
```bash
mapfile -t SH < <(git ls-files 'docs/db-scripts/*.sh'); git update-index --chmod=+x "${SH[@]}"
```
