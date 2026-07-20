#!/usr/bin/env bash
# Grant/revoke SCHEMA-level privileges (USAGE / CREATE / ALL) for a role.
# USAGE = may "enter" the schema and reference objects in it (needed to reach its tables).
# CREATE = may create new objects (tables, etc.) inside the schema.
# Usage: ./grant-schema.sh <grant|revoke> <role> <db> <schema> <USAGE|CREATE|ALL>
#   e.g.: ./grant-schema.sh grant  dev_a appdb finance USAGE
#         ./grant-schema.sh revoke dev_a appdb finance CREATE
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

ACTION="${1:-}"; ROLE="${2:-}"; DB="${3:-}"; SCH="${4:-}"; PRIV="${5:-}"
[ -n "$ACTION" ] && [ -n "$ROLE" ] && [ -n "$DB" ] && [ -n "$SCH" ] && [ -n "$PRIV" ] \
  || die "Missing arguments. See usage at the top."
role_exists "$ROLE" || die "Role '$ROLE' does not exist."
db_exists "$DB"     || die "Database '$DB' does not exist."
[ "$($PSQL -d "$DB" -tAc "SELECT 1 FROM information_schema.schemata WHERE schema_name='$SCH'")" = "1" ] \
  || die "Schema '$SCH' does not exist in '$DB'."

# normalise + validate the privilege keyword
P="$(printf '%s' "$PRIV" | tr '[:lower:]' '[:upper:]')"
case "$P" in USAGE|CREATE|ALL) ;; *) die "Privilege must be USAGE, CREATE, or ALL (got '$PRIV').";; esac

case "$ACTION" in
  grant)
    $PSQL -d "$DB" -v r="$ROLE" -v s="$SCH" <<SQL
GRANT $P ON SCHEMA :"s" TO :"r";
SQL
    echo ">> GRANT $P ON SCHEMA $SCH  ->  $ROLE  (db: $DB)"
    ;;
  revoke)
    $PSQL -d "$DB" -v r="$ROLE" -v s="$SCH" <<SQL
REVOKE $P ON SCHEMA :"s" FROM :"r";
SQL
    echo ">> REVOKE $P ON SCHEMA $SCH  <-  $ROLE  (db: $DB)"
    ;;
  *) die "ACTION must be 'grant' or 'revoke'.";;
esac
