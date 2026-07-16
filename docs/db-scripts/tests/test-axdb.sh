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

dq -c "CREATE ROLE hr_user LOGIN PASSWORD 'x';" >/dev/null
dq -d appdb -c "GRANT hr_readwrite TO hr_user;" >/dev/null
OUT="$(./axdb.sh perm appdb)"
assert_contains "$OUT" "hr_user" "axdb perm lists roles"

finish
