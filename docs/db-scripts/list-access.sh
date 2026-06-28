#!/usr/bin/env bash
# Liệt kê role / database / quyền — để kiểm tra ai có quyền gì.
# Dùng:
#   ./list-access.sh roles            # danh sách role + thuộc tính
#   ./list-access.sh dbs              # danh sách database
#   ./list-access.sh members <group>  # thành viên 1 group role
#   ./list-access.sh grants <db>      # quyền trên bảng trong 1 db (\dp)
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

CMD="${1:-roles}"
case "$CMD" in
  roles) $PSQL -c "\du" ;;
  dbs)   $PSQL -c "\l" ;;
  members)
    G="${2:-}"; [ -n "$G" ] || die "Thiếu tên group."
    $PSQL -v g="$G" -tA <<'SQL'
SELECT m.rolname FROM pg_auth_members am
JOIN pg_roles g ON g.oid=am.roleid
JOIN pg_roles m ON m.oid=am.member
WHERE g.rolname=:'g' ORDER BY 1;
SQL
    ;;
  grants)
    DB="${2:-}"; [ -n "$DB" ] || die "Thiếu tên db."
    db_exists "$DB" || die "Database '$DB' chưa tồn tại."
    $PSQL -d "$DB" -c "\dp"
    ;;
  *) die "Lệnh không hợp lệ. Xem hướng dẫn ở đầu file.";;
esac
