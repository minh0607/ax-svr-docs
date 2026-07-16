# Thiết kế: Mô hình schema-per-app cho AX Svr (PostgreSQL)

**Ngày:** 2026-07-16
**Phạm vi:** DevDB (`AXDEV`) trước, chuẩn hóa để áp cho mọi DB sau này.
**Trạng thái:** Đã duyệt hướng, chờ review spec.

---

## 1. Bối cảnh & vấn đề

Toolkit `docs/db-scripts/` hiện dùng mô hình **1 schema `public` + group role** (`<db>_readonly` / `<db>_readwrite`). Khi mới có 1 app thì ổn, nhưng khi nhiều project chạy chung 1 DB thì phát sinh:

- **Đụng tên bảng** giữa các project → dev phải tự đặt prefix (`licasi_`, `pro_`, `hr_`, `fi_`) để né trùng — đây là dấu hiệu thiếu namespace.
- **Không tách quyền theo project** — mọi bảng nằm chung `public`, khó cấp quyền gọn theo từng nhóm.
- **Bẫy đã gặp thực tế trên DevDB `AXDEV`:**
  - 4 bảng `licasi_*` (`licasi_importlog`, `licasi_production_lines`, `licasi_product_master`, `licasi_weekly_data`) nằm ở `public`, user thường (`sehcserver`) không thấy vì chưa được GRANT.
  - Role `db_dev` đang là **SUPERUSER** → bỏ qua toàn bộ group / default-privileges / `REVOKE CREATE ON public` → phá vỡ mô hình phân quyền.
  - `setup-group-roles.sh` khai `ALTER DEFAULT PRIVILEGES` **không có `FOR ROLE`** → chỉ áp cho bảng do đúng role chạy script tạo, nên bảng do role khác (vd `db_dev`) tạo không tự được cấp quyền cho group.

## 2. Mục tiêu / Không làm

**Mục tiêu**
- Chuẩn hóa mô hình **mỗi app = 1 schema** trong cùng 1 DB.
- Group role + default-privileges theo **từng schema**, để bảng tạo sau tự có quyền.
- Cấp quyền **chéo project** gọn bằng cách gán group (membership), không grant từng bảng.
- Di chuyển `licasi` hiện có vào schema riêng **không đổi tên bảng, không sửa code app**.
- Sửa toolkit + docs để mô hình dùng lại được cho mọi DB.
- Sửa lỗ hổng: `db_dev` superuser, `setup-group-roles.sh` thiếu `FOR ROLE`.

**Không làm (YAGNI)**
- Không chuyển sang mô hình database-per-app (đã cân nhắc, chọn schema-per-app cho nhẹ + query chéo dễ).
- Không đổi tên bảng `licasi_*` (code đã dùng, không được đổi).
- Không đụng production đang chạy trừ khi có yêu cầu riêng — spec này chạy/nghiệm thu trên DevDB trước.
- Không tự động hóa tạo login role cho từng nhân sự — vẫn thủ công qua script hiện có.

## 3. Mô hình chuẩn (áp cho mọi app)

```
1 app   = 1 schema                       (production, hr, finance, licasi…)
          + 2 group role:  <app>_readonly / <app>_readwrite   (NOLOGIN)
          + default privileges FOR ROLE <owner>  → bảng tạo sau tự có quyền

1 người / 1 app-connection = 1 login role (KHÔNG superuser)
          → GRANT vào group        → quyền nằm ở group, không ở từng người
          → search_path = <app>, public   → query trong project khỏi ghi schema

superuser CHỈ dành cho dbadmin (DBA). App/dev KHÔNG superuser.
```

**3 tầng, không trộn:** `login role (người)` → `group role (mức quyền)` → `schema (app)`.
Người đến/đi = thêm/bớt login role + gán group; không đụng bảng hay quyền.

### Quy ước đặt tên
- Schema = tên project viết thường, không dấu: `production`, `hr`, `finance`.
- Group: `<schema>_readonly`, `<schema>_readwrite`.
- Bảng trong schema mới **không cần prefix** (`production.plan` thay vì `production.pro_plan`). Project cũ đã có prefix thì **giữ nguyên**, không bắt buộc đổi.

