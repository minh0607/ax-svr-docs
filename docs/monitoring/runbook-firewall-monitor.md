# Runbook: monitor trạng thái firewall (ufw / Windows Firewall) qua Zabbix

> Mục tiêu: biết **máy nào firewall đang tắt** (ufw disable / Windows Firewall off) → cảnh báo lên SOC wall.
> Template OS base KHÔNG có sẵn chỉ số này → thêm UserParameter + item + trigger.
> Linux: AX-DB01/02/03, NAS, Proxy01/02 · Windows: WEB01/02.

Quy ước giá trị: **1 = firewall BẬT (an toàn)** · **0 = TẮT (cảnh báo)** — đồng nhất để panel tô màu green/red.

---

## 1. Linux — ufw
`ufw status` cần root. Không chạy agent bằng root → **sudoers hẹp** (đúng mô hình least-privilege, giống cách làm Samba `smbstatus`).

**a. UserParameter** — `/etc/zabbix/zabbix_agent2.d/ufw.conf`:
```
UserParameter=ufw.enabled,sudo /usr/sbin/ufw status 2>/dev/null | grep -q "Status: active" && echo 1 || echo 0
```

**b. sudoers** — tạo bằng `sudo visudo -f /etc/sudoers.d/zabbix-ufw`:
```
zabbix ALL=(root) NOPASSWD: /usr/sbin/ufw status
```

**c. Restart + test:**
```bash
sudo systemctl restart zabbix-agent2
zabbix_agent2 -t ufw.enabled        # phải ra 1 (đang active) hoặc 0
```

> **Không muốn dùng sudo?** đọc file config (không phản ánh runtime tức thời nhưng đủ dùng):
> `UserParameter=ufw.enabled,grep -q '^ENABLED=yes' /etc/ufw/ufw.conf && echo 1 || echo 0`
> (`/etc/ufw/ufw.conf` 0644 → zabbix đọc được; `ufw enable/disable` có cập nhật `ENABLED`.)

---

## 2. Windows — Windows Firewall / wf.msc (WEB01/02)
**a. UserParameter** — `C:\Program Files\Zabbix Agent 2\zabbix_agent2.d\firewall.conf`
(hoặc thêm thẳng vào `zabbix_agent2.conf`; đảm bảo có `Include=...\zabbix_agent2.d\*.conf`):
```
UserParameter=win.firewall.enabled,powershell -NoProfile -NonInteractive -Command "if(@(Get-NetFirewallProfile | Where-Object {-not $_.Enabled}).Count -eq 0){1}else{0}"
```
Trả 1 nếu **cả 3 profile** (Domain/Private/Public) đều bật; 0 nếu có bất kỳ profile tắt.

> `Get-NetFirewallProfile` đọc đúng profile của **Windows Firewall (wf.msc)** — KHÔNG phải Microsoft Defender Antivirus (khác hẳn).

**b. Timeout:** PowerShell khởi động chậm → trong `zabbix_agent2.conf` đặt `Timeout=10` (mặc định 3s dễ bị timeout). Restart:
```powershell
Restart-Service "Zabbix Agent 2"
```
**c. Test:** `& "C:\Program Files\Zabbix Agent 2\zabbix_agent2.exe" -t win.firewall.enabled`

> Muốn chi tiết từng profile: tạo thêm 3 item với `... Where-Object {$_.Name -eq 'Public' -and $_.Enabled}` v.v. Bản 1-item ở trên đủ cho cảnh báo tổng.

---

## 3. Cách nhanh — import template rồi link (khuyên dùng)
Import **`zbx-template-firewall.yaml`** (gồm 2 template):
1. Data collection → **Templates → Import** → chọn file → Import.
2. Link:
   - **"Firewall Monitor Template for Ubuntu"** → AX-DB01/02/03, NAS, Proxy01/02.
   - **"Firewall Monitor Template for Windows"** → WEB01/02.
3. Vẫn cần **UserParameter + sudoers/Timeout** ở mục 1-2 trên từng agent (template chỉ định nghĩa item/trigger, không đẩy config agent).

Mỗi template gồm: item `Firewall status (...)` (1m, value-map **1=ON / 0=OFF**) + trigger **Firewall DISABLED on {HOST.NAME}** (`=0`, High, tag `service:security`).

> Muốn tạo tay thì theo mục 3b + 4 dưới.

## 3b. Zabbix — item + trigger (tạo tay)
Data collection → Hosts → (từng host) → **Items → Create item:**

| Field | Linux | Windows |
|---|---|---|
| **Name** | `Firewall status (ufw)` | `Firewall status (Windows Firewall)` |
| Key | `ufw.enabled` | `win.firewall.enabled` |
| Type | Zabbix agent | Zabbix agent |
| Type of information | Numeric (unsigned) | Numeric (unsigned) |
| Update interval | `1m` | `1m` |

> **Đặt Name có chữ "Firewall status"** như trên — panel Grafana (mục 4) lọc item theo tên `/Firewall status/`.

*(3 DB + NAS + 2 Proxy dùng chung key Linux; 2 WEB dùng key Windows — nên tạo ở **host-level** hoặc gom vào 1 template nhỏ rồi link cho gọn.)*

**Trigger** (Create trigger, mỗi loại 1 cái — hoặc trigger prototype nếu dùng template):
```
# Linux
last(/{HOST}/ufw.enabled)=0            -> "Firewall DISABLED (ufw) on {HOST.NAME}"
# Windows
last(/{HOST}/win.firewall.enabled)=0   -> "Firewall DISABLED (Windows Firewall) on {HOST.NAME}"
```
- Severity: **High** (hoặc Disaster nếu coi là nghiêm trọng).
- **Tags:** `service:security` → khớp SOC wall (Problems panel) để drill-down.

---

## 4. Grafana (tuỳ chọn) — panel "Firewall status"
Trên **SOC wall** (và linux/windows detail) thêm panel **Stat**, datasource Zabbix:
- Linux: item filter `ufw.enabled`, host `/AX-(DB|NAS|Proxy)/`.
- Windows: item filter `win.firewall.enabled`, host `/AX-WEB/`.
- **Value mappings:** `1 → ON` (green), `0 → OFF` (red); `colorMode: background`.

Cảnh báo thực (đèn đỏ + Problems) đã do **trigger** ở mục 3 lo; panel Stat chỉ để nhìn nhanh ai đang ON/OFF.

---

## Verify tổng
1. `zabbix_agent2 -t ufw.enabled` / `-t win.firewall.enabled` ra 0/1.
2. Zabbix **Monitoring → Latest data**: item có giá trị (khác "No data").
3. Thử `sudo ufw disable` trên 1 máy test → sau ≤1m item về 0 + trigger nổ + SOC wall đỏ → `sudo ufw enable` lại.
