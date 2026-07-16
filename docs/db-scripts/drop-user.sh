#!/usr/bin/env bash
# SAFE role/user drop: reassign owned objects to another owner (across all DBs) before DROP.
# Usage: ./drop-user.sh <user> [reassign_to]     (default reassign_to=dbadmin)
#   e.g.: ./drop-user.sh dev_a
#         ./drop-user.sh dev_a dbadmin
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

PROTECTED="postgres dbadmin useradmin replicator"

NAME="${1:-}"; [ -n "$NAME" ] || read -rp "User to drop: " NAME
REASSIGN_TO="${2:-dbadmin}"

# Guard: do not drop system/critical roles
for p in $PROTECTED; do
  [ "$NAME" = "$p" ] && die "DENIED: '$NAME' is a protected role, will not drop via this script."
done
role_exists "$NAME" || die "Role '$NAME' does not exist."
role_exists "$REASSIGN_TO" || die "Reassign target role '$REASSIGN_TO' does not exist."

echo "Will DROP role: $NAME"
echo "  - Reassign all owned objects -> $REASSIGN_TO (across ALL databases)"
echo "  - Revoke remaining privileges, then DROP ROLE"
confirm "Confirm dropping '$NAME'?" || { echo "Aborted."; exit 0; }

# REASSIGN + DROP OWNED must run within EACH database
DBS="$($PSQL -tAc "SELECT datname FROM pg_database WHERE datistemplate=false AND datallowconn")"
for db in $DBS; do
  echo "  [db: $db] reassign + drop owned ..."
  $PSQL -d "$db" -v u="$NAME" -v t="$REASSIGN_TO" <<'SQL' || true
REASSIGN OWNED BY :"u" TO :"t";
SQL
  $PSQL -d "$db" -v u="$NAME" <<'SQL' || true
DROP OWNED BY :"u";
SQL
done

$PSQL -v u="$NAME" <<'SQL'
DROP ROLE :"u";
SQL
echo ">> Dropped role: $NAME (objects reassigned to $REASSIGN_TO)"
