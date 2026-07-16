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

  # The official postgres image's entrypoint runs initdb, brings up a
  # TEMPORARY localhost-only server to execute init scripts, shuts that
  # server down, then execs the real long-running server. pg_isready can
  # succeed against the temporary server, so we must not rely on it alone:
  # first wait for the init phase to finish, then confirm the REAL server
  # answers an actual query (not just a readiness ping).

  # Step 1: wait for the init phase to complete (temp server done).
  # `docker logs` is read from the host; the sleep between polls still
  # runs INSIDE the container so the host shell never blocks foreground.
  local init_done=""
  for i in $(seq 1 60); do
    if docker logs "$PG_CONTAINER" 2>&1 | grep -q "PostgreSQL init process complete"; then
      init_done=1
      break
    fi
    docker exec "$PG_CONTAINER" sleep 0.5
  done
  [ -n "$init_done" ] || { echo "postgres init did not complete" >&2; return 1; }

  # Step 2: wait for the REAL server to answer a genuine query
  # (pg_isready alone can succeed against the temporary init server).
  for i in $(seq 1 60); do
    docker exec -i "$PG_CONTAINER" psql -U postgres -tAc "SELECT 1" >/dev/null 2>&1 && return 0
    docker exec "$PG_CONTAINER" sleep 0.5
  done

  echo "postgres not ready" >&2
  return 1
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
