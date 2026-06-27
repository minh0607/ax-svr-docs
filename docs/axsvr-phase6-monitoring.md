# AX Svr — Phase 6: Monitoring & Alerting (Prometheus + Grafana)

> Giám sát toàn hệ thống: node, PostgreSQL/Patroni, etcd, Nginx, IIS/Windows, backup, cert.
> Phát hiện sự cố TRƯỚC khi user phàn nàn.

## Đặt monitoring ở đâu?

| Lựa chọn | Ghi chú |
|---|---|
| **VM riêng `mon`** (khuyến nghị) | vd 107.118.210.96 / 10.1.1.96 — tách biệt, không ảnh hưởng node khác |
| Co-locate trên NAS | Tiết kiệm VM (NAS chỉ chạy Samba) → cân nhắc tải |

> Tài liệu dùng host `mon` = **10.1.1.96** (scrape qua LAN). Grafana truy cập qua WAN 107.118.210.96.

```
                         Prometheus (mon 10.1.1.96) ── scrape ──┐
   node_exporter (mọi Linux)                                    │
   patroni /metrics :8008  (DB)                                 │
   postgres_exporter (DB)                                       │
   etcd /metrics :2379 (DB)                                     ├──► Grafana + Alertmanager
   nginx-exporter (proxy)                                       │
   windows_exporter (web Win) :9182                             │
   pgbackrest (textfile) (DB3)                                  ┘
```

---

## 6.1 — Cài Prometheus + Grafana + Alertmanager (trên `mon`)

```bash
sudo apt update
sudo apt install -y prometheus prometheus-alertmanager
# Grafana (repo chính thức):
sudo apt install -y apt-transport-https software-properties-common
wget -q -O - https://apt.grafana.com/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" | \
  sudo tee /etc/apt/sources.list.d/grafana.list
sudo apt update && sudo apt install -y grafana
sudo systemctl enable --now grafana-server      # Grafana :3000
```

---

## 6.2 — Cài exporters

**node_exporter — TẤT CẢ máy Linux (proxy, db, nas, mon):**
```bash
sudo apt install -y prometheus-node-exporter     # :9100
sudo ufw allow from 10.1.1.96 to any port 9100 proto tcp
```

**PostgreSQL/Patroni (3 DB node):**
- Patroni đã expose Prometheus metrics sẵn tại `http://<db>:8008/metrics` (no setup).
- Thêm postgres_exporter cho metric DB chi tiết:
```bash
sudo apt install -y prometheus-postgres-exporter
# tạo user giám sát trong PostgreSQL (chạy 1 lần qua primary):
#   CREATE USER mon_exporter PASSWORD '<pwd>';
#   GRANT pg_monitor TO mon_exporter;
# cấu hình DATA_SOURCE_NAME trỏ localhost; mở :9187 cho mon
sudo ufw allow from 10.1.1.96 to any port 9187 proto tcp
sudo ufw allow from 10.1.1.96 to any port 8008 proto tcp
```

**etcd (3 DB node):** metrics sẵn tại `http://<db>:2379/metrics`.
```bash
sudo ufw allow from 10.1.1.96 to any port 2379 proto tcp   # đã mở ở Phase 1 cho LAN
```

**Nginx (2 proxy):**
```bash
# bật stub_status
sudo tee /etc/nginx/conf.d/status.conf >/dev/null <<'EOF'
server {
  listen 10.1.1.98:8080;          # đổi .99 cho proxy2
  location /stub_status { stub_status; allow 10.1.1.96; deny all; }
}
EOF
sudo systemctl reload nginx
# nginx-prometheus-exporter đọc stub_status -> :9113
sudo apt install -y prometheus-nginx-exporter
sudo ufw allow from 10.1.1.96 to any port 9113 proto tcp
```

**Windows web (2 máy) — windows_exporter:**
```powershell
# tải windows_exporter MSI, bật collector iis + tệp cơ bản
msiexec /i windows_exporter.msi ENABLED_COLLECTORS="cpu,cs,logical_disk,net,os,service,memory,iis"
# firewall chỉ cho mon:
New-NetFirewallRule -DisplayName "win_exporter from mon" -Direction Inbound `
  -Protocol TCP -LocalPort 9182 -RemoteAddress 10.1.1.96 -Action Allow
```

**pgBackRest (trên DB3 — repo host) — textfile collector:**
```bash
# cron đẩy trạng thái backup ra file .prom cho node_exporter đọc
# vd: kiểm backup gần nhất < 26h, ghi metric ax_pgbackrest_last_backup_age_seconds
```

---

## 6.3 — Prometheus scrape config

`/etc/prometheus/prometheus.yml`:
```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['localhost:9093']

rule_files:
  - /etc/prometheus/rules/ax-alerts.yml

