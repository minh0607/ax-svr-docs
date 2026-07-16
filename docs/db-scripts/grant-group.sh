#!/usr/bin/env bash
# Grant/revoke GROUP ROLE membership for a user (role membership — NOT table privileges).
# Use this to assign a user to a project group, or to give cross-project access.
# Usage: ./grant-group.sh <grant|revoke> <user> <group>
#   e.g.: ./grant-group.sh grant  dev_a finance_readonly
#         ./grant-group.sh revoke dev_a finance_readonly
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

ACTION="${1:-}"; USER_="${2:-}"; GROUP="${3:-}"
[ -n "$ACTION" ] && [ -n "$USER_" ] && [ -n "$GROUP" ] || die "Missing arguments. See usage at the top."
role_exists "$USER_" || die "Role '$USER_' does not exist."
role_exists "$GROUP" || die "Group role '$GROUP' does not exist."

case "$ACTION" in
  grant)
    $PSQL -v u="$USER_" -v g="$GROUP" <<'SQL'
GRANT :"g" TO :"u";
SQL
    echo ">> GRANT group $GROUP -> $USER_"
    ;;
  revoke)
    $PSQL -v u="$USER_" -v g="$GROUP" <<'SQL'
REVOKE :"g" FROM :"u";
SQL
    echo ">> REVOKE group $GROUP <- $USER_"
    ;;
  *) die "ACTION must be 'grant' or 'revoke'.";;
esac
