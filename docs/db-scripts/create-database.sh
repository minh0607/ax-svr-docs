#!/usr/bin/env bash
# Tạo DATABASE + siết quyền mặc định (revoke PUBLIC) cho an toàn.
# Dùng: ./create-database.sh <dbname> [owner]
#   vd: ./create-database.sh appdb dbadmin
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

DB="${1:-}"; [ -n "$DB" ] || read -rp "Tên database: " DB
OWNER="${2:-}"; [ -n "$OWNER" ] || read -rp "Owner (role sở hữu): " OWNER

db_exists "$DB" && die "Database '$DB' đã tồn tại."
role_exists "$OWNER" || die "Owner '$OWNER' chưa tồn tại."

# Tạo DB (CREATE DATABASE không chạy trong transaction nên tách riêng)
$PSQL -v d="$DB" -v o="$OWNER" <<'SQL'
CREATE DATABASE :"d" OWNER :"o" ENCODING UTF8;
SQL

# Siết quyền: không cho PUBLIC tự kết nối / tạo object trong db này
$PSQL -d "$DB" -v d="$DB" <<'SQL'
REVOKE ALL ON DATABASE :"d" FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
SQL

echo ">> Đã tạo database: $DB (owner: $OWNER), đã thu hồi quyền PUBLIC."
echo "   Tiếp theo: ./setup-group-roles.sh $DB  → tạo nhóm readonly/readwrite"
