#!/usr/bin/env bash
# Tạo USER ADMIN — role quản lý user/DB (CREATEROLE + CREATEDB) nhưng KHÔNG phải superuser.
# Dùng để uỷ quyền tạo user/cấp quyền mà không cần đưa superuser.
# Dùng: ./create-user-admin.sh [tên]   (vd: ./create-user-admin.sh useradmin)
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

NAME="${1:-}"; [ -n "$NAME" ] || read -rp "Tên user admin (vd useradmin): " NAME
role_exists "$NAME" && die "Role '$NAME' đã tồn tại."

PW="$(prompt_pw "Mật khẩu cho $NAME")"
[ -n "$PW" ] || die "Mật khẩu rỗng."

# CREATEROLE: tạo/sửa role khác. CREATEDB: tạo database. KHÔNG superuser.
$PSQL -v n="$NAME" -v pw="$PW" <<'SQL'
CREATE ROLE :"n" LOGIN CREATEROLE CREATEDB PASSWORD :'pw';
SQL
echo ">> Đã tạo USER ADMIN (CREATEROLE + CREATEDB, không superuser): $NAME"
