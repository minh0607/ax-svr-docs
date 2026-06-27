#!/usr/bin/env bash
# ============================================================================
# AX Svr — Apply firewall (ufw) theo vai trò. CHỈ admin remote (SSH) được.
# Môi trường air-gap. Nhập IP admin -> mở SSH chỉ cho IP đó + port theo vai trò.
# ----------------------------------------------------------------------------
# Dùng:
#   sudo ./apply-firewall.sh <role> [admin_ip[,admin_ip2,...]]
#   role: proxy | nas | db | mon | devdb
#   (không truyền admin_ip -> script sẽ hỏi)
# Ví dụ:
#   sudo ./apply-firewall.sh db 107.118.210.50
#   sudo ./apply-firewall.sh proxy 107.118.210.50,107.118.210.51
# ============================================================================
set -euo pipefail

# ----- THAM SỐ MẠNG (chỉnh nếu khác) ----------------------------------------
LAN_SUBNET="10.1.1.0/24"          # mạng nội bộ giữa các server
MON_IP="10.1.1.96"                # node monitoring (scrape exporter)
WAN_USER_SUBNET="107.118.210.0/24" # dải user truy cập web (cho proxy 80/443)
DEV_DB_SUBNET="107.118.210.0/24"  # dải máy Dev được phép kết nối DevDB:5432

[ "$(id -u)" -eq 0 ] || { echo "Cần chạy bằng sudo/root."; exit 1; }

ROLE="${1:-}"
ADMINS="${2:-}"

case "$ROLE" in
  proxy|nas|db|mon|devdb) ;;
  *) echo "Usage: sudo $0 <proxy|nas|db|mon|devdb> [admin_ip,...]"; exit 1;;
esac

# Hỏi IP admin nếu chưa truyền
if [ -z "$ADMINS" ]; then
  read -rp "Nhập IP admin được phép SSH (phân tách bằng dấu phẩy nếu nhiều): " ADMINS
fi
[ -n "$ADMINS" ] || { echo "Chưa nhập IP admin."; exit 1; }

# Tách danh sách IP
IFS=',' read -ra ADMIN_IPS <<< "$ADMINS"

# Xác nhận
echo "------------------------------------------------------------"
echo " Role        : $ROLE"
echo " Admin SSH   : ${ADMIN_IPS[*]}"
echo " LAN subnet  : $LAN_SUBNET"
echo "------------------------------------------------------------"
read -rp "Áp dụng firewall? Thao tác sẽ RESET ufw. [y/N]: " ok
[ "$ok" = "y" ] || [ "$ok" = "Y" ] || { echo "Hủy."; exit 0; }

# ----- Base policy ----------------------------------------------------------
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# SSH CHỈ từ IP admin
for ip in "${ADMIN_IPS[@]}"; do
  ufw allow from "$ip" to any port 22 proto tcp comment "admin SSH"
done

# ----- Rule theo vai trò ----------------------------------------------------
allow_mon() { ufw allow from "$MON_IP" to any port "$1" proto tcp comment "mon scrape"; }

case "$ROLE" in
  proxy)
    ufw allow from "$WAN_USER_SUBNET" to any port 80  proto tcp comment "user http"
    ufw allow from "$WAN_USER_SUBNET" to any port 443 proto tcp comment "user https"
    allow_mon 9100      # node_exporter
    allow_mon 9113      # nginx_exporter
    ;;
  db)
    ufw allow from "$LAN_SUBNET" to any port 5432 proto tcp comment "postgres"
    ufw allow from "$LAN_SUBNET" to any port 8008 proto tcp comment "patroni"
    ufw allow from "$LAN_SUBNET" to any port 2379 proto tcp comment "etcd client"
    ufw allow from "$LAN_SUBNET" to any port 2380 proto tcp comment "etcd peer"
    allow_mon 9100      # node_exporter
    allow_mon 9187      # postgres_exporter
    # (DB3 cũng dùng role 'db' — backup nội bộ qua SSH đã mở cho LAN? backup dùng SSH 22)
    ufw allow from "$LAN_SUBNET" to any port 22 proto tcp comment "pgbackrest ssh (LAN)"
    ;;
  nas)
    ufw allow from "$LAN_SUBNET" to any port 445 proto tcp comment "smb"
    ufw allow from "$LAN_SUBNET" to any port 139 proto tcp comment "smb"
    allow_mon 9100
    ;;
  mon)
    # Grafana/Prometheus chỉ cho admin xem
    for ip in "${ADMIN_IPS[@]}"; do
      ufw allow from "$ip" to any port 3000 proto tcp comment "grafana admin"
      ufw allow from "$ip" to any port 9090 proto tcp comment "prometheus admin"
    done
    ;;
  devdb)
    ufw allow from "$DEV_DB_SUBNET" to any port 5432 proto tcp comment "dev db access"
    ;;
esac

ufw --force enable
echo
ufw status verbose
echo
echo ">> XONG firewall cho role '$ROLE'. SSH chỉ mở cho: ${ADMIN_IPS[*]}"
