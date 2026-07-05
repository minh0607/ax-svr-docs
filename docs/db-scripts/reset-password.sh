#!/usr/bin/env bash
# Change a role's password.
# Usage: ./reset-password.sh <role>
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

NAME="${1:-}"; [ -n "$NAME" ] || read -rp "Role to change password for: " NAME
role_exists "$NAME" || die "Role '$NAME' does not exist."

PW="$(prompt_pw "NEW password for $NAME")"
PW2="$(prompt_pw "Re-enter password")"
[ -n "$PW" ] || die "Empty password."
[ "$PW" = "$PW2" ] || die "The two entries do not match."

$PSQL -v n="$NAME" -v pw="$PW" <<'SQL'
ALTER ROLE :"n" PASSWORD :'pw';
SQL
echo ">> Changed password for role: $NAME"
