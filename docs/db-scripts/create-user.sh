#!/usr/bin/env bash
# Tạo USER thường (login). Tuỳ chọn gán vào group role để hưởng quyền nhóm.
# Dùng: ./create-user.sh <username> [group_role]
#   vd: ./create-user.sh dev_a
#       ./create-user.sh dev_a appdb_readonly
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

NAME="${1:-}"; [ -n "$NAME" ] || read -rp "Tên user: " NAME
GROUP="${2:-}"
role_exists "$NAME" && die "Role '$NAME' đã tồn tại."

PW="$(prompt_pw "Mật khẩu cho $NAME")"
[ -n "$PW" ] || die "Mật khẩu rỗng."

$PSQL -v n="$NAME" -v pw="$PW" <<'SQL'
CREATE ROLE :"n" LOGIN PASSWORD :'pw';
SQL
echo ">> Đã tạo user: $NAME"

if [ -n "$GROUP" ]; then
  role_exists "$GROUP" || die "Group role '$GROUP' chưa tồn tại (tạo bằng setup-group-roles.sh)."
  $PSQL -v n="$NAME" -v g="$GROUP" <<'SQL'
GRANT :"g" TO :"n";
SQL
  echo ">> Đã gán $NAME vào nhóm $GROUP"
fi
