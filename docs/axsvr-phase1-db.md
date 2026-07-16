# AX Svr — Phase 1: Cụm PostgreSQL HA (etcd + Patroni)

> Phương án: **Cách 2 (multi-host connection)** — chỉ dựng **etcd + Patroni** trên 3 node, KHÔNG HAProxy/VIP.
> **PostgreSQL 17** (qua PGDG repo). Toàn bộ data + log nằm trong **`/data/postgresql`**.

```
DB1 10.1.1.103  │  DB2 10.1.1.104  │  DB3 10.1.1.105
PostgreSQL 17 + Patroni + etcd  (mỗi node đủ 3 thành phần)
Replication: 1 synchronous + 1 asynchronous

Layout đĩa mỗi node:
  /data/postgresql/17/main   <- data_dir (gồm pg_wal)
  /data/postgresql/logs      <- log
```

---

## 1.0 — Chuẩn bị chung (chạy trên CẢ 3 node)

**Hostname + /etc/hosts:**
```bash
sudo hostnamectl set-hostname ax-db01     # đổi tương ứng từng node
sudo tee -a /etc/hosts >/dev/null <<'EOF'
10.1.1.103  ax-db01
10.1.1.104  ax-db02
10.1.1.105  ax-db03
EOF
```

**Đồng bộ giờ (etcd/Patroni rất cần):**
```bash
sudo timedatectl set-ntp true
timedatectl status | grep "synchronized"   # phải: yes
```

**Thêm PGDG repo + cài PostgreSQL 17 + Patroni + etcd:**
```bash
sudo apt update && sudo apt install -y curl ca-certificates gnupg lsb-release
sudo install -d /usr/share/postgresql-common/pgdg
sudo curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail \
  https://www.postgresql.org/media/keys/ACCC4CF8.asc
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
  | sudo tee /etc/apt/sources.list.d/pgdg.list
sudo apt update
sudo apt install -y postgresql-17 postgresql-client-17 \
                    patroni python3-etcd3 etcd-server etcd-client pgbackrest
```

**Gỡ cluster mặc định (Patroni sẽ tự initdb cluster riêng vào /data):**
```bash
sudo systemctl disable --now postgresql
sudo pg_dropcluster --stop 17 main
```

**Tạo thư mục /data (Patroni initdb sẽ ghi vào đây):**
```bash
sudo mkdir -p /data/postgresql/17/main /data/postgresql/logs
sudo chown -R postgres:postgres /data/postgresql
sudo chmod 700 /data/postgresql/17/main
sudo chmod 750 /data/postgresql/logs
```
> `/data` nên là **volume/đĩa riêng** (không chung với OS) để cấp dung lượng + snapshot độc lập.

**Firewall — chỉ mở trong LAN 10.1.1.0/24:**
```bash
sudo ufw allow from 10.1.1.0/24 to any port 5432 proto tcp   # PostgreSQL
sudo ufw allow from 10.1.1.0/24 to any port 8008 proto tcp   # Patroni REST
sudo ufw allow from 10.1.1.0/24 to any port 2379 proto tcp   # etcd client
sudo ufw allow from 10.1.1.0/24 to any port 2380 proto tcp   # etcd peer
sudo ufw allow from 107.118.210.0/24 to any port 22 proto tcp  # SSH quản trị (airgap)
sudo ufw enable
```

---

## 1.1 — etcd cluster 3 node (DCS quorum)

Mỗi node có 1 file `/etc/default/etcd` riêng. Dưới đây là **file đầy đủ cho từng node** — copy-paste thẳng, không phải tự đổi. Lưu ý dòng `ETCD_INITIAL_CLUSTER` **giống hệt trên cả 3 node** (danh bạ đủ 3 thành viên).

