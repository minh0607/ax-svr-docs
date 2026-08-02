#!/usr/bin/env bash
# ============================================================================
# AX Svr — GENERATE lệnh firewall (ufw) theo từng host, khớp hạ tầng thực tế.
# ----------------------------------------------------------------------------
# Khác apply-firewall.sh (bản Prometheus cũ): script NÀY bám theo monitoring
# Zabbix (agent2 :10050 qua proxy) + siết cổng theo TỪNG HOST thay vì cả dải LAN.
#
# Mặc định chỉ IN LỆNH ra màn hình (air-gap: review trước rồi mới chạy).
#   sudo ./gen-firewall.sh db ax-db01            # xem lệnh cho db01
#   sudo ./gen-firewall.sh db ax-db01 | sudo bash   # tự tay pipe nếu muốn
#   sudo ./gen-firewall.sh db ax-db01 --apply    # hoặc để script tự chạy
#
#   role: db <node> | proxy <node> | nas
#   node: db  -> ax-db01|ax-db02|ax-db03
#         proxy-> ax-proxy01|ax-proxy02
#
# Mô hình truy cập (3 đường, KHÔNG hở 5432 ra WAN):
#   - web/app  -> DB qua LAN (5432)
#   - admin    -> SSH bastion (22) rồi mới psql; KHÔNG mở 5432 cho dải admin
#   - monitor  -> agent2 nối PG qua localhost (không cần mở 5432 cho Zabbix)
# Web (Windows/IIS) dùng firewall riêng -> xem apply-firewall-windows.ps1.
# ============================================================================
set -euo pipefail

# ----- THAM SỐ MẠNG (chỉnh cho khớp; có thể override bằng biến môi trường) ---
LAN_PREFIX="${LAN_PREFIX:-10.1.1}"                 # dải LAN nội bộ
ADMIN_SRC="${ADMIN_SRC:-107.118.210.0/24}"         # nguồn SSH/RDP admin (NÊN siết còn IP cụ thể)
WAN_USER_SUBNET="${WAN_USER_SUBNET:-107.118.210.0/24}"  # user vào web 80/443

ZBX_PROXY="${ZBX_PROXY:-<ZBX_PROXY_IP>}"           # IP Zabbix proxy 'sehc-svrproxy' (bắt buộc điền)
GRAFANA_IP="${GRAFANA_IP:-}"                        # IP server Grafana công ty (để trống = bỏ qua 5432 cho dashboard 8-9)
ADMIN_DB_IPS="${ADMIN_DB_IPS:-}"                    # IP workstation DBA nối thẳng 5432 (office-net), phân tách bằng ',' — để trống = không mở

# Octet cuối theo host inventory (đã chốt)
DB01="${LAN_PREFIX}.103"; DB02="${LAN_PREFIX}.104"; DB03="${LAN_PREFIX}.105"
WEB01="${LAN_PREFIX}.101"; WEB02="${LAN_PREFIX}.102"
PROXY01="${LAN_PREFIX}.98"; PROXY02="${LAN_PREFIX}.99"
NAS="${LAN_PREFIX}.97"

# ----- Tham số dòng lệnh ----------------------------------------------------
ROLE="${1:-}"; NODE=""; APPLY=0; NO_RESET=0
shift || true
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    --no-reset) NO_RESET=1 ;;
    *) NODE="$a" ;;
  esac
done

usage() { echo "Usage: sudo $0 <db|proxy|nas> [node] [--apply] [--no-reset]"; echo "  db    node: ax-db01|ax-db02|ax-db03"; echo "  proxy node: ax-proxy01|ax-proxy02"; echo "  --no-reset : bỏ 'ufw reset' (sửa live, tránh khe hở trên DB đã bind office-net)"; exit 1; }
[ -n "$ROLE" ] || usage

# Gom lệnh vào mảng rồi in/chạy 1 lần
RULES=()
add() { RULES+=("$*"); }

