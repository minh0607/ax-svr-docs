# Runbook: cho admin (DBA) nối trực tiếp PostgreSQL Production

> Mục tiêu: DBA nối thẳng DB từ workstation trên **office-net `107.118.210.x`** (psql/DBeaver/pgAdmin), vẫn giữ least-privilege.
> Áp cho **ax-db01/02/03**. Phần `listen` + firewall làm **trên từng node**; phần SQL/pg_hba làm trên **Leader** (tự replicate / hoặc lặp theo hướng dẫn).
> Bối cảnh mạng: `107.118.210.x` = mạng nội bộ công ty (user + admin, **không internet**); `10.1.1.x` = mạng backend giữa server (app↔DB, replication, etcd).

Hiện trạng: `listen_addresses = 10.1.1.103` (chỉ IP LAN backend) → workstation office-net **không** nối được, `psql -h localhost` cũng **refused**. Runbook này thêm `127.0.0.1` + IP office-net vào listener, rồi siết 3 lớp.

---

## Mô hình 3 lớp (nhắc lại)
`ufw` (IP nguồn) → `pg_hba` (mật khẩu + ghim IP) → `GRANT` (quyền). Với hướng bind office-net, **pg_hba là "cổng thật"**, ufw là lớp phụ.

Ký hiệu: `<DBA_IP>` = IP workstation của DBA · IP node: db01 `.103`, db02 `.104`, db03 `.105` (cùng octet trên cả 2 dải).

DBA mẫu (điền theo thực tế): `107.118.67.122`, `107.118.84.37`. Hai IP này ở **subnet khác** với NIC office-net của DB node (`107.118.210.103`) — mạng công ty có định tuyến giữa các subnet nên `ufw allow from <ip>` + pg_hba ghim đúng IP vẫn hoạt động xuyên subnet.

---

## 1. Mở listener: local + LAN + office-net — sửa qua Patroni (KHÔNG sửa postgresql.conf)

`listen_addresses` do Patroni render từ `/etc/patroni/patroni.yml`; sửa tay `postgresql.conf` sẽ bị ghi đè.

**Trên mỗi node**, sửa `/etc/patroni/patroni.yml`:
```yaml
postgresql:
  listen: 127.0.0.1,10.1.1.103,107.118.210.103:5432   # ax-db01; db02→.104; db03→.105
  connect_address: 10.1.1.103:5432                      # GIỮ NGUYÊN IP LAN backend (replication quảng bá qua đây)
```
> `connect_address` để nguyên IP `10.1.1.x` — đây là địa chỉ các node khác dùng để nối tới node này; đổi sang office-net sẽ làm replication đi nhầm dải.

## 2. Rolling restart (đổi `listen_addresses` cần RESTART, không phải reload)
Leader hiện tại = **ax-db01**. Replica trước, leader sau.
```bash
sudo systemctl reload patroni      # mỗi node: nạp config, gắn cờ "pending restart"

# replica trước (async rồi sync)
sudo patronictl -c /etc/patroni/patroni.yml restart ax-db-cluster ax-db03
sudo patronictl -c /etc/patroni/patroni.yml restart ax-db-cluster ax-db02

# leader: switchover đi rồi restart, xong đưa về
sudo patronictl -c /etc/patroni/patroni.yml switchover ax-db-cluster   # db01 → db02
sudo patronictl -c /etc/patroni/patroni.yml restart   ax-db-cluster ax-db01
sudo patronictl -c /etc/patroni/patroni.yml switchover ax-db-cluster   # db02 → db01
```
**Verify:** `sudo ss -tlnp | grep 5432` → phải thấy `127.0.0.1:5432`, `10.1.1.103:5432`, `107.118.210.103:5432` (KHÔNG có `0.0.0.0`).

## 3. Firewall — chỉ mở 5432 office-net cho ĐÚNG IP DBA (không mở cả /24)
Dùng generator (xem `docs/firewall/gen-firewall.sh`):
```bash
ZBX_PROXY=10.1.1.96 GRAFANA_IP=<grafana_ip> ADMIN_DB_IPS=107.118.67.122,107.118.84.37 \
  ./gen-firewall.sh db ax-db01                 # review
# ...--apply để chạy, hoặc --no-reset khi sửa live (tránh khe hở lúc reset)
```
Dòng sinh ra: `ufw allow from 107.118.67.122 to any port 5432 proto tcp comment 'DBA workstation'` (mỗi DBA 1 dòng). Dải `10.1.1.x` vẫn chỉ web + peer + monitor.

> ⚠️ **Không `ufw reset` trên DB node đang chạy** khi đã bind office-net: giữa reset↔enable có khe hở vài giây. Sửa từng rule (`ufw allow/delete`) hoặc dùng `--no-reset`.

## 4. Tạo role per-người + ghim IP + scram-sha-256 (chạy trên Leader)
Tạo role **riêng cho từng DBA** (để pgAudit truy ai làm gì), ở **đúng mức quyền cần** — đừng mặc định superuser:

| Nhu cầu | Lệnh | Ghi chú |
|---|---|---|
| Full DBA (superuser) | `axdb.sh create-admin <dba>` | ⚠️ tăng superuser-count → dashboard Security cảnh báo; chỉ cho người thực sự cần |
| Quản role/DB, không super | `axdb.sh create-user-admin <dba>` | CREATEROLE + CREATEDB |
| Thao tác trong 1-2 schema | `axdb.sh create-user <dba> <group>` | least-privilege, gắn group sẵn |

```bash
sudo -u postgres bash axdb.sh create-user-admin <dba>            # ví dụ mức không-superuser
sudo -u postgres bash axdb.sh bind-ip <dba> 107.118.67.122       # ghim đúng IP workstation
```
`bind-ip` tự viết block pg_hba per-user qua Patroni DCS. **Tuyệt đối không** để dòng `0.0.0.0/0`.
Kiểm: `sudo -u postgres psql -c "SELECT type,database,user_name,address,auth_method FROM pg_hba_file_rules WHERE user_name @> ARRAY['<dba>'];"`

## 5. Nguyên tắc quyền
Không dùng `postgres` gốc (khóa local-only); **không share `dbadmin`** — mỗi người 1 role riêng để pgAudit (`role`/`ddl`) truy được. Giữ số superuser tối thiểu (`postgres` + `dbadmin`); DBA thường nên là non-superuser (mục 4).

---

## Cách DBA nối (sau khi lắp xong)
```bash
# nối thẳng tới primary bất kể leader ở node nào:
psql "host=107.118.210.103,107.118.210.104,107.118.210.105 port=5432 \
      target_session_attrs=read-write user=<dba_user> dbname=AXDB"
```
DBeaver/pgAdmin: khai 3 host trên + `targetServerType/target_session_attrs=read-write`.

**Lựa chọn nhẹ hơn (không cần bind office-net):** SSH tunnel — DBeaver/pgAdmin có sẵn tab SSH tunnel (SSH host = `107.118.210.103`, DB host = `127.0.0.1:5432`). Dùng khi không muốn mở thêm listener.

---

## Rollback
```bash
# gỡ listener office-net: sửa patroni.yml về  listen: 127.0.0.1,10.1.1.103:5432  -> rolling restart lại (mục 2)
# gỡ firewall:  sudo ufw delete allow from 107.118.67.122 to any port 5432 proto tcp
# gỡ ghim IP:   sudo -u postgres bash axdb.sh bind-ip <dba> --unpin
# gỡ role:      sudo -u postgres psql -c "DROP ROLE <dba>;"   (trên Leader)
```