**DB1 — `/etc/default/etcd` (10.1.1.103):**
```ini
ETCD_NAME="ax-db01"
ETCD_DATA_DIR="/var/lib/etcd"
ETCD_LISTEN_PEER_URLS="http://10.1.1.103:2380"
ETCD_LISTEN_CLIENT_URLS="http://10.1.1.103:2379,http://127.0.0.1:2379"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://10.1.1.103:2380"
ETCD_ADVERTISE_CLIENT_URLS="http://10.1.1.103:2379"
ETCD_INITIAL_CLUSTER="ax-db01=http://10.1.1.103:2380,ax-db02=http://10.1.1.104:2380,ax-db03=http://10.1.1.105:2380"
ETCD_INITIAL_CLUSTER_TOKEN="ax-etcd-cluster"
ETCD_INITIAL_CLUSTER_STATE="new"
```

**DB2 — `/etc/default/etcd` (10.1.1.104):**
```ini
ETCD_NAME="ax-db02"
ETCD_DATA_DIR="/var/lib/etcd"
ETCD_LISTEN_PEER_URLS="http://10.1.1.104:2380"
ETCD_LISTEN_CLIENT_URLS="http://10.1.1.104:2379,http://127.0.0.1:2379"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://10.1.1.104:2380"
ETCD_ADVERTISE_CLIENT_URLS="http://10.1.1.104:2379"
ETCD_INITIAL_CLUSTER="ax-db01=http://10.1.1.103:2380,ax-db02=http://10.1.1.104:2380,ax-db03=http://10.1.1.105:2380"
ETCD_INITIAL_CLUSTER_TOKEN="ax-etcd-cluster"
ETCD_INITIAL_CLUSTER_STATE="new"
```

**DB3 — `/etc/default/etcd` (10.1.1.105):**
```ini
ETCD_NAME="ax-db03"
ETCD_DATA_DIR="/var/lib/etcd"
ETCD_LISTEN_PEER_URLS="http://10.1.1.105:2380"
ETCD_LISTEN_CLIENT_URLS="http://10.1.1.105:2379,http://127.0.0.1:2379"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://10.1.1.105:2380"
ETCD_ADVERTISE_CLIENT_URLS="http://10.1.1.105:2379"
ETCD_INITIAL_CLUSTER="ax-db01=http://10.1.1.103:2380,ax-db02=http://10.1.1.104:2380,ax-db03=http://10.1.1.105:2380"
ETCD_INITIAL_CLUSTER_TOKEN="ax-etcd-cluster"
ETCD_INITIAL_CLUSTER_STATE="new"
```

> etcd data để ở `/var/lib/etcd` (nhỏ, là DCS — không phải data DB). Muốn gom vào /data thì đổi `ETCD_DATA_DIR=/data/etcd` + tạo thư mục, nhưng không bắt buộc.

**Khởi động (gần như đồng thời trên cả 3 node):**
```bash
sudo systemctl enable --now etcd
etcdctl --endpoints=http://10.1.1.103:2379,http://10.1.1.104:2379,http://10.1.1.105:2379 endpoint health
```

> **⚠️ Lỗi thường gặp — `endpoint health` failed, etcd chỉ nghe trên `127.0.0.1:2379`, không nghe trên IP LAN.**
> Nguyên nhân: gói etcd tự start ngay lúc `apt install` bằng config MẶC ĐỊNH (chỉ bind localhost). Khi sửa `/etc/default/etcd` xong, lệnh `enable --now` **không restart** tiến trình đang chạy sẵn → vẫn giữ config cũ; data-dir cũng đã init bằng member mặc định. Cách xử lý — làm trên **cả 3 node gần đồng thời** (vì `INITIAL_CLUSTER_STATE="new"`):
> ```bash
> sudo systemctl stop etcd
> sudo rm -rf /var/lib/etcd/*        # xoá member init sai — CHỈ an toàn lúc dựng mới, chưa có data thật
> sudo systemctl restart etcd
> sudo ss -tlnp | grep 2379          # verify: phải thấy 10.1.1.103:2379 (IP LAN), không chỉ 127.0.0.1
> ```
> Kiểm tra thêm nếu vẫn lỗi: `systemctl cat etcd | grep EnvironmentFile` phải có `-/etc/default/etcd`.

---

## 1.2 — Patroni

**Tạo mật khẩu mạnh (lưu nơi an toàn):**
```bash
openssl rand -base64 24   # superuser
openssl rand -base64 24   # replicator
```

