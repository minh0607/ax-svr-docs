# AX Svr — DevDB Server (PostgreSQL 17 standalone)

> Môi trường **Dev** cho đội Dev kết nối test. **Standalone** (không Patroni).
> PostgreSQL 17 (PGDG), toàn bộ data + log trong **`/data/postgresql`**.
> IP: **107.118.210.90** (Dev kết nối từ máy cá nhân trong dải `107.118.210.0/24`).

```
Layout đĩa:
  /data/postgresql/17/main   <- data_dir (gồm pg_wal)
  /data/postgresql/logs      <- log
```

> Đây là bản đã chuẩn hóa để **"bê công thức"** sang Production (Phase 1) cho khớp: cùng PG17, cùng `/data`.

---

## Bước 1 — Thêm PGDG repo + cài PostgreSQL 17

```bash
sudo apt update && sudo apt install -y curl ca-certificates gnupg lsb-release
sudo install -d /usr/share/postgresql-common/pgdg
sudo curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail \
  https://www.postgresql.org/media/keys/ACCC4CF8.asc
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
  | sudo tee /etc/apt/sources.list.d/pgdg.list
sudo apt update
sudo apt install -y postgresql-17 postgresql-client-17 postgresql-contrib
```
> Gói `postgresql-17` **tự tạo** user/group `postgres` — KHÔNG tạo tay (tránh lệch home `/var/lib/postgresql`).

---

## Bước 2 — Tạo thư mục /data và dời data dir (Ubuntu Way)

```bash
# Dừng dịch vụ + xóa cluster mặc định (sinh ra khi cài)
sudo systemctl stop postgresql
sudo pg_dropcluster --stop 17 main

# Tạo thư mục trong /data (nên là đĩa riêng)
sudo mkdir -p /data/postgresql/17/main /data/postgresql/logs
sudo chown -R postgres:postgres /data/postgresql
sudo chmod 700 /data/postgresql/17/main
sudo chmod 750 /data/postgresql/logs

# Khởi tạo lại cluster trỏ thẳng vào /data
sudo pg_createcluster -d /data/postgresql/17/main 17 main
```

> **Không cần chỉnh AppArmor.** Trên Ubuntu 24.04, PostgreSQL không bị AppArmor confine mặc định — cách `pg_createcluster -d` ở trên chạy được ngay. Nếu start lỗi, xem `journalctl -u postgresql@17-main -e` (thường là quyền thư mục).

---

## Bước 3 — Cấu hình kết nối + log (`postgresql.conf`)

```bash
sudo nano /etc/postgresql/17/main/postgresql.conf
```
Sửa các thông số (bỏ dấu `#`):
```ini
# --- Kết nối ---
listen_addresses = 'localhost,107.118.210.90'

# --- Log vào /data ---
logging_collector = on
log_directory = '/data/postgresql/logs'
log_filename = 'postgresql-%Y-%m-%d.log'
log_rotation_age = 1d
log_statement = 'all'          # Dev: tiện debug câu lệnh
```
> ⚠️ `log_statement = 'all'` rất nhiều log → có thể đầy đĩa. Dev chấp nhận, nhưng `log_rotation_age=1d` + dọn định kỳ. Production thì KHÔNG bật `all`.

---

## Mô hình kiểm soát truy cập 3 lớp

Dev có **nhiều IP thay đổi + nhiều user + phân quyền theo table** → tách 3 lớp độc lập:

| Lớp | Công cụ | Lo việc | Khi IP/user đổi |
|---|---|---|---|
| 1. Mạng (IP nào tới được 5432) | **ufw** | Chặn/mở theo IP | Sửa ở ufw |
| 2. Xác thực (ai có mật khẩu đúng) | **pg_hba.conf** | Bắt buộc password | KHÔNG cần đụng |
| 3. Phân quyền (user làm gì, table nào) | **GRANT/REVOKE** | Quyền theo bảng | Chạy SQL |

→ Vì **ufw gác IP**, `pg_hba` để **rộng về IP** (khỏi sửa mỗi lần dev đổi IP), chỉ giữ vai trò "bắt buộc mật khẩu". DBA dùng role admin riêng (`dbadmin`), KHÔNG dùng `postgres` gốc.

---

## Bước 4 — `pg_hba.conf` (lớp 2: bắt buộc mật khẩu)