scrape_configs:
  - job_name: node
    static_configs:
      - targets:
          - 10.1.1.98:9100   # proxy1
          - 10.1.1.99:9100   # proxy2
          - 10.1.1.97:9100   # nas
          - 10.1.1.103:9100  # db1
          - 10.1.1.104:9100  # db2
          - 10.1.1.105:9100  # db3
          - 10.1.1.96:9100   # mon

  - job_name: patroni
    metrics_path: /metrics
    static_configs:
      - targets: [10.1.1.103:8008, 10.1.1.104:8008, 10.1.1.105:8008]

  - job_name: postgres
    static_configs:
      - targets: [10.1.1.103:9187, 10.1.1.104:9187, 10.1.1.105:9187]

  - job_name: etcd
    metrics_path: /metrics
    static_configs:
      - targets: [10.1.1.103:2379, 10.1.1.104:2379, 10.1.1.105:2379]

  - job_name: nginx
    static_configs:
      - targets: [10.1.1.98:9113, 10.1.1.99:9113]

  - job_name: windows
    static_configs:
      - targets: [10.1.1.101:9182, 10.1.1.102:9182]
```
```bash
sudo systemctl restart prometheus
# kiểm tra targets UP: http://107.118.210.96:9090/targets
```

---

## 6.4 — Dashboard Grafana (import theo ID)

Vào Grafana (`http://107.118.210.96:3000`, mặc định admin/admin → đổi ngay), add datasource Prometheus (`http://localhost:9090`), rồi import:

| Dashboard | ID |
|---|---|
| Node Exporter Full | 1860 |
| PostgreSQL (postgres_exporter) | 9628 |
| Patroni | 18870 |
| etcd | 3070 |
| Nginx exporter | 12708 |
| Windows Exporter | 14694 |

---

## 6.5 — Cảnh báo quan trọng (`/etc/prometheus/rules/ax-alerts.yml`)

```yaml
groups:
  - name: ax-critical
    rules:
      - alert: NodeDown
        expr: up == 0
        for: 1m
        labels: { severity: critical }
        annotations: { summary: "{{ $labels.instance }} DOWN" }

      - alert: PatroniNoLeader
        expr: sum(patroni_master) by (scope) < 1
        for: 30s
        labels: { severity: critical }
        annotations: { summary: "Cụm {{ $labels.scope }} KHÔNG có Leader" }

      - alert: PostgresReplicationLagHigh
        expr: patroni_replica_lag_in_bytes > 50*1024*1024
        for: 2m
        labels: { severity: warning }
        annotations: { summary: "Replica {{ $labels.instance }} lag > 50MB" }

      - alert: DiskAlmostFull
        expr: (node_filesystem_avail_bytes / node_filesystem_size_bytes) < 0.12
        for: 5m
        labels: { severity: warning }
        annotations: { summary: "Đĩa {{ $labels.instance }} còn < 12%" }

      - alert: BackupStale
        expr: ax_pgbackrest_last_backup_age_seconds > 93600   # >26h
        for: 10m
        labels: { severity: critical }
        annotations: { summary: "Backup DB quá hạn (>26h)" }

      - alert: EtcdNoQuorum
        expr: count(up{job="etcd"} == 1) < 2
        for: 1m
        labels: { severity: critical }
        annotations: { summary: "etcd mất quorum (<2 node)" }
```

**Alertmanager** (`/etc/prometheus/alertmanager.yml`): route cảnh báo ra **email / Slack / Telegram** (chọn kênh anh dùng). Ví dụ email:
```yaml
route:
  receiver: ax-email
receivers:
  - name: ax-email
    email_configs:
      - to: 'admin@example.com'
        from: 'alert@example.com'
        smarthost: 'smtp.example.com:587'
        auth_username: 'alert@example.com'
        auth_password: '<smtp_pwd>'
```

---

## 6.6 — Những cảnh báo nên có (tối thiểu)

- [ ] **NodeDown** — bất kỳ server tắt
- [ ] **PatroniNoLeader** — cụm DB mất primary (nghiêm trọng nhất)
- [ ] **EtcdNoQuorum** — mất quorum → Patroni không bầu được leader
- [ ] **ReplicationLag** — replica tụt hậu
- [ ] **DiskAlmostFull** — đầy đĩa (đặc biệt WAL/backup)
- [ ] **BackupStale** — backup không chạy
- [ ] **Web/IIS down** — `windows_exporter` service hoặc health.html fail
- [ ] **CertExpiry** — cert HTTPS sắp hết hạn (blackbox_exporter, tùy chọn)

---

## Checklist Phase 6

- [ ] Prometheus + Grafana + Alertmanager chạy trên `mon`
- [ ] node_exporter trên mọi máy Linux; windows_exporter trên 2 web
- [ ] Patroni/etcd metrics scrape OK; postgres_exporter OK; nginx-exporter OK
- [ ] Tất cả targets UP trên `:9090/targets`
- [ ] Dashboard Grafana import xong
- [ ] Alert rules nạp; Alertmanager gửi được kênh thông báo
- [ ] **Test thử 1 cảnh báo** (tắt 1 node → nhận alert)
