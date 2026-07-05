# AX Svr — Phase 4: Proxy HA (Nginx + Keepalived/VIP)

> 2 Nginx active-passive, dùng chung **Proxy-VIP 107.118.210.100** (WAN, user truy cập).
> **Giai đoạn hiện tại:** Nginx chỉ nghe **port 80 (HTTP)**, load balance về 2 IIS web qua LAN.
> **Giai đoạn sau:** bật HTTPS (terminate TLS tại Nginx) — xem mục 4.1b.

```
User --WAN--> 107.118.210.100 (VIP) --> Nginx ax-proxy01 .98 / ax-proxy02 .99
                                          | LAN
                                          v
                          IIS ax-web01 10.1.1.101:80 / ax-web02 10.1.1.102:80
```

| | WAN 107.118.210.x | LAN 10.1.1.x |
|---|---|---|
| ax-proxy01 | .98 (MASTER) | .98 |
| ax-proxy02 | .99 (BACKUP) | .99 |
| Proxy-VIP | **.100** | — |
| ax-web01 (IIS) | .101 | .101 (nhận traffic) |
| ax-web02 (IIS) | .102 | .102 (nhận traffic) |

---

## 4.0 — Chuẩn bị (CẢ 2 proxy)

```bash
sudo apt update
sudo apt install -y nginx keepalived

# Xác định tên NIC của dải WAN 107.118.210.x (vd ens3) — dùng cho keepalived:
ip -br a | grep 107.118.210
```
Ghi nhớ tên interface WAN (ví dụ `ens3`) — thay vào `<WAN_IF>` bên dưới.

---

## 4.1 — Nginx reverse proxy + load balancing (HTTP, CẢ 2 proxy, file giống nhau)

> Giai đoạn hiện tại: **chỉ HTTP port 80**, chưa SSL.

`/etc/nginx/conf.d/ax-web.conf`:
```nginx
upstream ax_web_backend {
    least_conn;
    server 10.1.1.101:80 max_fails=3 fail_timeout=10s;
    server 10.1.1.102:80 max_fails=3 fail_timeout=10s;
    keepalive 32;
}

server {
    listen 80 default_server;
    server_name _;                       # hoặc ax.example.com

    client_max_body_size 50m;

    location / {
        proxy_pass http://ax_web_backend;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection        "";
        proxy_connect_timeout 5s;
        proxy_next_upstream error timeout http_502 http_503 http_504;
    }
}
```

```bash
sudo nginx -t && sudo systemctl enable --now nginx
```

> Lưu ý: Nginx `listen 80` (mọi interface) — node nào giữ VIP thì nhận traffic. Không bind cứng vào IP VIP để node backup không lỗi khởi động.

⚠️ **Cảnh báo:** dải `107.118.210.x` là WAN → traffic HTTP đi **cleartext** (kể cả login/session), dễ bị nghe lén/MITM. Chỉ dùng cho giai đoạn test; production nên bật HTTPS (mục 4.1b).

---

## 4.1b — Bật HTTPS (GIAI ĐOẠN SAU, chưa áp dụng)

> Khi cần bật TLS: thay block `server` ở 4.1 bằng 2 block dưới (redirect 80→443 + terminate 443).

```nginx
# HTTP -> HTTPS
server {
    listen 80 default_server;
    server_name _;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    http2 on;
    server_name ax.example.com;          # đổi domain thực tế

    ssl_certificate     /etc/nginx/ssl/ax.crt;
    ssl_certificate_key /etc/nginx/ssl/ax.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    client_max_body_size 50m;

    location / {
        proxy_pass http://ax_web_backend;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection        "";
        proxy_connect_timeout 5s;
        proxy_next_upstream error timeout http_502 http_503 http_504;
    }
}
```

**Cert:** nếu có domain public -> Let's Encrypt; nếu nội bộ -> internal CA hoặc self-signed:
```bash
sudo mkdir -p /etc/nginx/ssl
# self-signed tạm (thay bằng cert thật cho production):
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/nginx/ssl/ax.key -out /etc/nginx/ssl/ax.crt \
  -subj "/CN=ax.example.com"
```
> 2 proxy phải dùng **cùng một cert** (copy giống nhau).

