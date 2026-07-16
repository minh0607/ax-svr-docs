#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
trap pg_down EXIT
pg_up
make_db appdb appowner
./create-schema.sh finance appdb appowner

# show schemas lists finance + owner
OUT="$(./axdb.sh show schemas appdb)"
assert_contains "$OUT" "finance" "show schemas lists finance"
assert_contains "$OUT" "appowner" "show schemas shows owner"

# set-schema moves a public table into finance, name unchanged
dq -d appdb -c "SET ROLE appowner; CREATE TABLE public.legacy_t(id int);" >/dev/null
./axdb.sh set-schema appdb public.legacy_t finance
assert_eq "$(dq -d appdb -tAc "SELECT schemaname FROM pg_tables WHERE tablename='legacy_t'")" "finance" "set-schema moved table to finance"
assert_eq "$(dq -d appdb -tAc "SELECT count(*) FROM pg_tables WHERE schemaname='finance' AND tablename='legacy_t'")" "1" "table name unchanged after move"

# drop-schema RESTRICT refuses when non-empty (feed confirmation via stdin)
if printf 'finance\n' | ./axdb.sh drop-schema appdb finance 2>/dev/null; then
  assert_eq "restrict" "blocked" "drop-schema RESTRICT should fail on non-empty schema"
else
  assert_eq "restrict" "restrict" "drop-schema RESTRICT blocks non-empty schema"
fi

# drop-schema --cascade removes it
printf 'finance\n' | ./axdb.sh drop-schema appdb finance --cascade
assert_eq "$(dq -d appdb -tAc "SELECT count(*) FROM information_schema.schemata WHERE schema_name='finance'")" "0" "drop-schema --cascade removed schema"

# protected schema refused
if printf 'public\n' | ./axdb.sh drop-schema appdb public 2>/dev/null; then
  assert_eq "prot" "blocked" "drop-schema should refuse public"
else
  assert_eq "prot" "prot" "drop-schema refuses public"
fi

finish