Mỗi node có 1 file `/etc/patroni/patroni.yml` riêng. Dưới đây là **file đầy đủ cho từng node** — copy-paste thẳng.

> ⚠️ **Chỉ 5 dòng khác nhau giữa 3 node** (`name`, `restapi.listen/connect_address`, `postgresql.listen/connect_address`). Mọi thứ còn lại (`bootstrap`, `etcd3.hosts`, mật khẩu, `data_dir`, `tags`) **PHẢI giống hệt cả 3 node**. Nếu sau này chỉnh tham số chung (vd `shared_buffers`, `pg_hba`), **sửa cả 3 file**.
> Mật khẩu `<MK_SUPERUSER>` / `<MK_REPLICATOR>` giống nhau trên cả 3 node. WAL nằm trong `data_dir/pg_wal` → tự động trong `/data`.

**DB1 — `/etc/patroni/patroni.yml` (10.1.1.103):**
```yaml
scope: ax-pg-cluster
namespace: /service/
name: ax-db01

restapi:
  listen: 10.1.1.103:8008
  connect_address: 10.1.1.103:8008

etcd3:
  hosts:
    - 10.1.1.103:2379
    - 10.1.1.104:2379
    - 10.1.1.105:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    synchronous_mode: true
    synchronous_node_count: 1
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        max_connections: 200
        shared_buffers: 2GB
        wal_level: replica
        hot_standby: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 1GB
        password_encryption: scram-sha-256
        # --- Log vào /data ---
        logging_collector: "on"
        log_directory: "/data/postgresql/logs"
        log_filename: "postgresql-%Y-%m-%d.log"
  initdb:
    - encoding: UTF8
    - data-checksums
  pg_hba:
    - local all all trust
    - host all all 127.0.0.1/32 scram-sha-256
    - host all all 10.1.1.0/24 scram-sha-256              # web app kết nối
    - host replication replicator 10.1.1.0/24 scram-sha-256

postgresql:
  listen: 10.1.1.103:5432
  connect_address: 10.1.1.103:5432
  data_dir: /data/postgresql/17/main      # <- DATA trong /data
  bin_dir: /usr/lib/postgresql/17/bin
  pgpass: /tmp/pgpass
  authentication:
    superuser:
      username: postgres
      password: "<MK_SUPERUSER>"
    replication:
      username: replicator
      password: "<MK_REPLICATOR>"

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
```

**DB2 — `/etc/patroni/patroni.yml` (10.1.1.104):**
```yaml
scope: ax-pg-cluster
namespace: /service/
name: ax-db02

restapi:
  listen: 10.1.1.104:8008
  connect_address: 10.1.1.104:8008

etcd3:
  hosts:
    - 10.1.1.103:2379
    - 10.1.1.104:2379
    - 10.1.1.105:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    synchronous_mode: true
    synchronous_node_count: 1
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        max_connections: 200
        shared_buffers: 2GB
        wal_level: replica
        hot_standby: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 1GB
        password_encryption: scram-sha-256
        # --- Log vào /data ---
        logging_collector: "on"
        log_directory: "/data/postgresql/logs"
        log_filename: "postgresql-%Y-%m-%d.log"
  initdb:
    - encoding: UTF8
    - data-checksums
  pg_hba:
    - local all all trust
    - host all all 127.0.0.1/32 scram-sha-256
    - host all all 10.1.1.0/24 scram-sha-256              # web app kết nối
    - host replication replicator 10.1.1.0/24 scram-sha-256

postgresql:
  listen: 10.1.1.104:5432
  connect_address: 10.1.1.104:5432
  data_dir: /data/postgresql/17/main      # <- DATA trong /data
  bin_dir: /usr/lib/postgresql/17/bin
  pgpass: /tmp/pgpass
  authentication:
    superuser:
      username: postgres
      password: "<MK_SUPERUSER>"
    replication:
      username: replicator
      password: "<MK_REPLICATOR>"

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
```

