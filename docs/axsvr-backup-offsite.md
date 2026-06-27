# AX Svr — Off-site Backup cho /backup (hoàn tất 3-2-1)

> Bổ sung **bản backup thứ 3 ở off-site**. Hiện backup chỉ nằm trên `/backup` của DB3 (phương án B)
> → DB3 hỏng / mất site = mất hết. Off-site là lớp chống thảm họa bắt buộc cho production.

```
Quy tắc 3-2-1:
  3 bản: production (DB) + /backup (DB3) + OFF-SITE  ← file này
  2 loại lưu trữ khác nhau
  1 bản ở nơi khác về địa lý
```

---

## Chọn đích off-site

| Hướng | Khi nào dùng |
|---|---|
| **A. Cloud object storage (S3-compatible)** ⭐ | Khuyến nghị — pgBackRest hỗ trợ S3 native, có mã hóa + retention riêng |
| **B. Server/NAS ở site khác (qua SSH)** | Có sẵn hạ tầng ở chi nhánh/DC khác |
| **C. rclone đồng bộ thủ công** | Đơn giản, chỉ cần đẩy file dump đi |

---

## A. pgBackRest repo2 = Cloud S3 (KHUYẾN NGHỊ)

pgBackRest hỗ trợ **nhiều repository**. Giữ `repo1` = `/backup` local (Phase 5), thêm `repo2` = cloud.
Mỗi `backup` và mỗi WAL `archive-push` sẽ **tự ghi sang CẢ HAI repo** → off-site liên tục, có PITR.

Tương thích S3: **AWS S3, Backblaze B2, Wasabi, MinIO, Cloudflare R2...**

### A.1 — Thêm cấu hình repo2 (trên DB3, `/etc/pgbackrest/pgbackrest.conf`)

Thêm vào `[global]`:
```ini
# ===== repo2: off-site S3 (có mã hóa) =====
repo2-type=s3
repo2-s3-bucket=ax-pg-backup
repo2-s3-endpoint=s3.us-west-001.backblazeb2.com   # đổi theo nhà cung cấp
repo2-s3-region=us-west-001
repo2-s3-key=<ACCESS_KEY>
repo2-s3-key-secret=<SECRET_KEY>
repo2-path=/ax
repo2-retention-full=4                 # off-site giữ nhiều hơn (vd 4 tuần)
# --- BẮT BUỘC mã hóa cho dữ liệu rời khỏi nhà ---
repo2-cipher-type=aes-256-cbc
repo2-cipher-pass=<PASSPHRASE_MANH>

# Đẩy WAL bất đồng bộ để không làm chậm DB khi gửi lên cloud:
archive-async=y
spool-path=/var/spool/pgbackrest
```
```bash
sudo mkdir -p /var/spool/pgbackrest
sudo chown postgres:postgres /var/spool/pgbackrest
sudo chmod 600 /etc/pgbackrest/pgbackrest.conf     # file chứa key — siết quyền
```

> ⚠️ **`repo2-cipher-pass` là chìa khóa giải mã.** Mất passphrase = **không restore được** backup off-site. Lưu ở nơi an toàn TÁCH BIỆT (password manager / vault), tuyệt đối không chỉ để trên DB3.

### A.2 — Khởi tạo repo2 + backup thử

```bash
# Tạo stanza trên repo2 (repo1 đã có từ Phase 5):
sudo -u postgres pgbackrest --stanza=ax stanza-create
sudo -u postgres pgbackrest --stanza=ax check

# Backup ghi sang CẢ 2 repo:
sudo -u postgres pgbackrest --stanza=ax --type=full backup

# Hoặc chỉ định riêng 1 repo nếu cần:
sudo -u postgres pgbackrest --stanza=ax --repo=2 --type=full backup

# Xem trạng thái từng repo:
sudo -u postgres pgbackrest --stanza=ax info
```
> Không cần đổi cron Phase 5 — `backup` và `archive-push` tự xử lý cả repo1 + repo2.

---

## B. Off-site qua Server/NAS ở site khác (SSH)

