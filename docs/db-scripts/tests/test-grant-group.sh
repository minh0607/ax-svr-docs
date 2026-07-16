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