**DB3 — `/etc/patroni/patroni.yml` (10.1.1.105):**
```yaml
scope: ax-pg-cluster
namespace: /service/
name: ax-db03

restapi:
  listen: 10.1.1.105:8008
  connect_address: 10.1.1.105:8008

etcd3:
  hosts:
    - 10.1.1.103:2379
    - 10.1.1.104:2379
    - 10.1.1.105:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    synchronous_mode: true
    synchronous_node_count: 1
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        max_connections: 200
        shared_buffers: 2GB
        wal_level: replica
        hot_standby: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 1GB
        password_encryption: scram-sha-256
        # --- Log vào /data ---
        logging_collector: "on"
        log_directory: "/data/postgresql/logs"
        log_filename: "postgresql-%Y-%m-%d.log"
  initdb:
    - encoding: UTF8
    - data-checksums
  pg_hba:
    - local all all trust
    - host all all 127.0.0.1/32 scram-sha-256
    - host all all 10.1.1.0/24 scram-sha-256              # web app kết nối
    - host replication replicator 10.1.1.0/24 scram-sha-256

postgresql:
  listen: 10.1.1.105:5432
  connect_address: 10.1.1.105:5432
  data_dir: /data/postgresql/17/main      # <- DATA trong /data
  bin_dir: /usr/lib/postgresql/17/bin
  pgpass: /tmp/pgpass
  authentication:
    superuser:
      username: postgres
      password: "<MK_SUPERUSER>"
    replication:
      username: replicator
      password: "<MK_REPLICATOR>"

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
```

**Systemd** `/etc/systemd/system/patroni.service` (cả 3 node giống nhau):
```ini
[Unit]
Description=Patroni PostgreSQL HA
After=network.target etcd.service
Wants=network-online.target

[Service]
Type=simple
User=postgres
Group=postgres
ExecStart=/usr/bin/patroni /etc/patroni/patroni.yml
Restart=on-failure
RestartSec=5
KillMode=process
TimeoutSec=60

[Install]
WantedBy=multi-user.target
```
```bash
sudo mkdir -p /etc/patroni
sudo chown -R postgres:postgres /etc/patroni
sudo chmod 600 /etc/patroni/patroni.yml
```

---

## 1.3 — Khởi động ĐÚNG THỨ TỰ

```bash
# BƯỚC 1: chỉ trên DB1 — initdb vào /data + thành Leader đầu tiên
sudo systemctl enable --now patroni        # DB1
patronictl -c /etc/patroni/patroni.yml list   # chờ ~20s

# BƯỚC 2: sau khi DB1 là Leader, mới bật DB2 rồi DB3
sudo systemctl enable --now patroni        # DB2
sudo systemctl enable --now patroni        # DB3
```

**Kết quả mong đợi:**
```
+ Cluster: ax-pg-cluster ------+--------------+---------+----+-----------+
| Member | Host        | Role         | State   | TL | Lag in MB |
| ax-db01 | 10.1.1.103  | Leader       | running |  1 |           |
| ax-db02 | 10.1.1.104  | Sync Standby | running |  1 |         0 |
| ax-db03 | 10.1.1.105  | Replica      | running |  1 |         0 |
```

**Xác nhận data nằm đúng /data:**
```bash
psql -h 10.1.1.103 -U postgres -c "SHOW data_dir;"     # /data/postgresql/17/main
psql -h 10.1.1.103 -U postgres -c "SHOW log_directory;" # /data/postgresql/logs
```

---

## 1.4 — TEST FAILOVER (bắt buộc)

```bash
psql -h 10.1.1.103 -U postgres -c "CREATE TABLE t(id int); INSERT INTO t VALUES(1);"
sudo systemctl stop patroni       # trên DB1 (đang là Leader)
patronictl -c /etc/patroni/patroni.yml list      # ~15-30s sau: Leader mới
psql -h 10.1.1.104 -U postgres -c "INSERT INTO t VALUES(2); SELECT * FROM t;"
sudo systemctl start patroni      # DB1 rejoin thành Replica (pg_rewind)
patronictl list
```

---

## Bàn giao Web Engineer (connection string Cách 2)

