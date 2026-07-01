# AX Svr — Tài liệu triển khai hệ thống

Hệ thống web HA (high availability) toàn diện: 2 proxy, 2 web, 3 DB cluster auto-failover, NAS, backup, monitoring. Tất cả chạy trên VM.

---

## 📑 Mục lục tài liệu

| Phase | File | Nội dung |
|---|---|---|
| 0 | [axsvr-phase0-setup.md](axsvr-phase0-setup.md) | Cài nền: OS, mạng 2 NIC, hardening, phần mềm theo vai trò |
| 1 | [axsvr-phase1-db.md](axsvr-phase1-db.md) | Cụm PostgreSQL HA (etcd + Patroni), 1 sync + 1 async |
| 2 | [axsvr-phase2-nas.md](axsvr-phase2-nas.md) | NAS chia sẻ source web (Samba, deploy-to-local) |
| 3 | [axsvr-phase3-web-iis.md](axsvr-phase3-web-iis.md) | Web Windows 2025 + IIS (SPA, health, forwarded headers) |
| 4 | [axsvr-phase4-proxy.md](axsvr-phase4-proxy.md) | Proxy HA (Nginx LB + Keepalived/VIP) |
| 5 | [axsvr-phase5-backup.md](axsvr-phase5-backup.md) | Backup pgBackRest (repo trên /backup DB3 — p.án B, PITR + pg_dump) |
| 5b | [axsvr-backup-offsite.md](axsvr-backup-offsite.md) | Off-site backup (repo2 cloud/SSH) — hoàn tất 3-2-1 |
| 6 | [axsvr-phase6-monitoring.md](axsvr-phase6-monitoring.md) | Monitoring + Alerting (Prometheus/Grafana) |
| Dev | [axsvr-devdb-setup.md](axsvr-devdb-setup.md) | DevDB standalone (PG17 + /data, cho đội Dev) |
| Tool | [axsvr-autoinstall.md](axsvr-autoinstall.md) | Autoinstall Ubuntu 24.04 (seed ISO mỗi host) |
| Tool | [firewall/apply-firewall.sh](firewall/apply-firewall.sh) | Apply ufw theo vai trò — SSH chỉ cho IP admin |
| Tool | [firewall/apply-firewall-windows.ps1](firewall/apply-firewall-windows.ps1) | Firewall Web Windows — RDP chỉ cho IP admin |
| Tool | [db-scripts/](db-scripts/README.md) | Quản trị PostgreSQL: tạo admin/user/db, phân quyền |

**Áp firewall (chỉ admin remote):**
```bash
# Linux — chạy trên từng server theo vai trò, nhập IP admin:
sudo ./firewall/apply-firewall.sh db     107.118.210.50
sudo ./firewall/apply-firewall.sh proxy  107.118.210.50,107.118.210.51
sudo ./firewall/apply-firewall.sh nas    107.118.210.50
sudo ./firewall/apply-firewall.sh mon    107.118.210.50
sudo ./firewall/apply-firewall.sh devdb  107.118.210.50
```
```powershell
# Windows web (2 máy):
.\firewall\apply-firewall-windows.ps1 -AdminIps "107.118.210.50"
```

**Thứ tự triển khai:** `0 → 1 → 2 → 3 → 4 → 5 → 6`
(nền → lõi HA DB → kho source → web → edge HA → an toàn dữ liệu → giám sát)

---

## (b) 🗺️ Sơ đồ kiến trúc tổng thể

