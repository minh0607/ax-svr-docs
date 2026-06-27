#!/usr/bin/env bash
# Tạo DATABASE ADMIN (SUPERUSER) — DBA dùng để quản trị từ xa, thay cho 'postgres' gốc.
# Dùng: ./create-db-admin.sh [tên]      (vd: ./create-db-admin.sh dbadmin)
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

NAME="${1:-}"; [ -n "$NAME" ] || read -rp "Tên DB admin (vd dbadmin): " NAME
[ "$NAME" = postgres ] && die "Đừng dùng tên 'postgres'. Hãy đặt tên khác."
role_exists "$NAME" && die "Role '$NAME' đã tồn tại."

PW="$(prompt_pw "Mật khẩu cho $NAME")"
[ -n "$PW" ] || die "Mật khẩu rỗng."

$PSQL -v n="$NAME" -v pw="$PW" <<'SQL'
CREATE ROLE :"n" LOGIN SUPERUSER CREATEDB CREATEROLE PASSWORD :'pw';
SQL
echo ">> Đã tạo DB ADMIN (SUPERUSER): $NAME"
echo "   DBA login từ xa: psql -h <host> -U $NAME -d postgres"
