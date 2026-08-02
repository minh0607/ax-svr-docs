# Grafana dashboards — AX Svr (Zabbix)

Bộ dashboard (Zabbix 7.4 · agent2 · Grafana 13 · plugin `alexanderzobnin-zabbix-datasource`). Import: Dashboards → New → Import → Upload JSON → chọn biến **Zabbix datasource**.

| # | File | Mục đích | Chạy được ngay? |
|---|------|----------|-----------------|
| 1 | `grafana-ax-soc-wall.json` | **SOC/NOC wall** — UP/DOWN, active problems, đèn đỏ/xanh (treo tường, kiosk) | ✅ |
| 2 | `grafana-ax-fleet-dashboard.json` | Tổng quan nhanh theo OS (Linux/Windows) | ✅ |
| 3 | `grafana-ax-linux-detail.json` | **Linux chi tiết** (7 máy: DB/DBDEV/NAS/Proxy) — CPU breakdown, load, mem/swap, disk+inode+I/O, net errors | ✅ |
| 4 | `grafana-ax-windows-detail.json` | **Windows chi tiết** (WEB01/02) — CPU/mem/disk/net (+ chỗ chờ IIS) | ✅ (IIS cần perf-counter) |
| 5 | `grafana-ax-postgres-patroni.json` | **PostgreSQL + Patroni cluster** — connections, TPS, cache hit, replication lag, role, slots | ⚠️ cần template (xem PREREQUISITES §1-2) |
| 6 | `grafana-ax-nginx-cluster.json` | **Nginx proxy cluster** — WHO IS ACTIVE (VIP), requests/s, dropped conns, backend reachability | ⚠️ cần template (§3-4) |
| 7 | `grafana-ax-nas.json` | **NAS / Samba** — smbd/nmbd, sessions, share space+inode, I/O | ⚠️ cần UserParameter (§5) |

> **Dashboard 5–7 sẽ TRỐNG cho tới khi gắn template/cấu hình tương ứng** — làm theo **[PREREQUISITES.md](PREREQUISITES.md)** (gắn "PostgreSQL by Zabbix agent 2" + "Patroni by HTTP" + "Nginx by Zabbix agent", bật stub_status, thêm UserParameter Keepalived/Samba, tạo user `zbx_monitor`…). Panel nào cần gì đã ghi ở `description` (hover để xem) + panel `text` đầu mỗi dashboard.

Các dashboard đều lọc host bằng regex (`/AX-/`, `/AX-(DB|NAS|Proxy)/`, `/AX-WEB/`, `/AX-DB0/`, `/AX-Proxy/`, `/AX-NAS/`) nên tự gom đúng máy, không cần khai từng host.

---

## SOC / NOC Wall — `grafana-ax-soc-wall.json`
3 khối, auto-refresh 30s:
- **🟢 Cluster status:** ô lớn UP/DOWN từng host (xanh=UP, đỏ=DOWN) — dựa trên item `Zabbix agent availability`.
- **🚨 Active problems:** bảng cảnh báo Zabbix đang mở (panel Problems của plugin), tô màu theo severity, mới nhất trên cùng. Đây là trọng tâm SOC.
- **📊 Resource pressure:** đèn CPU% / RAM% / Disk% hiện tại, đổi cam/đỏ khi vượt ngưỡng.

**Chiếu lên màn tường:** mở dashboard → thêm `?kiosk&refresh=30s&theme=dark` vào URL (hoặc nút Kiosk mode) để full-screen không viền.

**Cần:** plugin Zabbix có sẵn **panel Problems** (`alexanderzobnin-zabbix-triggers-panel`) — mặc định đi kèm plugin. Nếu panel "Active problems" báo thiếu panel type → cập nhật plugin Zabbix. VIP (AX-Web-VIP) chỉ có ICMP nên có thể không hiện ở ô availability (dựa trên agent) — nếu cần, thêm 1 ô stat item `/ICMP ping/` cho VIP.

---

## Fleet detail — `grafana-ax-fleet-dashboard.json`
Tổng quan sức khỏe 10 máy AX (CPU, RAM, disk, load, network) lấy từ Zabbix qua plugin Grafana `alexanderzobnin-zabbix-datasource`.

## Yêu cầu
- Grafana đã cài plugin **Zabbix** (`alexanderzobnin-zabbix-datasource`) và đã có 1 data source trỏ tới Zabbix (chính là cái Grafana đang show Zabbix hiện tại).
- Các host trong Zabbix đặt tên tiền tố `AX-` (đúng như hiện có: AX-DB01, AX-Proxy01, AX-WEB01…). Dashboard lọc host bằng regex `/AX-/` nên **tự gom đủ 10 máy**.

## Cách import
1. Grafana → **Dashboards → New → Import**.
2. **Upload** file `grafana-ax-fleet-dashboard.json` (hoặc dán nội dung).
3. Ở bước chọn, gán biến **`Zabbix datasource`** = data source Zabbix của anh → **Import**.

## Nội dung dashboard (chia theo OS)
- **Overview — all AX hosts:** 3 ô lớn CPU% / RAM% / disk hiện tại theo từng máy (cam/đỏ khi cao).
- **🐧 Linux servers** (host `/AX-(DB|NAS|Proxy)/` → DB01/02/03, DBDEV, NAS, Proxy01/02): CPU · Load 1m · Memory · **Filesystem mọi mount (`/`, `/data`, `/backup`)** · Network.
- **🪟 Windows servers (Web/IIS)** (host `/AX-WEB/` → WEB01/02): CPU · Memory · Disk (C:, D:) · Network. *(Không có Load average — Windows không có khái niệm này.)*

> Tách section bằng **regex host** nên tự phân loại; không cần khai từng máy. Muốn thêm máy Linux mới có tên khác quy ước thì sửa regex trong panel.

## Nếu một panel trống (không ra dữ liệu)
Nguyên nhân thường gặp: **tên item khác** giữa các phiên bản template Zabbix. Dashboard dùng tên chuẩn của template "Linux by Zabbix agent":
`CPU utilization`, `Memory utilization`, `Load average (1m avg)`, `*: Space utilization`, `Interface *: Bits received/sent`.
Sửa: mở panel → tab **Query** → sửa ô **Item** cho khớp tên item thật trong Zabbix (Monitoring → Latest data để xem tên). Web (Windows/IIS) dùng template khác nên tên item có thể khác — chỉnh item cho panel tương ứng nếu cần.

## Ghi chú
- DB (AX-DB0x) chỉ có template "Linux by Zabbix agent" → dashboard này là **mức OS**. Muốn thêm chỉ số PostgreSQL/Patroni (TPS, connections, replication lag…) cần gắn thêm template PostgreSQL by Zabbix agent lên các DB host, rồi thêm panel — nói em nếu cần bản mở rộng đó.
