# AX Svr — Phase 0: Cài đặt nền (OS + phần mềm)

> Phase nền tảng: cài OS, cấu hình mạng 2 NIC, hardening cơ bản, và cài phần mềm theo vai trò.
> Làm xong Phase 0 mới sang Phase 1 (DB), 2 (NAS), 4 (Proxy), 5 (Backup).

---

## 0.1 — Bảng tổng hợp máy / OS / phần mềm

| Server | OS | WAN 107.118.210.x | LAN 10.1.1.x | Phần mềm chính |
|---|---|---|---|---|
| Proxy 1 | Ubuntu 24.04 | .98 | .98 | nginx, keepalived |
| Proxy 2 | Ubuntu 24.04 | .99 | .99 | nginx, keepalived |
| Web 1 | Win Server 2025 | .101 | .101 | IIS (+ .NET hosting bundle) |
| Web 2 | Win Server 2025 | .102 | .102 | IIS (+ .NET hosting bundle) |
| NAS | Ubuntu 24.04 | .97 (mgmt) | .97 (data) | samba (CHỈ phục vụ web) |
| DB 1 | Ubuntu 24.04 | .103 | .103 | postgresql-17 (PGDG), patroni, etcd, pgbackrest |
| DB 2 | Ubuntu 24.04 | .104 | .104 | nt |
| DB 3 | Ubuntu 24.04 | .105 | .105 | nt |
| DevDB | Ubuntu 24.04 | .90 | — | postgresql-17 (PGDG) |

> **Quy ước data:** mọi DB (dev + prod) để data + log trong **`/data/postgresql`** (`/data` nên là đĩa riêng). Chi tiết Phase 1 (prod) và file DevDB.

---

## 0.2 — Cài Ubuntu Server 24.04 (cho 6 máy Linux)

Dùng **Ubuntu Server 24.04 LTS** (không cài Desktop GUI cho server production).

**Các lựa chọn khi chạy installer:**
1. Language: English (khuyến nghị để log đồng nhất).
2. Keyboard: tùy.
3. Network: có thể để DHCP tạm, **cấu hình IP tĩnh sau** ở mục 0.3 (dễ kiểm soát hơn khi có 2 NIC).
4. Storage:
   - Dùng **LVM** (dễ mở rộng disk sau này — quan trọng với DB/NAS).
   - DB/NAS: cân nhắc tách `/var/lib/postgresql` (DB) hoặc `/srv` & `/var/lib/pgbackrest` (NAS) sang volume/disk riêng.
5. Profile: tạo user admin (vd `axadmin`).
6. **Bật "Install OpenSSH server"** (cần SSH ngay).
7. **Không** cài snap thừa (bỏ qua featured server snaps).

Sau khi cài xong, đăng nhập và cập nhật:
```bash
sudo apt update && sudo apt -y full-upgrade
sudo reboot
```

---

## 0.3 — Cấu hình mạng 2 NIC tĩnh (netplan)

> Quy tắc: **chỉ NIC WAN có default gateway + DNS**; NIC LAN **không** gateway (chỉ nội bộ).

Xác định tên NIC:
```bash
ip -br link        # vd: ens3 (WAN), ens4 (LAN) — thay cho đúng máy anh
```

Tạo `/etc/netplan/01-ax.yaml` (ví dụ **DB1**, đổi IP cho từng máy theo bảng 0.1):
```yaml
network:
  version: 2
  ethernets:
    ens3:                          # NIC WAN
      addresses: [107.118.210.103/24]
      routes:
        - to: default
          via: 107.118.210.1         # đổi đúng gateway WAN
      nameservers:
        addresses: [107.118.210.1, 1.1.1.1]
    ens4:                          # NIC LAN
      addresses: [10.1.1.103/24]
      # KHÔNG gateway, KHÔNG nameservers
```
Áp dụng + kiểm tra:
```bash
sudo chmod 600 /etc/netplan/01-ax.yaml
sudo netplan apply
ip -br a                       # đúng IP trên 2 NIC
ip route | grep default       # default đi qua WAN
ping -c2 10.1.1.104           # thông LAN tới node khác
ping -c2 8.8.8.8              # thông internet qua WAN
```

> **DevDB (.90)** chỉ 1 NIC WAN: bỏ phần `ens4`.

---

## 0.4 — Hardening & chuẩn bị chung (mọi máy Linux)

**Hostname + hosts** (đặt tên dễ nhận biết):
```bash
sudo hostnamectl set-hostname pg-db1     # vd; proxy1, nas, ...
sudo tee -a /etc/hosts >/dev/null <<'EOF'
107.118.210.98  proxy1
107.118.210.99  proxy2
10.1.1.97     nas
10.1.1.103    pg-db1
10.1.1.104    pg-db2
10.1.1.105    pg-db3
EOF
```

