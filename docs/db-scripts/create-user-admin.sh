#!/usr/bin/env bash
# Create a USER ADMIN — a role that manages users/DBs (CREATEROLE + CREATEDB) but is NOT a superuser.
# Used to delegate creating users/granting privileges without handing out superuser.
# Usage: ./create-user-admin.sh [name]   (e.g.: ./create-user-admin.sh useradmin)
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

NAME="${1:-}"; [ -n "$NAME" ] || read -rp "User admin name (e.g. useradmin): " NAME
role_exists "$NAME" && die "Role '$NAME' already exists."

PW="$(prompt_pw "Password for $NAME")"
[ -n "$PW" ] || die "Password is empty."

# CREATEROLE: create/modify other roles. CREATEDB: create databases. NOT a superuser.
$PSQL -v n="$NAME" -v pw="$PW" <<'SQL'
CREATE ROLE :"n" LOGIN CREATEROLE CREATEDB PASSWORD :'pw';
SQL
echo ">> Created USER ADMIN (CREATEROLE + CREATEDB, not superuser): $NAME"
