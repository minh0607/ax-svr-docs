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
