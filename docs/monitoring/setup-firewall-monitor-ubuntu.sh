#!/usr/bin/env bash
# ============================================================================
# Setup firewall (ufw) monitoring cho Zabbix Agent 2 — Ubuntu.
# Tạo UserParameter + sudoers hẹp -> restart agent -> test.
# Chạy: sudo ./setup-firewall-monitor-ubuntu.sh
# Sau đó: gắn template "Firewall Monitor Template for Ubuntu" cho host trong Zabbix.
# ============================================================================
set -euo pipefail

AGENT_USER="${AGENT_USER:-zabbix}"                 # user chạy zabbix-agent2
UFW_BIN="${UFW_BIN:-/usr/sbin/ufw}"
AGENT_D="${AGENT_D:-/etc/zabbix/zabbix_agent2.d}"
MAIN_CONF="${MAIN_CONF:-/etc/zabbix/zabbix_agent2.conf}"
UP_FILE="$AGENT_D/ufw.conf"
SUDOERS="/etc/sudoers.d/zabbix-ufw"

[ "$(id -u)" -eq 0 ] || { echo "Cần chạy bằng sudo/root."; exit 1; }
command -v "$UFW_BIN" >/dev/null || { echo "!! Không thấy ufw ở $UFW_BIN (đặt UFW_BIN=...)."; exit 1; }
[ -d "$AGENT_D" ] || { echo "!! Không thấy $AGENT_D — zabbix-agent2 đã cài chưa? (đặt AGENT_D=...)"; exit 1; }
id "$AGENT_USER" >/dev/null 2>&1 || { echo "!! Không thấy user '$AGENT_USER' (đặt AGENT_USER=...)."; exit 1; }

# 1) UserParameter
cat > "$UP_FILE" <<EOF
# AX firewall monitor — ufw status (1=active, 0=inactive)
UserParameter=ufw.enabled,sudo $UFW_BIN status 2>/dev/null | grep -q "Status: active" && echo 1 || echo 0
EOF
echo ">> wrote $UP_FILE"

# 2) sudoers hẹp — validate TRƯỚC khi giữ (sudoers hỏng = khoá sudo cả máy)
TMP="$(mktemp)"
echo "$AGENT_USER ALL=(root) NOPASSWD: $UFW_BIN status" > "$TMP"
if visudo -cf "$TMP" >/dev/null 2>&1; then
  install -m 0440 -o root -g root "$TMP" "$SUDOERS"
  rm -f "$TMP"
  echo ">> wrote $SUDOERS"
else
  rm -f "$TMP"
  echo "!! sudoers không hợp lệ — huỷ."; exit 1
fi

# 3) cảnh báo nếu main conf chưa Include thư mục .d
if ! grep -Eq "^Include=.*zabbix_agent2\.d" "$MAIN_CONF" 2>/dev/null; then
  echo "!! Cảnh báo: $MAIN_CONF chưa 'Include=$AGENT_D/*.conf' — thêm dòng đó rồi restart."
fi

# 4) restart + test
systemctl restart zabbix-agent2
echo ">> restarted zabbix-agent2"
sleep 1
echo -n ">> test 'ufw.enabled' (as root): "
zabbix_agent2 -t ufw.enabled 2>/dev/null || echo "(zabbix_agent2 -t lỗi — kiểm agent)"
# QUAN TRỌNG: -t chạy như root; test đúng ngữ cảnh agent = quyền sudo của $AGENT_USER
echo -n ">> sudo NOPASSWD check (as $AGENT_USER): "
if sudo -u "$AGENT_USER" sudo -n "$UFW_BIN" status >/dev/null 2>&1; then echo OK; else echo "FAILED — kiểm $SUDOERS"; fi

echo ">> Xong. Trong Zabbix: gắn template 'Firewall Monitor Template for Ubuntu' cho host này."
