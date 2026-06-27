# AX Svr — DB Scripts (quản trị PostgreSQL)

Bộ script tạo role/database/phân quyền. Dùng cho **DevDB** và **Production** (Patroni).

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
| `list-access.sh <roles\|dbs\|members <g>\|grants <db>>` | Xem role/db/quyền |

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

## Lưu ý bảo mật

- Mật khẩu nhập qua prompt ẩn (không vào shell history).
- Nếu `log_statement='all'` (DevDB) → lệnh tạo/đổi mật khẩu có thể bị ghi log. Production để `log_statement='ddl'`/`none`.
- `postgres` gốc giữ local-only; quản trị từ xa dùng `dbadmin`.
- 3 lớp kiểm soát: **ufw** (IP) → **pg_hba** (mật khẩu) → **các script này** (quyền role/table).
