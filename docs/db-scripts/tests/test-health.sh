#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
trap pg_down EXIT
pg_up
make_db appdb appowner

# health must run cleanly even though NONE of patronictl/etcdctl/pgbackrest/systemctl exist in the container,
# and must report the real data_directory + PRIMARY role from the live PostgreSQL.
OUT="$(./axdb.sh health appdb)"; RC=$?
assert_eq "$RC" "0" "health exits 0 even without cluster tools"
assert_contains "$OUT" "data_directory" "reports the real data_directory"
assert_contains "$OUT" "PRIMARY"        "detects primary role (pg_is_in_recovery=f)"
assert_contains "$OUT" "postgresql"     "has the postgresql section"
# graceful-skip lines for tools that are absent in the container
assert_contains "$OUT" "patroni"        "has a patroni section (skipped note ok)"
assert_contains "$OUT" "etcd"           "has an etcd section (skipped note ok)"

# default db (no arg) also works
./axdb.sh health >/dev/null && echo ok >/tmp/axdbhealth.$$ ; assert_eq "$(cat /tmp/axdbhealth.$$)" "ok" "health with no db arg works"; rm -f /tmp/axdbhealth.$$

finish
