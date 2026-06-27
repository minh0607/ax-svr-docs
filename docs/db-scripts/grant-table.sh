#!/usr/bin/env bash
# Phân quyền theo TỪNG BẢNG (grant/revoke) cho 1 role.
# Dùng: ./grant-table.sh <grant|revoke> <role> <db> <table> <privs>
#   table : tên bảng (vd orders) HOẶC "ALL TABLES IN SCHEMA public"
#   privs : SELECT | INSERT | UPDATE | DELETE | "SELECT,INSERT,UPDATE" | ALL
# Ví dụ:
#   ./grant-table.sh grant  dev_a appdb orders "SELECT,INSERT,UPDATE"
#   ./grant-table.sh revoke dev_a appdb orders INSERT
#   ./grant-table.sh grant  reporting appdb "ALL TABLES IN SCHEMA public" SELECT
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

ACTION="${1:-}"; ROLE="${2:-}"; DB="${3:-}"; TBL="${4:-}"; PRIVS="${5:-}"
[ -n "$ACTION" ] && [ -n "$ROLE" ] && [ -n "$DB" ] && [ -n "$TBL" ] && [ -n "$PRIVS" ] \
  || die "Thiếu tham số. Xem hướng dẫn ở đầu file."

role_exists "$ROLE" || die "Role '$ROLE' chưa tồn tại."
db_exists "$DB"     || die "Database '$DB' chưa tồn tại."

case "$ACTION" in
  grant)
    $PSQL -d "$DB" -v r="$ROLE" -c "GRANT $PRIVS ON $TBL TO :\"r\";"
    echo ">> GRANT $PRIVS ON $TBL  ->  $ROLE  (db: $DB)"
    ;;
  revoke)
    $PSQL -d "$DB" -v r="$ROLE" -c "REVOKE $PRIVS ON $TBL FROM :\"r\";"
    echo ">> REVOKE $PRIVS ON $TBL  <-  $ROLE  (db: $DB)"
    ;;
  *) die "ACTION phải là 'grant' hoặc 'revoke'.";;
esac
