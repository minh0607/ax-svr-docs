# AX Svr — DB Scripts (quản trị PostgreSQL)

Bộ script tạo role/database/phân quyền. Dùng cho **DevDB** và **Production** (Patroni).

## ⭐ Script TỔNG: `axdb.sh` (1 file, gộp tất cả)

Nếu muốn **1 script duy nhất**, dùng `axdb.sh <command>` (self-contained, không cần file khác):
```bash
./axdb.sh help                              # xem tất cả lệnh
./axdb.sh create-admin dbadmin
./axdb.sh create-db appdb dbadmin
./axdb.sh setup-groups appdb
./axdb.sh create-user dev_a appdb_readonly
./axdb.sh grant dev_a appdb orders "SELECT,INSERT"
./axdb.sh passwd dev_a
./axdb.sh bind-ip a 1.1.1.1                  # tự nhận DevDB(file) hay Patroni(DCS)
./axdb.sh drop-user dev_a
./axdb.sh drop-db appdb
./axdb.sh list roles
```
> `bind-ip` **tự phát hiện**: có `patronictl` + `/etc/patroni/patroni.yml` → dùng DCS; ngược lại sửa file. Ép bằng `--file` / `--patroni`.

Các script rời bên dưới vẫn dùng được (cùng logic) — chọn 1 trong 2 cách.

---

## Kết nối với quyền admin

| Cách | Lệnh |
|---|---|
| **Chạy ngay trên DB server** (mặc định) | chạy script bình thường — dùng socket as `postgres` |
| **Chạy từ xa** (qua dbadmin) | `export PSQL_ADMIN="psql -h 107.118.210.90 -U dbadmin"` rồi chạy script |

> Production (Patroni): chạy trên node **Leader**, hoặc từ xa qua connection multi-host trỏ `target_session_attrs=read-write`.

## Danh sách script

| Script | Việc |
|---|---|
| `create-db-admin.sh <tên>` | Tạo **DBA** (SUPERUSER) — quản trị từ xa, thay `postgres` gốc |
| `create-user-admin.sh <tên>` | Tạo **user admin** (CREATEROLE+CREATEDB, không superuser) |
| `create-user.sh <user> [group]` | Tạo user thường, tuỳ chọn gán nhóm |
| `create-database.sh <db> [owner]` | Tạo database + thu hồi quyền PUBLIC |
| `setup-group-roles.sh <db>` | Tạo nhóm `<db>_readonly` / `<db>_readwrite` + default privileges |
| `grant-table.sh <grant\|revoke> <role> <db> <table> <privs>` | Phân quyền theo từng bảng |
| `reset-password.sh <role>` | Đổi mật khẩu role (nhập 2 lần, ẩn) |
| `bind-user-ip.sh <user> <ip[,ip2]>` / `<user> --unpin` | **Pin user chỉ từ IP** — **DevDB/standalone** (sửa pg_hba file) |
| `bind-user-ip-patroni.sh <user> <ip[,ip2]>` / `<user> --unpin` | **Pin user chỉ từ IP** — **Production Patroni** (qua DCS/patronictl) |
| `drop-user.sh <user> [reassign_to]` | **Xoá user an toàn** — chuyển object sang owner khác rồi drop |
| `drop-database.sh <db>` | **Xoá database an toàn** — nhắc backup + gõ lại tên + FORCE |
| `list-access.sh <roles\|dbs\|members <g>\|grants <db>>` | Xem role/db/quyền |

### Lưu ý các script XOÁ (destructive)
- `drop-user.sh`: chặn xoá role bảo vệ (`postgres`, `dbadmin`, `useradmin`, `replicator`); chuyển object sở hữu sang `reassign_to` (mặc định `dbadmin`) trên **mọi database** trước khi DROP.
- `drop-database.sh`: chặn db hệ thống; in dung lượng + số kết nối; **bắt gõ lại đúng tên** mới xoá; dùng `WITH (FORCE)` để ngắt kết nối. **Không hoàn tác được — backup trước!**