```
                              ┌─────────────┐
                              │   USER /    │
                              │  INTERNET   │
                              └──────┬──────┘
                                     │  WAN  (107.118.210.0/24)
                                     ▼
                         ╔═══════════════════════╗
                         ║  Proxy-VIP  .100      ║   ← Keepalived (VRRP)
                         ╚═══════════╤═══════════╝
                       ┌─────────────┴─────────────┐
                       ▼                           ▼
              ┌─────────────────┐         ┌─────────────────┐
              │ AX-Proxy01(.98) │ MASTER  │ AX-Proxy02(.99) │ BACKUP
              │ Nginx+Keepalived│◄═══════►│ Nginx+Keepalived│
              └────────┬────────┘  VRRP   └────────┬────────┘
                       │                           │
═══════════════════════╪═══════════════════════════╪══════════════ LAN (10.1.1.0/24)
                       │      load balance         │
              ┌────────┴───────────┬───────────────┘
              ▼                    ▼
     ┌─────────────────┐  ┌─────────────────┐
     │  Web 1 (.101)   │  │  Web 2 (.102)   │   Windows 2025 + IIS
     │  IIS  D:\app    │  │  IIS  D:\app    │   (React chạy LOCAL)
     └───┬────────┬────┘  └────┬───────┬────┘
         │        │            │       │
   deploy│        │ DB conn    │       │deploy
   (SMB) │        │(multi-host)│       │(SMB)
         ▼        │            │       ▼
   ┌──────────┐   │            │   ┌──────────┐
   │   NAS    │   │            │   │   NAS    │
   │  .97     │   │            │   │  .97     │
   │ source   │   │            │   │ source   │
   │ web ONLY │   │            │   │ web ONLY │
   └──────────┘   │            │   └──────────┘
                  ▼            ▼
            ┌──────────────────────────────────────┐
            │   DB conn string đa host (Cách 2):    │
            │   .103, .104, .105  read-write        │
            └──────────────────────────────────────┘
                           │
              ┌────────────┼────────────┐
              ▼            ▼            ▼
   ┌────────────┐  ┌────────────┐  ┌──────────────────┐
   │ DB1 (.103) │  │ DB2 (.104) │  │ DB3 (.105)       │
   │ PostgreSQL │  │ PostgreSQL │  │ PostgreSQL       │
   │ Patroni    │◄─┤ Patroni    ├─►│ Patroni          │
   │ etcd       │  │ etcd       │  │ etcd             │
   │  LEADER    │  │SYNC STANDBY│  │  REPLICA         │
   └─────┬──────┘  └─────┬──────┘  │ + /backup (repo) │
         │WAL            │WAL      │   pgBackRest+dump │
         └───────────────┴────────►│◄── backup pull   │
                                   └──────────────────┘
        └─ streaming replication + etcd quorum ─┘

   ┌──────────────────────────────────────────────────┐
   │  mon (.96): Prometheus + Grafana + Alertmanager   │
   │  scrape mọi node/DB/proxy/web qua LAN             │
   └──────────────────────────────────────────────────┘

   ┌──────────────────────────────────────────────────┐
   │  DevDB (.90): PostgreSQL standalone (môi trường dev)│
   └──────────────────────────────────────────────────┘
```

### Hai dải mạng
| Dải | Vai trò |
|---|---|
| **107.118.210.0/24 (WAN)** | Dải user truy cập (mạng **air-gap**, KHÔNG ra Internet). Proxy mở 443/80 cho user. |
| **10.1.1.0/24 (LAN)** | Nội bộ: proxy↔web, web↔db, replication, backup, monitoring. |

