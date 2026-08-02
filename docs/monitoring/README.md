# Grafana dashboard — AX Svr Fleet (Zabbix)

Dashboard: `grafana-ax-fleet-dashboard.json` — tổng quan sức khỏe 10 máy AX (CPU, RAM, disk, load, network) lấy từ Zabbix qua plugin Grafana `alexanderzobnin-zabbix-datasource`.

## Yêu cầu
- Grafana đã cài plugin **Zabbix** (`alexanderzobnin-zabbix-datasource`) và đã có 1 data source trỏ tới Zabbix (chính là cái Grafana đang show Zabbix hiện tại).
- Các host trong Zabbix đặt tên tiền tố `AX-` (đúng như hiện có: AX-DB01, AX-Proxy01, AX-WEB01…). Dashboard lọc host bằng regex `/AX-/` nên **tự gom đủ 10 máy**.

## Cách import
1. Grafana → **Dashboards → New → Import**.
2. **Upload** file `grafana-ax-fleet-dashboard.json` (hoặc dán nội dung).
3. Ở bước chọn, gán biến **`Zabbix datasource`** = data source Zabbix của anh → **Import**.

## Nội dung dashboard
- **Overview (latest):** 3 ô lớn CPU% / RAM% / disk `/`% hiện tại theo từng host (đổi màu cam/đỏ khi cao).
- **CPU & Load:** biểu đồ CPU utilization + Load average 1m.
- **Memory & Disk:** Memory utilization + **Filesystem space utilization mọi mount** (thấy luôn `/data`, `/backup` vừa gắn).
- **Network:** bits in/out các interface.
- Biến `Host` (multi-select) để lọc theo máy; mặc định `All`.

## Nếu một panel trống (không ra dữ liệu)
Nguyên nhân thường gặp: **tên item khác** giữa các phiên bản template Zabbix. Dashboard dùng tên chuẩn của template "Linux by Zabbix agent":
`CPU utilization`, `Memory utilization`, `Load average (1m avg)`, `*: Space utilization`, `Interface *: Bits received/sent`.
Sửa: mở panel → tab **Query** → sửa ô **Item** cho khớp tên item thật trong Zabbix (Monitoring → Latest data để xem tên). Web (Windows/IIS) dùng template khác nên tên item có thể khác — chỉnh item cho panel tương ứng nếu cần.

## Ghi chú
- DB (AX-DB0x) chỉ có template "Linux by Zabbix agent" → dashboard này là **mức OS**. Muốn thêm chỉ số PostgreSQL/Patroni (TPS, connections, replication lag…) cần gắn thêm template PostgreSQL by Zabbix agent lên các DB host, rồi thêm panel — nói em nếu cần bản mở rộng đó.
