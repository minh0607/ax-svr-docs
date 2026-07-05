#!/usr/bin/env bash
# Create a DATABASE ADMIN (SUPERUSER) — used by the DBA for remote administration, replacing the built-in 'postgres'.
# Usage: ./create-db-admin.sh [name]      (e.g.: ./create-db-admin.sh dbadmin)
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

NAME="${1:-}"; [ -n "$NAME" ] || read -rp "DB admin name (e.g. dbadmin): " NAME
[ "$NAME" = postgres ] && die "Do not use the name 'postgres'. Choose a different name."
role_exists "$NAME" && die "Role '$NAME' already exists."

PW="$(prompt_pw "Password for $NAME")"
[ -n "$PW" ] || die "Password is empty."

$PSQL -v n="$NAME" -v pw="$PW" <<'SQL'
CREATE ROLE :"n" LOGIN SUPERUSER CREATEDB CREATEROLE PASSWORD :'pw';
SQL
echo ">> Created DB ADMIN (SUPERUSER): $NAME"
echo "   DBA remote login: psql -h <host> -U $NAME -d postgres"
