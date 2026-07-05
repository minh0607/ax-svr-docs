#!/usr/bin/env bash
# SAFE DATABASE DROP: prompts for backup + requires retyping the exact name + forces connections closed (FORCE).
# Usage: ./drop-database.sh <dbname>
#   e.g.: ./drop-database.sh appdb
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

PROTECTED="postgres template0 template1"

DB="${1:-}"; [ -n "$DB" ] || read -rp "Database to drop: " DB

for p in $PROTECTED; do
  [ "$DB" = "$p" ] && die "DENIED: '$DB' is a system database, will not drop."
done
db_exists "$DB" || die "Database '$DB' does not exist."

# Info before dropping
SIZE="$($PSQL -tAc "SELECT pg_size_pretty(pg_database_size('$DB'))")"
CONN="$($PSQL -tAc "SELECT count(*) FROM pg_stat_activity WHERE datname='$DB'")"
echo "------------------------------------------------------------"
echo " Database : $DB"
echo " Size: $SIZE"
echo " Open connections: $CONN"
echo "------------------------------------------------------------"
echo "⚠️  DROPPING A DATABASE IS IRREVERSIBLE. Make sure you have a backup!"
echo "    (pgBackRest/pg_dump — see Phase 5)"

# STRONG confirmation: retype the exact database name
read -rp "Retype the EXACT database name to confirm the drop: " TYPED
[ "$TYPED" = "$DB" ] || die "Name does not match ('$TYPED' != '$DB'). Aborting."

# FORCE: automatically terminate open connections (PostgreSQL 13+)
$PSQL -v d="$DB" <<'SQL'
DROP DATABASE IF EXISTS :"d" WITH (FORCE);
SQL
echo ">> Dropped database: $DB"