---

## 4.2 — Keepalived (VRRP) -> Proxy-VIP 107.118.210.100

**Script kiểm tra Nginx** (cả 2 proxy) `/etc/keepalived/check_nginx.sh`:
```bash
#!/bin/bash
systemctl is-active --quiet nginx
```
```bash
sudo chmod +x /etc/keepalived/check_nginx.sh
```

**ax-proxy01 (MASTER)** `/etc/keepalived/keepalived.conf`:
```conf
vrrp_script chk_nginx {
    script "/etc/keepalived/check_nginx.sh"
    interval 2
    weight -40            # nginx chết -> giảm priority -> nhường VIP
    fall 2
    rise 2
}

vrrp_instance AX_PROXY {
    state MASTER
    interface <WAN_IF>        # NIC dải 107.118.210.x
    virtual_router_id 51
    priority 150              # MASTER cao hơn
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass <CHUOI_BIMAT>   # giống nhau 2 node
    }
    virtual_ipaddress {
        107.118.210.100/24
    }
    track_script {
        chk_nginx
    }
}
```

**ax-proxy02 (BACKUP)** `/etc/keepalived/keepalived.conf` — khác ax-proxy01 ở `state` (BACKUP) và `priority` (100):
```conf
vrrp_script chk_nginx {
    script "/etc/keepalived/check_nginx.sh"
    interval 2
    weight -40            # nginx chết -> giảm priority -> nhường VIP
    fall 2
    rise 2
}

vrrp_instance AX_PROXY {
    state BACKUP
    interface <WAN_IF>        # NIC dải 107.118.210.x
    virtual_router_id 51       # phải GIỐNG ax-proxy01
    priority 100               # thấp hơn ax-proxy01
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass <CHUOI_BIMAT>   # giống ax-proxy01
    }
    virtual_ipaddress {
        107.118.210.100/24
    }
    track_script {
        chk_nginx
    }
}
```

```bash
sudo systemctl enable --now keepalived
```

---

## 4.3 — Kiểm tra

```bash
# Trên ax-proxy01 phải thấy VIP:
ip a | grep 107.118.210.100        # xuất hiện trên ax-proxy01 (MASTER)

# Từ máy client (WAN):
curl -I http://107.118.210.100     # ra HTTP 200 từ web
```

---

## 4.4 — TEST FAILOVER (bắt buộc)

**1) Proxy chết -> VIP nhảy sang proxy còn lại:**
```bash
sudo systemctl stop keepalived      # trên ax-proxy01
# VIP 107.118.210.100 phải xuất hiện trên ax-proxy02 trong ~1-3s
ip a | grep 107.118.210.100           # kiểm tra trên ax-proxy02
curl -I http://107.118.210.100        # vẫn truy cập được
sudo systemctl start keepalived     # bật lại ax-proxy01 -> giành lại VIP (priority cao)
```

**2) Nginx chết (không phải cả VM) -> nhờ chk_nginx, VIP cũng nhường:**
```bash
sudo systemctl stop nginx           # trên node đang giữ VIP
# priority giảm -40 -> node kia thành MASTER, VIP chuyển sang
sudo systemctl start nginx
```

**3) Web chết -> Nginx tự loại khỏi pool:**
```bash
# Tắt IIS ax-web01 -> Nginx route hết về ax-web02, user không gián đoạn (max_fails/fail_timeout)
```

---

## Ghi chú quan trọng

1. **DNS:** tên miền trỏ vào **Proxy-VIP 107.118.210.100** (không trỏ IP proxy thật).
2. **Firewall proxy:** giai đoạn này chỉ mở **80** từ WAN (thêm 443 khi bật HTTPS ở 4.1b); chỉ proxy được phép gọi web qua LAN.
3. **Web (IIS):** chỉ mở port 80 cho 2 proxy (10.1.1.98/.99) qua LAN; KHÔNG expose ra WAN.
4. `virtual_router_id` (51) phải **duy nhất** trong mạng (tránh trùng nếu có cụm VRRP khác).
