# Runbook: monitor Keepalived / VIP (Zabbix) — báo switch, rớt proxy, ai giữ VIP

> Mục tiêu:
> 1. **Mỗi lần VIP chuyển proxy (failover) → báo** (kèm tên proxy mới đang active).
> 2. **Rớt 1 proxy → báo.**
> 3. **Biết proxy nào đang handle VIP** (live trên dashboard).
>
> VIP = **`107.118.210.100`** (office-net, mặt user) · Proxy: **ax-proxy01** `.98` · **ax-proxy02** `.99`.
> Không có template Keepalived chính thức → tự tạo UserParameter + item + trigger.

---

## 1. UserParameter — trên CẢ 2 proxy
`/etc/zabbix/zabbix_agent2.d/keepalived.conf`:
```
UserParameter=vip.holder,ip addr show | grep -q "107.118.210.100/" && echo 1 || echo 0
UserParameter=keepalived.proc,pgrep -c keepalived
```
```bash
sudo systemctl restart zabbix-agent2
zabbix_agent2 -t vip.holder        # proxy đang giữ VIP -> 1, proxy kia -> 0
zabbix_agent2 -t keepalived.proc   # >=1 (0 = keepalived chết)
```
- `vip.holder` = **1** ở proxy nào → proxy đó **đang ACTIVE** (giữ VIP).
- `keepalived.proc` = số tiến trình keepalived.

---

## 2. Item — tạo trên MỖI proxy (AX-Proxy01 và AX-Proxy02)
Data collection → Hosts → (proxy) → Items → **Create item** (2 item/proxy):

| Field | Item A | Item B |
|---|---|---|
| Name | `Keepalived: VIP holder` | `Keepalived: process count` |
| Key | `vip.holder` | `keepalived.proc` |
| Type | Zabbix agent | Zabbix agent |
| Type of information | Numeric (unsigned) | Numeric (unsigned) |
| Update interval | **`30s`** *(bắt kịp failover nhanh)* | `1m` |

> Để `vip.holder` interval **30s** — nếu 1m, một cú failover-rồi-failback nhanh có thể lọt giữa 2 lần poll → miss.

---

## 3. Trigger

### 3a. Mỗi lần switch → báo (kèm ai đang active) — **1 trigger/proxy**
Tạo trên từng proxy (đổi host tương ứng):
```
change(/AX-Proxy01/vip.holder)=1
```
- `change()` = giá trị mới − cũ; `=1` nghĩa `0→1` = **proxy này VỪA nhận VIP** = có failover.
- Name: `VIP acquired by {HOST.NAME}` · Severity: **Warning** (hoặc Info).
- **Tag:** `service:keepalived`.
- Cấu hình sự kiện (để mỗi lần switch = 1 event rõ ràng, không tự biến mất):
  - **OK event generation: None**
  - **Allow manual close: Yes**
  → mỗi lần chuyển VIP tạo 1 problem "VIP acquired by AX-ProxyXX", nằm đó tới khi anh ack. Thông báo cho biết **switch vừa xảy ra + ai đang giữ**.

> Nếu muốn gọn hơn (không sticky), bỏ 2 tuỳ chọn trên → problem tự resolve sau 1 chu kỳ (anh vẫn nhận thông báo Problem). Chọn 1 trong 2 kiểu.

### 3b. Rớt proxy → báo
Trên mỗi proxy:
```
last(/AX-Proxy01/keepalived.proc)=0
```
- Name: `Keepalived DOWN on {HOST.NAME}` · Severity: **High** · duration ~2m (thêm `and ...` hoặc dùng recovery mặc định). Tag `service:keepalived`.

Backstop (proxy tắt hẳn, agent không phản hồi) — 1 trigger/proxy:
```
nodata(/AX-Proxy01/agent.ping,3m)=1
```
- Name: `Proxy unreachable — {HOST.NAME}` · Severity: **High**.

### 3c. Split-brain (cả 2 cùng giữ VIP) — 1 trigger chung
```
last(/AX-Proxy01/vip.holder)=1 and last(/AX-Proxy02/vip.holder)=1
```
- Name: `VIP SPLIT-BRAIN — both proxies hold 107.118.210.100` · Severity: **High**. Tag `service:keepalived`.

### 3d. Không ai giữ VIP → báo — 1 trigger chung
```
last(/AX-Proxy01/vip.holder)=0 and last(/AX-Proxy02/vip.holder)=0
```
- Name: `VIP DOWN — no proxy holds 107.118.210.100` · Severity: **Disaster**.
- Kèm (độc lập): host **AX-Web-VIP** (IP `107.118.210.100`) gắn template **"ICMP Ping"** → trigger `max(/AX-Web-VIP/icmpping,#3)=0` = VIP thật sự chết.

---

## 4. "Proxy nào đang handle VIP" — xem live
- **Dashboard nginx** (`grafana-ax-nginx-cluster.json`) đã có panel **WHO IS ACTIVE** đọc `vip.holder` → tile proxy = 1 sáng lên.
- Ngoài ra event "VIP acquired by AX-ProxyXX" (3a) trong Problems/SOC wall cho biết **holder hiện tại** ngay lúc chuyển.

---

## 5. Gửi thông báo (email/Telegram…) khi switch/rớt
Alerting → Actions → Trigger actions: điều kiện **Tag = `service:keepalived`** (hoặc severity ≥ Warning) → gửi tới media của anh. Nhờ tag chung, cả 4 loại trigger trên đi cùng 1 action.

---

## 6. Verify (diễn tập failover)
```bash
# trên proxy đang ACTIVE:
sudo systemctl stop keepalived
```
Kỳ vọng trong ≤30-60s:
1. VIP nhảy sang proxy kia (`ip addr show | grep 107.118.210.100` ở proxy kia).
2. `vip.holder` đảo 0↔1 → trigger **3a** "VIP acquired by <proxy kia>" nổ.
3. Trigger **3b** "Keepalived DOWN on <proxy vừa stop>" nổ.
4. `sudo systemctl start keepalived` → về bình thường; ack các event.

> Diễn tập ngoài giờ cao điểm vì VIP chuyển sẽ ngắt kết nối user đang mở trong tích tắc.