```
Host=10.1.1.103,10.1.1.104,10.1.1.105;Port=5432;Database=<db>;
Username=<user>;Password=<pwd>;Target Session Attributes=read-write
```
Driver tự tìm primary; failover xong kết nối mới tự trỏ đúng. KHÔNG hardcode 1 IP.

---

## Phân quyền nhiều project (schema-per-app)

Khi nhiều project dùng chung 1 database (vd `AXDEV`), mỗi project nên có **1 schema riêng** thay vì dồn hết vào `public`:

```
Database AXDEV
├── schema production   →  pro_plan, pro_result                   (group production_readonly/readwrite)
├── schema hr           →  hr_employee, hr_salary, hr_attendance  (group hr_readonly/readwrite)
└── schema finance      →  fi_cost, fi_fee                        (group finance_readonly/readwrite)
```

> **Lưu ý:** group role là cluster-global (dùng chung toàn cluster). Nếu tạo TRÙNG tên schema ở hai database khác nhau, chúng dùng chung một group — người được gán group ở DB này cũng có quyền ở schema cùng tên bên DB kia. Trong cùng một database thì không sao; nếu cần trùng tên schema qua nhiều database, hãy đặt tên group kèm tên DB.

Tạo schema cho 1 project (xem thêm `docs/db-scripts/README.md`):
```bash
./create-schema.sh finance appdb appowner
# hoặc: ./axdb.sh schema finance appdb appowner
```

**Cấp quyền chéo project** — vd account Production cần đọc dữ liệu Finance:

| Cần | Lệnh | Ghi chú |
|---|---|---|
| Đọc 1 bảng finance | `GRANT USAGE ON SCHEMA finance TO acc;`<br>`GRANT SELECT ON finance.fi_cost TO acc;` | query ghi rõ `finance.fi_cost` |
| Đọc mọi bảng finance | `GRANT finance_readonly TO acc;` | gồm cả bảng tạo mới sau này |
| Đọc+ghi mọi bảng finance | `GRANT finance_readwrite TO acc;` | |
| Thu hồi | `REVOKE finance_readonly FROM acc;` | |

Query chéo schema luôn phải ghi rõ `schema.table` (vd `SELECT * FROM finance.fi_cost`); trong project nhà thì để trần nhờ `search_path = <schema>, public`.

Gán user vào project (hoặc quyền chéo project) — không cần SQL thô:
```bash
./axdb.sh grant-group  fi_user finance_readwrite
./axdb.sh set-search-path fi_user finance
./axdb.sh grant-group  prod_acc finance_readonly   # quyền đọc chéo project
./axdb.sh revoke-group prod_acc finance_readonly
```

Xem / quản lý schema:
```bash
./axdb.sh show schemas appdb
./axdb.sh set-schema  appdb public.legacy_t finance   # chuyển bảng vào schema, giữ nguyên tên
./axdb.sh drop-schema appdb finance [--cascade]
```

Đổi tên (mỗi lệnh tự xử lý luôn phần phụ thuộc vào tên cũ):
```bash
./axdb.sh rename-table  appdb finance.fi_cost fi_expense   # chỉ đổi tên bảng; schema giữ nguyên
./axdb.sh rename-schema appdb finance fin                  # tự đổi tên finance_readonly/finance_readwrite -> fin_*; patch search_path của role ở phạm vi TOÀN CLUSTER (thiết lập của role không gắn với từng database, nên các database khác có schema 'finance' có thể bị ảnh hưởng — lệnh sẽ cảnh báo khi phát hiện)
./axdb.sh rename-user   old_user new_user                  # tự chuyển ghim IP (pg_hba pin) sang tên mới (chế độ file)
```
3 hệ quả được xử lý tự động: đổi tên group đi kèm, patch `search_path` của role, chuyển ghim IP. Lưu ý: đổi tên KHÔNG tự cập nhật code ứng dụng / connection string — phải tự sửa các chỗ đó.

Xem tổng quan quyền của user:
```bash
./list-access.sh perm appdb            # tóm tắt toàn bộ user
./list-access.sh perm appdb prod_acc   # chi tiết từng bảng cho 1 user
# tương đương: ./axdb.sh perm appdb [user]
```
