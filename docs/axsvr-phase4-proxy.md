# AX Svr — Phase 4: Proxy HA (Nginx + Keepalived/VIP)

> 2 Nginx active-passive, dùng chung **Proxy-VIP 107.118.210.100** (WAN, user truy cập).
> Nginx terminate HTTPS, load balance về 2 IIS web qua LAN.

```
User --WAN--> 107.118.210.100 (VIP) --> Nginx Proxy1 .98 / Proxy2 .99
                                          | LAN
                                          v
                          IIS Web1 10.1.1.101:80 / Web2 10.1.1.102:80
```

| | WAN 107.118.210.x | LAN 10.1.1.x |
|---|---|---|
| Proxy 1 | .98 (MASTER) | .98 |
| Proxy 2 | .99 (BACKUP) | .99 |
| Proxy-VIP | **.100** | — |
| Web 1 (IIS) | .101 | .101 (nhận traffic) |
| Web 2 (IIS) | .102 | .102 (nhận traffic) |

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

## 4.1 — Nginx reverse proxy + load balancing (CẢ 2 proxy, file giống nhau)

`/etc/nginx/conf.d/ax-web.conf`:
```nginx
upstream ax_web_backend {
    least_conn;
    server 10.1.1.101:80 max_fails=3 fail_timeout=10s;
    server 10.1.1.102:80 max_fails=3 fail_timeout=10s;
    keepalive 32;
}

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

```bash
sudo nginx -t && sudo systemctl enable --now nginx
```

> Lưu ý: Nginx `listen 443` (mọi interface) — node nào giữ VIP thì nhận traffic. Không bind cứng vào IP VIP để node backup không lỗi khởi động.

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

**Proxy 1 (MASTER)** `/etc/keepalived/keepalived.conf`:
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

**Proxy 2 (BACKUP)** — chỉ khác `state` và `priority`:
```conf
vrrp_instance AX_PROXY {
    state BACKUP
    interface <WAN_IF>
    virtual_router_id 51       # phải GIỐNG proxy1
    priority 100               # thấp hơn
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass <CHUOI_BIMAT>
    }
    virtual_ipaddress {
        107.118.210.100/24
    }
    track_script {
        chk_nginx
    }
}
```
(phần `vrrp_script chk_nginx { ... }` copy y hệt proxy1)

```bash
sudo systemctl enable --now keepalived
```

---

## 4.3 — Kiểm tra

```bash
# Trên Proxy1 phải thấy VIP:
ip a | grep 107.118.210.100        # xuất hiện trên proxy1 (MASTER)

# Từ máy client (WAN):
curl -kI https://107.118.210.100   # ra HTTP 200/301 từ web
```

---

## 4.4 — TEST FAILOVER (bắt buộc)

**1) Proxy chết -> VIP nhảy sang proxy còn lại:**
```bash
sudo systemctl stop keepalived      # trên Proxy1
# VIP 107.118.210.100 phải xuất hiện trên Proxy2 trong ~1-3s
ip a | grep 107.118.210.100           # kiểm tra trên Proxy2
curl -kI https://107.118.210.100      # vẫn truy cập được
sudo systemctl start keepalived     # bật lại Proxy1 -> giành lại VIP (priority cao)
```

**2) Nginx chết (không phải cả VM) -> nhờ chk_nginx, VIP cũng nhường:**
```bash
sudo systemctl stop nginx           # trên node đang giữ VIP
# priority giảm -40 -> node kia thành MASTER, VIP chuyển sang
sudo systemctl start nginx
```

**3) Web chết -> Nginx tự loại khỏi pool:**
```bash
# Tắt IIS Web1 -> Nginx route hết về Web2, user không gián đoạn (max_fails/fail_timeout)
```

---

## Ghi chú quan trọng

1. **DNS:** tên miền trỏ vào **Proxy-VIP 107.118.210.100** (không trỏ IP proxy thật).
2. **Firewall proxy:** mở 80/443 từ WAN; chỉ proxy được phép gọi web qua LAN.
3. **Web (IIS):** chỉ mở port 80 cho 2 proxy (10.1.1.98/.99) qua LAN; KHÔNG expose ra WAN.
4. `virtual_router_id` (51) phải **duy nhất** trong mạng (tránh trùng nếu có cụm VRRP khác).
