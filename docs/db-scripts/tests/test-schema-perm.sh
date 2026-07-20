#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
trap pg_down EXIT
pg_up
make_db appdb appowner
./create-schema.sh finance appdb appowner          # creates finance_readonly / finance_readwrite (both hold USAGE)
dq -c "CREATE ROLE fi_user LOGIN PASSWORD 'x';" >/dev/null
dq -d appdb -c "GRANT finance_readwrite TO fi_user;" >/dev/null   # inherits USAGE via the group
dq -c "CREATE ROLE builder LOGIN PASSWORD 'x';" >/dev/null
./grant-schema.sh grant builder appdb finance CREATE >/dev/null    # direct CREATE

OUT="$(./axdb.sh schema-perm appdb finance)"
assert_contains "$OUT" "finance_readwrite" "lists the group holding USAGE"
assert_contains "$OUT" "fi_user"           "lists user with inherited USAGE"
assert_contains "$OUT" "builder"           "lists user with direct CREATE"

# a role with nothing does NOT appear
dq -c "CREATE ROLE nobody LOGIN PASSWORD 'x';" >/dev/null
case "$(./axdb.sh schema-perm appdb finance)" in
  *nobody*) assert_eq "n" "y" "role with no schema priv must not be listed";;
  *)        assert_eq "n" "n" "role with no schema priv is not listed";;
esac

# list-access path works too
assert_contains "$(./list-access.sh schema-perm appdb finance)" "builder" "list-access schema-perm works"

finish
