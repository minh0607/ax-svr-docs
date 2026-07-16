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

# Resolve the schema the target lives in, so we can ensure USAGE on it.
# PostgreSQL requires BOTH: USAGE on the schema AND a privilege on the table.
# Echoes the schema name, or nothing if it cannot be resolved.
target_schema() {
  local db="$1" tbl="$2"
  if printf '%s' "$tbl" | grep -qiE '^[[:space:]]*ALL[[:space:]]+TABLES[[:space:]]+IN[[:space:]]+SCHEMA[[:space:]]+'; then
    printf '%s' "$tbl" | sed -E 's/^[[:space:]]*[Aa][Ll][Ll][[:space:]]+[Tt][Aa][Bb][Ll][Ee][Ss][[:space:]]+[Ii][Nn][[:space:]]+[Ss][Cc][Hh][Ee][Mm][Aa][[:space:]]+//; s/[[:space:]]*;?[[:space:]]*$//'
    return 0
  fi
  # to_regclass resolves exactly like the GRANT will (same search_path); NULL if absent
  $PSQL -d "$db" -tAc "SELECT n.nspname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.oid = to_regclass('$tbl')"
}

case "$ACTION" in
  grant)
    SCH="$(target_schema "$DB" "$TBL")"
    if [ -n "$SCH" ]; then
      $PSQL -d "$DB" -v r="$ROLE" -v s="$SCH" <<'SQL'
GRANT USAGE ON SCHEMA :"s" TO :"r";
SQL
      echo ">> GRANT USAGE ON SCHEMA $SCH  ->  $ROLE   (required to reach tables inside it)"
    fi
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
    echo "   NOTE: USAGE on the schema was left in place (the role may still need it for other tables)."
    echo "         To cut off the whole schema: REVOKE USAGE ON SCHEMA <schema> FROM $ROLE;"
    ;;
  *) die "ACTION must be 'grant' or 'revoke'.";;
esac
