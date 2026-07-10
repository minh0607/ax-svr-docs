# ĐỀ XUẤT & BÁO CÁO DỰ ÁN — HẠ TẦNG WEB HIGH AVAILABILITY "AX SVR"

> **Loại tài liệu:** Proposal nội bộ — trình quản lý
> **Ngày:** 10/07/2026
> **Trạng thái dự án:** Đã triển khai hoàn tất hạ tầng chính (production)
> **Người thực hiện:** Đội hạ tầng

---

## 1. Tóm tắt điều hành (Executive Summary)

Dự án AX Svr xây dựng hạ tầng web **High Availability (HA)** hoàn chỉnh cho khách hàng trên nền tảng ảo hóa, trong môi trường mạng **air-gap** (cô lập, không kết nối Internet). Hệ thống được thiết kế theo nguyên tắc **không còn điểm chết đơn lẻ (SPOF)** ở mọi tầng:

- **Tầng biên (edge):** 2 proxy Nginx + Keepalived/VIP — mất 1 proxy, dịch vụ tự chuyển trong **< 3 giây**.
- **Tầng web:** 2 server IIS (Windows Server 2025) chạy song song sau load balancer — mất 1 web, Nginx tự loại khỏi pool.
- **Tầng dữ liệu:** cụm PostgreSQL 17 gồm 3 node (Patroni + etcd) tự động bầu leader mới trong **< 30 giây** khi node chính gặp sự cố, với 1 replica đồng bộ (synchronous) đảm bảo **không mất dữ liệu đã commit (RPO = 0)**.
- **An toàn dữ liệu:** backup pgBackRest với WAL liên tục, hỗ trợ khôi phục về bất kỳ thời điểm nào (PITR).

Khối lượng bàn giao gồm: **hạ tầng 10 VM đã triển khai**, bộ tài liệu vận hành ~2.400 dòng (10 tài liệu phase), bộ công cụ quản trị DB (14 scripts), scripts firewall tự động theo vai trò, và công cụ tạo ISO cài đặt tự động. Toàn bộ được quản lý version trên Git (tag v1.0.0).

**Đề xuất tiếp theo:** tích hợp giám sát vào hệ thống **Zabbix/Grafana sẵn có** của công ty (không dựng node monitoring riêng), bổ sung backup off-site để hoàn thiện chuẩn 3-2-1, và thiết lập lịch diễn tập failover/khôi phục định kỳ.

---

## 2. Bối cảnh & mục tiêu

### Bối cảnh
Khách hàng cần hạ tầng chạy ứng dụng web (React SPA + backend kết nối PostgreSQL) phục vụ người dùng nội bộ qua dải mạng riêng, yêu cầu:
- Dịch vụ **không gián đoạn** khi 1 máy chủ bất kỳ gặp sự cố.
- Dữ liệu **không mất** khi hỏng node database.
- Môi trường **air-gap**: không kết nối Internet → mọi giải pháp phải hoạt động offline.
- Chỉ quản trị viên được phép truy cập remote vào máy chủ.

### Mục tiêu đã cam kết
| Mục tiêu | Chỉ số | Kết quả |
|---|---|---|
| HA tầng proxy | Failover VIP | < 3 giây |
| HA tầng web | Loại node lỗi khỏi pool | Tự động (health check) |
| HA tầng DB | Bầu leader mới | < 30 giây, tự động |
| Chống mất dữ liệu | RPO khi mất leader | = 0 (sync replica) |
| Khôi phục dữ liệu | PITR | Về bất kỳ thời điểm nào |
| Bảo mật | Truy cập remote | Chỉ IP admin (ufw + Windows FW) |

---

## 3. Kiến trúc giải pháp

### 3.1 Sơ đồ tổng thể

```
        USER (dải WAN 107.118.210.0/24 — air-gap)
                        │
                        ▼
            ╔═══ Proxy-VIP .100 ═══╗          ← Keepalived (VRRP)
            ║                      ║
     ax-proxy01 (.98)  ◄──►  ax-proxy02 (.99)   Nginx LB, TLS terminate
            │      load balance    │
            ├──────────┬───────────┘
            ▼          ▼                        LAN 10.1.1.0/24
     ax-web01 (.101)  ax-web02 (.102)           Win2025 + IIS, app local D:\app
            │          │
            │  connection string đa host
            │  (target_session_attrs=read-write)
            ▼          ▼
     ax-db01 (.103)  ax-db02 (.104)  ax-db03 (.105)
       LEADER        SYNC STANDBY     ASYNC REPLICA
       PostgreSQL 17 + Patroni + etcd (quorum 3 node)
                                      └─ /backup: pgBackRest + pg_dump

     nas (.97): Samba — kho source web (deploy theo release)
     devdb (.90): PostgreSQL 17 standalone — môi trường Dev
```