### Quy ước ngôn ngữ script
Toàn bộ **giao diện script** (prompt nhập liệu, thông báo `echo`, tiêu đề cột output, thông báo lỗi) viết **tiếng Anh** — đồng bộ với các script hiện có trong `db-scripts/`. Tài liệu hướng dẫn (`README.md`, `axsvr-phase1-db.md`, spec) vẫn tiếng Việt.

### Ví dụ minh họa (AXDEV)
```
Database AXDEV
├── schema production   →  pro_plan, pro_result            (group production_readonly/readwrite)
├── schema hr           →  hr_employee, hr_salary, hr_attendance  (group hr_*)
├── schema finance      →  fi_cost, fi_fee                 (group finance_*)
└── schema licasi       →  licasi_importlog, licasi_production_lines,
                           licasi_product_master, licasi_weekly_data  (group licasi_*)
```

## 4. Cấp quyền trong & chéo project

**Điều kiện PostgreSQL để đụng schema khác (nhớ CẢ HAI):**
1. `USAGE` trên **schema** đích, và
2. quyền (`SELECT`/…) trên **bảng**.
Thiếu (1) → lỗi `permission denied for schema <x>`.

**Trong project nhà:** account là member của `<app>_readwrite` (hoặc `_readonly`), `search_path = <app>, public`. Query để trần: `SELECT * FROM pro_plan`.

**Chéo project** — ví dụ account Production cần dữ liệu Finance:

| Cần | Lệnh | Ghi chú |
|---|---|---|
| Đọc 1 bảng finance | `GRANT USAGE ON SCHEMA finance TO acc;`<br>`GRANT SELECT ON finance.fi_cost TO acc;` | query ghi rõ `finance.fi_cost` |
| Đọc **mọi** bảng finance | `GRANT finance_readonly TO acc;` | gồm cả bảng tạo mới sau này |
| Đọc+ghi mọi bảng finance | `GRANT finance_readwrite TO acc;` | |
| Thu hồi | `REVOKE finance_readonly FROM acc;` | |

**Nguyên lý:** quyền **cộng dồn qua membership** — 1 account ở nhiều group cùng lúc
(`prod_acc ∈ production_readwrite ∈ finance_readonly`). Cấp/thu quyền chéo = thêm/bớt group.

**search_path khi query chéo:** luôn ghi rõ `schema.table` (tránh trùng tên + vì search_path không có schema kia). Nếu dùng thường xuyên mới thêm: `ALTER ROLE acc SET search_path = production, finance, public;`.

## 5. Di chuyển `licasi` hiện tại — KHÔNG đổi tên, KHÔNG sửa code

Thứ tự an toàn (chạy trên DevDB `AXDEV`):

0. **Discovery** (bắt buộc trước khi làm) — xác định:
   - Tên login role app licasi + đang thuộc group nào (query ở phần Phụ lục).
   - Owner thực của 4 bảng `licasi_*`.
1. `CREATE SCHEMA licasi;` + tạo group `licasi_readonly` / `licasi_readwrite` (NOLOGIN).
2. Chuyển 4 bảng vào schema, **giữ nguyên tên**:
   `ALTER TABLE public.licasi_importlog SET SCHEMA licasi;` (×4).
   → thành `licasi.licasi_importlog` …
3. `ALTER ROLE <user_app> SET search_path = licasi, public;`
   → code viết `SELECT * FROM licasi_importlog` (không ghi schema) vẫn chạy như cũ.
4. `GRANT licasi_readwrite TO <user_app>;` + set default-privileges `FOR ROLE <owner>` trong schema licasi.
5. Kiểm tra: đăng nhập bằng `<user_app>`, chạy đúng các query app dùng → phải ra dữ liệu.