base_policy() {
  if [ "$NO_RESET" = 1 ]; then
    RULES+=("# --no-reset: giữ ruleset hiện có, chỉ thêm/đảm bảo các rule dưới (ufw tự bỏ qua rule trùng)")
  else
    add "ufw --force reset"
  fi
  add "ufw default deny incoming"
  add "ufw default allow outgoing"
  add "ufw allow from ${ADMIN_SRC} to any port 22 proto tcp comment 'admin SSH (bastion)'"
}

require_zbx() {
  if [ "$ZBX_PROXY" = "<ZBX_PROXY_IP>" ]; then
    echo "!! Chưa đặt ZBX_PROXY. Chạy: ZBX_PROXY=10.1.1.xx sudo $0 $ROLE $NODE" >&2
    echo "   (IP của Zabbix proxy 'sehc-svrproxy' — để mở 10050/8008/8080 cho nó)" >&2
    exit 1
  fi
}

case "$ROLE" in
  db)
    case "$NODE" in
      ax-db01) SELF=$DB01; PEERS=("$DB02" "$DB03") ;;
      ax-db02) SELF=$DB02; PEERS=("$DB01" "$DB03") ;;
      ax-db03) SELF=$DB03; PEERS=("$DB01" "$DB02") ;;
      *) echo "db cần node ax-db01|ax-db02|ax-db03"; usage ;;
    esac
    require_zbx
    base_policy
    # 5432: replication giữa DB node + app (web) + Grafana (dashboard 8-9)
    for p in "${PEERS[@]}"; do
      add "ufw allow from ${p} to any port 5432 proto tcp comment 'pg replication (${p})'"
    done
    add "ufw allow from ${WEB01} to any port 5432 proto tcp comment 'app ax-web01'"
    add "ufw allow from ${WEB02} to any port 5432 proto tcp comment 'app ax-web02'"
    if [ -n "$GRAFANA_IP" ]; then
      add "ufw allow from ${GRAFANA_IP} to any port 5432 proto tcp comment 'grafana direct-PG (dashboard 8-9)'"
    else
      RULES+=("# (bỏ qua 5432 cho Grafana — đặt GRAFANA_IP=... nếu dùng dashboard 8-9)")
    fi
    # 5432 cho DBA nối thẳng từ office-net (chỉ khi bind office-net + khai ADMIN_DB_IPS)
    if [ -n "$ADMIN_DB_IPS" ]; then
      IFS=',' read -ra _ADM <<< "$ADMIN_DB_IPS"
      for ip in "${_ADM[@]}"; do
        add "ufw allow from ${ip} to any port 5432 proto tcp comment 'DBA workstation'"
      done
      RULES+=("# nhớ: ghim pg_hba từng IP này (axdb.sh bind-ip <admin> ${_ADM[0]}) + scram-sha-256")
    else
      RULES+=("# (không mở 5432 cho DBA office-net — đặt ADMIN_DB_IPS=ip1,ip2 nếu dùng hướng bind office-net)")
    fi
    # 8008 Patroni REST: giữa DB node (điều phối failover) + Zabbix (Patroni by HTTP)
    for p in "${PEERS[@]}"; do
      add "ufw allow from ${p} to any port 8008 proto tcp comment 'patroni REST (${p})'"
    done
    add "ufw allow from ${ZBX_PROXY} to any port 8008 proto tcp comment 'zabbix Patroni by HTTP'"
    # etcd: client 2379 + peer 2380 — CHỈ giữa 3 DB node
    for p in "${PEERS[@]}"; do
      add "ufw allow from ${p} to any port 2379 proto tcp comment 'etcd client (${p})'"
      add "ufw allow from ${p} to any port 2380 proto tcp comment 'etcd peer (${p})'"
    done
    # Zabbix agent2
    add "ufw allow from ${ZBX_PROXY} to any port 10050 proto tcp comment 'zabbix-agent2'"
    RULES+=("# monitor PG: agent2 nối 127.0.0.1:5432 -> KHÔNG mở 5432 cho Zabbix")
    RULES+=("# admin nối DB: chỉ mở 5432 cho ĐÚNG IP DBA ở trên (không mở cả dải office-net) hoặc qua SSH tunnel")
    ;;

  proxy)
    case "$NODE" in
      ax-proxy01) PEER=$PROXY02 ;;
      ax-proxy02) PEER=$PROXY01 ;;
      *) echo "proxy cần node ax-proxy01|ax-proxy02"; usage ;;
    esac
    require_zbx
    base_policy
    add "ufw allow from ${WAN_USER_SUBNET} to any port 80  proto tcp comment 'user http'"
    add "ufw allow from ${WAN_USER_SUBNET} to any port 443 proto tcp comment 'user https'"
    # Keepalived / VRRP (proto 112): ufw KHÔNG nhận 'proto vrrp' -> phải sửa before.rules
    RULES+=("# --- Keepalived/VRRP (proto 112) — ufw không có rule trực tiếp ---")
    RULES+=("#   Thêm vào /etc/ufw/before.rules NGAY TRƯỚC dòng 'COMMIT':")
    RULES+=("#     -A ufw-before-input  -p 112 -s ${PEER} -j ACCEPT")
    RULES+=("#     -A ufw-before-input  -p 112 -d 224.0.0.18 -j ACCEPT")
    RULES+=("#     -A ufw-before-output -p 112 -j ACCEPT")
    RULES+=("#   Rồi: sudo ufw reload   (làm y hệt trên proxy còn lại, đổi PEER)")
    # stub_status + agent2 cho Zabbix
    add "ufw allow from ${ZBX_PROXY} to any port 8080 proto tcp comment 'nginx stub_status'"
    add "ufw allow from ${ZBX_PROXY} to any port 10050 proto tcp comment 'zabbix-agent2'"
    RULES+=("# proxy -> backend IIS :80 là chiều OUTGOING (default allow out) -> không cần rule vào")
    ;;

  nas)
    require_zbx
    base_policy
    # Samba cho web server (nguồn deploy)
    add "ufw allow from ${WEB01} to any port 445 proto tcp comment 'smb ax-web01'"
    add "ufw allow from ${WEB02} to any port 445 proto tcp comment 'smb ax-web02'"
    add "ufw allow from ${WEB01} to any port 139 proto tcp comment 'netbios ax-web01'"
    add "ufw allow from ${WEB02} to any port 139 proto tcp comment 'netbios ax-web02'"
    add "ufw allow from ${WEB01} to any port 137,138 proto udp comment 'netbios udp ax-web01'"
    add "ufw allow from ${WEB02} to any port 137,138 proto udp comment 'netbios udp ax-web02'"
    add "ufw allow from ${ZBX_PROXY} to any port 10050 proto tcp comment 'zabbix-agent2'"
    ;;

  *) usage ;;
esac

add "ufw --force enable"
add "ufw status verbose"

# ----- Xuất / chạy ----------------------------------------------------------
echo "# ============================================================"
echo "# AX firewall — role '${ROLE}'${NODE:+ / $NODE} — $( [ "$APPLY" = 1 ] && echo APPLYING || echo 'DRY-RUN (chỉ in lệnh)' )"
echo "# ============================================================"
if [ "$APPLY" = 1 ]; then
  [ "$(id -u)" -eq 0 ] || { echo "Cần sudo/root để --apply."; exit 1; }
  for r in "${RULES[@]}"; do
    case "$r" in \#*) echo "$r"; continue ;; esac
    echo "+ $r"
    eval "$r"
  done
else
  for r in "${RULES[@]}"; do echo "$r"; done
  echo
  echo "# Review xong -> chạy: sudo $0 $ROLE $NODE --apply   (hoặc | sudo bash)"
fi