### 3.2 Các quyết định kiến trúc chính & lý do

1. **2 proxy + Keepalived/VIP (active-passive)** — HA tầng biên với 1 IP duy nhất cho user; failover tự động qua VRRP, không cần thiết bị cân bằng tải chuyên dụng.
2. **Cụm DB Patroni + etcd 3 node** — auto-failover chuẩn công nghiệp cho PostgreSQL; quorum số lẻ tránh split-brain; 1 sync standby (RPO=0) + 1 async replica.
3. **Ứng dụng kết nối DB bằng connection string đa host** (`target_session_attrs=read-write`) thay vì HAProxy/DB-VIP — **bớt 1 lớp trung gian, bớt 1 điểm hỏng**, độ an toàn dữ liệu tương đương (Patroni đảm nhiệm failover).
4. **Web chạy local (`D:\app`), NAS chỉ là kho source** — NAS hỏng thì web vẫn chạy bình thường; tránh biến NAS thành SPOF. Deploy theo release có version, rollback được.
5. **Backup tập trung trên đĩa `/backup` riêng của DB3** — full hằng tuần + differential hằng ngày + WAL streaming liên tục; kèm pg_dump logic backup. (Giới hạn & hướng xử lý: xem mục 6.)
6. **TLS terminate tại Nginx** — quản lý chứng chỉ tập trung 1 chỗ; IIS chạy HTTP nội bộ trong LAN.
7. **Air-gap compliance** — toàn bộ hướng dẫn cài đặt có phương án offline (mirror APT, CA nội bộ, NTP nội bộ).

### 3.3 Bảo mật — mô hình nhiều lớp

- **Mạng 2 dải tách biệt:** WAN (user truy cập) / LAN (replication, backup, quản trị nội bộ). PostgreSQL, etcd, Patroni, Samba **chỉ bind LAN**.
- **Firewall theo vai trò:** script `apply-firewall.sh` (Linux/ufw) + `apply-firewall-windows.ps1` (Windows/RDP) — SSH/RDP **chỉ mở cho IP admin**.
- **Kiểm soát DB 3 lớp:** ufw (chặn theo IP) → pg_hba (xác thực, pin IP per-user) → GRANT (quyền trên từng bảng). Tài khoản `postgres` gốc khóa local-only, quản trị dùng role riêng `dbadmin`.

---

## 4. Khối lượng công việc đã hoàn thành

### 4.1 Hạ tầng đã triển khai (production)

| # | Hạng mục | Chi tiết |
|---|---|---|
| 1 | 10 VM cài đặt hoàn chỉnh | 2 proxy, 2 web (Win2025), 3 DB, NAS, DevDB + chuẩn hóa OS/mạng 2 NIC/hardening |
| 2 | Cụm PostgreSQL HA | PostgreSQL 17 + Patroni + etcd 3 node, 1 sync + 1 async, data trên đĩa riêng `/data` |
| 3 | Tầng web IIS | 2 node Win2025, SPA routing, health check, forwarded headers |
| 4 | Tầng proxy HA | Nginx LB + Keepalived VIP, health check upstream |
| 5 | NAS kho source | Samba bind LAN, quy trình deploy theo release NAS→local |
| 6 | Backup | pgBackRest (full/diff/WAL) + pg_dump, cron trên DB3, đĩa `/backup` riêng |
| 7 | Firewall toàn hệ thống | ufw theo vai trò + Windows Firewall, chỉ admin remote |
| 8 | DevDB | PostgreSQL 17 standalone cho đội Dev |

> **Ghi chú monitoring:** tài liệu Phase 6 (Prometheus/Grafana) đã hoàn chỉnh, nhưng **không dựng node monitoring riêng** — quyết định tận dụng hệ thống **Zabbix/Grafana sẵn có** của công ty (xem đề xuất mục 7).

### 4.2 Sản phẩm bàn giao (deliverables)

