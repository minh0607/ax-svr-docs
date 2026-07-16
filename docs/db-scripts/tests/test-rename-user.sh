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
