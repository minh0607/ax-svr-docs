#!/usr/bin/env bash
# Shared test harness for db-scripts: an ephemeral PostgreSQL 17 container
# is used as the admin target via PSQL_ADMIN override.
set -euo pipefail

PG_IMAGE="postgres:17"
PG_CONTAINER="axdb-scripts-test"

# Point the db-scripts at the container instead of a local socket.
export PSQL_ADMIN="docker exec -i $PG_CONTAINER psql -U postgres"

dq() { docker exec -i "$PG_CONTAINER" psql -U postgres -tA "$@"; }

pg_up() {
  docker rm -f "$PG_CONTAINER" >/dev/null 2>&1 || true
  docker run -d --name "$PG_CONTAINER" -e POSTGRES_PASSWORD=postgres "$PG_IMAGE" >/dev/null
  # Wait for readiness (sleep runs INSIDE the container).
  docker exec "$PG_CONTAINER" bash -c 'for i in $(seq 1 60); do pg_isready -U postgres >/dev/null 2>&1 && exit 0; sleep 0.5; done; exit 1' \
    || { echo "postgres not ready" >&2; return 1; }
}

pg_down() { docker rm -f "$PG_CONTAINER" >/dev/null 2>&1 || true; }

PASS=0; FAIL=0
assert_eq() { # actual expected msg
  if [ "$1" = "$2" ]; then PASS=$((PASS+1)); echo "  ok: $3";
  else FAIL=$((FAIL+1)); echo "  FAIL: $3 (got '$1' want '$2')"; fi
}
assert_contains() { # haystack needle msg
  case "$1" in *"$2"*) PASS=$((PASS+1)); echo "  ok: $3";;
    *) FAIL=$((FAIL+1)); echo "  FAIL: $3 (missing '$2')";; esac
}
finish() { echo "== PASS=$PASS FAIL=$FAIL =="; [ "$FAIL" -eq 0 ]; }

# Arrange helper: a database owned by a fresh non-login owner role.
# Usage: make_db <dbname> <ownername>
make_db() {
  dq -c "CREATE ROLE $2 NOLOGIN;" >/dev/null
  dq -c "CREATE DATABASE $1 OWNER $2 ENCODING UTF8;" >/dev/null
}
