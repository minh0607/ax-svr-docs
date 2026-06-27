#!/usr/bin/env bash
# Tạo GROUP ROLE readonly/readwrite cho 1 database + DEFAULT PRIVILEGES
# => bảng tạo SAU NÀY cũng tự được cấp quyền (không phải grant lại từng bảng).
# Dùng: ./setup-group-roles.sh <dbname>
#   vd: ./setup-group-roles.sh appdb   -> tạo appdb_readonly, appdb_readwrite
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

DB="${1:-}"; [ -n "$DB" ] || read -rp "Tên database: " DB
db_exists "$DB" || die "Database '$DB' chưa tồn tại."

RO="${DB}_readonly"
RW="${DB}_readwrite"

# Tạo group role (NOLOGIN) nếu chưa có
for g in "$RO" "$RW"; do
  role_exists "$g" || $PSQL -v g="$g" -c 'CREATE ROLE :"g" NOLOGIN;'
done

# Cấp quyền trong database
$PSQL -d "$DB" -v db="$DB" -v ro="$RO" -v rw="$RW" <<'SQL'
GRANT CONNECT ON DATABASE :"db" TO :"ro", :"rw";
GRANT USAGE ON SCHEMA public TO :"ro", :"rw";

-- quyền trên bảng ĐANG CÓ
GRANT SELECT ON ALL TABLES IN SCHEMA public TO :"ro";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO :"rw";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO :"rw";

-- quyền cho bảng SẼ TẠO sau này (default privileges)
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON TABLES TO :"ro";
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"rw";
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO :"rw";
SQL

echo ">> Đã tạo 2 nhóm cho '$DB':"
echo "   - $RO  (chỉ đọc)"
echo "   - $RW  (đọc + ghi)"
echo "   Gán user vào nhóm: ./create-user.sh <user> $RO   hoặc  GRANT $RW TO <user>;"
