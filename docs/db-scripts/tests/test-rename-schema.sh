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
