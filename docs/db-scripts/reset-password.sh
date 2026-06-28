#!/usr/bin/env bash
# Đổi mật khẩu 1 role.
# Dùng: ./reset-password.sh <role>
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

NAME="${1:-}"; [ -n "$NAME" ] || read -rp "Role cần đổi mật khẩu: " NAME
role_exists "$NAME" || die "Role '$NAME' không tồn tại."

PW="$(prompt_pw "Mật khẩu MỚI cho $NAME")"
PW2="$(prompt_pw "Nhập lại mật khẩu")"
[ -n "$PW" ] || die "Mật khẩu rỗng."
[ "$PW" = "$PW2" ] || die "Hai lần nhập không khớp."

$PSQL -v n="$NAME" -v pw="$PW" <<'SQL'
ALTER ROLE :"n" PASSWORD :'pw';
SQL
echo ">> Đã đổi mật khẩu cho role: $NAME"
