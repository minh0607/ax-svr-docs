# AX Svr — Phase 2: NAS chia sẻ source web

> NAS (Ubuntu, LAN 10.1.1.97) là **kho source/artifact gốc** dùng chung cho 2 IIS web.
> Web Windows truy cập qua **Samba (SMB)** trên LAN.

## NAS CHỈ phục vụ web (1 vai duy nhất)

| Vai trò | Thư mục | User/quyền |
|---|---|---|
| Kho source web (SMB) | `/srv/web-source` | user `webdeploy` |

> NAS **KHÔNG** làm repo backup DB. Backup DB đặt trên `/backup` của DB3 (xem Phase 5, phương án B).

---

## ⚠️ Quyết định kiến trúc: KHÔNG cho IIS chạy trực tiếp từ NAS

Có 2 mô hình. Em khuyến nghị **Mô hình A**.

### Mô hình A — Deploy-to-local (KHUYẾN NGHỊ) ⭐
NAS chỉ giữ **source gốc**; mỗi web **đồng bộ về đĩa local** (`D:\app`) và IIS chạy từ local.
```
NAS /srv/web-source  ──(robocopy/sync)──►  Web1 D:\app   (IIS chạy local)
                     ──(robocopy/sync)──►  Web2 D:\app   (IIS chạy local)
```
- ✅ NAS chết → web **vẫn chạy** (đang chạy bản local).
- ✅ Nhanh (đọc đĩa local, không qua SMB mỗi request).
- ✅ Tránh lỗi file-lock/permission của IIS qua UNC.
- ❌ Cần bước deploy/sync (1 lệnh robocopy hoặc CI/CD).

### Mô hình B — IIS trỏ thẳng UNC (KHÔNG khuyến nghị)
IIS physical path = `\\10.1.1.97\web-source`. Cập nhật 1 chỗ là cả 2 web thấy.
- ❌ **NAS = SPOF**: NAS chết → cả 2 web chết.
- ❌ Chậm hơn (mỗi request đọc qua SMB).
- ❌ Phức tạp quyền (App Pool identity phải có quyền trên share).

→ Dùng A. Phần dưới cấu hình NAS để phục vụ cả hai, nhưng quy trình chuẩn là A.

---

## 2.1 — Tạo user & thư mục source (trên NAS)

```bash
sudo mkdir -p /srv/web-source
sudo groupadd webdeploy
sudo useradd -M -s /usr/sbin/nologin -g webdeploy webdeploy
sudo chown -R webdeploy:webdeploy /srv/web-source
sudo chmod -R 2775 /srv/web-source       # setgid giữ group cho file mới

# Mật khẩu Samba cho user webdeploy (khác mật khẩu hệ thống):
sudo smbpasswd -a webdeploy
```

---

## 2.2 — Cấu hình Samba (chỉ phục vụ LAN)

Thêm vào cuối `/etc/samba/smb.conf`:
```ini
[global]
   # chỉ nghe trên NIC LAN, không expose WAN
   interfaces = 10.1.1.97/24
   bind interfaces only = yes
   server min protocol = SMB3
   # chỉ cho 2 web + dải LAN truy cập
   hosts allow = 10.1.1.101 10.1.1.102 127.0.0.1
   hosts deny = 0.0.0.0/0

[web-source]
   path = /srv/web-source
   browseable = yes
   read only = no
   valid users = webdeploy
   create mask = 0664
   directory mask = 2775
   force group = webdeploy
```

Kiểm tra + khởi động:
```bash
sudo testparm                       # kiểm tra cú pháp
sudo systemctl enable --now smbd nmbd
```

**Firewall — chỉ mở Samba cho LAN:**
```bash
sudo ufw allow from 10.1.1.0/24 to any port 445 proto tcp
sudo ufw allow from 10.1.1.0/24 to any port 139 proto tcp
```

---

## 2.3 — Web (Windows) kết nối & deploy (Mô hình A)

**Kiểm tra truy cập share từ Web (PowerShell):**
```powershell
# mở share bằng credential webdeploy
net use \\10.1.1.97\web-source /user:webdeploy *
dir \\10.1.1.97\web-source
```

**Script deploy: đồng bộ NAS → local D:\app** (chạy trên mỗi web, hoặc do web engineer/CI gọi):
```powershell
# deploy.ps1  — copy bản mới nhất từ NAS về local, IIS chạy từ local
$src  = "\\10.1.1.97\web-source\current"
$dst  = "D:\app"
robocopy $src $dst /MIR /R:2 /W:2 /NFL /NDL
iisreset /noforce        # hoặc recycle app pool nếu cần
```
> `/MIR` mirror chính xác (xóa file thừa ở đích). Cẩn thận thư mục đích đúng.

**IIS site:** physical path = `D:\app` (local), KHÔNG phải UNC.

**Quy trình cập nhật web:**
```
web engineer build React  →  đẩy vào NAS /srv/web-source/current
                          →  chạy deploy.ps1 trên Web1 và Web2
                          →  IIS phục vụ bản mới từ local
```

---

## 2.4 — Lưu ý load balancing (2 web giống nhau)

Vì Nginx (Phase 4) phân tải round-robin/least_conn về 2 web, **2 web phải đồng nhất**:

1. **Source giống nhau:** luôn deploy cả Web1 **và** Web2 từ cùng bản trên NAS (đừng deploy lệch).
2. **Session/state:** nếu app có session, hoặc dùng **sticky session** (Nginx `ip_hash`/cookie), hoặc **shared session store** (Redis/DB). → bàn với web engineer. React tĩnh thì thường stateless, nhưng backend API cần lưu ý.
3. **Upload/file người dùng:** nếu app cho upload, **không lưu vào local từng web** (lệch nhau) → lưu chung trên NAS share riêng hoặc object storage.

---

## 2.5 — Backup chính NAS source

Source gốc cũng cần backup (NAS hỏng là mất source chưa commit):
```bash
# ví dụ: snapshot source định kỳ sang nơi khác (cron trên NAS)
0 2 * * * tar czf /srv/backup/web-source-$(date +\%F).tgz -C /srv web-source
```
> Tốt hơn: source nên nằm trong **git repo** (NAS chỉ là artifact build) → có lịch sử + khôi phục dễ.

---

## Checklist Phase 2

- [ ] `/srv/web-source` + user `webdeploy` (tách khỏi `pgbackrest`)
- [ ] Samba chỉ nghe LAN, `hosts allow` đúng 2 web
- [ ] Firewall mở 445/139 chỉ cho LAN
- [ ] Web map được share, `deploy.ps1` chạy OK
- [ ] IIS physical path = **D:\app (local)**, không UNC
- [ ] Quy trình deploy đồng bộ cả 2 web
- [ ] Đã thống nhất xử lý session/upload với web engineer
- [ ] Backup source gốc
