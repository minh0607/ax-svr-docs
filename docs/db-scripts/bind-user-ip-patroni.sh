#!/usr/bin/env bash
# Pin a user so it can ONLY connect from specific IP(s) — on a PATRONI CLUSTER (Production).
# pg_hba is managed by Patroni in the DCS => update via patronictl (do NOT edit the file).
# ----------------------------------------------------------------------------
# Run on any DB node (patronictl talks to the shared DCS).
# Usage:
#   ./bind-user-ip-patroni.sh <user> <ip1[,ip2,...]>     # pin
#   ./bind-user-ip-patroni.sh <user> --unpin             # unpin
# Examples:
#   ./bind-user-ip-patroni.sh a 1.1.1.1
#   ./bind-user-ip-patroni.sh app_svc 10.1.1.101,10.1.1.102
# ============================================================================
set -euo pipefail

CONF="${PATRONI_CONF:-/etc/patroni/patroni.yml}"
PCTL="patronictl -c $CONF"

USER_NAME="${1:-}"; ACTION="${2:-}"
[ -n "$USER_NAME" ] && [ -n "$ACTION" ] || { echo "Usage: $0 <user> <ip1[,ip2]> | <user> --unpin"; exit 1; }
command -v patronictl >/dev/null || { echo "ERROR: patronictl not found"; exit 1; }
python3 -c "import yaml" 2>/dev/null || { echo "ERROR: python3-yaml is missing"; exit 1; }
[ -f "$CONF" ] || { echo "ERROR: $CONF not found"; exit 1; }

# Cluster name (scope)
CLUSTER="$($PCTL list -f json 2>/dev/null | python3 -c 'import sys,json
d=json.load(sys.stdin)
print(d[0]["Cluster"] if d else "")' 2>/dev/null || true)"

CURRENT="$($PCTL show-config)"

# --- Manipulate the pg_hba list with python ---
PYSCRIPT="$(mktemp)"
cat > "$PYSCRIPT" <<'PY'
import sys, yaml
user, action = sys.argv[1], sys.argv[2]
cfg = yaml.safe_load(sys.stdin) or {}
hba = (cfg.get('postgresql') or {}).get('pg_hba') or []

# Safety: if the DCS has no pg_hba, STOP (avoid overwriting and losing the original rules)
if not hba:
    sys.stderr.write("ERROR: DCS has no postgresql.pg_hba yet — stopping to avoid wiping the original rules.\n"
                     "     Add pg_hba to patroni.yml/DCS first (see Phase 1).\n")
    sys.exit(2)

start = "# >>> peruser:%s" % user
end   = "# <<< peruser:%s" % user

# remove the user's old block
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
    out = block + out    # put it at the TOP -> matches before the general rule

print(yaml.safe_dump({'postgresql': {'pg_hba': out}},
                     default_flow_style=False, sort_keys=False))
PY

PARTIAL="$(printf '%s' "$CURRENT" | python3 "$PYSCRIPT" "$USER_NAME" "$ACTION")" || { rm -f "$PYSCRIPT"; exit 2; }
rm -f "$PYSCRIPT"

echo "----- Will apply postgresql.pg_hba (via DCS) -----"
printf '%s\n' "$PARTIAL"

# Apply to DCS + reload the whole cluster (pg_hba changes only need reload, not restart)
printf '%s' "$PARTIAL" | $PCTL edit-config ${CLUSTER:+"$CLUSTER"} --apply - --force
$PCTL reload ${CLUSTER:+"$CLUSTER"} --force >/dev/null 2>&1 || true

echo ">> Updated per-user pg_hba for '$USER_NAME' on the Patroni CLUSTER."
echo "--- Rules for '$USER_NAME' in the DCS ---"
$PCTL show-config | python3 -c "import sys,yaml
h=(yaml.safe_load(sys.stdin) or {}).get('postgresql',{}).get('pg_hba',[]) or []
[print(x) for x in h if '$USER_NAME' in x]"
