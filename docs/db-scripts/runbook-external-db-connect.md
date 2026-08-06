# Runbook: kết nối cụm DB Production từ app / hệ thống khác

> Cụm DB **không có VIP, không HAProxy** (thiết kế Cách 2). Client tự tìm Leader bằng **multi-host connection string + `target_session_attrs`**.
> Áp cho: **2 web server** (ax-web01/02) và **hệ thống ngoài** (báo cáo, tích hợp…).
> Node DB: db01 `10.1.1.103` / db02 `.104` / db03 `.105` (LAN backend) · office-net `107.118.210.103/104/105`.

---

## 1. Cơ chế — luôn trúng Leader (read-write)
Liệt kê **cả 3 node** + `target_session_attrs=read-write`. Driver quét từng host, `SHOW transaction_read_only` → node **read-write = Leader** thì dùng, replica thì bỏ qua. Failover xong reconnect là ra Leader mới, **không đổi config**.

```
postgresql://appuser:PWD@10.1.1.103:5432,10.1.1.104:5432,10.1.1.105:5432/AXDB?target_session_attrs=read-write
```

### `target_session_attrs`
| Giá trị | Vào | Dùng cho |
|---|---|---|
| `read-write` (= `primary`) | **Leader** | ghi dữ liệu — mặc định |
| `prefer-standby` | replica trước, fallback Leader | báo cáo/đọc nặng (giảm tải Leader) |
| `read-only` | chỉ replica | read-only thuần |
| `any` | node đầu reachable | **TRÁNH** — có thể trúng replica, ghi lỗi |

> Đọc từ replica có thể trễ vài ms (dù synchronous) → chỉ cho query chịu được hơi cũ.

---

## 2. IP dùng theo vị trí client
| Client | IP trong chuỗi | Firewall | Đường đi |
|---|---|---|---|
| **Web server** (.101/.102) | **LAN** `10.1.1.103,104,105` | đã mở sẵn (gen-firewall role `db`) | backend LAN (cô lập) |
| **Hệ thống ngoài** (office-net) | **office-net** `107.118.210.103,104,105` | phải thêm IP thủ công | office-net routed |

> Web dùng LAN vì cùng dải backend với DB (đúng đường service). Hệ thống ngoài không tới được LAN → dùng office-net (5432 đã bật office-net theo quyết định B).

---

## 3. Chuỗi kết nối theo driver
| Ngôn ngữ | Cú pháp |
|---|---|
| **libpq** (psql, Python psycopg2/3, PHP, Ruby, Go pgx) | `host=10.1.1.103,10.1.1.104,10.1.1.105 port=5432 dbname=AXDB user=appuser target_session_attrs=read-write` |
| **JDBC (Java)** | `jdbc:postgresql://10.1.1.103:5432,10.1.1.104:5432,10.1.1.105:5432/AXDB?targetServerType=primary` |
| **.NET (Npgsql)** | `Host=10.1.1.103,10.1.1.104,10.1.1.105;Port=5432;Database=AXDB;Username=appuser;Password=***;Target Session Attributes=read-write;Pooling=true;Maximum Pool Size=20` |
| **Node (node-postgres)** | ⚠️ KHÔNG hỗ trợ multi-host/target_session_attrs sẵn → cần lib phụ / logic reconnect / PgBouncer |

Hệ thống ngoài: thay IP LAN bằng `107.118.210.103/104/105`.

---

## 4. Onboard 1 client mới — checklist

### a. Role least-privilege + ghim IP (trên Leader)
```bash
sudo -u postgres bash axdb.sh create-user appuser <group>       # KHÔNG superuser; gắn group readwrite/readonly
# web server (2 IP LAN):
sudo -u postgres bash axdb.sh bind-ip appuser 10.1.1.101,10.1.1.102
# hoặc hệ thống ngoài (IP office-net của nó):
sudo -u postgres bash axdb.sh bind-ip appuser 107.118.x.x
```
`bind-ip` sinh pg_hba per-user (ghim IP + scram-sha-256 + reject IP khác), replicate cả cụm.

### b. Firewall
- **Web server:** đã mở sẵn (.101/.102 → 5432) — khỏi làm.
- **Hệ thống ngoài:** mở 5432 cho đúng IP nó, trên cả 3 node:
  ```bash
  ADMIN_DB_IPS=107.118.x.x ZBX_PROXY=<zbx> ... sudo ./gen-firewall.sh db ax-db01 --no-reset --apply
  ```
  (lặp db02/db03)

### c. Quyền dữ liệu
Gắn `appuser` vào group `<schema>_readwrite`/`_readonly` theo mô hình schema-per-app (`axdb.sh grant-group`), không cấp trực tiếp bừa.

---

## 5. Vận hành
- **Chuỗi để ở app config** (appsettings.json / web.config / env) — luôn liệt kê **3 host**, đừng hardcode 1 node.
- **Failover:** kết nối đang mở sẽ đứt → app/pool **reconnect + retry** (Npgsql/HikariCP tự lo) → driver quét lại tìm Leader mới.
- **max_connections:** tổng pool của mọi client < `max_connections` của PG. Nhiều kết nối → cân nhắc **PgBouncer** (transaction pooling).
- **Tách đọc (tùy chọn):** chuỗi thứ 2 `target_session_attrs=prefer-standby` cho báo cáo → đẩy sang replica.

---

## 6. Verify
```bash
# luôn phải trúng Leader (pg_is_in_recovery = f)
psql "host=10.1.1.103,10.1.1.104,10.1.1.105 port=5432 dbname=AXDB user=appuser target_session_attrs=read-write" \
  -c "SELECT inet_server_addr() AS node, pg_is_in_recovery() AS is_replica;"

# thử tắt Leader (diễn tập) -> chạy lại lệnh trên -> phải trúng node mới, is_replica vẫn = f
```
Lỗi thường gặp:
- `no pg_hba.conf entry` → thiếu bước 4a (bind-ip) hoặc sai IP.
- `Connection refused`/timeout → thiếu firewall (4b) hoặc sai dải IP (LAN vs office-net).
- `cannot execute ... in a read-only transaction` → quên `target_session_attrs=read-write` (đang trúng replica).
