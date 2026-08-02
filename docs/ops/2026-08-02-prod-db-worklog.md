# AX Svr — Production DB worklog — 2026-08-02

> Cụm: `ax-db-cluster` (PostgreSQL 17, Patroni + etcd 3 node) — ax-db01/02/03 (10.1.1.103/104/105).
> Người thực hiện: SEHC infra. Loại: thao tác trực tiếp trên production (đã hoàn tất, không mất dữ liệu).

## Tóm tắt
Phát hiện `/data` của cả cụm đang nằm trên phân vùng **root** vì đĩa dữ liệu riêng chưa bao giờ được mount. Đã **di chuyển `/data` sang đĩa 100G riêng (`/dev/sdb`) trên cả 3 node**, node-by-node theo Patroni, và **đưa leader về ax-db01**. Đồng thời bổ sung công cụ chẩn đoán vào toolkit `db-scripts`.

---

## Job 1 — Di chuyển /data sang đĩa riêng (chính)

### Vấn đề phát hiện
- `data_directory = /data/postgresql/17/main` nằm trên `sda2` (`/`, root) → dữ liệu ghi vào ổ hệ điều hành.
- Đĩa 100G `/dev/sdb` **trống, chưa mount** (quên mount lúc cài). Kiểm bằng `wipefs`/`blkid`/`sfdisk` → đĩa trắng, an toàn dùng.
- Lỗi này có trên **cả 3 node**.

### Cách làm
Theo runbook `docs/db-scripts/runbook-mount-data-disk.md`: mỗi node lần lượt `stop patroni → parted (mklabel + mkpart) → partprobe → mkfs.ext4 → mv /data /data.old → mount /dev/sdb1 tại /data → tạo data_dir rỗng + chown postgres:postgres + chmod 700 → thêm fstab (UUID) → start patroni (Patroni tự clone lại từ leader) → verify Lag 0 → rm /data.old`.

### Thứ tự thực tế & kết quả
| Node | Vai trò lúc làm | Kết quả |
|---|---|---|
| ax-db03 | Replica (async) | ✅ /data trên `/dev/sdb1` (98G), rejoin Replica, Lag 0. Ghi nhận: `/backup` đã có trên `/dev/sdc1`. |
| ax-db01 | Leader → (stop → failover) | ✅ Khi stop patroni, Patroni tự failover leader sang db03 (TL2, zero-loss). db01 migrate xong, rejoin làm Replica. |
| ax-db02 | Sync Standby | ✅ Migrate xong, /data trên đĩa riêng. |

Sau cùng cả 3 node: `data_directory` nằm trên mount riêng `/data` (`/dev/sdb1`), `./axdb.sh check-storage` = **storage OK** trên cả ba.

### Sự cố nhỏ gặp phải (đã xử lý) — bài học
1. **Quên bước phân quyền** (`chown postgres:postgres` + `chmod 700` data_dir) → Patroni **không start/bootstrap được**, node không xuất hiện trong `patronictl list`, `reinit` báo `No REPLICA among provided members`. Fix: chạy chown/chmod rồi `systemctl restart patroni`.
2. **Quên lệnh `parted mkpart`** (chỉ chạy `mklabel`) → không có `/dev/sdb1` → `mkfs` báo `does not exist`. `partprobe` không cứu vì partition chưa tạo. Fix: chạy `parted ... mkpart` rồi `partprobe` + `mkfs`.
3. **Stop nhầm leader (db01)** → Patroni tự failover graceful (zero-loss), node rejoin làm replica. Không sao — thứ tự node linh hoạt, miễn một-node-một-lúc + luôn còn leader + 1 standby.

> Cả 3 bài học đã được ghi vào runbook để không lặp lại.

---

## Job 2 — Đưa leader về ax-db01

- `switchover` thẳng về db01 **bị từ chối** vì `synchronous_mode: true` → chỉ node đang là **Sync Standby** mới là candidate; db01 là replica async.
- Dùng **Cách A (an toàn nhất, giữ nguyên synchronous_mode)**: switchover vòng qua Sync Standby rồi về db01 khi db01 trở thành sync. Không tắt sync → **zero-loss suốt quá trình**.
- **Kết quả:** ax-db01 = **Leader**. (Sync Standby / Replica giữa db02–db03 do Patroni quản — xác nhận bằng `patronictl list`.)

### Ghi chú kỹ thuật (đã bàn, chưa áp dụng)
- Muốn hoán đổi vai **Sync Standby ↔ Replica** giữa db02/db03: không gán trực tiếp được, phải `restart` node sync hiện tại để Patroni trao vai cho node kia. **Có blip vài giây write-stall** (primary chờ Patroni trỏ lại `synchronous_standby_names`, tối đa ~`loop_wait`). Đây là thay đổi cosmetic → chỉ làm khi có lý do + vào khung giờ tải thấp. Reads không ảnh hưởng, không mất data.

---

## Job 3 — Bổ sung toolkit db-scripts (đã merge + push)
- `axdb.sh health [db]` — sức khỏe cụm 1 lệnh (services/etcd/patroni/replication/disk/backup, tự dò data_dir + pgBackRest).
- `axdb.sh check-storage [db]` — phát hiện data_dir nằm nhầm trên root / đĩa quên mount (chính công cụ dùng cho Job 1).
- `grant-schema` / `revoke-schema` / `schema-perm` — quản lý quyền cấp-schema (USAGE/CREATE).
- Runbook `runbook-mount-data-disk.md` (per-node, có rollback + các bài học).
- Suite test: 15 file (Docker PostgreSQL 17), tất cả xanh.

---

## Trạng thái cuối
- Cả 3 node: `/data` trên đĩa riêng `/dev/sdb1`, `/backup` trên `/dev/sdc1` (db03), fstab đầy đủ (tự mount khi reboot).
- Leader = **ax-db01**; cụm 3 node streaming, Lag 0; `synchronous_mode` vẫn bật.
- Root (`sda2`) đã giải phóng (đã `rm -rf /data.old` sau khi mỗi node xác nhận healthy).

## Việc còn tồn đọng / cần theo dõi
- [ ] **Xác minh backup thật sự đang chạy:** `/backup` đã mount nhưng cần chạy `sudo -u postgres pgbackrest info` trên db03 để chắc có bản full/diff gần đây + WAL archiving OK (`SELECT last_archived_time, failed_count FROM pg_stat_archiver;`). Trước đó chưa xác nhận repo pgBackRest hoạt động.
- [ ] (tuỳ chọn) Off-site backup repo2 để hoàn tất 3-2-1.
- [ ] (tuỳ chọn) Hoán đổi vai sync db02↔db03 nếu có yêu cầu — làm lúc tải thấp.

## Tham chiếu
- Runbook di chuyển đĩa: `docs/db-scripts/runbook-mount-data-disk.md`
- Toolkit: `docs/db-scripts/` (README + `axdb.sh health` / `check-storage`)
- Kiểm tra nhanh mọi node: `sudo bash axdb.sh check-storage` và `sudo patronictl -c /etc/patroni/patroni.yml list`
