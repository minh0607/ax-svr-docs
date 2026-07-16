#!/usr/bin/env bash
# Create a SCHEMA (per-app namespace) + readonly/readwrite group roles for it,
# with DEFAULT PRIVILEGES FOR ROLE <owner> so future tables are auto-granted.
# Usage: ./create-schema.sh <schema> <db> [owner]
#   owner defaults to the database owner if omitted.
#   e.g.: ./create-schema.sh finance appdb appowner
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

SCH="${1:-}"; [ -n "$SCH" ] || read -rp "Schema name: " SCH
DB="${2:-}";  [ -n "$DB" ]  || read -rp "Database name: " DB
db_exists "$DB" || die "Database '$DB' does not exist."

OWNER="${3:-}"
if [ -z "$OWNER" ]; then
  OWNER="$($PSQL -tAc "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='$DB'")"
  [ -n "$OWNER" ] || die "Cannot resolve owner of '$DB'."
  echo ">> owner not given, using database owner: $OWNER"
fi
role_exists "$OWNER" || die "Owner role '$OWNER' does not exist."

RO="${SCH}_readonly"
RW="${SCH}_readwrite"

for g in "$RO" "$RW"; do
  role_exists "$g" || $PSQL -v g="$g" <<'SQL'
CREATE ROLE :"g" NOLOGIN;
SQL
done

$PSQL -d "$DB" -v db="$DB" -v sch="$SCH" -v owner="$OWNER" -v ro="$RO" -v rw="$RW" <<'SQL'
CREATE SCHEMA IF NOT EXISTS :"sch" AUTHORIZATION :"owner";

GRANT CONNECT ON DATABASE :"db" TO :"ro", :"rw";
GRANT USAGE ON SCHEMA :"sch" TO :"ro", :"rw";

GRANT SELECT ON ALL TABLES IN SCHEMA :"sch" TO :"ro";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA :"sch" TO :"rw";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA :"sch" TO :"rw";

ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA :"sch"
  GRANT SELECT ON TABLES TO :"ro";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA :"sch"
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"rw";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA :"sch"
  GRANT USAGE, SELECT ON SEQUENCES TO :"rw";
SQL

echo ">> Created schema '$SCH' in '$DB' (owner: $OWNER) + groups:"
echo "   - $RO  (read-only)"
echo "   - $RW  (read + write)"
echo "   Assign a user:  GRANT $RW TO <user>;   and set  ALTER ROLE <user> SET search_path = $SCH, public;"
echo "   Cross-project read access:  GRANT $RO TO <other_user>;"
