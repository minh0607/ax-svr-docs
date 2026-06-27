#!/usr/bin/env bash
# Pin 1 user CHỈ kết nối được từ IP cụ thể — trên CỤM PATRONI (Production).
# pg_hba do Patroni quản lý trong DCS => cập nhật qua patronictl (KHÔNG sửa file).
# ----------------------------------------------------------------------------
# Chạy trên 1 DB node bất kỳ (patronictl nói chuyện với DCS chung).
# Dùng:
#   ./bind-user-ip-patroni.sh <user> <ip1[,ip2,...]>     # pin
#   ./bind-user-ip-patroni.sh <user> --unpin             # bỏ pin
# Ví dụ:
#   ./bind-user-ip-patroni.sh a 1.1.1.1
#   ./bind-user-ip-patroni.sh app_svc 10.1.1.101,10.1.1.102
# ============================================================================
set -euo pipefail

CONF="${PATRONI_CONF:-/etc/patroni/patroni.yml}"
PCTL="patronictl -c $CONF"

USER_NAME="${1:-}"; ACTION="${2:-}"
[ -n "$USER_NAME" ] && [ -n "$ACTION" ] || { echo "Dùng: $0 <user> <ip1[,ip2]> | <user> --unpin"; exit 1; }
command -v patronictl >/dev/null || { echo "LỖI: không thấy patronictl"; exit 1; }
python3 -c "import yaml" 2>/dev/null || { echo "LỖI: thiếu python3-yaml"; exit 1; }
[ -f "$CONF" ] || { echo "LỖI: không thấy $CONF"; exit 1; }

# Tên cluster (scope)
CLUSTER="$($PCTL list -f json 2>/dev/null | python3 -c 'import sys,json
d=json.load(sys.stdin)
print(d[0]["Cluster"] if d else "")' 2>/dev/null || true)"

CURRENT="$($PCTL show-config)"

# --- Manip pg_hba list bằng python ---
PYSCRIPT="$(mktemp)"
cat > "$PYSCRIPT" <<'PY'
import sys, yaml
user, action = sys.argv[1], sys.argv[2]
cfg = yaml.safe_load(sys.stdin) or {}
hba = (cfg.get('postgresql') or {}).get('pg_hba') or []

# An toàn: nếu DCS không có pg_hba thì DỪNG (tránh ghi đè mất rule gốc)
if not hba:
    sys.stderr.write("LỖI: DCS chưa có postgresql.pg_hba — dừng để tránh wipe rule gốc.\n"
                     "     Thêm pg_hba vào patroni.yml/DCS trước (xem Phase 1).\n")
    sys.exit(2)

start = "# >>> peruser:%s" % user
end   = "# <<< peruser:%s" % user

# bỏ block cũ của user
out, skip = [], False
for line in hba:
    if line == start: skip = True; continue
    if line == end:   skip = False; continue
    if not skip:      out.append(line)

if action != "--unpin":
    block = [start]
    for ip in action.split(','):
        ip = ip.strip()
        if '/' not in ip: ip += '/32'
        block.append("host all %s %s scram-sha-256" % (user, ip))
    block.append("host all %s 0.0.0.0/0 reject" % user)
    block.append("host all %s ::0/0 reject" % user)
    block.append(end)
    out = block + out    # đặt LÊN ĐẦU -> ưu tiên match trước rule chung

print(yaml.safe_dump({'postgresql': {'pg_hba': out}},
                     default_flow_style=False, sort_keys=False))
PY

PARTIAL="$(printf '%s' "$CURRENT" | python3 "$PYSCRIPT" "$USER_NAME" "$ACTION")" || { rm -f "$PYSCRIPT"; exit 2; }
rm -f "$PYSCRIPT"

echo "----- Sẽ áp postgresql.pg_hba (qua DCS) -----"
printf '%s\n' "$PARTIAL"

# Áp vào DCS + reload toàn cụm (thay đổi pg_hba chỉ cần reload, không restart)
printf '%s' "$PARTIAL" | $PCTL edit-config ${CLUSTER:+"$CLUSTER"} --apply - --force
$PCTL reload ${CLUSTER:+"$CLUSTER"} --force >/dev/null 2>&1 || true

echo ">> Đã cập nhật pg_hba per-user cho '$USER_NAME' trên CỤM Patroni."
echo "--- Rule của '$USER_NAME' trong DCS ---"
$PCTL show-config | python3 -c "import sys,yaml
h=(yaml.safe_load(sys.stdin) or {}).get('postgresql',{}).get('pg_hba',[]) or []
[print(x) for x in h if '$USER_NAME' in x]"
