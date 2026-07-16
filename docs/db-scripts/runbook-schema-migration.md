# Runbook: di chuyển licasi sang schema + hạ superuser db_dev (DevDB AXDEV)

> Chạy TRÊN DB server, bằng `sudo -u postgres psql -d AXDEV` (hoặc `dbadmin`).
> KHÔNG đổi tên 4 bảng licasi_*. Có bước rollback.

## 0. Discovery — nắm hiện trạng
```sql
-- role app licasi + đang thuộc group nào
SELECT r.rolname AS role, r.rolcanlogin AS login,
       COALESCE(string_agg(g.rolname, ','), '(none)') AS groups
FROM pg_roles r
LEFT JOIN pg_auth_members m ON m.member=r.oid
LEFT JOIN pg_roles g ON g.oid=m.roleid
WHERE r.rolname NOT LIKE 'pg\_%'
GROUP BY 1,2 ORDER BY r.rolcanlogin DESC,1;

-- owner 4 bảng
SELECT tablename, tableowner FROM pg_tables WHERE tablename LIKE 'licasi_%';
```
Ghi lại: TÊN role app licasi (gọi là `<APP_USER>`) và OWNER 4 bảng (gọi là `<OWNER>`).

## 1. Tạo schema + group
```bash
cd /path/to/db-scripts
./create-schema.sh licasi AXDEV <OWNER>
```
Kiểm tra: `\dn` thấy `licasi`; `\du` thấy `licasi_readonly`, `licasi_readwrite`.

## 2. Chuyển 4 bảng vào schema (GIỮ NGUYÊN TÊN)
```sql
ALTER TABLE public.licasi_importlog        SET SCHEMA licasi;
ALTER TABLE public.licasi_production_lines SET SCHEMA licasi;
ALTER TABLE public.licasi_product_master   SET SCHEMA licasi;
ALTER TABLE public.licasi_weekly_data      SET SCHEMA licasi;
```
Kiểm tra: `SELECT tablename FROM pg_tables WHERE schemaname='licasi';` → 4 bảng.

## 3. Gán app user + search_path (để code KHÔNG phải sửa)
```sql
GRANT licasi_readwrite TO <APP_USER>;
ALTER ROLE <APP_USER> SET search_path = licasi, public;
```

## 4. Nghiệm thu bằng chính role app
```bash
psql -h <host> -U <APP_USER> -d AXDEV -c "SELECT count(*) FROM licasi_importlog;"
```
Kỳ vọng: chạy ra số dòng (query để trần vẫn thấy bảng nhờ search_path). Nếu lỗi "relation does not exist" → kiểm tra lại Bước 3.

## 5. Hạ superuser db_dev
> Chỉ làm sau khi chắc app KHÔNG kết nối bằng db_dev (xem Discovery).
```sql
ALTER ROLE db_dev NOSUPERUSER;         -- bỏ CREATEDB nếu không cần: ALTER ROLE db_dev NOCREATEDB;
```
Kiểm tra: `SELECT rolsuper FROM pg_roles WHERE rolname='db_dev';` → `f`.

## 6. Kiểm tra tổng quan
```bash
./list-access.sh perm AXDEV
./list-access.sh perm AXDEV <APP_USER>
```

## Rollback
```sql
-- đưa bảng về public
ALTER TABLE licasi.licasi_importlog        SET SCHEMA public;
ALTER TABLE licasi.licasi_production_lines SET SCHEMA public;
ALTER TABLE licasi.licasi_product_master   SET SCHEMA public;
ALTER TABLE licasi.licasi_weekly_data      SET SCHEMA public;
ALTER ROLE <APP_USER> RESET search_path;
-- khôi phục db_dev nếu cần: ALTER ROLE db_dev SUPERUSER;
```
