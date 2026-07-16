#!/usr/bin/env bash
# List roles / databases / privileges — to check who has what.
# Usage:
#   ./list-access.sh roles            # list roles + attributes
#   ./list-access.sh dbs              # list databases
#   ./list-access.sh members <group>  # members of a group role
#   ./list-access.sh grants <db>      # table privileges in a db (\dp)
#   ./list-access.sh perm <db> [user]  # permission overview (summary; or per-table drill-down for a user)
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
  perm)
    DB="${2:-}"; [ -n "$DB" ] || die "Missing db name."
    db_exists "$DB" || die "Database '$DB' does not exist."
    USER_ARG="${3:-}"
    if [ -z "$USER_ARG" ]; then
      # Level 1: summary of all login users
      $PSQL -d "$DB" <<'SQL'
SELECT r.rolname AS role,
       CASE WHEN r.rolsuper THEN 't' ELSE 'f' END AS super,
       COALESCE(string_agg(DISTINCT g.rolname, ', ' ORDER BY g.rolname), '(none)') AS groups,
       COALESCE(string_agg(DISTINCT
         CASE
           WHEN g.rolname LIKE '%\_readwrite' THEN regexp_replace(g.rolname,'_readwrite$','')||': RW'
           WHEN g.rolname LIKE '%\_readonly'  THEN regexp_replace(g.rolname,'_readonly$','') ||': RO'
         END, ', '), CASE WHEN r.rolsuper THEN 'ALL' ELSE '-' END) AS schema_access
FROM pg_roles r
LEFT JOIN pg_auth_members m ON m.member = r.oid
LEFT JOIN pg_roles g ON g.oid = m.roleid
WHERE r.rolcanlogin AND r.rolname NOT LIKE 'pg\_%'
GROUP BY r.rolname, r.rolsuper
ORDER BY r.rolsuper DESC, r.rolname;
SQL
    else
      # Level 2: effective per-table privileges for one user (incl. inherited via groups)
      role_exists "$USER_ARG" || die "Role '$USER_ARG' does not exist."
      $PSQL -d "$DB" -v u="$USER_ARG" <<'SQL'
SELECT n.nspname AS schema, c.relname AS "table",
       array_to_string(ARRAY[
         CASE WHEN has_table_privilege(:'u', c.oid, 'SELECT') THEN 'SELECT' END,
         CASE WHEN has_table_privilege(:'u', c.oid, 'INSERT') THEN 'INSERT' END,
         CASE WHEN has_table_privilege(:'u', c.oid, 'UPDATE') THEN 'UPDATE' END,
         CASE WHEN has_table_privilege(:'u', c.oid, 'DELETE') THEN 'DELETE' END
       ], ',') AS privileges
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog','information_schema')
  AND (has_table_privilege(:'u', c.oid,'SELECT') OR has_table_privilege(:'u', c.oid,'INSERT')
    OR has_table_privilege(:'u', c.oid,'UPDATE') OR has_table_privilege(:'u', c.oid,'DELETE'))
ORDER BY 1,2;
SQL
    fi
    ;;
  *) die "Invalid command. See the usage at the top of this file.";;
esac