> ## 🔒 Bảo mật — môi trường AIR-GAP + chỉ admin remote
> Hệ thống **cô lập, không ra Internet** → không lo tấn công từ ngoài. Nguyên tắc nội bộ:
> - **CHỈ admin** mới remote (SSH/RDP) được vào server → dùng script [`firewall/apply-firewall.sh`](firewall/apply-firewall.sh) (nhập IP admin → apply ufw).
> - Web/DB/NAS/mon: **không** mở dịch vụ ra dải user WAN; chỉ Proxy phục vụ user.
> - PostgreSQL/etcd/Patroni/Samba **chỉ bind LAN 10.1.1.x**.
> - **Hệ quả air-gap:** apt/PGDG/Grafana **không tải được online** → cần **mirror offline / đĩa cài**; TLS dùng **CA nội bộ** (không Let's Encrypt); NTP dùng **nguồn giờ nội bộ**; off-site backup **không thể là cloud** → site khác / đĩa rời.

---

## 📋 Bảng IP tổng

| Thành phần | WAN 107.118.210.x | LAN 10.1.1.x | OS / phần mềm |
|---|---|---|---|
| Proxy-VIP | **.100** | — | (Keepalived) |
| AX-Proxy01 | .98 | .98 | Ubuntu / nginx, keepalived |
| AX-Proxy02 | .99 | .99 | Ubuntu / nginx, keepalived |
| Web 1 | .101 | .101 | Win2025 / IIS |
| Web 2 | .102 | .102 | Win2025 / IIS |
| NAS | .97 (mgmt) | .97 (data) | Ubuntu / samba (CHỈ source web) |
| DB 1 | .103 | .103 | Ubuntu / postgresql-17, patroni, etcd, pgbackrest |
| DB 2 | .104 | .104 | nt |
| DB 3 | .105 | .105 | nt + phân vùng /backup (backup local hằng ngày) |
| mon | .96 | .96 | Ubuntu / prometheus, grafana |
| DevDB | .90 | — | Ubuntu / postgresql-17 |

> **PostgreSQL 17** (qua PGDG). Mọi DB để data + log trong **`/data/postgresql`**.

> Lưu ý: Proxy-VIP `107.118.210.100` (WAN). Phương án DB chốt **Cách 2 (multi-host)** → KHÔNG có DB-VIP.

---

## 🔑 Quyết định kiến trúc chính (đã chốt)

1. **2 proxy + VIP** (Keepalived) — HA tầng edge.
2. **DB: Patroni + etcd, 3 node** — auto-failover, quorum số lẻ.
3. **DB kết nối: Cách 2 multi-host** (không HAProxy/VIP) — đơn giản + an toàn dữ liệu như nhau (Patroni lo).
4. **Web chạy LOCAL** (`D:\app`), NAS chỉ là kho source — tránh NAS thành SPOF.
5. **Backup dồn về `/backup` trên DB3** (phương án B); NAS **chỉ** chứa source web. ⚠️ backup trên 1 node cụm → cần off-site để đủ an toàn.
6. **TLS terminate ở Nginx** — IIS chạy HTTP nội bộ.

---

## (c) ✅ Checklist nghiệm thu Go-Live

### Hạ tầng & mạng
- [ ] 11 VM (gồm mon, devdb) cài OS, update mới nhất
- [ ] Mỗi VM đúng IP 2 NIC; **chỉ 1 default gateway** (WAN); LAN ping thông
- [ ] NTP đồng bộ toàn bộ
- [ ] SSH key-only; ufw/Windows Firewall bật, mở port theo vai trò
- [ ] VM cùng vai trò đặt **khác host vật lý** (anti-affinity) — phần ảo hóa anh tự cover

### Database (Phase 1)
- [ ] `patronictl list`: 1 Leader + 1 Sync Standby + 1 Replica, đều `running`
- [ ] etcd 3 node `endpoint health` = healthy
- [ ] **TEST: tắt Leader → tự bầu Leader mới < 30s, ghi tiếp được**
- [ ] DB1 bật lại → tự rejoin thành Replica

### NAS (Phase 2)
- [ ] Samba chỉ nghe LAN; `hosts allow` đúng 2 web
- [ ] Web map share OK; `deploy.ps1` đồng bộ NAS→local chạy được
- [ ] NAS chỉ chạy Samba (không có vai trò backup)

### Web/IIS (Phase 3)
- [ ] Site bind **chỉ LAN:80**; physical path `D:\app` (local)
- [ ] SPA routing OK (refresh sâu URL không 404)
- [ ] `health.html` = OK; web engineer đã bật ForwardedHeaders
- [ ] 2 web nội dung đồng nhất

### Proxy (Phase 4)
- [ ] `https://107.118.210.100` ra web
- [ ] **TEST: tắt AX-Proxy01 → VIP nhảy AX-Proxy02 < 3s, vẫn truy cập**
- [ ] **TEST: tắt Web1 → Nginx loại khỏi pool, web vẫn chạy**
- [ ] Cert hợp lệ (không self-signed cho production); HTTP→HTTPS redirect

### Backup (Phase 5)
- [ ] `pgbackrest info`: full backup gần nhất OK (repo trên /backup DB3)
- [ ] `check` xác nhận archive_command hoạt động (WAL DB1/DB2 → DB3)
- [ ] Cron full + diff + pg_dump cài trên DB3
- [ ] `/backup` là đĩa riêng, khác ổ với `/data` của DB3
- [ ] **TEST: diễn tập PITR restore thành công ít nhất 1 lần**
- [ ] (Khuyến nghị) có bản off-site (3-2-1)

### Monitoring (Phase 6)
- [ ] Tất cả targets UP trên Prometheus `:9090/targets`
- [ ] Grafana dashboard hiển thị dữ liệu
- [ ] Alert rules nạp; Alertmanager gửi được thông báo
- [ ] **TEST: tắt 1 node → nhận được cảnh báo thật**

### Toàn cục
- [ ] DNS trỏ vào **Proxy-VIP 107.118.210.100**
- [ ] Tất cả mật khẩu/secret lưu nơi an toàn (không hardcode trong repo)
- [ ] Sơ đồ + bảng IP cập nhật khớp thực tế
- [ ] Đã chạy thử **kịch bản sập**: tắt lần lượt từng node, hệ thống vẫn phục vụ user

> **Nguyên tắc vàng:** HA của cả hệ thống = mắt xích yếu nhất. Đừng để bất kỳ tầng nào còn SPOF.
