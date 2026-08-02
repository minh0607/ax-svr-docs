# Monitoring — Prerequisites để "lên data" cho service dashboards

> Zabbix 7.4 · zabbix-agent2 trên mọi node · Grafana 13 (plugin `alexanderzobnin-zabbix-datasource`).
> Các dashboard **OS** (Linux/Windows/Fleet/SOC) chạy ngay với template base đang có.
> Các dashboard **service** dưới đây **chỉ hiện data sau khi gắn template + cấu hình tương ứng**. Sau mỗi bước: kiểm ở **Monitoring → Latest data** thấy giá trị thật rồi mới tin panel.

## Template checklist (tóm tắt)

**Đã gắn sẵn:** `Linux by Zabbix agent` (DB×3, DBDEV, NAS, Proxy×2) · `Windows by Zabbix agent` (WEB01/02) · `ICMP Ping` (Web-VIP).

**Cần gắn thêm (template chính thức Zabbix 7.4):**
| Template | Host | Dashboard | Kèm theo |
|---|---|---|---|
| `PostgreSQL by Zabbix agent 2` | AX-DB01/02/03 (+DBDEV) | 5 | user `zabbixmonitor` + pg_hba + `{$PG.*}` (§1) |
| `Patroni by HTTP` | AX-DB01/02/03 | 5 | mở `:8008` + `{$PATRONI.*}` (§2) |
| `Nginx by Zabbix agent` | AX-Proxy01/02 | 6 | bật stub_status + `{$NGINX.STUB_STATUS.*}` (§3) |
| `SMART disks by Zabbix agent 2` *(tuỳ chọn)* | AX-NAS | 7 | cài `smartmontools` (§5) |

**KHÔNG có template chính thức → tự tạo item:** Keepalived (`vip.holder`, `keepalived.proc` — §4) · Samba (`samba.*` — §5) · Backend reachability (`net.tcp.service[http,10.1.1.101/102,80]`) · IIS (`perf_counter[]` — §6) · etcd (`http.agent` :2379/health — §2).

---

## 1. PostgreSQL (dashboard `grafana-ax-postgres-patroni.json` — section PostgreSQL)
Áp trên **AX-DB01/02/03** (và DBDEV nếu muốn).

**a. Template:** gắn **"PostgreSQL by Zabbix agent 2"** (agent2 đã có plugin `pgsql` sẵn — không cài thêm gì).

**b. User giám sát** (tạo 1 lần trên Leader, tự replicate):
```sql
CREATE ROLE zabbixmonitor WITH LOGIN PASSWORD '<strong-pwd>';
GRANT pg_monitor TO zabbixmonitor;     -- chỉ đọc thống kê, KHÔNG đọc data
```

**c. pg_hba — sửa qua Patroni, KHÔNG sửa tay** (`patronictl edit-config`, hoặc bootstrap block), vì Patroni sẽ ghi đè `pg_hba.conf`:
```yaml
- host  all  zabbixmonitor  127.0.0.1/32  scram-sha-256
```
(agent2 kết nối localhost trên chính node → chỉ cần 127.0.0.1, không mở 5432 ra ngoài.)

**d. Macro (host hoặc host-group vì 3 node giống nhau):**
| Macro | Value |
|---|---|
| `{$PG.HOST}` | `localhost` |
| `{$PG.PORT}` | `5432` |
| `{$PG.USER}` | `zabbixmonitor` |
| `{$PG.PASSWORD}` | (Secret macro) |

**e. Verify:** `zabbix_agent2 -t pgsql.ping` trên mỗi node → OK.

**⚠️ PG17 gotcha:** checkpoint counters đã chuyển từ `pg_stat_bgwriter` sang **`pg_stat_checkpointer`**. Nếu bản plugin agent2 cũ hơn PG17, item checkpoint có thể = 0. Kiểm: `SELECT * FROM pg_stat_checkpointer;` — nếu view có data mà item Zabbix phẳng → plugin cần bản mới.

**Panel cần calculated/custom query** (không có sẵn — thêm qua custom query của plugin agent2): cache hit ratio, longest running query, oldest XID/wraparound, blocked locks. Panel đã tạo sẵn trong JSON nhưng sẽ trống tới khi thêm custom item.

---

## 2. Patroni cluster (dashboard `...postgres-patroni.json` — section Patroni)
**a. Template:** gắn **"Patroni by HTTP"** (Zabbix poll REST API :8008 — Patroni đã chạy sẵn, không cài gì).

