# AX Svr — Phase 5: Backup PostgreSQL (pgBackRest) — Phương án B

> **Kho backup đặt trên `/backup` của DB3** (10.1.1.105). NAS chỉ phục vụ web, KHÔNG dính backup.
> DB3 vừa là node cụm, vừa là **repository host** (repo local trên `/backup`).
> PostgreSQL 17, data tại `/data/postgresql/17/main`.

```
        WAL archive (SSH)                    backup pull (SSH)
DB1 .103 ──────────────►                   ◄──────────────
DB2 .104 ──────────────►   DB3 .105  (repo local /backup/pgbackrest)
DB3 .105 ──(local)─────►   + pg_dump logic /backup/pgdump
```

## ⚠️ CẢNH BÁO RỦI RO (phương án B)

Backup nằm **trên chính DB3 — một node của cụm**. Nghĩa là:
- ✅ Cứu được: lỡ tay DROP/DELETE, lỗi logic, restore nhanh, PITR.
- ❌ **KHÔNG cứu được:** DB3 (VM/host/đĩa) hỏng → **mất luôn toàn bộ backup**. Thảm họa cả site → mất hết.

→ Đây là rủi ro đã chấp nhận khi chọn B. **Khuyến nghị mạnh:** sớm bổ sung **1 bản off-site** (cloud/NAS khác) để đạt 3-2-1. `/backup` nên là **đĩa vật lý/độ bền khác** với đĩa `/data` của DB3 (đừng cùng 1 ổ — hỏng ổ là mất cả hai).

---

## 5.0 — Chuẩn bị

**Cài pgBackRest cùng version trên cả 3 DB node** (đã cài ở Phase 0/1):
```bash
pgbackrest version    # 3 node phải cùng version
```

**Trên DB3 — phân vùng /backup + thư mục repo (owner = postgres):**
```bash
# (giả định /backup đã mount là phân vùng riêng, KHÁC ổ với /data)
sudo mkdir -p /backup/pgbackrest /backup/pgdump /backup/scripts /var/log/pgbackrest
sudo chown -R postgres:postgres /backup /var/log/pgbackrest
sudo chmod 750 /backup/pgbackrest
```

---

## 5.1 — SSH passwordless giữa các node (user `postgres`)

Dùng thẳng user `postgres` cho gọn (repo + pg cùng 1 user). Cần:
- `postgres@DB1` ↔ `postgres@DB3`
- `postgres@DB2` ↔ `postgres@DB3`

**Trên mỗi DB node** (nếu chưa có key):
```bash
sudo -u postgres ssh-keygen -t ed25519 -N "" -f ~postgres/.ssh/id_ed25519
sudo -u postgres cat ~postgres/.ssh/id_ed25519.pub
```

**Gắn key 2 chiều giữa DB1↔DB3 và DB2↔DB3:**
```bash
# Trên DB3: thêm pubkey postgres@DB1 và postgres@DB2:
sudo -u postgres tee -a ~postgres/.ssh/authorized_keys <<'EOF'
<pubkey postgres@db1>
<pubkey postgres@db2>
EOF
# Trên DB1 và DB2: thêm pubkey postgres@DB3:
sudo -u postgres tee -a ~postgres/.ssh/authorized_keys <<'EOF'
<pubkey postgres@db3>
EOF
sudo -u postgres chmod 600 ~postgres/.ssh/authorized_keys
```

**Test (không hỏi mật khẩu):**
```bash
sudo -u postgres ssh postgres@10.1.1.105 hostname    # từ DB1/DB2
sudo -u postgres ssh postgres@10.1.1.103 hostname    # từ DB3
```

**Firewall:** SSH (22) đã mở trong LAN ở Phase 0.

---

## 5.2 — Cấu hình pgBackRest

**Trên DB3** (repo host) `/etc/pgbackrest/pgbackrest.conf`:
```ini
[global]
repo1-path=/backup/pgbackrest
repo1-retention-full=2
repo1-retention-diff=6
repo1-bundle=y
repo1-block=y
process-max=4
start-fast=y
compress-type=zst
compress-level=3
log-level-console=info
log-level-file=detail
backup-standby=y          # ưu tiên copy từ standby, giảm tải primary

[ax]
pg1-host=10.1.1.103
pg1-host-user=postgres
pg1-path=/data/postgresql/17/main
pg2-host=10.1.1.104
pg2-host-user=postgres
pg2-path=/data/postgresql/17/main
pg3-path=/data/postgresql/17/main        # DB3 local — không cần host
```

**Trên DB1 và DB2** (repo nằm remote ở DB3) `/etc/pgbackrest/pgbackrest.conf`:
```ini
[global]
repo1-host=10.1.1.105
repo1-host-user=postgres
process-max=4
compress-type=zst
log-level-console=info
log-level-file=detail

[ax]
pg1-path=/data/postgresql/17/main
```

---

## 5.3 — Bật archive_command qua Patroni (cluster-wide)

