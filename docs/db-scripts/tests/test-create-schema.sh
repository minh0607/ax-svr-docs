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
