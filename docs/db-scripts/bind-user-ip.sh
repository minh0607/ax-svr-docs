#!/usr/bin/env bash
# Pin 1 user CHỈ kết nối được từ IP cụ thể (1 hoặc nhiều) — chỉnh pg_hba.conf.
# Áp dụng cho DevDB / PostgreSQL standalone (pg_hba là FILE).
# ----------------------------------------------------------------------------
# Dùng:
#   ./bind-user-ip.sh <user> <ip1[,ip2,...]>     # pin user vào (các) IP
#   ./bind-user-ip.sh <user> --unpin             # bỏ pin (user trở lại rule chung)
# Ví dụ:
#   ./bind-user-ip.sh app_svc 10.1.1.101
#   ./bind-user-ip.sh dev_a   192.0.2.10,192.0.2.11
#   ./bind-user-ip.sh dev_a   --unpin
# ----------------------------------------------------------------------------
# PRODUCTION (Patroni): pg_hba do Patroni quản lý -> KHÔNG sửa file.
#   Thêm rule vào patroni.yml mục bootstrap.dcs.postgresql.pg_hba (hoặc
#   `patronictl edit-config`) rồi `patronictl reload`. Xem ghi chú cuối file.
# ============================================================================
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

PG_VER="${PG_VER:-17}"
HBA="${HBA:-/etc/postgresql/$PG_VER/main/pg_hba.conf}"
PERUSER="$(dirname "$HBA")/pg_hba_peruser.conf"
INCLUDE_LINE="include_if_exists pg_hba_peruser.conf"

USER_NAME="${1:-}"; ACTION="${2:-}"
[ -n "$USER_NAME" ] && [ -n "$ACTION" ] || die "Dùng: $0 <user> <ip1[,ip2]> | <user> --unpin"
[ -f "$HBA" ] || die "Không thấy $HBA (đặt biến HBA=... nếu khác)."
role_exists "$USER_NAME" || die "Role '$USER_NAME' không tồn tại."

# Backup pg_hba
sudo cp -a "$HBA" "$HBA.bak" 2>/dev/null || true
sudo touch "$PERUSER"
sudo chown --reference="$HBA" "$PERUSER" 2>/dev/null || true
sudo chmod 640 "$PERUSER" 2>/dev/null || true

# Đảm bảo include nằm ở ĐẦU pg_hba.conf (per-user rule ưu tiên cao nhất)
if ! grep -qxF "$INCLUDE_LINE" "$HBA"; then
  sudo sed -i "1i $INCLUDE_LINE" "$HBA"
  echo "  + đã thêm '$INCLUDE_LINE' vào đầu $HBA"
fi

# Xoá block cũ của user (nếu có)
sudo sed -i "/^# >>> peruser:$USER_NAME$/,/^# <<< peruser:$USER_NAME$/d" "$PERUSER"

if [ "$ACTION" = "--unpin" ]; then
  echo ">> Đã BỎ PIN cho '$USER_NAME' — user trở lại rule chung."
else
  IPS="$ACTION"
  BLOCK="# >>> peruser:$USER_NAME"$'\n'
  IFS=',' read -ra arr <<< "$IPS"
  for ip in "${arr[@]}"; do
    case "$ip" in */*) ;; *) ip="$ip/32";; esac      # không có mask -> /32
    BLOCK+="host    all    $USER_NAME    $ip    scram-sha-256"$'\n'
  done
  # cấm user từ MỌI IP khác (IPv4 + IPv6)
  BLOCK+="host    all    $USER_NAME    0.0.0.0/0    reject"$'\n'
  BLOCK+="host    all    $USER_NAME    ::0/0        reject"$'\n'
  BLOCK+="# <<< peruser:$USER_NAME"
  printf '%s\n' "$BLOCK" | sudo tee -a "$PERUSER" >/dev/null
  echo ">> Đã PIN '$USER_NAME' chỉ từ: $IPS (mọi IP khác bị reject)."
fi

# Reload + kiểm tra lỗi cú pháp pg_hba
$PSQL -c "SELECT pg_reload_conf();" >/dev/null
echo "--- Kiểm tra lỗi pg_hba (rỗng = OK) ---"
$PSQL -c "SELECT line_number, type, error FROM pg_hba_file_rules WHERE error IS NOT NULL;"
echo "--- Rule hiện tại của '$USER_NAME' ---"
$PSQL -tAc "SELECT type, address, auth_method FROM pg_hba_file_rules
            WHERE '$USER_NAME' = ANY(user_name) ORDER BY line_number;"