**b. Firewall:** mở cho **Zabbix proxy/server** tới `:8008` trên cả 3 DB node:
```bash
sudo ufw allow from <zabbix-proxy-ip> to any port 8008 proto tcp
```

**c. Macro:** `{$PATRONI.API.PORT}=8008`, `{$PATRONI.API.SCHEME}=http`.

**d. Ground truth để đối chiếu tên item** (verify ở Latest data):
- `GET :8008/patroni` → `role`, `state`, `postgresql.timeline`, `postgresql.wal.*`
- `GET :8008/cluster` → `members[].role/state/lag`
- `GET :8008/leader` → HTTP 200 chỉ ở Leader (dùng làm tín hiệu "cluster unlocked" nếu không node nào 200)

**e. Cross-check nhanh bằng chính toolkit:** `./axdb.sh health` (in `patronictl list` + `sync_state` + `replay_lag`) → so khớp với panel.

**etcd quorum:** import template **`zbx-template-etcd-health.yaml`** ("etcd Health Monitor Template for DB") → link AX-DB01/02/03. Nó dùng **agent-side** (agent2 curl `http://127.0.0.1:2379/health` local) → **KHÔNG hở 2379 ra office-net** (etcd chỉ nghe localhost+LAN, và không nên lộ ra ngoài). Cần UserParameter `etcd.health[*]` + macro `{$ETCD.ENDPOINT}`. Trigger `etcd UNHEALTHY on {HOST.NAME}` (High); ≥2/3 node unhealthy = mất quorum → Patroni read-only (tạo tay trigger cross-host nếu cần cảnh báo "quorum lost").

---

## 3. Nginx cluster (dashboard `grafana-ax-nginx-cluster.json`)
Áp trên **AX-Proxy01/02**.

**a. Bật stub_status.** Template "Nginx by Zabbix agent" cho **agent2 chạy NGAY TRÊN proxy** lấy stub_status → cho nghe **loopback** là sạch nhất (khỏi hở office-net, khỏi ufw, 2 proxy giống hệt):
```nginx
# /etc/nginx/conf.d/status.conf
server {
    listen 127.0.0.1:8080;
    location /basic_status { stub_status; allow 127.0.0.1; deny all; }
}
```
```bash
sudo nginx -t && sudo systemctl reload nginx
curl -s http://127.0.0.1:8080/basic_status    # phải ra "Active connections: ..."
```
Macro khi đó: `{$NGINX.STUB_STATUS.HOST}=127.0.0.1`.

> **Bẫy 403:** nếu bind office-net (`listen 107.118.210.99:8080`) mà agent gọi tới đó thì **source = IP chính proxy** → phải `allow` IP đó (không chỉ `127.0.0.1`), nếu không nginx trả **403** và mọi item con "Not supported". Loopback tránh hẳn lỗi này. (Chỉ dùng "Nginx by **HTTP**" — server poll từ xa — mới cần bind office-net + `allow <zabbix-proxy-ip>` + `ufw allow ... 8080`.)

**b. Template:** gắn **"Nginx by Zabbix agent"**. Macro per host:
| Macro | Value |
|---|---|
| `{$NGINX.STUB_STATUS.HOST}` | `127.0.0.1` (loopback — khuyên) |
| `{$NGINX.STUB_STATUS.PORT}` | `8080` |
| `{$NGINX.STUB_STATUS.PATH}` | `basic_status` |

Item cho panel: `Connections active/reading/writing/waiting`, `Connections accepted/handled/dropped per second`, `Requests per second`, `Service status`.

---

## 4. Keepalived / VIP (cùng dashboard Nginx)
**a. UserParameter trên cả 2 proxy** (`/etc/zabbix/zabbix_agent2.d/keepalived.conf`):
```
UserParameter=vip.holder,ip addr show | grep -q "107.118.210.100/" && echo 1 || echo 0
UserParameter=keepalived.proc,pgrep -c keepalived
```
`systemctl restart zabbix-agent2`. Tạo item `vip.holder` (0/1) + `keepalived.proc` trên mỗi proxy. Panel "WHO IS ACTIVE": node báo 1 = ACTIVE.

> VIP nổi trên **office-net `107.118.210.100`** (mặt user), không phải LAN — nên grep đúng IP này. Keepalived thêm VIP dạng `/32` → `grep "107.118.210.100/"` khớp.

