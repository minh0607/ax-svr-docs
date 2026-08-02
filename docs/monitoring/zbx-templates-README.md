# Zabbix custom templates — AX Svr

Bộ template Zabbix 7.4 **tự tạo** cho các service không có template chính thức phù hợp. Tất cả **import-ready** (YAML).
Nguyên tắc: **template định nghĩa item/trigger/macro; UserParameter + sudoers phải cài trên agent từng host** (template không đẩy config agent).

> Template chính thức (không nằm ở đây): `PostgreSQL by Zabbix agent 2`, `Patroni by HTTP`, `Nginx by Zabbix agent`, `Linux/Windows by Zabbix agent`, `ICMP Ping` — xem [PREREQUISITES.md](PREREQUISITES.md) + `runbook-attach-pg-patroni.md`.

## Cách import chung
1. Data collection → **Templates → Import** → chọn file `.yaml` → Import.
2. Vào host → tab **Templates → Link** template tương ứng.
3. Cài **UserParameter + sudoers** (bảng dưới) trên agent host đó → `systemctl restart zabbix-agent2` (Linux) / `Restart-Service "Zabbix Agent 2"` (Windows).
4. Verify: `zabbix_agent2 -t <key>` ra giá trị; Zabbix → Latest data thấy data.

---

## Danh sách template

| File | Template | Link vào host | Tag |
|---|---|---|---|
| `zbx-template-keepalived-vip.yaml` | **AX Keepalived VIP by Agent** | ax-proxy01, ax-proxy02 | `service:keepalived` |
| `zbx-template-firewall.yaml` | **Firewall Monitor Template for Ubuntu** | db01/02/03, nas, proxy01/02 | `service:security` |
| `zbx-template-firewall.yaml` | **Firewall Monitor Template for Windows** | web01, web02 | `service:security` |
| `zbx-template-samba-nas.yaml` | **Samba Monitor Template for NAS** | nas | `service:samba` |
| `zbx-template-etcd-health.yaml` | **etcd Health Monitor Template for DB** | db01/02/03 | `service:etcd` |

---

## Chi tiết từng template

### 1. AX Keepalived VIP by Agent  → `runbook-keepalived-vip-monitor.md`
- **Item:** `vip.holder[{$KEEPALIVED.VIP}]` (30s) · `keepalived.proc` (1m)
- **Trigger:** `VIP acquired by {HOST.NAME}` (Warning — báo mỗi lần switch) · `Keepalived DOWN on {HOST.NAME}` (High)
- **Macro:** `{$KEEPALIVED.VIP}` = `107.118.210.100`
- **Agent** (`/etc/zabbix/zabbix_agent2.d/keepalived.conf`):
  ```
  UserParameter=vip.holder[*],ip addr show | grep -q "$1/" && echo 1 || echo 0
  UserParameter=keepalived.proc,pgrep -c keepalived
  ```

### 2. Firewall Monitor Template for Ubuntu  → `runbook-firewall-monitor.md`
- **Item:** `ufw.enabled` (1m, value-map 1=ON/0=OFF) · **Trigger:** `Firewall DISABLED (ufw) on {HOST.NAME}` (High)
- **Agent** (`/etc/zabbix/zabbix_agent2.d/ufw.conf`) + **sudoers** `/etc/sudoers.d/zabbix-ufw`:
  ```
  UserParameter=ufw.enabled,sudo /usr/sbin/ufw status 2>/dev/null | grep -q "Status: active" && echo 1 || echo 0
  # sudoers:
  zabbix ALL=(root) NOPASSWD: /usr/sbin/ufw status
  ```

### 3. Firewall Monitor Template for Windows  → `runbook-firewall-monitor.md`
- **Item:** `win.firewall.enabled` (1m, value-map ON/OFF) · **Trigger:** `Firewall DISABLED (Windows Firewall) on {HOST.NAME}` (High)
- Windows Firewall = **wf.msc** (≠ Microsoft Defender Antivirus). `Get-NetFirewallProfile` đọc đúng wf.msc.
- **Agent** (`...\zabbix_agent2.d\firewall.conf`, đặt `Timeout=10` trong `zabbix_agent2.conf`):
  ```
  UserParameter=win.firewall.enabled,powershell -NoProfile -NonInteractive -Command "if(@(Get-NetFirewallProfile | Where-Object {-not $_.Enabled}).Count -eq 0){1}else{0}"
  ```

### 4. Samba Monitor Template for NAS  → PREREQUISITES §5
- **Item:** `samba.smbd.proc` · `samba.nmbd.proc` · `samba.sessions` · `samba.locked_files` (1m)
- **Trigger:** `Samba smbd DOWN` (High) · `Samba nmbd DOWN` (Warning — bỏ nếu chỉ dùng SMB2/3)
- **Agent** (`/etc/zabbix/zabbix_agent2.d/samba.conf`) + **sudoers**:
  ```
  UserParameter=samba.smbd.proc,pgrep -c smbd
  UserParameter=samba.nmbd.proc,pgrep -c nmbd
  UserParameter=samba.sessions,sudo /usr/bin/smbstatus -b 2>/dev/null | tail -n +5 | grep -c .
  UserParameter=samba.locked_files,sudo /usr/bin/smbstatus -L 2>/dev/null | tail -n +5 | grep -c .
  # sudoers:
  zabbix ALL=(root) NOPASSWD: /usr/bin/smbstatus
  ```

### 5. etcd Health Monitor Template for DB  → PREREQUISITES §2
- **Item:** `etcd.health[{$ETCD.ENDPOINT}]` (1m, value-map healthy/UNHEALTHY) · **Trigger:** `etcd UNHEALTHY on {HOST.NAME}` (High)
- **Macro:** `{$ETCD.ENDPOINT}` = `http://127.0.0.1:2379/health` (đổi `https://` + `--cacert` nếu TLS)
- Agent-side (curl localhost) → **không hở 2379 ra office-net**.
- **Agent** (`/etc/zabbix/zabbix_agent2.d/etcd.conf`):
  ```
  UserParameter=etcd.health[*],curl -s "$1" | grep -q '"health":"true"' && echo 1 || echo 0
  ```

---

## Trigger cross-host — TẠO TAY (template Zabbix không tham chiếu 2 host)

| Cảnh báo | Expression | Severity |
|---|---|---|
| VIP split-brain | `last(/AX-Proxy01/vip.holder[107.118.210.100])=1 and last(/AX-Proxy02/vip.holder[107.118.210.100])=1` | High |
| VIP no-holder | `last(/AX-Proxy01/vip.holder[107.118.210.100])=0 and last(/AX-Proxy02/vip.holder[107.118.210.100])=0` | Disaster |
| etcd quorum lost | ≥2/3 node `etcd.health=0` (đếm qua trigger so 3 host) | Disaster |

---

## Ghi chú chung
- **Agent active checks:** nếu agent chạy active, sau import đổi Type item → *Zabbix agent (active)*.
- **Gửi thông báo:** Alerting → Actions, điều kiện theo **Tag** (`service:keepalived|security|samba|etcd`) → 1 action gom nhiều template.
- Template **không** cài UserParameter/sudoers hộ — đó là bước thủ công trên agent (hoặc đẩy bằng config-mgmt).
