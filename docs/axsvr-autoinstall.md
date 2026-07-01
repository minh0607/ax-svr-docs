# AX Svr — Autoinstall Ubuntu 24.04 (không cần bấm tay)

> Tự động cài OS cho 6+ VM Linux: **OS + mạng 2 NIC + LVM + đĩa `/data` (+ `/backup` cho DB3) + admin + SSH key**.
> Phần mềm theo vai trò (PG17, nginx, patroni...) cài **sau** theo Phase docs — vì PGDG/repo chưa có lúc cài OS.

File: [`autoinstall/gen-autoinstall.sh`](autoinstall/gen-autoinstall.sh)

---

## Cơ chế

Ubuntu 24.04 dùng **autoinstall** (subiquity + cloud-init). Mình cấp 2 file:
- `user-data` — toàn bộ cấu hình cài đặt (autoinstall)
- `meta-data` — instance-id / hostname

Đóng 2 file thành **NoCloud seed ISO**, gắn kèm ISO cài Ubuntu → installer tự đọc và cài **không hỏi gì**.

Generator sinh sẵn seed ISO cho từng host từ **bảng IP** (đã điền đúng AX Svr).

---

## Bước 1 — Chuẩn bị máy chạy generator (Ubuntu/WSL/Linux bất kỳ)

```bash
sudo apt install -y cloud-image-utils         # có lệnh cloud-localds
# cần 1 SSH key để đăng nhập sau khi cài (mặc định ~/.ssh/id_ed25519.pub)
ls ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519
```

## Bước 2 — Kiểm tra tham số trong script

Mở `gen-autoinstall.sh`, sửa phần **THAM SỐ CHUNG** cho khớp:
```bash
WAN_IF="ens3"        # tên NIC WAN — KIỂM TRA THỰC TẾ: ip -br link
LAN_IF="ens4"        # tên NIC LAN
WAN_GW="107.118.210.1" # gateway WAN
DNS="107.118.210.1 1.1.1.1"
```
> ⚠️ **Quan trọng nhất: tên NIC** (`ens3/ens4`). Tùy nền ảo hóa có thể là `enp1s0`, `eth0`... Sai tên là mạng không lên. Kiểm tra trên 1 VM mẫu trước.

Bảng host đã điền sẵn theo AX Svr (proxy/nas/db/mon/devdb) — sửa nếu cần.

## Bước 3 — Sinh seed ISO

```bash
cd docs/autoinstall
./gen-autoinstall.sh
# nhập mật khẩu admin (sẽ được hash sha-512)
```
Kết quả trong `out/`:
```
out/pg-db1-seed.iso
out/pg-db2-seed.iso
out/pg-db3-seed.iso     (có cả /data + /backup)
out/AX-Proxy01-seed.iso ...
```

## Bước 4 — Gắn ISO & boot từng VM

Mỗi VM gắn **2 ổ CD/ISO**:
1. ISO cài **Ubuntu Server 24.04** (`ubuntu-24.04-live-server-amd64.iso`)
2. **seed ISO** tương ứng host (vd `pg-db3-seed.iso`)

Cấu hình đĩa ảo của VM:
| Vai trò | Đĩa cần gắn |
|---|---|
| AX-Proxy01/02 | sda (OS) |
| nas, db1, db2, mon, devdb | sda (OS) + **sdb** (→ `/data`) |
| **db3** | sda (OS) + **sdb** (`/data`) + **sdc** (`/backup`) |

> Generator dùng **LABEL** (`axdata`/`axbackup`), không phụ thuộc thứ tự tên đĩa — nhưng cứ gắn theo sda/sdb/sdc cho chắc.

Boot VM → installer tự chạy, cài xong **tự reboot**. Không bấm gì.

## Bước 5 — Sau khi cài xong

```bash
# đăng nhập bằng SSH key:
ssh axadmin@107.118.210.103
# kiểm tra:
ip -br a                 # đúng 2 IP
df -h | grep -E "/data|/backup"   # phân vùng đã mount
timedatectl              # NTP synchronized
```
Rồi tiếp tục cài phần mềm theo vai trò: **Phase 0 (0.4 hardening + 0.5 packages) → Phase tương ứng**.

---

## Những gì autoinstall ĐÃ làm sẵn (khỏi làm lại ở Phase 0)

- ✅ OS + LVM trên `/dev/sda`
- ✅ Mạng 2 NIC tĩnh (WAN có gateway+DNS, LAN không)
- ✅ Phân vùng `/data` (và `/backup` cho DB3) tự mount qua fstab
- ✅ User `axadmin` + SSH key, **tắt đăng nhập mật khẩu** (allow-pw: false)
- ✅ `/etc/hosts` cluster, `qemu-guest-agent`, `chrony` (NTP), `ufw` cài sẵn
- ✅ root bị khóa

## Còn phải làm thủ công sau (Phase 0+)

- Cấu hình `ufw` rules theo vai trò, SSH hardening bổ sung
- Thêm PGDG + cài PG17/patroni/etcd (DB), nginx/keepalived (proxy), samba (NAS)...
- Đặt hostname đặc thù nếu khác (script đã đặt theo bảng)

---

## Lưu ý & khắc phục

| Vấn đề | Xử lý |
|---|---|
| Mạng không lên sau cài | Sai `WAN_IF/LAN_IF` — sửa tên NIC, sinh lại |
| `/data` không mount | VM chưa gắn đĩa sdb, hoặc sdb không trống |
| Muốn cài thủ công 1 máy | Bỏ seed ISO, chạy installer bình thường |
| Đổi mật khẩu/người dùng | Sửa `ADMIN_USER`/`PWHASH` rồi sinh lại |
| Test trước khi cài thật | Validate cú pháp: `cloud-init schema --config-file out/<host>/user-data` |

> **An toàn:** `user-data` chứa SSH pubkey + password hash (không phải mật khẩu thô) → tương đối an toàn, nhưng vẫn nên giữ thư mục `out/` cẩn thận, không commit lên repo công khai.