## Quy trình điển hình (ví dụ database `appdb`)

```bash
# 1) DBA + user admin (1 lần cho cả hệ thống)
./create-db-admin.sh   dbadmin
./create-user-admin.sh useradmin

# 2) Tạo database + nhóm quyền
./create-database.sh    appdb dbadmin
./setup-group-roles.sh  appdb           # -> appdb_readonly, appdb_readwrite

# 3) Tạo user và gán nhóm
./create-user.sh dev_a appdb_readonly   # dev_a chỉ ĐỌC
./create-user.sh dev_b appdb_readwrite  # dev_b ĐỌC+GHI

# 4) Phân quyền lẻ theo bảng (khi cần ngoại lệ)
./grant-table.sh grant  dev_a appdb orders "SELECT,INSERT,UPDATE"
./grant-table.sh revoke dev_a appdb orders INSERT

# 5) Kiểm tra
./list-access.sh roles
./list-access.sh grants appdb
```

## Mô hình phân quyền khuyến nghị (nhiều user)

```
Quyền gắn vào NHÓM (group role), KHÔNG gắn trực tiếp vào từng user:
  appdb_readonly  ← dev_a, dev_c, reporting...
  appdb_readwrite ← dev_b, app_service...
=> thêm/bớt người chỉ cần GRANT/REVOKE nhóm; quyền bảng mới tự áp nhờ DEFAULT PRIVILEGES.
```

## Pin account vào IP cụ thể (`bind-user-ip.sh`)

IP **không** gán ở account — gán ở `pg_hba.conf`. Script này quản lý giúp:
```bash
./bind-user-ip.sh app_svc 10.1.1.101          # app_svc CHỈ từ IP này
./bind-user-ip.sh dev_a   192.0.2.10,192.0.2.11  # nhiều IP
./bind-user-ip.sh dev_a   --unpin             # bỏ pin -> theo rule chung
```
- Cơ chế: thêm `include_if_exists pg_hba_peruser.conf` ở đầu `pg_hba.conf`, ghi block `allow <IP> + reject mọi IP khác` cho user, rồi reload + kiểm tra lỗi.
- **Dùng khi:** account IP cố định (service account, server, máy DBA). **Không nên** pin dev laptop IP hay đổi (phải sửa + reload mỗi lần).
- **3 lớp:** ufw (IP toàn cục) · pg_hba/pin (IP theo user) · GRANT (quyền table).

### Pin IP — 2 bản (giống MySQL `user@host`)
| Môi trường | Script | Cơ chế |
|---|---|---|
| DevDB / standalone | `bind-user-ip.sh` | sửa file `pg_hba.conf` + reload |
| Production Patroni | `bind-user-ip-patroni.sh` | cập nhật DCS qua `patronictl edit-config` + reload cụm |

```bash
# DevDB:
./bind-user-ip.sh a 1.1.1.1            # a CHỈ vào được từ 1.1.1.1, IP khác bị reject
# Production (chạy trên 1 DB node):
./bind-user-ip-patroni.sh a 1.1.1.1
```
> ⚠️ **Không** dùng `bind-user-ip.sh` (sửa file) trên cụm Patroni — Patroni sẽ ghi đè. Dùng bản `-patroni`.
> Khác MySQL: PG là **1 role 1 mật khẩu**, IP tách ở pg_hba; cần mật khẩu khác theo IP thì tạo role riêng mỗi IP.

## Lưu ý bảo mật

- Mật khẩu nhập qua prompt ẩn (không vào shell history).
- Nếu `log_statement='all'` (DevDB) → lệnh tạo/đổi mật khẩu có thể bị ghi log. Production để `log_statement='ddl'`/`none`.
- `postgres` gốc giữ local-only; quản trị từ xa dùng `dbadmin`.
- 3 lớp kiểm soát: **ufw** (IP) → **pg_hba** (mật khẩu) → **các script này** (quyền role/table).
