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
