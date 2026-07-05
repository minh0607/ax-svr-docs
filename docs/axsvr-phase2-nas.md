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
NAS /srv/web-source  ──(robocopy/sync)──►  ax-web01 D:\app   (IIS chạy local)
                     ──(robocopy/sync)──►  ax-web02 D:\app   (IIS chạy local)
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

## 2.3 — Deploy: NAS → local 2 web (thủ công theo RELEASE — chưa có CI/CD)

> Chưa có CI/CD → deploy **theo từng đợt release**, **KHÔNG cron định kỳ**.
> Mỗi release đẩy **CẢ 2 web** từ **cùng 1 bản** trên NAS → 2 web luôn giống nhau.
> IIS vẫn chạy từ **đĩa local** (`D:\app`); NAS chỉ cần sống lúc deploy.

### Quy trình mỗi lần ra bản mới
```
1. Web engineer build React  →  ra thư mục build
2. Upload build lên NAS theo PHIÊN BẢN, vd:  /srv/web-source/2025-07-01
   rồi trỏ "current" sang bản mới  (để rollback dễ)
3. Trên ax-web01 VÀ ax-web02: chạy deploy.ps1  → kéo "current" về D:\app
4. Kiểm tra: health 2 web + truy cập qua VIP
```

NAS đổi "current" sang bản mới (rollback = trỏ lại bản cũ rồi deploy lại):
```bash
ln -sfn /srv/web-source/2025-07-01 /srv/web-source/current
```

### Lưu credential NAS 1 lần trên mỗi web (khỏi nhập lại)
```powershell
cmdkey /add:10.1.1.97 /user:webdeploy /pass
```

### deploy.ps1 — chạy trên TỪNG web (ax-web01, ax-web02) lúc release
```powershell
param(
  [string]$Src  = "\\10.1.1.97\web-source\current",
  [string]$Dst  = "D:\app",
  [string]$Pool = "AXPool"
)
Import-Module WebAdministration
robocopy $Src $Dst /MIR /R:2 /W:2 /NFL /NDL /NP
if ($LASTEXITCODE -ge 8) { Write-Error "robocopy lỗi ($LASTEXITCODE)"; exit 1 }
Restart-WebAppPool -Name $Pool          # nạp bản mới (nhẹ hơn iisreset)
Write-Host "Deploy xong trên $env:COMPUTERNAME"
```
> **Vì sao vẫn dùng robocopy?** Ở đây nó chạy **lúc release (thủ công)**, KHÔNG phải cron → không bị lệch/trễ. `/MIR` đảm bảo local khớp đúng NAS. robocopy exit code 0–7 = OK, ≥8 = lỗi.

### (Tùy chọn) đẩy CẢ 2 web bằng 1 lệnh — từ máy admin
```powershell
# máy admin đọc NAS, ghi thẳng vào D:\app của 2 web (qua admin share d$)
"\\10.1.1.101\d$\app","\\10.1.1.102\d$\app" | ForEach-Object {
  robocopy "\\10.1.1.97\web-source\current" $_ /MIR /R:2 /W:2 /NP
}
# rồi recycle pool từng web (qua RDP hoặc PowerShell Remoting)
```
> Cần mở SMB(445) từ máy admin tới 2 web + quyền admin. Tiện hơn nhưng thêm thiết lập — nếu ngại thì cứ chạy `deploy.ps1` trên từng web.

**IIS site:** physical path = `D:\app` (local), **KHÔNG** phải UNC.
**⚠️ KHÔNG** đặt cron robocopy định kỳ — chỉ chạy khi RELEASE.

---

## 2.4 — Lưu ý load balancing (2 web giống nhau)

Vì Nginx (Phase 4) phân tải round-robin/least_conn về 2 web, **2 web phải đồng nhất**:

1. **Source giống nhau:** luôn deploy cả ax-web01 **và** ax-web02 từ cùng bản trên NAS (đừng deploy lệch).
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
- [ ] Web map được share (cmdkey lưu cred), `deploy.ps1` chạy OK
- [ ] IIS physical path = **D:\app (local)**, không UNC
- [ ] Deploy **theo release** (đẩy cả 2 web cùng bản), **KHÔNG cron định kỳ**
- [ ] Có đánh **phiên bản** trên NAS + "current" để rollback
- [ ] Đã thống nhất xử lý session/upload với web engineer
- [ ] Backup source gốc