| Sản phẩm | Quy mô |
|---|---|
| Bộ tài liệu triển khai & vận hành (Phase 0→6, DevDB, off-site, autoinstall) | 10 tài liệu, ~2.400 dòng, config tách riêng từng node (copy-paste được) |
| Bộ công cụ quản trị PostgreSQL `db-scripts/` | 14 scripts: tạo admin/user/db, phân quyền nhóm, pin IP per-user, hỗ trợ cả DevDB & cụm Patroni |
| Scripts firewall tự động | 2 scripts (Linux + Windows) |
| Công cụ autoinstall Ubuntu 24.04 | `gen-autoinstall.sh` sinh seed ISO cho từng host |
| Checklist nghiệm thu Go-Live | Đầy đủ theo từng tầng, gồm các bài test sập node thực tế |
| Quản lý version | Git repo riêng (private), tag **v1.0.0** |

### 4.3 Kết quả kiểm thử HA (theo checklist nghiệm thu)

- Tắt node DB leader → cụm tự bầu leader mới **< 30 giây**, ứng dụng ghi tiếp bình thường; node cũ bật lại tự rejoin thành replica.
- Tắt proxy chính → VIP chuyển sang proxy phụ **< 3 giây**, user không gián đoạn.
- Tắt 1 web → Nginx tự loại khỏi pool, dịch vụ tiếp tục trên node còn lại.
- Backup: WAL archive hoạt động liên tục, khôi phục PITR đã diễn tập thành công.

---

## 5. Giá trị mang lại

1. **Loại bỏ SPOF ở mọi tầng** — bất kỳ 1 máy chủ nào hỏng, dịch vụ vẫn chạy; giảm thiểu downtime ngoài kế hoạch.
2. **An toàn dữ liệu 2 lớp** — sync replica (RPO=0 khi mất leader) + backup PITR (khôi phục sai sót logic, xóa nhầm dữ liệu).
3. **Vận hành đơn giản hóa** — failover hoàn toàn tự động ở cả 3 tầng, không cần can thiệp tay lúc sự cố.
4. **Tri thức được tài liệu hóa** — bất kỳ kỹ sư nào cũng có thể vận hành/tái dựng hệ thống theo runbook; không phụ thuộc cá nhân.
5. **Tái sử dụng được** — bộ tài liệu + scripts là nền tảng chuẩn để triển khai cho các khách hàng tương lai có nhu cầu tương tự.

---

## 6. Rủi ro còn lại & giới hạn hiện tại

| # | Rủi ro / giới hạn | Mức độ | Hướng xử lý |
|---|---|---|---|
| 1 | Backup đang nằm trên DB3 — cùng cụm với dữ liệu chính. Thảm họa mất cả cụm (cháy, hỏng storage ảo hóa) sẽ mất cả backup | **Cao** | Bổ sung backup off-site (site khác/đĩa rời — air-gap không dùng được cloud) → hoàn thiện chuẩn 3-2-1. Tài liệu đã viết sẵn (Phase 5b) |
| 2 | Chưa có giám sát/cảnh báo tập trung — sự cố 1 node (hệ thống vẫn chạy nhờ HA) có thể không ai biết, đến khi node thứ 2 hỏng mới lộ | **Cao** | Tích hợp Zabbix/Grafana sẵn có (mục 7.1) |
| 3 | HA chỉ đúng khi VM cùng vai trò nằm **khác host vật lý** (anti-affinity) | Trung bình | Xác nhận cấu hình anti-affinity trên tầng ảo hóa |
| 4 | Chứng chỉ TLS dùng CA nội bộ — cần quy trình gia hạn/phân phối CA cho client | Trung bình | Đưa vào quy trình vận hành định kỳ |
| 5 | Kỹ năng vận hành Patroni/pgBackRest cần duy trì | Trung bình | Diễn tập failover + PITR định kỳ (quý/lần) theo checklist có sẵn |

---

## 7. Đề xuất giai đoạn tiếp theo

### 7.1 Tích hợp giám sát vào Zabbix/Grafana sẵn có *(ưu tiên cao)*
Không dựng node monitoring riêng; tận dụng hạ tầng giám sát công ty đang vận hành:
- Cài Zabbix agent trên các node Linux/Windows; giám sát port/service các tầng (nginx, keepalived, IIS, postgres, patroni, etcd).
- Giám sát trạng thái cụm qua Patroni REST API (`:8008/metrics`) và etcd health.
- Cảnh báo tối thiểu: node down, cụm mất leader/mất sync standby, backup thất bại/quá hạn, dung lượng đĩa `/data`, `/backup`, chứng chỉ sắp hết hạn.
- Dashboard Grafana cho DB cluster + traffic proxy.

