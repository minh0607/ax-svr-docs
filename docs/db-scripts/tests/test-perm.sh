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
dq -d appdb -c "GRANT finance_readonly TO prod_acc;" >/dev/null

SUM="$(./list-access.sh perm appdb)"
assert_contains "$SUM" "prod_acc" "summary lists prod_acc"
assert_contains "$SUM" "finance_readonly" "summary shows group"
assert_contains "$SUM" "finance: RO" "summary shows derived schema access"

DET="$(./list-access.sh perm appdb prod_acc)"
assert_contains "$DET" "finance" "drilldown shows schema finance"
assert_contains "$DET" "fi_cost" "drilldown shows table"
assert_contains "$DET" "SELECT" "drilldown shows SELECT priv"

finish
