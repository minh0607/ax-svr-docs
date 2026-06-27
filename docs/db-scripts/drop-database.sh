#!/usr/bin/env bash
# Xoá DATABASE AN TOÀN: nhắc backup + yêu cầu gõ lại đúng tên + ngắt kết nối (FORCE).
# Dùng: ./drop-database.sh <dbname>
#   vd: ./drop-database.sh appdb
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

PROTECTED="postgres template0 template1"

DB="${1:-}"; [ -n "$DB" ] || read -rp "Database cần xoá: " DB

for p in $PROTECTED; do
  [ "$DB" = "$p" ] && die "TỪ CHỐI: '$DB' là database hệ thống, không xoá."
done
db_exists "$DB" || die "Database '$DB' không tồn tại."

# Thông tin trước khi xoá
SIZE="$($PSQL -tAc "SELECT pg_size_pretty(pg_database_size('$DB'))")"
CONN="$($PSQL -tAc "SELECT count(*) FROM pg_stat_activity WHERE datname='$DB'")"
echo "------------------------------------------------------------"
echo " Database : $DB"
echo " Dung lượng: $SIZE"
echo " Kết nối đang mở: $CONN"
echo "------------------------------------------------------------"
echo "⚠️  XOÁ DATABASE LÀ KHÔNG THỂ HOÀN TÁC. Hãy chắc đã backup!"
echo "    (pgBackRest/pg_dump — xem Phase 5)"

# Xác nhận MẠNH: gõ lại đúng tên database
read -rp "Gõ lại CHÍNH XÁC tên database để xác nhận xoá: " TYPED
[ "$TYPED" = "$DB" ] || die "Tên không khớp ('$TYPED' != '$DB'). Hủy."

# FORCE: tự ngắt các kết nối đang mở (PostgreSQL 13+)
$PSQL -v d="$DB" -c 'DROP DATABASE IF EXISTS :"d" WITH (FORCE);'
echo ">> Đã xoá database: $DB"
