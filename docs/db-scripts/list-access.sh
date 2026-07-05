#!/usr/bin/env bash
# List roles / databases / privileges — to check who has what.
# Usage:
#   ./list-access.sh roles            # list roles + attributes
#   ./list-access.sh dbs              # list databases
#   ./list-access.sh members <group>  # members of a group role
#   ./list-access.sh grants <db>      # table privileges in a db (\dp)
source "$(cd "$(dirname "$0")" && pwd)/_common.sh"

CMD="${1:-roles}"
case "$CMD" in
  roles) $PSQL -c "\du" ;;
  dbs)   $PSQL -c "\l" ;;
  members)
    G="${2:-}"; [ -n "$G" ] || die "Missing group name."
    $PSQL -v g="$G" -tA <<'SQL'
SELECT m.rolname FROM pg_auth_members am
JOIN pg_roles g ON g.oid=am.roleid
JOIN pg_roles m ON m.oid=am.member
WHERE g.rolname=:'g' ORDER BY 1;
SQL
    ;;
  grants)
    DB="${2:-}"; [ -n "$DB" ] || die "Missing db name."
    db_exists "$DB" || die "Database '$DB' does not exist."
    $PSQL -d "$DB" -c "\dp"
    ;;
  *) die "Invalid command. See the usage at the top of this file.";;
esac
