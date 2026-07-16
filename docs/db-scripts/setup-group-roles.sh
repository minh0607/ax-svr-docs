#!/usr/bin/env bash
# Create readonly/readwrite GROUP ROLEs for a database + DEFAULT PRIVILEGES
# so tables created LATER by <owner> are granted automatically.
# Usage: ./setup-group-roles.sh <dbname> [owner]
#   owner defaults to the database owner if omitted.
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

DB="${1:-}"; [ -n "$DB" ] || read -rp "Database name: " DB
db_exists "$DB" || die "Database '$DB' does not exist."

OWNER="${2:-}"
if [ -z "$OWNER" ]; then
  OWNER="$($PSQL -tAc "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='$DB'")"
  [ -n "$OWNER" ] || die "Cannot resolve owner of '$DB'."
  echo ">> owner not given, using database owner: $OWNER"
fi
role_exists "$OWNER" || die "Owner role '$OWNER' does not exist."

RO="${DB}_readonly"
RW="${DB}_readwrite"

for g in "$RO" "$RW"; do
  role_exists "$g" || $PSQL -v g="$g" <<'SQL'
CREATE ROLE :"g" NOLOGIN;
SQL
done

$PSQL -d "$DB" -v db="$DB" -v ro="$RO" -v rw="$RW" -v owner="$OWNER" <<'SQL'
GRANT CONNECT ON DATABASE :"db" TO :"ro", :"rw";
GRANT USAGE ON SCHEMA public TO :"ro", :"rw";

GRANT SELECT ON ALL TABLES IN SCHEMA public TO :"ro";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO :"rw";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO :"rw";

-- Tables created LATER by <owner> are auto-granted (FOR ROLE = key fix):
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA public
  GRANT SELECT ON TABLES TO :"ro";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"rw";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO :"rw";
SQL

echo ">> Created 2 groups for '$DB' (default privileges FOR ROLE $OWNER):"
echo "   - $RO  (read-only)"
echo "   - $RW  (read + write)"
echo "   NOTE: default privileges apply to tables created by '$OWNER'. Always create tables as $OWNER."
