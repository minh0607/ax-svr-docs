#!/usr/bin/env bash
# Xoá role/user AN TOÀN: chuyển quyền sở hữu object sang owner khác (mọi DB) rồi mới DROP.
# Dùng: ./drop-user.sh <user> [reassign_to]     (mặc định reassign_to=dbadmin)
#   vd: ./drop-user.sh dev_a
#       ./drop-user.sh dev_a dbadmin
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

PROTECTED="postgres dbadmin useradmin replicator"

NAME="${1:-}"; [ -n "$NAME" ] || read -rp "User cần xoá: " NAME
REASSIGN_TO="${2:-dbadmin}"

# Chốt chặn: không xoá role hệ thống/quan trọng
for p in $PROTECTED; do
  [ "$NAME" = "$p" ] && die "TỪ CHỐI: '$NAME' là role được bảo vệ, không xoá qua script này."
done
role_exists "$NAME" || die "Role '$NAME' không tồn tại."
role_exists "$REASSIGN_TO" || die "Role nhận quyền '$REASSIGN_TO' không tồn tại."

echo "Sẽ XOÁ role: $NAME"
echo "  - Chuyển mọi object đang sở hữu -> $REASSIGN_TO (trên TẤT CẢ database)"
echo "  - Thu hồi quyền còn lại rồi DROP ROLE"
confirm "Xác nhận xoá '$NAME'?" || { echo "Hủy."; exit 0; }

# REASSIGN + DROP OWNED phải chạy trong TỪNG database
DBS="$($PSQL -tAc "SELECT datname FROM pg_database WHERE datistemplate=false AND datallowconn")"
for db in $DBS; do
  echo "  [db: $db] reassign + drop owned ..."
  $PSQL -d "$db" -v u="$NAME" -v t="$REASSIGN_TO" -c 'REASSIGN OWNED BY :"u" TO :"t";' || true
  $PSQL -d "$db" -v u="$NAME" -c 'DROP OWNED BY :"u";' || true
done

$PSQL -v u="$NAME" -c 'DROP ROLE :"u";'
echo ">> Đã xoá role: $NAME (object đã chuyển cho $REASSIGN_TO)"
