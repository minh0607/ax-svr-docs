#!/usr/bin/env bash
# Create a DATABASE + tighten default privileges (revoke PUBLIC) for safety.
# Usage: ./create-database.sh <dbname> [owner]
#   e.g.: ./create-database.sh appdb dbadmin
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

DB="${1:-}"; [ -n "$DB" ] || read -rp "Database name: " DB
OWNER="${2:-}"; [ -n "$OWNER" ] || read -rp "Owner (owning role): " OWNER

db_exists "$DB" && die "Database '$DB' already exists."
role_exists "$OWNER" || die "Owner '$OWNER' does not exist."

# Create DB (CREATE DATABASE cannot run inside a transaction, so keep it separate)
$PSQL -v d="$DB" -v o="$OWNER" <<'SQL'
CREATE DATABASE :"d" OWNER :"o" ENCODING UTF8;
SQL

# Tighten privileges: do not let PUBLIC connect / create objects in this db
$PSQL -d "$DB" -v d="$DB" <<'SQL'
REVOKE ALL ON DATABASE :"d" FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
SQL

echo ">> Created database: $DB (owner: $OWNER), PUBLIC privileges revoked."
echo "   Next: ./setup-group-roles.sh $DB  → create readonly/readwrite groups"
