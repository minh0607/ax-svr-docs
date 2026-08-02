# Runbook: bật monitoring PostgreSQL + Patroni (Zabbix 7.4) — cụm AX DB

> Mục tiêu: dashboard **`grafana-ax-postgres-patroni.json`** (Dashboard 5) lên data.
> Áp cho **AX-DB01 / AX-DB02 / AX-DB03**. Chạy phần SQL trên **Leader** (xác định bằng `patronictl list`); phần pg_hba + firewall chạy **trên từng node**.
> An toàn: chỉ tạo user chỉ-đọc + mở cổng cho Zabbix; không đụng data, không downtime (chỉ `reload`).

Ký hiệu: `<PGZBX_PWD>` = mật khẩu user monitor (tự đặt) · `<ZBX_PROXY_IP>` = IP của Zabbix proxy `sehc-svrproxy`.

---

## 0. Kiểm tra trước
```bash
# agent2 đang chạy trên mỗi DB node
systemctl is-active zabbix-agent2
zabbix_agent2 -V | head -1          # xác nhận là agent 2
# Trong Zabbix (Data collection → Templates) có sẵn: "PostgreSQL by Zabbix agent 2" và "Patroni by HTTP"
```

## 1. Tạo user giám sát — chạy 1 LẦN trên LEADER
User là object cluster-wide → tự replicate sang 2 standby.
```bash
sudo -u postgres psql -c "CREATE ROLE zbx_monitor WITH LOGIN PASSWORD '<PGZBX_PWD>';"
sudo -u postgres psql -c "GRANT pg_monitor TO zbx_monitor;"
# kiểm tra
sudo -u postgres psql -c "\du zbx_monitor"
```
`pg_monitor` = chỉ đọc thống kê (pg_stat_*), KHÔNG đọc dữ liệu bảng → an toàn chạy từ mọi node.

## 2. Cho phép zbx_monitor kết nối localhost — trên TỪNG node (AX-DB01/02/03)
pg_hba do Patroni quản. **Append 1 dòng vào list `pg_hba` đang có trong `/etc/patroni/patroni.yml`** (KHÔNG xoá dòng khác — sẽ mất rule replication/app):
```yaml
# trong /etc/patroni/patroni.yml, dưới  postgresql: \n  pg_hba:  (thêm vào cuối list)
  - host  all  zbx_monitor  127.0.0.1/32  scram-sha-256
```
Rồi reload (không restart, không downtime):
```bash
sudo systemctl reload patroni      # hoặc: patronictl -c /etc/patroni/patroni.yml reload <cluster>
```
> Làm y hệt trên cả 3 node (cùng 1 dòng). Kiểm: `sudo -u postgres psql -c "SELECT 1"` vẫn chạy bình thường sau reload.
> (agent2 pgsql plugin nối 127.0.0.1 nên chỉ cần dòng này — KHÔNG mở 5432 ra ngoài.)

## 3. Mở cổng Patroni REST :8008 cho Zabbix — trên TỪNG node
"Patroni by HTTP" poll REST API :8008 từ Zabbix proxy.
```bash
sudo ufw allow from <ZBX_PROXY_IP> to any port 8008 proto tcp
sudo ufw status | grep 8008
# kiểm API trả JSON:
curl -s http://127.0.0.1:8008/patroni | head
```

## 4. Trong Zabbix UI — gắn template + macro (cho cả 3 DB host)
Data collection → Hosts → **AX-DB01** (rồi lặp cho DB02, DB03):

**Tab Templates → Link new templates → thêm:**
- `PostgreSQL by Zabbix agent 2`
- `Patroni by HTTP`

**Tab Macros → thêm (giống nhau cả 3 host, hoặc đặt ở host-group cho gọn):**
| Macro | Value |
|---|---|
| `{$PG.HOST}` | `127.0.0.1` |
| `{$PG.PORT}` | `5432` |
| `{$PG.USER}` | `zbx_monitor` |
| `{$PG.PASSWORD}` | `<PGZBX_PWD>`  → **chọn kiểu "Secret text"** |
| `{$PATRONI.API.PORT}` | `8008` |
| `{$PATRONI.API.SCHEME}` | `http` |

> Nếu template PostgreSQL bản này dùng `{$PG.URI}` thay vì host/port: đặt `{$PG.URI}` = `tcp://127.0.0.1:5432`.

## 5. Verify (sau 1-2 phút cho Zabbix poll)
```bash
# trên mỗi DB node — plugin kết nối được PG chưa
zabbix_agent2 -t pgsql.ping
```
Trong Zabbix **Monitoring → Latest data**, lọc host `AX-DB01`, item chứa `PostgreSQL` / `Patroni` → thấy giá trị thật (khác "No data").
Đối chiếu nhanh bằng toolkit: `./axdb.sh health` (in role + replay_lag) so với panel Patroni.

## Lưu ý
- **PG17:** checkpoint counters đã chuyển sang view `pg_stat_checkpointer`. Nếu panel checkpoint = 0 mà `SELECT * FROM pg_stat_checkpointer;` có data → plugin agent2 cần bản hỗ trợ PG17.
- Panel "cache hit ratio", "longest query", "blocked locks", "connections % of max" là **calculated/custom** — cần thêm custom query cho plugin agent2 (xem PREREQUISITES §1); các panel còn lại lên data ngay sau bước 4.
- Mật khẩu `<PGZBX_PWD>`: chỉ lưu ở Secret macro của Zabbix, không hardcode chỗ khác.

## Rollback (nếu cần gỡ)
```bash
# gỡ template khỏi host trong Zabbix UI (Unlink and clear)
# xoá dòng pg_hba vừa thêm + reload patroni
# xoá user: sudo -u postgres psql -c "DROP ROLE zbx_monitor;"  (trên Leader)
# đóng cổng: sudo ufw delete allow from <ZBX_PROXY_IP> to any port 8008 proto tcp
```