```bash
patronictl -c /etc/patroni/patroni.yml edit-config
```
Thêm vào `postgresql.parameters`:
```yaml
postgresql:
  parameters:
    archive_mode: "on"
    archive_command: 'pgbackrest --stanza=ax archive-push %p'
    archive_timeout: 60
```
> Mỗi node đọc config local của nó: DB1/DB2 đẩy WAL về DB3 qua SSH; DB3 ghi WAL vào repo local.
> `archive_mode: on` cần restart — lăn từng node:
```bash
patronictl -c /etc/patroni/patroni.yml restart ax-pg-cluster --pending
```

---

## 5.4 — Tạo stanza + backup đầu tiên (chạy trên DB3)

```bash
sudo -u postgres pgbackrest --stanza=ax stanza-create
sudo -u postgres pgbackrest --stanza=ax check          # xác nhận archive + repo OK
sudo -u postgres pgbackrest --stanza=ax --type=full backup
sudo -u postgres pgbackrest --stanza=ax info
```

---

## 5.5 — Lịch backup tự động (cron trên DB3)

`sudo crontab -u postgres -e`:
```cron
# Full: Chủ nhật 01:00
0 1 * * 0  pgbackrest --stanza=ax --type=full backup
# Diff: T2-T7 01:00  (đây là "backup mỗi ngày" trên /backup)
0 1 * * 1-6 pgbackrest --stanza=ax --type=diff backup
```
> WAL archive liên tục (không qua cron) → PITR tới từng giây.

---

## 5.6 — pg_dump logic hằng ngày (lớp cứu lỗi logic, ra /backup/pgdump)

`/backup/scripts/daily-dump.sh`:
```bash
#!/bin/bash
set -euo pipefail
DEST=/backup/pgdump
DATE=$(date +%F)
mkdir -p "$DEST"
# chạy trên DB3 (thường là replica) — kết nối qua DB local
pg_dumpall -h 127.0.0.1 -U postgres --globals-only | gzip > "$DEST/globals-$DATE.sql.gz"
for db in $(psql -h 127.0.0.1 -U postgres -tAc \
   "SELECT datname FROM pg_database WHERE datistemplate=false AND datname<>'postgres'"); do
   pg_dump -h 127.0.0.1 -U postgres -Fc "$db" > "$DEST/$db-$DATE.dump"
done
find "$DEST" -type f -mtime +7 -delete     # giữ 7 ngày
```
```bash
sudo chown postgres:postgres /backup/scripts/daily-dump.sh
sudo chmod 750 /backup/scripts/daily-dump.sh
```
`crontab -u postgres`:
```cron
0 2 * * *  /backup/scripts/daily-dump.sh >> /backup/dump.log 2>&1
```
> `-Fc` cho phép `pg_restore` chọn lọc từng bảng. Lưu ý: pg_dump đọc từ DB3 (replica) — không tải lên primary.

---

## 5.7 — Dung lượng /backup cần cấp (DB < 100GB)

Vì `/backup` chứa **cả pgBackRest repo lẫn pg_dump**:

| Thành phần | Ước tính |
|---|---|
| pgBackRest: 2 full (nén ~0.35×) | ~70 GB |
| diff 1 tuần + WAL archive | ~50 GB |
| pg_dump: 7 bản (~30GB/bản) | ~210 GB |
| **Tổng + đệm** | → **cấp ~400 GB** |

> Muốn tiết kiệm: giảm pg_dump xuống giữ 3–4 ngày, hoặc `repo1-retention-full=1`. Theo dõi alert `DiskAlmostFull` (Phase 6).

---

## 5.8 — RESTORE (diễn tập bắt buộc — backup chưa test = chưa có backup)

### A) PITR physical (pgBackRest)
```bash
# Trên node cần restore:
sudo systemctl stop patroni
sudo -u postgres rm -rf /data/postgresql/17/main/*
sudo -u postgres pgbackrest --stanza=ax \
  --type=time --target="2026-06-27 10:00:00" --delta restore
sudo systemctl start patroni
patronictl -c /etc/patroni/patroni.yml list
```

### B) Restore logic 1 bảng/1 DB (từ pg_dump)
```bash
# khôi phục chọn lọc từ file .dump:
pg_restore -h <primary> -U postgres -d <db> -t <ten_bang> /backup/pgdump/<db>-<date>.dump
```

---

## 5.9 — Verify định kỳ (trên DB3)

```bash
sudo -u postgres pgbackrest --stanza=ax verify
sudo -u postgres pgbackrest --stanza=ax info
```

---

## Checklist Phase 5 (B)

- [ ] `/backup` là phân vùng riêng trên DB3, **khác ổ vật lý với /data**
- [ ] SSH 2 chiều postgres giữa DB1↔DB3, DB2↔DB3 OK
- [ ] `stanza-create` + `check` pass
- [ ] Full backup đầu tiên thành công; `info` thấy backup
- [ ] archive_command bật qua Patroni; WAL từ DB1/DB2 về được DB3
- [ ] Cron full + diff + pg_dump trên DB3
- [ ] **Đã diễn tập PITR restore + restore 1 bảng từ dump**
- [ ] **KẾ HOẠCH off-site** (vì backup hiện chỉ nằm trên DB3 — single point)
- [ ] Alert dung lượng /backup (Phase 6)
