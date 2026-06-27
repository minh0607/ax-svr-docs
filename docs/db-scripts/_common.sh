#!/usr/bin/env bash
# ============================================================================
# _common.sh — nguồn chung cho các script quản trị PostgreSQL (source vào script khác)
# ----------------------------------------------------------------------------
# Cách kết nối quyền admin:
#   - Mặc định: chạy NGAY TRÊN DB server, dùng socket as user postgres.
#   - Chạy TỪ XA: export PSQL_ADMIN="psql -h 107.118.210.90 -U dbadmin"
#                 (sẽ hỏi mật khẩu dbadmin, hoặc đặt PGPASSWORD)
# ============================================================================
set -euo pipefail

PSQL_ADMIN="${PSQL_ADMIN:-sudo -u postgres psql}"
PSQL="$PSQL_ADMIN -v ON_ERROR_STOP=1 -X -q"

role_exists() { [ "$($PSQL -tAc "SELECT 1 FROM pg_roles    WHERE rolname='$1'" 2>/dev/null)" = "1" ]; }
db_exists()   { [ "$($PSQL -tAc "SELECT 1 FROM pg_database WHERE datname='$1'" 2>/dev/null)" = "1" ]; }

# Hỏi mật khẩu an toàn (không hiện ra màn hình, không vào history)
prompt_pw() { local v; read -rsp "$1: " v >&2; echo >&2; printf '%s' "$v"; }

confirm() { local a; read -rp "$1 [y/N]: " a >&2; [ "$a" = y ] || [ "$a" = Y ]; }

die() { echo "LỖI: $*" >&2; exit 1; }

# Lưu ý: nếu postgresql.conf đang log_statement='all', câu lệnh tạo/đổi mật khẩu
# có thể bị ghi log. Trên Production nên dùng log_statement='ddl' hoặc 'none'.
