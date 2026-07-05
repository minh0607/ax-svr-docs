#!/usr/bin/env bash
# Pin a user so it can ONLY connect from specific IP(s) (one or more) — edits pg_hba.conf.
# Applies to DevDB / standalone PostgreSQL (pg_hba is a FILE).
# ----------------------------------------------------------------------------
# Usage:
#   ./bind-user-ip.sh <user> <ip1[,ip2,...]>     # pin user to the IP(s)
#   ./bind-user-ip.sh <user> --unpin             # unpin (user falls back to the general rule)
# Examples:
#   ./bind-user-ip.sh app_svc 10.1.1.101
#   ./bind-user-ip.sh dev_a   192.0.2.10,192.0.2.11
#   ./bind-user-ip.sh dev_a   --unpin
# ----------------------------------------------------------------------------
# PRODUCTION (Patroni): pg_hba is managed by Patroni -> do NOT edit the file.
#   Add the rule to patroni.yml under bootstrap.dcs.postgresql.pg_hba (or use
#   `patronictl edit-config`) then `patronictl reload`. See notes at end of file.
# ============================================================================
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

PG_VER="${PG_VER:-17}"
HBA="${HBA:-/etc/postgresql/$PG_VER/main/pg_hba.conf}"
PERUSER="$(dirname "$HBA")/pg_hba_peruser.conf"
INCLUDE_LINE="include_if_exists pg_hba_peruser.conf"

USER_NAME="${1:-}"; ACTION="${2:-}"
[ -n "$USER_NAME" ] && [ -n "$ACTION" ] || die "Usage: $0 <user> <ip1[,ip2]> | <user> --unpin"
[ -f "$HBA" ] || die "$HBA not found (set HBA=... if it differs)."
role_exists "$USER_NAME" || die "Role '$USER_NAME' does not exist."

# Backup pg_hba
sudo cp -a "$HBA" "$HBA.bak" 2>/dev/null || true
sudo touch "$PERUSER"
sudo chown --reference="$HBA" "$PERUSER" 2>/dev/null || true
sudo chmod 640 "$PERUSER" 2>/dev/null || true

# Make sure the include is at the TOP of pg_hba.conf (per-user rule has highest priority)
if ! grep -qxF "$INCLUDE_LINE" "$HBA"; then
  sudo sed -i "1i $INCLUDE_LINE" "$HBA"
  echo "  + added '$INCLUDE_LINE' to the top of $HBA"
fi

# Remove the user's old block (if any)
sudo sed -i "/^# >>> peruser:$USER_NAME$/,/^# <<< peruser:$USER_NAME$/d" "$PERUSER"

if [ "$ACTION" = "--unpin" ]; then
  echo ">> UNPINNED '$USER_NAME' — user falls back to the general rule."
else
  IPS="$ACTION"
  BLOCK="# >>> peruser:$USER_NAME"$'\n'
  IFS=',' read -ra arr <<< "$IPS"
  for ip in "${arr[@]}"; do
    case "$ip" in */*) ;; *) ip="$ip/32";; esac      # no mask -> /32
    BLOCK+="host    all    $USER_NAME    $ip    scram-sha-256"$'\n'
  done
  # deny the user from ALL other IPs (IPv4 + IPv6)
  BLOCK+="host    all    $USER_NAME    0.0.0.0/0    reject"$'\n'
  BLOCK+="host    all    $USER_NAME    ::0/0        reject"$'\n'
  BLOCK+="# <<< peruser:$USER_NAME"
  printf '%s\n' "$BLOCK" | sudo tee -a "$PERUSER" >/dev/null
  echo ">> PINNED '$USER_NAME' only from: $IPS (all other IPs rejected)."
fi

# Reload + check pg_hba syntax errors
$PSQL -c "SELECT pg_reload_conf();" >/dev/null
echo "--- Checking pg_hba errors (empty = OK) ---"
$PSQL -c "SELECT line_number, type, error FROM pg_hba_file_rules WHERE error IS NOT NULL;"
echo "--- Current rules for '$USER_NAME' ---"
$PSQL -tAc "SELECT type, address, auth_method FROM pg_hba_file_rules
            WHERE '$USER_NAME' = ANY(user_name) ORDER BY line_number;"
