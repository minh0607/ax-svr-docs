#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
trap pg_down EXIT
pg_up
make_db appdb appowner

# check-storage must run cleanly against a live PostgreSQL, resolve the real data_directory,
# and print each section. It must exit 0 regardless of whether it finds warnings.
OUT="$(./axdb.sh check-storage appdb)"
assert_contains "$OUT" "AX DB storage check" "prints header"
assert_contains "$OUT" "data directory"      "has data-directory section"
assert_contains "$OUT" "path"                "shows the data dir path"
assert_contains "$OUT" "block devices"       "has block-devices section"
assert_contains "$OUT" "fstab"               "has fstab section"
assert_contains "$OUT" "storage"             "prints a verdict line (OK or WARNINGS)"

# no-arg (defaults to postgres) also works and exits 0
./axdb.sh check-storage >/dev/null && echo ok > /tmp/cs.$$ ; assert_eq "$(cat /tmp/cs.$$)" "ok" "no-arg default works"; rm -f /tmp/cs.$$

finish
