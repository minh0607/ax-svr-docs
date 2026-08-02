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
sudo -u postgres psql -c "CREATE ROLE zabbixmonitor WITH LOGIN PASSWORD '<PGZBX_PWD>';"
sudo -u postgres psql -c "GRANT pg_monitor TO zabbixmonitor;"
# kiểm tra
sudo -u postgres psql -c "\du zabbixmonitor"
```
`pg_monitor` = chỉ đọc thống kê (pg_stat_*), KHÔNG đọc dữ liệu bảng → an toàn chạy từ mọi node.

## 2. Cho phép zabbixmonitor kết nối localhost — trên TỪNG node (AX-DB01/02/03)
pg_hba do Patroni quản. **Append 1 dòng vào list `pg_hba` đang có trong `/etc/patroni/patroni.yml`** (KHÔNG xoá dòng khác — sẽ mất rule replication/app):
```yaml
# trong /etc/patroni/patroni.yml, dưới  postgresql: \n  pg_hba:  (thêm vào cuối list)
  - host  all  zabbixmonitor  127.0.0.1/32  scram-sha-256
```
Rồi reload (không restart, không downtime):
```bash
sudo systemctl reload patroni      # hoặc: patronictl -c /etc/patroni/patroni.yml reload <cluster>
```
> Làm y hệt trên cả 3 node (cùng 1 dòng). Kiểm: `sudo -u postgres psql -c "SELECT 1"` vẫn chạy bình thường sau reload.
> (agent2 pgsql plugin nối 127.0.0.1 nên chỉ cần dòng này — KHÔNG mở 5432 ra ngoài.)

## 3. Cho REST API :8008 nghe được từ Zabbix + mở cổng — trên TỪNG node
"Patroni by HTTP" là item **HTTP agent** → **Zabbix proxy poll từ xa** tới `{HOST.CONN}:8008` (interface của DB host trong Zabbix = office-net `107.118.210.10x`).

**a. Nếu Patroni REST đang chỉ nghe IP LAN** (`sudo ss -tlnp | grep 8008` chỉ thấy `10.1.1.10x:8008`) → proxy office-net không thấy. Sửa `restapi` trong `/etc/patroni/patroni.yml`:
```yaml
restapi:
  listen: 0.0.0.0:8008              # nghe mọi interface (restapi.listen chỉ nhận 1 địa chỉ)
  connect_address: 10.1.1.103:8008  # GIỮ NGUYÊN IP LAN — các node quảng bá cho nhau qua backend
```
```bash
sudo systemctl reload patroni       # restapi thường rebind qua reload; nếu chưa, restart service patroni từng node (replica trước)
sudo ss -tlnp | grep 8008           # phải thấy 0.0.0.0:8008 (hoặc :::8008)
```
> ⚠️ REST API write-endpoint (switchover/restart) **mặc định không auth** → khi mở office-net BẮT BUỘC ufw chỉ cho đúng IP proxy. Nên thêm `restapi.authentication` (username/password) để chặn write; **GET đọc trạng thái vẫn mở → template không cần credential**.

**b. Mở cổng cho ĐÚNG Zabbix proxy:**
```bash
sudo ufw allow from <ZBX_PROXY_IP> to any port 8008 proto tcp
sudo ufw status | grep 8008
```

**c. Kiểm API — chạy TỪ máy Zabbix proxy** (không phải từ node, để test đúng đường office-net + firewall):
```bash
curl -s http://107.118.210.103:8008/patroni | head    # phải ra JSON role/state
```
> Patroni KHÔNG nghe `127.0.0.1` → `curl 127.0.0.1:8008` sẽ refused; luôn dùng IP thật.

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
| `{$PG.USER}` | `zabbixmonitor` |
| `{$PG.PASSWORD}` | `<PGZBX_PWD>`  → **chọn kiểu "Secret text"** |
| `{$PATRONI.API.PORT}` | `8008` |
| `{$PATRONI.API.SCHEME}` | `http` |
| `{$PATRONI.HOST}` *(nếu template có)* | `{HOST.CONN}` |

> **Bẫy hay gặp:** item Patroni báo *"failed to connect to 127.0.0.1 port 8008"* = macro host để mặc định `localhost` → proxy tự gọi chính nó. Sửa `{$PATRONI.HOST}` = `{HOST.CONN}` (dùng interface office-net của DB host). Nếu master item **hardcode** `http://127.0.0.1:8008/...` trong ô URL → sửa thẳng URL thành `http://{HOST.CONN}:8008/...`. Dùng nút **Test → Get value** để thấy URL đã resolve.
> **Không cần user/password** cho Patroni (chỉ GET). Nếu template PostgreSQL dùng `{$PG.URI}`: đặt `{$PG.URI}` = `tcp://127.0.0.1:5432`.

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
# xoá user: sudo -u postgres psql -c "DROP ROLE zabbixmonitor;"  (trên Leader)
# đóng cổng: sudo ufw delete allow from <ZBX_PROXY_IP> to any port 8008 proto tcp
```
