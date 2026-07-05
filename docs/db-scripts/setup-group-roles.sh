#!/usr/bin/env bash
# Create readonly/readwrite GROUP ROLEs for a database + DEFAULT PRIVILEGES
# => tables created LATER are also granted automatically (no need to re-grant per table).
# Usage: ./setup-group-roles.sh <dbname>
#   e.g.: ./setup-group-roles.sh appdb   -> creates appdb_readonly, appdb_readwrite
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

DB="${1:-}"; [ -n "$DB" ] || read -rp "Database name: " DB
db_exists "$DB" || die "Database '$DB' does not exist."

RO="${DB}_readonly"
RW="${DB}_readwrite"

# Create group role (NOLOGIN) if it does not exist yet
for g in "$RO" "$RW"; do
  role_exists "$g" || $PSQL -v g="$g" <<'SQL'
CREATE ROLE :"g" NOLOGIN;
SQL
done

# Grant privileges inside the database
$PSQL -d "$DB" -v db="$DB" -v ro="$RO" -v rw="$RW" <<'SQL'
GRANT CONNECT ON DATABASE :"db" TO :"ro", :"rw";
GRANT USAGE ON SCHEMA public TO :"ro", :"rw";

-- privileges on EXISTING tables
GRANT SELECT ON ALL TABLES IN SCHEMA public TO :"ro";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO :"rw";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO :"rw";

-- privileges for tables CREATED LATER (default privileges)
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON TABLES TO :"ro";
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"rw";
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO :"rw";
SQL

echo ">> Created 2 groups for '$DB':"
echo "   - $RO  (read-only)"
echo "   - $RW  (read + write)"
echo "   Assign a user to a group: ./create-user.sh <user> $RO   or  GRANT $RW TO <user>;"