**Rủi ro chính:** set sai `search_path` cho đúng role app → query để trần không tìm ra bảng. Giảm rủi ro bằng bước Discovery + bước 5 kiểm tra bằng chính role app.
**Rollback:** `ALTER TABLE licasi.licasi_x SET SCHEMA public;` (đưa về chỗ cũ) + reset search_path.

## 6. Thay đổi toolkit (deliverable)

1. **Thêm `docs/db-scripts/create-schema.sh`** (+ subcommand `axdb.sh schema <app> <db> [owner]`):
   tạo schema + 2 group role + `GRANT USAGE`/quyền bảng hiện có + `ALTER DEFAULT PRIVILEGES ... FOR ROLE <owner>` — trong 1 lần chạy. Owner mặc định = owner của DB nếu không truyền.
2. **Vá `setup-group-roles.sh`** (và nhánh tương ứng trong `axdb.sh`): nhận thêm tham số `[owner]`, sinh `ALTER DEFAULT PRIVILEGES FOR ROLE <owner>` thay vì để trống. Giữ tương thích ngược (không truyền owner → cảnh báo + hành vi cũ).
3. **Bổ sung lệnh cấp quyền chéo** vào `grant-table.sh`/`axdb.sh` hoặc tài liệu hóa: gán group (`GRANT <schema>_readonly TO acc`) như cách chuẩn cấp quyền cả schema.
4. **Thêm tool "permission overview" theo user** — `axdb.sh perm <db> [user]` (và nhánh tương ứng trong `list-access.sh`):
   - **Không có `[user]` → bản tóm tắt toàn bộ user** (mức 1): mỗi login role 1 dòng — thuộc tính (`super`), group đang thuộc, và schema truy cập được (RO/RW) suy từ tên group `<schema>_readonly|readwrite`.
   - **Có `[user]` → drill-down 1 user** (mức 2): quyền hiệu lực (effective, gồm cả kế thừa qua group) trên từng bảng, dùng `has_table_privilege(user, table, priv)` để tính đúng cả quyền thừa hưởng.
   - Output **tiếng Anh** (`role | super | groups | schema access`; `schema.table | privileges`).
   - Truy vấn tham khảo ở Phụ lục B.
5. **Cập nhật docs:** `docs/db-scripts/README.md` + `docs/axsvr-phase1-db.md` — thêm mục "Nhiều project / nhiều người: schema-per-app" kèm ví dụ Production/HR/Finance ở mục 3–4.

## 7. Sửa `db_dev`

`ALTER ROLE db_dev NOSUPERUSER;` (giữ `CREATEDB` nếu app thật sự cần tạo DB; thường bỏ luôn).
Lý do: role app/dev siêu quyền vô hiệu hóa group + default-privileges + `REVOKE CREATE ON public` + ghim IP. App phải kết nối bằng login role thường, không phải superuser.
**Trước khi hạ:** xác nhận app hiện KHÔNG đang kết nối bằng `db_dev` (nếu có, tạo role app riêng + chuyển connection string trước).

## 8. Kiểm thử / nghiệm thu

Chạy trên DevDB, kịch bản kiểm chứng:
1. Tạo schema demo `finance` + 2 group qua `create-schema.sh` → `\dn` thấy schema, `\du` thấy group.
2. Tạo bảng mới trong schema bằng owner → group `finance_readonly` **tự** có `SELECT` (nhờ default-priv `FOR ROLE`).
3. Account Production (member `production_readwrite`) query `finance.fi_cost` **trước** khi cấp → bị từ chối; sau `GRANT finance_readonly` → đọc được; sau `REVOKE` → lại bị từ chối.
4. licasi: đăng nhập bằng role app, query để trần `licasi_importlog` → ra dữ liệu (chứng minh search_path đúng, code không phải sửa).
5. `db_dev` sau `NOSUPERUSER`: không còn tạo bảng thẳng vào `public` khi bị `REVOKE`.
6. `perm`: `axdb.sh perm AXDEV` liệt kê đúng user + group + schema access; `axdb.sh perm AXDEV prod_acc` hiện đúng các bảng prod_acc đọc/ghi được **kể cả** bảng finance thừa hưởng qua `finance_readonly` (so khớp với bước 3).