### 7.2 Backup off-site — hoàn thiện 3-2-1 *(ưu tiên cao)*
Triển khai repo2 pgBackRest sang site khác qua SSH (hoặc quy trình đĩa rời) theo tài liệu Phase 5b có sẵn.

### 7.3 Quy trình vận hành định kỳ
- Diễn tập failover DB + proxy, diễn tập khôi phục PITR: mỗi quý.
- Kiểm tra `pgbackrest info`, dung lượng đĩa, hạn chứng chỉ: hằng tuần (đưa vào cảnh báo tự động sau 7.1).
- Cập nhật bảo mật OS qua mirror APT offline: theo chu kỳ công ty quy định.

### 7.4 Nguồn lực đề xuất
| Hạng mục | Ước lượng |
|---|---|
| Tích hợp Zabbix/Grafana (7.1) | 3–5 ngày công |
| Backup off-site (7.2) | 2–3 ngày công + hạ tầng site phụ/đĩa rời |
| Soạn lịch & chạy diễn tập lần đầu (7.3) | 1–2 ngày công |

---

## 8. Kết luận

Hạ tầng AX Svr đã được triển khai hoàn chỉnh, đạt các mục tiêu HA và an toàn dữ liệu đã cam kết, kèm bộ tài liệu vận hành và công cụ quản trị đầy đủ. Hệ thống hiện phục vụ ổn định; hai hạng mục cần quyết định để đạt độ an toàn trọn vẹn là **tích hợp giám sát Zabbix/Grafana** và **backup off-site 3-2-1**.

Kính đề nghị quản lý:
1. **Ghi nhận nghiệm thu** khối lượng công việc đã hoàn thành (mục 4).
2. **Phê duyệt** triển khai giai đoạn tiếp theo (mục 7) với ước lượng nguồn lực kèm theo.

---

## Phụ lục A — Bảng IP hệ thống

| Thành phần | WAN 107.118.210.x | LAN 10.1.1.x | OS / phần mềm |
|---|---|---|---|
| Proxy-VIP | .100 | — | (Keepalived VRRP) |
| ax-proxy01 | .98 | .98 | Ubuntu / nginx, keepalived |
| ax-proxy02 | .99 | .99 | Ubuntu / nginx, keepalived |
| ax-web01 | .101 | .101 | Win2025 / IIS |
| ax-web02 | .102 | .102 | Win2025 / IIS |
| nas | .97 | .97 | Ubuntu / samba (chỉ source web) |
| ax-db01 | .103 | .103 | Ubuntu / PostgreSQL 17, Patroni, etcd, pgBackRest |
| ax-db02 | .104 | .104 | như trên |
| ax-db03 | .105 | .105 | như trên + đĩa `/backup` (repo backup) |
| devdb | .90 | — | Ubuntu / PostgreSQL 17 standalone |

## Phụ lục B — Danh mục tài liệu bàn giao

| Phase | Tài liệu | Nội dung |
|---|---|---|
| 0 | axsvr-phase0-setup.md | OS, mạng 2 NIC, hardening, phần mềm theo vai trò |
| 1 | axsvr-phase1-db.md | Cụm PostgreSQL HA (etcd + Patroni) |
| 2 | axsvr-phase2-nas.md | NAS kho source (Samba, deploy theo release) |
| 3 | axsvr-phase3-web-iis.md | Web Win2025 + IIS |
| 4 | axsvr-phase4-proxy.md | Proxy HA (Nginx + Keepalived/VIP) |
| 5 | axsvr-phase5-backup.md | Backup pgBackRest + pg_dump, PITR |
| 5b | axsvr-backup-offsite.md | Off-site backup (3-2-1) — *chưa triển khai, đề xuất* |
| 6 | axsvr-phase6-monitoring.md | Monitoring (tham khảo; thay bằng tích hợp Zabbix/Grafana) |
| Dev | axsvr-devdb-setup.md | DevDB standalone |
| Tool | axsvr-autoinstall.md + autoinstall/ | Autoinstall Ubuntu 24.04 (seed ISO) |
| Tool | firewall/ | Firewall theo vai trò (Linux + Windows) |
| Tool | db-scripts/ | 14 scripts quản trị PostgreSQL |
