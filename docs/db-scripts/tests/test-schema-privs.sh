#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
trap pg_down EXIT
pg_up
make_db appdb appowner
./create-schema.sh finance appdb appowner
dq -c "CREATE ROLE acc LOGIN PASSWORD 'x';" >/dev/null

# baseline: fresh role has neither USAGE nor CREATE on a private schema
assert_eq "$(dq -d appdb -tAc "SELECT has_schema_privilege('acc','finance','USAGE')")"  "f" "baseline: no USAGE"
assert_eq "$(dq -d appdb -tAc "SELECT has_schema_privilege('acc','finance','CREATE')")" "f" "baseline: no CREATE"

# standalone grant USAGE
./grant-schema.sh grant acc appdb finance USAGE
assert_eq "$(dq -d appdb -tAc "SELECT has_schema_privilege('acc','finance','USAGE')")" "t" "USAGE granted"

# axdb grant CREATE
./axdb.sh grant-schema acc appdb finance CREATE
assert_eq "$(dq -d appdb -tAc "SELECT has_schema_privilege('acc','finance','CREATE')")" "t" "CREATE granted via axdb"

# revoke CREATE only, USAGE stays
./axdb.sh revoke-schema acc appdb finance CREATE
assert_eq "$(dq -d appdb -tAc "SELECT has_schema_privilege('acc','finance','CREATE')")" "f" "CREATE revoked"
assert_eq "$(dq -d appdb -tAc "SELECT has_schema_privilege('acc','finance','USAGE')")"  "t" "USAGE still present"

# ALL grants both
dq -c "CREATE ROLE acc2 LOGIN PASSWORD 'x';" >/dev/null
./grant-schema.sh grant acc2 appdb finance ALL
assert_eq "$(dq -d appdb -tAc "SELECT has_schema_privilege('acc2','finance','USAGE')")"  "t" "ALL -> USAGE"
assert_eq "$(dq -d appdb -tAc "SELECT has_schema_privilege('acc2','finance','CREATE')")" "t" "ALL -> CREATE"

# invalid privilege rejected
if ./grant-schema.sh grant acc appdb finance SELECT 2>/dev/null; then
  assert_eq "x" "y" "should reject invalid schema privilege"
else
  assert_eq "x" "x" "rejects invalid schema privilege"
fi

finish