**b. VIP ICMP:** host **AX-Web-VIP** (IP `107.118.210.100`) gắn template **"ICMP Ping"** (items `icmpping`/`icmppingloss`/`icmppingsec`; cần `fping` trên Zabbix proxy/server).

**c. Split-brain** (cả 2 = 1 hoặc cả 2 = 0): nên bắt bằng **Zabbix trigger** (so 2 item `vip.holder`), hiện lên qua panel Problems — không tính client-side trong Grafana.

---

## 5. NAS / Samba (dashboard `grafana-ax-nas.json`)
Không có template Samba chính thức → dùng template tự tạo **`zbx-template-samba-nas.yaml`** ("Samba Monitor Template for NAS"): Templates → Import → Link vào host **nas**. Template gồm item `samba.smbd.proc`/`samba.nmbd.proc`/`samba.sessions`/`samba.locked_files` + trigger smbd/nmbd DOWN (tag `service:samba`).

UserParameter trên agent host **nas** (`/etc/zabbix/zabbix_agent2.d/samba.conf`):
```
UserParameter=samba.smbd.proc,pgrep -c smbd
UserParameter=samba.nmbd.proc,pgrep -c nmbd
UserParameter=samba.sessions,sudo /usr/bin/smbstatus -b 2>/dev/null | tail -n +5 | grep -c .
UserParameter=samba.locked_files,sudo /usr/bin/smbstatus -L 2>/dev/null | tail -n +5 | grep -c .
```
`smbstatus` cần root → **sudoers hẹp** (least-privilege, không chạy agent bằng root):
```
zabbix ALL=(root) NOPASSWD: /usr/bin/smbstatus
```
`sudo systemctl restart zabbix-agent2` → test `zabbix_agent2 -t samba.smbd.proc`. Disk/inode/network của NAS lấy từ template Linux base sẵn có.

> `nmbd` có thể = 0 hợp lệ nếu chỉ dùng SMB2/3 (không NetBIOS) → khi đó bỏ/ack trigger nmbd.

**SMART (tuỳ chọn):** gắn **"SMART disks by Zabbix agent 2"** + cài `smartmontools` → sức khỏe ổ (reallocated sectors, nhiệt độ) — giá trị cao nhất cho file server.

---

## 6. IIS (Windows dashboard — section phase 2)
Template Windows base KHÔNG có IIS. Thêm `perf_counter[]` items (custom template gắn kèm):
- `\Web Service(_Total)\Current Connections`
- `\Web Service(_Total)\Bytes Sent/sec`, `Bytes Received/sec`
- `\ASP.NET Apps v4.0.30319\Requests/Sec`, `Requests Queued`, `Requests Rejected` ← *Requests Queued là tín hiệu sớm nhất app pool quá tải*

---

## 7. Alerting — trigger nên có (để SOC wall hiện đúng)
| Trigger | Điều kiện | Severity |
|---|---|---|
| VIP down | `icmpping`=0 (AX-Web-VIP) >1m | Disaster |
| VIP split-brain | cả 2 `vip.holder`=1 hoặc =0 | High |
| Nginx dropped conns | `nginx.connections.dropped.rate` > ngưỡng 5m | High |
| Backend (IIS) unreachable from proxy | `net.tcp.service[http,10.1.1.101/102,80]`=down | High |
| Keepalived dead | `keepalived.proc`=0 2m | High |
| smbd down | `samba.smbd.proc`=0 2m | High |
| Disk/inode cao | space/inode <15% free (warn) / <5% (crit) | Average/High |
| Replication lag cao | Patroni lag bytes >50MB / seconds >30s | High |
| PG connections gần max | >75% (warn) / >90% (crit) max_connections | Average |

> **Tag trigger theo service** (`service:nginx`, `service:postgres`, `service:samba`…) để từ SOC wall bấm thẳng sang dashboard đúng service (drill-down).

---

## 8. Cấu trúc thư mục Grafana (đề xuất)
```
Folder: AX Svr
├─ AX Svr — SOC / NOC Wall            (treo tường, kiosk)
├─ AX · Fleet Overview by OS          (tổng quan nhanh)
├─ AX · Linux Servers (Detail)
├─ AX · Windows Servers (Detail)
├─ AX · PostgreSQL / Patroni (Cluster)   ← cần mục 1+2
├─ AX · Nginx Cluster (Proxy Edge)       ← cần mục 3+4
└─ AX · NAS / File Share                 ← cần mục 5
```
Mỗi dashboard service có 1 panel **Active Problems** lọc theo host của nó = "vừa mở là thấy đang lỗi gì".