Nếu có server ở chi nhánh/DC khác (vd `10.2.0.50`):
```ini
# repo2 trên host remote qua SSH
repo2-host=10.2.0.50
repo2-host-user=postgres
repo2-path=/backup/pgbackrest
repo2-retention-full=4
repo2-cipher-type=aes-256-cbc
repo2-cipher-pass=<PASSPHRASE_MANH>
```
- Cần SSH passwordless `postgres@DB3` → `postgres@10.2.0.50` + pgBackRest cài ở host đó.
- Ưu: dữ liệu nằm trên hạ tầng mình quản. Nhược: phụ thuộc đường truyền giữa 2 site.

---

## C. rclone — đồng bộ đơn giản (chủ yếu cho pg_dump)

Nếu chỉ muốn đẩy **pg_dump** đi off-site (nhẹ, đơn giản):
```bash
sudo apt install -y rclone
sudo -u postgres rclone config        # tạo remote "offsite" (S3/Drive/B2...)
```
Cron trên DB3 (sau khi dump xong):
```cron
30 3 * * *  rclone sync /backup/pgdump offsite:ax-pgdump --transfers 4 >> /backup/rclone.log 2>&1
```
> ⚠️ **Không** rclone thẳng thư mục `repo1 pgBackRest` đang chạy (dễ copy trạng thái dở dang). Với pgBackRest dùng **repo2 native** (cách A/B), đừng dùng rclone cho repo.

---

## Restore TỪ off-site (phải diễn tập)

Khi mất cả DB3/site, restore từ repo2 lên node mới:
```bash
# trên node đích (đã cài pgBackRest + cùng pgbackrest.conf chứa repo2 + cipher-pass):
sudo systemctl stop patroni
sudo -u postgres rm -rf /data/postgresql/17/main/*
sudo -u postgres pgbackrest --stanza=ax --repo=2 \
  --type=time --target="2026-06-27 10:00:00" --delta restore
sudo systemctl start patroni
```
> Test restore từ repo2 ÍT NHẤT 1 lần — để chắc chắn key/cipher-pass và mạng cloud hoạt động.

---

## Giám sát (thêm vào Phase 6)

- Alert **off-site backup quá hạn** riêng cho repo2:
  ```yaml
  - alert: OffsiteBackupStale
    expr: ax_pgbackrest_repo2_last_backup_age_seconds > 180000   # >50h
    for: 15m
    labels: { severity: critical }
    annotations: { summary: "Backup off-site (repo2) quá hạn" }
  ```
- Theo dõi `pgbackrest info` cho **cả 2 repo** (textfile collector đọc từng repo).

---

## Chi phí & băng thông (lưu ý thực tế)

- **Băng thông upload:** WAL + full/diff đẩy lên cloud tốn upload. `archive-async=y` giúp gom WAL, không chặn DB.
- **Chi phí cloud:** lưu trữ + **phí egress khi restore** (tải về). Backblaze B2/Wasabi rẻ hơn AWS S3 cho dung lượng lớn.
- **Nén + dedup** của pgBackRest giảm đáng kể dung lượng/băng thông.
- Cân nhắc chỉ đẩy **full+diff** lên off-site (bỏ WAL liên tục) nếu băng thông yếu → RPO off-site = lần backup gần nhất thay vì ~1 phút. (Đánh đổi.)

---

## Bảo mật

- [ ] `repo2-cipher-pass` lưu **tách biệt** khỏi DB3 (vault/password manager)
- [ ] Mã hóa bật (`aes-256-cbc`) — dữ liệu rời khỏi nhà phải mã hóa
- [ ] Access key cloud quyền **tối thiểu** (chỉ ghi/đọc đúng bucket)
- [ ] `pgbackrest.conf` chmod 600 (chứa key)
- [ ] (Nếu được) bật **bucket versioning / object-lock** chống xóa nhầm hoặc ransomware

---

## Checklist off-site

- [ ] Chọn đích (A cloud S3 / B remote SSH / C rclone)
- [ ] repo2 cấu hình + **mã hóa** bật; passphrase lưu an toàn tách biệt
- [ ] `stanza-create` + `check` OK trên repo2
- [ ] Full backup ghi sang repo2 thành công (`info` thấy cả 2 repo)
- [ ] WAL archive đẩy được lên repo2 (archive-async)
- [ ] **Đã diễn tập restore từ repo2 (off-site)**
- [ ] Alert OffsiteBackupStale (Phase 6)
- [ ] Đã ước tính chi phí lưu trữ + egress