## 9. Thứ tự triển khai

1. Discovery trạng thái hiện tại (role app licasi, owner bảng, ai đang là superuser).
2. Vá `setup-group-roles.sh` + thêm `create-schema.sh` + subcommand `axdb.sh`.
3. Nghiệm thu script bằng schema demo trên DevDB (mục 8).
4. Di chuyển `licasi` vào schema (mục 5), kiểm tra bằng role app.
5. Hạ superuser `db_dev` (sau khi chắc app không dùng nó).
6. Cập nhật docs (README db-scripts + phase1-db).
7. Commit.

## Phụ lục A — lệnh Discovery

```sql
-- Role + group đang thuộc
SELECT r.rolname AS role, r.rolcanlogin AS login,
       COALESCE(string_agg(g.rolname, ','), '(none)') AS groups
FROM pg_roles r
LEFT JOIN pg_auth_members m ON m.member = r.oid
LEFT JOIN pg_roles g ON g.oid = m.roleid
WHERE r.rolname NOT LIKE 'pg\_%'
GROUP BY 1,2 ORDER BY r.rolcanlogin DESC, 1;

-- Owner các bảng licasi
SELECT tablename, tableowner FROM pg_tables WHERE tablename LIKE 'licasi_%';

-- Role có đặc quyền admin
SELECT rolname, rolsuper, rolcreaterole, rolcreatedb
FROM pg_roles WHERE rolsuper OR rolcreaterole OR rolcreatedb ORDER BY rolsuper DESC, rolname;
```

## Phụ lục B — Truy vấn cho tool `perm` (output tiếng Anh)

**Mức 1 — tóm tắt toàn bộ user** (`axdb.sh perm <db>`):
```sql
SELECT r.rolname AS role,
       CASE WHEN r.rolsuper THEN 't' ELSE 'f' END AS super,
       COALESCE(string_agg(DISTINCT g.rolname, ', ' ORDER BY g.rolname), '(none)') AS groups,
       COALESCE(string_agg(DISTINCT
         CASE
           WHEN g.rolname LIKE '%\_readwrite' THEN regexp_replace(g.rolname,'_readwrite$','')||': RW'
           WHEN g.rolname LIKE '%\_readonly'  THEN regexp_replace(g.rolname,'_readonly$','') ||': RO'
         END, ', '), CASE WHEN r.rolsuper THEN 'ALL' ELSE '-' END) AS schema_access
FROM pg_roles r
LEFT JOIN pg_auth_members m ON m.member = r.oid
LEFT JOIN pg_roles g ON g.oid = m.roleid
WHERE r.rolcanlogin AND r.rolname NOT LIKE 'pg\_%'
GROUP BY r.rolname, r.rolsuper
ORDER BY r.rolsuper DESC, r.rolname;
```

**Mức 2 — drill-down 1 user** (`axdb.sh perm <db> <user>`), tính cả quyền thừa hưởng qua group:
```sql
-- :u = tên user
SELECT n.nspname AS schema, c.relname AS "table",
       array_to_string(ARRAY[
         CASE WHEN has_table_privilege(:'u', c.oid, 'SELECT') THEN 'SELECT' END,
         CASE WHEN has_table_privilege(:'u', c.oid, 'INSERT') THEN 'INSERT' END,
         CASE WHEN has_table_privilege(:'u', c.oid, 'UPDATE') THEN 'UPDATE' END,
         CASE WHEN has_table_privilege(:'u', c.oid, 'DELETE') THEN 'DELETE' END
       ], ',') AS privileges
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog','information_schema')
  AND (has_table_privilege(:'u', c.oid,'SELECT') OR has_table_privilege(:'u', c.oid,'INSERT')
    OR has_table_privilege(:'u', c.oid,'UPDATE') OR has_table_privilege(:'u', c.oid,'DELETE'))
ORDER BY 1,2;
```