```bash
sudo nano /etc/postgresql/17/main/pg_hba.conf
```
Thêm (đặt các dòng này TRƯỚC các dòng host mặc định):
```text
# postgres gốc: CHỈ local, không bao giờ ra mạng
local   all   postgres                  peer
# cấm postgres gốc qua mạng (an toàn tuyệt đối)
host    all   postgres   0.0.0.0/0      reject
# MỌI role khác (dbadmin, devuser...): qua mạng + BẮT BUỘC mật khẩu
# (IP do ufw kiểm soát — pg_hba để rộng)
host    all   all        0.0.0.0/0      scram-sha-256
```
> `0.0.0.0/0` KHÔNG phải "mở toang" — **ufw mới là cửa gác IP** (lớp 1). pg_hba chỉ đảm bảo ai vào cũng phải có mật khẩu. `postgres` gốc bị `reject` nên không bao giờ vào được từ xa.
> Sau khi sửa: `sudo systemctl reload postgresql`

---

## Bước 5 — Khởi động + tạo role (DBA + dev)

```bash
sudo systemctl enable --now postgresql

# (1) DBA login từ xa — role admin RIÊNG, KHÔNG dùng postgres gốc:
sudo -u postgres psql -c "CREATE ROLE dbadmin LOGIN SUPERUSER PASSWORD '<MK_DBA_MANH>';"

# (2) Dev user (quyền vừa đủ, tự tạo DB làm việc):
sudo -u postgres psql -c "CREATE ROLE devuser LOGIN PASSWORD '<MK_DEV>' CREATEDB;"
```

> - `postgres` gốc: giữ khóa local, KHÔNG cấp ra mạng (pg_hba đã `reject`).
> - `dbadmin`: superuser, DBA dùng để quản trị từ xa. Đặt tên KHÁC `postgres` + mật khẩu mạnh.
> - Cả `dbadmin` và `devuser` đều khớp dòng `host all all scram-sha-256` → vào được qua mạng (IP do ufw gác).

### Lớp 3 — phân quyền theo table (sau này, dùng GRANT)
```sql
-- gợi ý: tạo group role theo nhóm quyền, rồi gán user vào nhóm
CREATE ROLE readonly NOLOGIN;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly;
GRANT readonly TO devuser;          -- devuser chỉ đọc

-- hoặc cấp quyền từng bảng cho từng user:
GRANT SELECT, INSERT, UPDATE ON orders TO dev_a;
REVOKE INSERT ON orders FROM dev_a;
```

---

## Bước 6 — Kiểm tra trước khi bàn giao

```bash
sudo -u postgres psql -c "SHOW data_directory;"     # /data/postgresql/17/main
sudo -u postgres psql -c "SHOW log_directory;"      # /data/postgresql/logs
sudo -u postgres psql -c "SELECT version();"        # PostgreSQL 17.x

# Test kết nối qua mạng bằng devuser (từ máy khác hoặc chính server):
psql "host=107.118.210.90 port=5432 user=devuser dbname=postgres"
```

---

## Firewall — Lớp 1: ufw gác IP (nơi kiểm soát IP thực sự)

```bash
# 5432: mở cho DẢI dev (đỡ phải sửa khi từng IP đổi) + IP của DBA
sudo ufw allow from 107.118.210.0/24 to any port 5432 proto tcp   # dải dev
sudo ufw allow from <IP_DBA> to any port 5432 proto tcp           # DBA từ xa
# 22: SSH chỉ admin
sudo ufw allow from <IP_ADMIN> to any port 22 proto tcp
sudo ufw enable
```
Thêm/bớt IP khi dev thay đổi (không cần đụng pg_hba):
```bash
sudo ufw allow from <IP_mới> to any port 5432 proto tcp     # thêm
sudo ufw delete allow from <IP_cũ> to any port 5432 proto tcp  # bớt
```
> Dev nằm trong vài dải cố định → mở theo **dải** thay vì từng IP cho đỡ phải sửa liên tục.

---

## 📄 Thông tin bàn giao Đội Dev

| | |
|---|---|
| Host / IP | `107.118.210.90` |
| Port | `5432` |
| User | `devuser` (CREATEDB — tự tạo DB làm việc) |
| Password | *(mật khẩu đặt ở Bước 5)* |
| Tool gợi ý | DBeaver / pgAdmin / Navicat |

> Dev dùng `devuser` tạo database riêng để làm việc, không cần superuser.

---

## Khác biệt so với Production (Phase 1)

| | DevDB | Production (Phase 1) |
|---|---|---|
| HA | ❌ standalone | ✅ Patroni + etcd 3 node |
| Cài cluster | `pg_createcluster` (Ubuntu way) | Patroni tự `initdb` |
| Data dir | `/data/postgresql/17/main` | `/data/postgresql/17/main` (giống) |
| log_statement | `all` (debug) | tắt (chỉ log lỗi/chậm) |
| Truy cập | Dev qua WAN 107.118.210.x | App qua LAN 10.1.1.x (multi-host) |

> Công thức `/data` + PG17 giống nhau → chuyển sang prod mượt.
