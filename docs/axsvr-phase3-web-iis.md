# AX Svr — Phase 3: Web Server (Windows 2025 + IIS)

> Cấu hình IIS để phục vụ React (từ `D:\app` local — xem Phase 2), nhận traffic từ Nginx qua LAN.
> App/React do web engineer build; phần này là **cấu hình hạ tầng IIS** anh phụ trách.

```
Nginx (10.1.1.98/.99) ──HTTP──► IIS bind 10.1.1.101:80 / 10.1.1.102:80 (D:\app)
```

> TLS đã terminate ở Nginx → IIS chạy **HTTP nội bộ** trên LAN là đủ (không cần cert ở IIS).

---

## 3.1 — Chuẩn bị (nhắc lại từ Phase 0)

```powershell
Install-WindowsFeature -Name Web-Server -IncludeManagementTools
# Nếu backend là ASP.NET Core: cài thêm .NET Hosting Bundle (web engineer xác nhận)
```
Cài thêm **URL Rewrite Module** (cho SPA routing): tải từ Microsoft, hoặc qua Web Platform Installer.

---

## 3.2 — Tạo App Pool + Site (PowerShell)

```powershell
Import-Module WebAdministration

# Gỡ Default Web Site để khỏi chiếm port 80
Remove-Website -Name "Default Web Site" -ErrorAction SilentlyContinue

# App Pool
New-WebAppPool -Name "AXPool"
# React tĩnh -> "No Managed Code". ASP.NET Core in-process cũng để rỗng (hosting bundle lo).
Set-ItemProperty IIS:\AppPools\AXPool -Name managedRuntimeVersion -Value ""
Set-ItemProperty IIS:\AppPools\AXPool -Name autoStart -Value $true
Set-ItemProperty IIS:\AppPools\AXPool -Name startMode -Value "AlwaysRunning"   # giảm cold start

# Site: BIND CHỈ trên LAN IP, KHÔNG bind WAN. Chạy block tương ứng trên từng web:

# --- ax-web01 (10.1.1.101) ---
New-Website -Name "AXWeb" -PhysicalPath "D:\app" -ApplicationPool "AXPool" `
  -IPAddress "10.1.1.101" -Port 80

# --- ax-web02 (10.1.1.102) ---
New-Website -Name "AXWeb" -PhysicalPath "D:\app" -ApplicationPool "AXPool" `
  -IPAddress "10.1.1.102" -Port 80
```

> **Tuyệt đối không** thêm binding trên 107.118.210.x (WAN).

---

## 3.3 — web.config (SPA routing + bảo mật + cache)

Đặt `D:\app\web.config` (web engineer thường kèm sẵn — nếu chưa, dùng mẫu này):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.webServer>

    <!-- React SPA: mọi route không phải file/thư mục thật -> index.html -->
    <rewrite>
      <rules>
        <rule name="SPA Fallback" stopProcessing="true">
          <match url=".*" />
          <conditions logicalGrouping="MatchAll">
            <add input="{REQUEST_FILENAME}" matchType="IsFile"      negate="true" />
            <add input="{REQUEST_FILENAME}" matchType="IsDirectory" negate="true" />
            <add input="{REQUEST_URI}" pattern="^/api/" negate="true" />
          </conditions>
          <action type="Rewrite" url="/index.html" />
        </rule>
      </rules>
    </rewrite>

    <!-- Nén tĩnh -->
    <urlCompression doStaticCompression="true" doDynamicCompression="true" />

    <!-- Cache asset có hash (js/css/img); KHÔNG cache index.html -->
    <staticContent>
      <clientCache cacheControlMode="UseMaxAge" cacheControlMaxAge="365.00:00:00" />
    </staticContent>

    <httpProtocol>
      <customHeaders>
        <remove name="X-Powered-By" />
        <add name="X-Content-Type-Options" value="nosniff" />
      </customHeaders>
    </httpProtocol>

  </system.webServer>
</configuration>
```
> `index.html` không nên cache lâu — đặt header `no-cache` cho riêng nó (web engineer cấu hình build), nếu không user sẽ kẹt bản cũ sau deploy.

---

## 3.4 — Health endpoint cho Nginx

Để Nginx biết web sống/chết, tạo endpoint nhẹ:
```powershell
Set-Content -Path "D:\app\health.html" -Value "OK"
```
- Nginx (Phase 4) hiện dùng **passive check** (`max_fails`/`fail_timeout`) — đủ cho cơ bản.
- Nâng cao (active check): nếu dùng Nginx Plus hoặc module phụ, trỏ health check tới `/health.html`. Với Nginx open-source, có thể thêm script ngoài kiểm `http://10.1.1.101/health.html` rồi cảnh báo (xem Phase 6).

---

## 3.5 — Forwarded headers (QUAN TRỌNG cho backend)

TLS terminate ở Nginx nên IIS/app thấy request là HTTP. Để app biết **client thật + scheme HTTPS**:
- Nginx đã gửi `X-Forwarded-For`, `X-Forwarded-Proto`, `X-Real-IP` (Phase 4).
- **ASP.NET Core:** web engineer phải bật `ForwardedHeaders` middleware (`UseForwardedHeaders`) để `Request.Scheme=https` và IP client đúng. → **Dặn web engineer.**

---

## 3.6 — Kiểm tra

```powershell
# Trên chính web:
curl http://10.1.1.101/health.html        # OK
curl http://10.1.1.101/                    # ra index React

# Từ Proxy (LAN) tới cả 2 web:
curl http://10.1.1.101/ ; curl http://10.1.1.102/
```
Sau đó test qua VIP (Phase 4): `https://107.118.210.100` phải ra web, tắt 1 web → vẫn chạy.

---

## Checklist Phase 3

- [ ] IIS + URL Rewrite cài xong; Default Web Site đã gỡ
- [ ] App Pool AXPool (AlwaysRunning); site bind **chỉ LAN IP:80**
- [ ] Physical path = `D:\app` (local, không UNC)
- [ ] `web.config` SPA fallback + cache + security headers
- [ ] `health.html` trả OK
- [ ] Firewall chỉ cho proxy (.98/.99) gọi port 80
- [ ] Đã dặn web engineer bật ForwardedHeaders
- [ ] 2 web đồng nhất, test qua VIP OK
