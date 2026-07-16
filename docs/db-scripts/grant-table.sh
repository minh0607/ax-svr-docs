#!/usr/bin/env bash
# PER-TABLE privileges (grant/revoke) for a role.
# Usage: ./grant-table.sh <grant|revoke> <role> <db> <table> <privs>
#   table : table name (e.g. orders) OR "ALL TABLES IN SCHEMA public"
#   privs : SELECT | INSERT | UPDATE | DELETE | "SELECT,INSERT,UPDATE" | ALL
# Examples:
#   ./grant-table.sh grant  dev_a appdb orders "SELECT,INSERT,UPDATE"
#   ./grant-table.sh revoke dev_a appdb orders INSERT
#   ./grant-table.sh grant  reporting appdb "ALL TABLES IN SCHEMA public" SELECT
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

ACTION="${1:-}"; ROLE="${2:-}"; DB="${3:-}"; TBL="${4:-}"; PRIVS="${5:-}"
[ -n "$ACTION" ] && [ -n "$ROLE" ] && [ -n "$DB" ] && [ -n "$TBL" ] && [ -n "$PRIVS" ] \
  || die "Missing arguments. See the usage at the top of this file."

role_exists "$ROLE" || die "Role '$ROLE' does not exist."
db_exists "$DB"     || die "Database '$DB' does not exist."

case "$ACTION" in
  grant)
    $PSQL -d "$DB" -v r="$ROLE" <<SQL
GRANT $PRIVS ON $TBL TO :"r";
SQL
    echo ">> GRANT $PRIVS ON $TBL  ->  $ROLE  (db: $DB)"
    ;;
  revoke)
    $PSQL -d "$DB" -v r="$ROLE" <<SQL
REVOKE $PRIVS ON $TBL FROM :"r";
SQL
    echo ">> REVOKE $PRIVS ON $TBL  <-  $ROLE  (db: $DB)"
    ;;
  *) die "ACTION must be 'grant' or 'revoke'.";;
esac