**Đồng bộ giờ (bắt buộc cho etcd/Patroni/log):**
```bash
sudo timedatectl set-ntp true
timedatectl status | grep synchronized      # yes
```

**Tự động vá bảo mật:**
```bash
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
```

**SSH hardening** (`/etc/ssh/sshd_config.d/99-ax.conf`):
```ini
PermitRootLogin no
PasswordAuthentication no        # chỉ dùng SSH key (sau khi đã cài key)
X11Forwarding no
```
```bash
sudo systemctl restart ssh
```

**Firewall nền (ufw)** — bật và mặc định chặn vào:
```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 107.118.210.0/24 to any port 22 proto tcp   # SSH quản trị (mạng airgap nội bộ)
sudo ufw enable
```
> Port theo vai trò (5432, 8008, 80/443, samba...) mở ở Phase tương ứng.

---

## 0.5 — Cài phần mềm theo vai trò

> Cấu hình chi tiết ở các Phase tương ứng — đây là nơi cài gói.

**Proxy 1 & 2:**
```bash
sudo apt install -y nginx keepalived        # cấu hình: Phase 4
```

**DB 1, 2, 3:** (PostgreSQL 17 qua PGDG — chi tiết Phase 1)
```bash
# thêm PGDG repo
sudo apt install -y curl ca-certificates gnupg lsb-release
sudo install -d /usr/share/postgresql-common/pgdg
sudo curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail \
  https://www.postgresql.org/media/keys/ACCC4CF8.asc
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
  | sudo tee /etc/apt/sources.list.d/pgdg.list
sudo apt update
sudo apt install -y postgresql-17 postgresql-client-17 \
                    patroni python3-etcd3 etcd-server etcd-client \
                    pgbackrest                  # cấu hình: Phase 1 + 5
sudo systemctl disable --now postgresql        # Patroni sẽ tự quản
sudo pg_dropcluster --stop 17 main
# data sẽ nằm trong /data/postgresql (Patroni initdb) — xem Phase 1
```

**NAS:** (chỉ chia sẻ source web — KHÔNG làm repo backup)
```bash
sudo apt install -y samba                       # cấu hình: Phase 2
```

**DB3 (bổ sung):** phân vùng `/backup` riêng (khác ổ với `/data`) để chứa backup — xem Phase 5.

**DevDB:** (PostgreSQL 17 standalone, data trong /data — xem file DevDB)
```bash
# thêm PGDG repo (như khối DB ở trên), rồi:
sudo apt install -y postgresql-17 postgresql-client-17 postgresql-contrib
# Dev: standalone (không Patroni), data dời vào /data/postgresql/17/main
```

---

## 0.6 — Windows Server 2025 (Web 1 & 2)

> App/React do web engineer deploy. Phần anh: dựng OS + IIS + mạng.

1. **Cài Windows Server 2025** (Desktop Experience).
2. **Mạng 2 NIC** (PowerShell, đổi tên NIC cho đúng):
   ```powershell
   # WAN
   New-NetIPAddress -InterfaceAlias "Ethernet0" -IPAddress 107.118.210.101 `
     -PrefixLength 24 -DefaultGateway 107.118.210.1
   Set-DnsClientServerAddress -InterfaceAlias "Ethernet0" -ServerAddresses 107.118.210.1
   # LAN (KHÔNG gateway)
   New-NetIPAddress -InterfaceAlias "Ethernet1" -IPAddress 10.1.1.101 -PrefixLength 24
   ```
3. **Cài IIS + .NET hosting bundle:**
   ```powershell
   Install-WindowsFeature -Name Web-Server -IncludeManagementTools
   # Sau đó cài .NET Hosting Bundle nếu backend là ASP.NET Core
   ```
4. **Firewall:** chỉ cho 2 Proxy (10.1.1.98/.99) gọi port 80 qua LAN; KHÔNG mở 80/443 ra WAN.
   ```powershell
   New-NetFirewallRule -DisplayName "AX HTTP from Proxy" -Direction Inbound `
     -Protocol TCP -LocalPort 80 -RemoteAddress 10.1.1.98,10.1.1.99 -Action Allow
   ```
5. Tạo thư mục deploy local `D:\app` (web engineer deploy React vào đây — xem Phase 2).

---

## 0.7 — Checklist trước khi sang Phase 1

- [ ] 9 máy cài OS xong, update mới nhất
- [ ] Mạng 2 NIC đúng IP; default route qua WAN; LAN ping thông giữa các node
- [ ] Giờ đồng bộ (NTP) trên mọi máy
- [ ] SSH key-only hoạt động; ufw bật
- [ ] Phần mềm theo vai trò đã cài (chưa cấu hình)
- [ ] `/etc/hosts` thống nhất tên–IP trên các node Linux
