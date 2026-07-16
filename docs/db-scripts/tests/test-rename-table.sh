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
