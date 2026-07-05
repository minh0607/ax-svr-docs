#!/usr/bin/env bash
# Create a regular USER (login). Optionally assign to a group role to inherit group privileges.
# Usage: ./create-user.sh <username> [group_role]
#   e.g.: ./create-user.sh dev_a
#         ./create-user.sh dev_a appdb_readonly
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

NAME="${1:-}"; [ -n "$NAME" ] || read -rp "Username: " NAME
GROUP="${2:-}"
role_exists "$NAME" && die "Role '$NAME' already exists."

PW="$(prompt_pw "Password for $NAME")"
[ -n "$PW" ] || die "Password is empty."

$PSQL -v n="$NAME" -v pw="$PW" <<'SQL'
CREATE ROLE :"n" LOGIN PASSWORD :'pw';
SQL
echo ">> Created user: $NAME"

if [ -n "$GROUP" ]; then
  role_exists "$GROUP" || die "Group role '$GROUP' does not exist (create it with setup-group-roles.sh)."
  $PSQL -v n="$NAME" -v g="$GROUP" <<'SQL'
GRANT :"g" TO :"n";
SQL
  echo ">> Assigned $NAME to group $GROUP"
fi
