#!/usr/bin/env bash
# ============================================================================
# axdb.sh — MASTER PostgreSQL administration script (AX Svr). Self-contained.
# Combines: create admin/user/db, group roles, privileges, password change, safe drop, IP pinning.
# ----------------------------------------------------------------------------
# Admin connection:
#   - Default: run on the DB server, use socket as 'postgres'.
#   - Remote:  export PSQL_ADMIN="psql -h 107.118.210.90 -U dbadmin"
# Usage: ./axdb.sh <command> [args]   |   ./axdb.sh help
# Note: SQL with variables is passed via STDIN (heredoc) because `psql -c` does NOT interpolate :var.
# ============================================================================
set -euo pipefail

PSQL_ADMIN="${PSQL_ADMIN:-sudo -u postgres psql}"
PSQL="$PSQL_ADMIN -v ON_ERROR_STOP=1 -X -q"
PROTECTED_ROLES="postgres dbadmin useradmin replicator"
PROTECTED_DBS="postgres template0 template1"

# ---------- helpers ----------
die()  { echo "ERROR: $*" >&2; exit 1; }
confirm() { local a; read -rp "$1 [y/N]: " a; [ "$a" = y ] || [ "$a" = Y ]; }
prompt_pw() { local v; read -rsp "$1: " v; echo >&2; printf '%s' "$v"; }
role_exists() { [ "$($PSQL -tAc "SELECT 1 FROM pg_roles    WHERE rolname='$1'" 2>/dev/null)" = "1" ]; }
db_exists()   { [ "$($PSQL -tAc "SELECT 1 FROM pg_database WHERE datname='$1'" 2>/dev/null)" = "1" ]; }
is_protected_role() { for p in $PROTECTED_ROLES; do [ "$1" = "$p" ] && return 0; done; return 1; }

# ---------- commands ----------
cmd_create_admin() {            # <name>
  local n="${1:-}"; [ -n "$n" ] || read -rp "DB admin name (e.g. dbadmin): " n
  [ "$n" = postgres ] && die "Do not use the name 'postgres'."
  role_exists "$n" && die "Role '$n' already exists."
  local pw; pw="$(prompt_pw "Password for $n")"; [ -n "$pw" ] || die "Empty password."
  $PSQL -v n="$n" -v pw="$pw" <<'SQL'
CREATE ROLE :"n" LOGIN SUPERUSER CREATEDB CREATEROLE PASSWORD :'pw';
SQL
  echo ">> Created DB ADMIN (SUPERUSER): $n"
}

cmd_create_user_admin() {       # <name>
  local n="${1:-}"; [ -n "$n" ] || read -rp "User admin name: " n
  role_exists "$n" && die "Role '$n' already exists."
  local pw; pw="$(prompt_pw "Password for $n")"; [ -n "$pw" ] || die "Empty password."
  $PSQL -v n="$n" -v pw="$pw" <<'SQL'
CREATE ROLE :"n" LOGIN CREATEROLE CREATEDB PASSWORD :'pw';
SQL
  echo ">> Created USER ADMIN (CREATEROLE+CREATEDB, not superuser): $n"
}

cmd_create_user() {             # <user> [group]
  local n="${1:-}" g="${2:-}"; [ -n "$n" ] || read -rp "User name: " n
  role_exists "$n" && die "Role '$n' already exists."
  local pw; pw="$(prompt_pw "Password for $n")"; [ -n "$pw" ] || die "Empty password."
  $PSQL -v n="$n" -v pw="$pw" <<'SQL'
CREATE ROLE :"n" LOGIN PASSWORD :'pw';
SQL
  echo ">> Created user: $n"
  if [ -n "$g" ]; then
    role_exists "$g" || die "Group '$g' does not exist."
    $PSQL -v n="$n" -v g="$g" <<'SQL'
GRANT :"g" TO :"n";
SQL
    echo ">> Added $n to group $g"
  fi
}

cmd_create_db() {               # <db> [owner]
  local d="${1:-}" o="${2:-}"
  [ -n "$d" ] || read -rp "Database name: " d
  [ -n "$o" ] || read -rp "Owner: " o
  db_exists "$d" && die "Database '$d' already exists."
  role_exists "$o" || die "Owner '$o' does not exist."
  $PSQL -v d="$d" -v o="$o" <<'SQL'
CREATE DATABASE :"d" OWNER :"o" ENCODING UTF8;
SQL
  $PSQL -d "$d" -v d="$d" <<'SQL'
REVOKE ALL ON DATABASE :"d" FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
SQL
  echo ">> Created database: $d (owner $o), PUBLIC revoked."
}

cmd_create_table() {            # <db> <table> "<columns>" [owner]
  local d="${1:-}" t="${2:-}" cols="${3:-}" o="${4:-}"
  [ -n "$d" ] || read -rp "Database: " d
  [ -n "$t" ] || read -rp "Table name: " t
  db_exists "$d" || die "Database '$d' does not exist."
  if [ -z "$cols" ]; then
    echo "Column definitions, e.g.: id serial PRIMARY KEY, name text NOT NULL, price numeric"
    read -rp "Columns: " cols
  fi
  [ -n "$cols" ] || die "No column definitions provided."
  # $t/$cols expand via bash (unquoted heredoc), same as cmd_grant_revoke
  $PSQL -d "$d" <<SQL
CREATE TABLE $t ($cols);
SQL
  echo ">> Created table: $t (db: $d)"
  if [ -n "$o" ]; then
    role_exists "$o" || die "Owner '$o' does not exist."
    $PSQL -d "$d" -v o="$o" <<SQL
ALTER TABLE $t OWNER TO :"o";
SQL
    echo ">> Owner $t -> $o (only owner can ADD/DROP COLUMN, alter table structure)."
  fi
}

cmd_set_owner() {               # <db> <table> <owner>
  local d="${1:-}" t="${2:-}" o="${3:-}"
  [ -n "$d" ] || read -rp "Database: " d
  [ -n "$t" ] || read -rp "Table name: " t
  [ -n "$o" ] || read -rp "New owner: " o
  db_exists "$d" || die "Database '$d' does not exist."
  role_exists "$o" || die "Owner '$o' does not exist."
  $PSQL -d "$d" -v o="$o" <<SQL
ALTER TABLE $t OWNER TO :"o";
SQL
  echo ">> Owner $t -> $o (only owner can ADD/DROP COLUMN, DROP/ALTER table)."
}

cmd_setup_groups() {            # <db> [owner]
  local d="${1:-}"; [ -n "$d" ] || read -rp "Database: " d
  db_exists "$d" || die "Database '$d' does not exist."
  local owner="${2:-}"
  if [ -z "$owner" ]; then
    owner="$($PSQL -tAc "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='$d'")"
    [ -n "$owner" ] || die "Cannot resolve owner of '$d'."
    echo ">> owner not given, using database owner: $owner"
  fi
  role_exists "$owner" || die "Owner role '$owner' does not exist."
  local ro="${d}_readonly" rw="${d}_readwrite"
  role_exists "$ro" || $PSQL -v g="$ro" <<'SQL'
CREATE ROLE :"g" NOLOGIN;
SQL
  role_exists "$rw" || $PSQL -v g="$rw" <<'SQL'
CREATE ROLE :"g" NOLOGIN;
SQL
  $PSQL -d "$d" -v db="$d" -v ro="$ro" -v rw="$rw" -v owner="$owner" <<'SQL'
GRANT CONNECT ON DATABASE :"db" TO :"ro", :"rw";
GRANT USAGE ON SCHEMA public TO :"ro", :"rw";
GRANT SELECT ON ALL TABLES IN SCHEMA public TO :"ro";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO :"rw";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO :"rw";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA public GRANT SELECT ON TABLES TO :"ro";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"rw";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO :"rw";
SQL
  echo ">> Created groups: $ro (read), $rw (read+write) + default privileges FOR ROLE $owner."
}

cmd_schema() {                  # <app> <db> [owner]
  local SCH="${1:-}" DB="${2:-}" OWNER="${3:-}"
  [ -n "$SCH" ] && [ -n "$DB" ] || die "Usage: axdb.sh schema <app> <db> [owner]"
  db_exists "$DB" || die "Database '$DB' does not exist."
  if [ -z "$OWNER" ]; then
    OWNER="$($PSQL -tAc "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='$DB'")"
    [ -n "$OWNER" ] || die "Cannot resolve owner of '$DB'."
    echo ">> owner not given, using database owner: $OWNER"
  fi
  role_exists "$OWNER" || die "Owner role '$OWNER' does not exist."
  local RO="${SCH}_readonly" RW="${SCH}_readwrite"
  for g in "$RO" "$RW"; do
    role_exists "$g" || $PSQL -v g="$g" <<'SQL'
CREATE ROLE :"g" NOLOGIN;
SQL
  done
  $PSQL -d "$DB" -v db="$DB" -v sch="$SCH" -v owner="$OWNER" -v ro="$RO" -v rw="$RW" <<'SQL'
CREATE SCHEMA IF NOT EXISTS :"sch" AUTHORIZATION :"owner";
GRANT CONNECT ON DATABASE :"db" TO :"ro", :"rw";
GRANT USAGE ON SCHEMA :"sch" TO :"ro", :"rw";
GRANT SELECT ON ALL TABLES IN SCHEMA :"sch" TO :"ro";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA :"sch" TO :"rw";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA :"sch" TO :"rw";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA :"sch" GRANT SELECT ON TABLES TO :"ro";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA :"sch" GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"rw";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA :"sch" GRANT USAGE, SELECT ON SEQUENCES TO :"rw";
SQL
  echo ">> schema '$SCH' ready in '$DB' (owner $OWNER): $RO / $RW"
}

cmd_perm() {                    # <db> [user]
  local DB="${1:-}" U="${2:-}"
  [ -n "$DB" ] || die "Usage: axdb.sh perm <db> [user]"
  db_exists "$DB" || die "Database '$DB' does not exist."
  if [ -z "$U" ]; then
    $PSQL -d "$DB" <<'SQL'
SELECT r.rolname AS role,
       CASE WHEN r.rolsuper THEN 't' ELSE 'f' END AS super,
       COALESCE(string_agg(DISTINCT g.rolname, ', ' ORDER BY g.rolname), '(none)') AS groups,
       COALESCE(string_agg(DISTINCT
         CASE WHEN g.rolname LIKE '%\_readwrite' THEN regexp_replace(g.rolname,'_readwrite$','')||': RW'
              WHEN g.rolname LIKE '%\_readonly'  THEN regexp_replace(g.rolname,'_readonly$','') ||': RO' END,
         ', '), CASE WHEN r.rolsuper THEN 'ALL' ELSE '-' END) AS schema_access
FROM pg_roles r
LEFT JOIN pg_auth_members m ON m.member = r.oid
LEFT JOIN pg_roles g ON g.oid = m.roleid
WHERE r.rolcanlogin AND r.rolname NOT LIKE 'pg\_%'
GROUP BY r.rolname, r.rolsuper ORDER BY r.rolsuper DESC, r.rolname;
SQL
  else
    role_exists "$U" || die "Role '$U' does not exist."
    $PSQL -d "$DB" -v u="$U" <<'SQL'
SELECT n.nspname AS schema, c.relname AS "table",
       array_to_string(ARRAY[
         CASE WHEN has_table_privilege(:'u', c.oid,'SELECT') THEN 'SELECT' END,
         CASE WHEN has_table_privilege(:'u', c.oid,'INSERT') THEN 'INSERT' END,
         CASE WHEN has_table_privilege(:'u', c.oid,'UPDATE') THEN 'UPDATE' END,
         CASE WHEN has_table_privilege(:'u', c.oid,'DELETE') THEN 'DELETE' END], ',') AS privileges
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE c.relkind='r' AND n.nspname NOT IN ('pg_catalog','information_schema')
  AND (has_table_privilege(:'u', c.oid,'SELECT') OR has_table_privilege(:'u', c.oid,'INSERT')
    OR has_table_privilege(:'u', c.oid,'UPDATE') OR has_table_privilege(:'u', c.oid,'DELETE'))
ORDER BY 1,2;
SQL
  fi
}

cmd_grant_revoke() {            # <grant|revoke> <role> <db> <table> <privs>
  local act="$1" role="${2:-}" db="${3:-}" tbl="${4:-}" privs="${5:-}"
  [ -n "$role" ] && [ -n "$db" ] && [ -n "$tbl" ] && [ -n "$privs" ] || die "Missing arguments."
  role_exists "$role" || die "Role '$role' does not exist."
  db_exists "$db" || die "Database '$db' does not exist."
  # $privs/$tbl: bash expand (unquoted heredoc); :"r": psql interpolation
  if [ "$act" = grant ]; then
    $PSQL -d "$db" -v r="$role" <<SQL
GRANT $privs ON $tbl TO :"r";
SQL
    echo ">> GRANT $privs ON $tbl -> $role"
  else
    $PSQL -d "$db" -v r="$role" <<SQL
REVOKE $privs ON $tbl FROM :"r";
SQL
    echo ">> REVOKE $privs ON $tbl <- $role"
  fi
}

cmd_passwd() {                  # <role>
  local n="${1:-}"; [ -n "$n" ] || read -rp "Role: " n
  role_exists "$n" || die "Role '$n' does not exist."
  local p1 p2; p1="$(prompt_pw "NEW password for $n")"; p2="$(prompt_pw "Re-enter")"
  [ -n "$p1" ] || die "Empty."; [ "$p1" = "$p2" ] || die "Does not match."
  $PSQL -v n="$n" -v pw="$p1" <<'SQL'
ALTER ROLE :"n" PASSWORD :'pw';
SQL
  echo ">> Password changed: $n"
}

cmd_drop_user() {               # <user> [reassign_to]
  local n="${1:-}" t="${2:-dbadmin}"; [ -n "$n" ] || read -rp "User to drop: " n
  is_protected_role "$n" && die "'$n' is a protected role, cannot drop."
  role_exists "$n" || die "Role '$n' does not exist."
  role_exists "$t" || die "Recipient role '$t' does not exist."
  confirm "Drop '$n' (objects reassigned to $t)?" || { echo "Cancelled."; return 0; }
  local dbs; dbs="$($PSQL -tAc "SELECT datname FROM pg_database WHERE datistemplate=false AND datallowconn")"
  for db in $dbs; do
    $PSQL -d "$db" -v u="$n" -v t="$t" <<'SQL' || true
REASSIGN OWNED BY :"u" TO :"t";
SQL
    $PSQL -d "$db" -v u="$n" <<'SQL' || true
DROP OWNED BY :"u";
SQL
  done
  $PSQL -v u="$n" <<'SQL'
DROP ROLE :"u";
SQL
  echo ">> Dropped role: $n"
}

cmd_drop_db() {                 # <db>
  local d="${1:-}"; [ -n "$d" ] || read -rp "Database to drop: " d
  for p in $PROTECTED_DBS; do [ "$d" = "$p" ] && die "'$d' is a system db."; done
  db_exists "$d" || die "Database '$d' does not exist."
  local size conn
  size="$($PSQL -tAc "SELECT pg_size_pretty(pg_database_size('$d'))")"
  conn="$($PSQL -tAc "SELECT count(*) FROM pg_stat_activity WHERE datname='$d'")"
  echo "DB: $d | size: $size | connections: $conn"
  echo "⚠️  IRREVERSIBLE DROP — have you backed up? (Phase 5)"
  local typed; read -rp "Re-type the EXACT db name to confirm: " typed
  [ "$typed" = "$d" ] || die "Does not match. Cancelled."
  $PSQL -v d="$d" <<'SQL'
DROP DATABASE IF EXISTS :"d" WITH (FORCE);
SQL
  echo ">> Dropped database: $d"
}

# bind-ip: auto-detects Patroni (DCS) or file; force with --file / --patroni
cmd_bind_ip() {                 # <user> <ip[,ip2]|--unpin> [--file|--patroni]
  local user="${1:-}" action="${2:-}" mode="${3:-auto}"
  [ -n "$user" ] && [ -n "$action" ] || die "Usage: bind-ip <user> <ip[,ip2]|--unpin> [--file|--patroni]"
  role_exists "$user" || die "Role '$user' does not exist."
  local use_patroni=0
  case "$mode" in
    --patroni) use_patroni=1;;
    --file)    use_patroni=0;;
    *) { command -v patronictl >/dev/null && [ -f "${PATRONI_CONF:-/etc/patroni/patroni.yml}" ]; } && use_patroni=1;;
  esac
  if [ "$use_patroni" = 1 ]; then _bind_patroni "$user" "$action"; else _bind_file "$user" "$action"; fi
}

_bind_file() {                  # <user> <action>
  local user="$1" action="$2"
  local ver="${PG_VER:-17}" hba="${HBA:-/etc/postgresql/${PG_VER:-17}/main/pg_hba.conf}"
  local peruser inc="include_if_exists pg_hba_peruser.conf"
  [ -f "$hba" ] || die "Cannot find $hba (set HBA=...)."
  peruser="$(dirname "$hba")/pg_hba_peruser.conf"
  sudo cp -a "$hba" "$hba.bak" 2>/dev/null || true
  sudo touch "$peruser"; sudo chown --reference="$hba" "$peruser" 2>/dev/null || true; sudo chmod 640 "$peruser" 2>/dev/null || true
  grep -qxF "$inc" "$hba" || { sudo sed -i "1i $inc" "$hba"; echo "  + added include at top of $hba"; }
  sudo sed -i "/^# >>> peruser:$user$/,/^# <<< peruser:$user$/d" "$peruser"
  if [ "$action" = "--unpin" ]; then
    echo ">> [file] Unpinned '$user'."
  else
    local blk="# >>> peruser:$user"$'\n'; local ip
    IFS=',' read -ra arr <<< "$action"
    for ip in "${arr[@]}"; do case "$ip" in */*) ;; *) ip="$ip/32";; esac; blk+="host all $user $ip scram-sha-256"$'\n'; done
    blk+="host all $user 0.0.0.0/0 reject"$'\n'"host all $user ::0/0 reject"$'\n'"# <<< peruser:$user"
    printf '%s\n' "$blk" | sudo tee -a "$peruser" >/dev/null
    echo ">> [file] Pinned '$user' -> $action (other IPs rejected)."
  fi
  $PSQL -c "SELECT pg_reload_conf();" >/dev/null
  $PSQL -c "SELECT line_number,error FROM pg_hba_file_rules WHERE error IS NOT NULL;"
}

_bind_patroni() {               # <user> <action>
  local user="$1" action="$2"
  local conf="${PATRONI_CONF:-/etc/patroni/patroni.yml}" pctl
  pctl="patronictl -c $conf"
  python3 -c "import yaml" 2>/dev/null || die "missing python3-yaml"
  local cluster; cluster="$($pctl list -f json 2>/dev/null | python3 -c 'import sys,json
d=json.load(sys.stdin);print(d[0]["Cluster"] if d else "")' 2>/dev/null || true)"
  local cur py partial; cur="$($pctl show-config)"
  py="$(mktemp)"
  cat > "$py" <<'PY'
import sys, yaml
user, action = sys.argv[1], sys.argv[2]
cfg = yaml.safe_load(sys.stdin) or {}
hba = (cfg.get('postgresql') or {}).get('pg_hba') or []
if not hba:
    sys.stderr.write("DCS has no pg_hba yet — stopping to avoid wiping the original rules.\n"); sys.exit(2)
s="# >>> peruser:%s"%user; e="# <<< peruser:%s"%user
out=[]; skip=False
for l in hba:
    if l==s: skip=True; continue
    if l==e: skip=False; continue
    if not skip: out.append(l)
if action!="--unpin":
    b=[s]
    for ip in action.split(','):
        ip=ip.strip();  ip=ip if '/' in ip else ip+'/32'
        b.append("host all %s %s scram-sha-256"%(user,ip))
    b+=["host all %s 0.0.0.0/0 reject"%user,"host all %s ::0/0 reject"%user,e]
    out=b+out
print(yaml.safe_dump({'postgresql':{'pg_hba':out}},default_flow_style=False,sort_keys=False))
PY
  partial="$(printf '%s' "$cur" | python3 "$py" "$user" "$action")" || { rm -f "$py"; exit 2; }
  rm -f "$py"
  printf '%s' "$partial" | $pctl edit-config ${cluster:+"$cluster"} --apply - --force
  $pctl reload ${cluster:+"$cluster"} --force >/dev/null 2>&1 || true
  echo ">> [patroni] Updated per-user pg_hba for '$user' (cluster $cluster)."
}

cmd_list() {                    # <roles|dbs|members <g>|grants <db>>
  case "${1:-roles}" in
    roles) $PSQL -c "\du";;
    dbs)   $PSQL -c "\l";;
    members) [ -n "${2:-}" ] || die "Missing group."
      $PSQL -v g="$2" -tA <<'SQL'
SELECT m.rolname FROM pg_auth_members am
JOIN pg_roles g ON g.oid=am.roleid
JOIN pg_roles m ON m.oid=am.member
WHERE g.rolname=:'g' ORDER BY 1;
SQL
      ;;
    grants) [ -n "${2:-}" ] || die "Missing db."; db_exists "$2" || die "DB does not exist."; $PSQL -d "$2" -c "\dp";;
    *) die "list <roles|dbs|members <g>|grants <db>>";;
  esac
}

cmd_check() {                   # check connection + report which user is connected
  echo "Connection mode: $PSQL_ADMIN"
  local out
  if out="$($PSQL -tAc "SELECT 'user='||current_user||'  db='||current_database()||'  superuser='||(SELECT rolsuper FROM pg_roles WHERE rolname=current_user)||'  '||version()" 2>&1)"; then
    echo ">> CONNECTION OK ✅"
    echo "   $out"
  else
    echo ">> CONNECTION FAILED ❌"
    echo "   $out"
    echo "   Hint: if testing for the first time, run LOCAL: unset PSQL_ADMIN  (uses sudo -u postgres)"
    return 1
  fi
}

cmd_set_db_owner() {            # <db> <owner>
  local d="${1:-}" o="${2:-}"
  [ -n "$d" ] || read -rp "Database: " d
  [ -n "$o" ] || read -rp "New owner: " o
  db_exists "$d" || die "Database '$d' does not exist."
  role_exists "$o" || die "Owner '$o' does not exist."
  $PSQL -v d="$d" -v o="$o" <<'SQL'
ALTER DATABASE :"d" OWNER TO :"o";
SQL
  echo ">> Database owner $d -> $o"
}

cmd_dashboard() {               # <role>  — everything a user/group can access
  local r="${1:-}"; [ -n "$r" ] || read -rp "User/Group role: " r
  role_exists "$r" || die "Role '$r' does not exist."
  echo "================ DASHBOARD: $r ================"
  echo "-- Attributes --"
  $PSQL -v r="$r" <<'SQL'
SELECT rolname AS role, rolcanlogin AS can_login, rolsuper AS superuser,
       rolcreatedb AS createdb, rolcreaterole AS createrole
FROM pg_roles WHERE rolname=:'r';
SQL
  echo "-- Member of (groups this role belongs to) --"
  $PSQL -v r="$r" -tA <<'SQL'
SELECT g.rolname FROM pg_auth_members m
JOIN pg_roles g ON g.oid=m.roleid
JOIN pg_roles u ON u.oid=m.member
WHERE u.rolname=:'r' ORDER BY 1;
SQL
  echo "-- Members (roles belonging to this group) --"
  $PSQL -v r="$r" -tA <<'SQL'
SELECT u.rolname FROM pg_auth_members m
JOIN pg_roles g ON g.oid=m.roleid
JOIN pg_roles u ON u.oid=m.member
WHERE g.rolname=:'r' ORDER BY 1;
SQL
  echo "-- Databases owned --"
  $PSQL -v r="$r" -tA <<'SQL'
SELECT datname FROM pg_database WHERE pg_get_userbyid(datdba)=:'r' ORDER BY 1;
SQL
  echo "-- Table privileges granted directly, per database --"
  local dbs db out
  dbs="$($PSQL -tAc "SELECT datname FROM pg_database WHERE datistemplate=false AND datallowconn")"
  for db in $dbs; do
    out="$($PSQL -d "$db" -v r="$r" -tA <<'SQL'
SELECT table_schema||'.'||table_name||' : '||string_agg(privilege_type, ',' ORDER BY privilege_type)
FROM information_schema.role_table_grants
WHERE grantee=:'r'
GROUP BY table_schema, table_name
ORDER BY 1;
SQL
)"
    [ -n "$out" ] && { echo "  [db: $db]"; echo "$out" | sed 's/^/    /'; }
  done
  echo "(Note: privileges inherited via group membership show up under the group's dashboard.)"
}

cmd_show() {                    # <dbs|tables <db>|structure <db> <t>|owner <db> [t]|perms <db> [t]>
  case "${1:-}" in
    dbs)
      $PSQL <<'SQL'
SELECT datname AS database, pg_get_userbyid(datdba) AS owner,
       pg_size_pretty(pg_database_size(datname)) AS size,
       pg_encoding_to_char(encoding) AS encoding
FROM pg_database WHERE datistemplate=false ORDER BY 1;
SQL
      ;;
    tables)
      local dt="${2:-}"; [ -n "$dt" ] || die "Missing database."; db_exists "$dt" || die "Database '$dt' does not exist."
      $PSQL -d "$dt" <<'SQL'
SELECT schemaname AS schema, tablename AS table, tableowner AS owner,
       pg_size_pretty(pg_total_relation_size(format('%I.%I',schemaname,tablename)::regclass)) AS size
FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema') ORDER BY 1,2;
SQL
      ;;
    structure)
      local ds="${2:-}" ts="${3:-}"; [ -n "$ds" ] && [ -n "$ts" ] || die "Usage: show structure <db> <table>"
      db_exists "$ds" || die "Database '$ds' does not exist."
      $PSQL -d "$ds" -c "\\d $ts"
      ;;
    owner)
      local do_="${2:-}" to_="${3:-}"; [ -n "$do_" ] || die "Missing database."; db_exists "$do_" || die "Database '$do_' does not exist."
      if [ -n "$to_" ]; then
        $PSQL -d "$do_" -v t="$to_" <<'SQL'
SELECT schemaname||'.'||tablename AS table, tableowner AS owner
FROM pg_tables WHERE tablename=:'t' ORDER BY 1;
SQL
      else
        echo "-- Database owner --"
        $PSQL -d "$do_" -v d="$do_" <<'SQL'
SELECT datname AS database, pg_get_userbyid(datdba) AS owner FROM pg_database WHERE datname=:'d';
SQL
        echo "-- Table owners --"
        $PSQL -d "$do_" <<'SQL'
SELECT schemaname||'.'||tablename AS table, tableowner AS owner
FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema') ORDER BY 1;
SQL
      fi
      ;;
    perms)
      local dp="${2:-}" tp="${3:-}"; [ -n "$dp" ] || die "Missing database."; db_exists "$dp" || die "Database '$dp' does not exist."
      $PSQL -d "$dp" -c "\\dp $tp"
      ;;
    *) die "show <dbs|tables <db>|structure <db> <table>|owner <db> [table]|perms <db> [table]>";;
  esac
}

usage() {
cat <<'H'
axdb.sh — PostgreSQL administration (AX Svr)

  (run with NO arguments  ->  opens interactive MENU)
  menu                                        Open interactive menu

  create-admin <name>                         Create DB admin (SUPERUSER)
  create-user-admin <name>                    Create user admin (CREATEROLE+CREATEDB)
  create-user <user> [group]                  Create regular user (+assign to group)
  create-db <db> [owner]                      Create database + revoke PUBLIC
  create-table <db> <table> "<columns>" [owner]   Create table (optional owner — new owner can add columns)
  setup-groups <db> [owner]                   Create <db>_readonly/_readwrite + default priv (FOR ROLE owner)
  schema <app> <db> [owner]                   Create schema <app> + <app>_readonly/_readwrite + default priv (FOR ROLE owner)
  perm <db> [user]                            Permission overview (summary; or per-table drill-down for a user)
  grant  <role> <db> <table> "<privs>"        Grant privileges to role (user OR group)
  revoke <role> <db> <table> "<privs>"        Revoke privileges
  set-owner <db> <table> <owner>              Change table owner (new owner gets full structural control)
  set-db-owner <db> <owner>                   Change database owner
  passwd <role>                               Change password (reset password)
  drop-user <user> [reassign_to=dbadmin]      Drop user safely
  drop-db <db>                                Drop database safely (re-type name)
  bind-ip <user> <ip[,ip2]|--unpin> [--file|--patroni]
                                              Pin user to specific IPs only (auto-detects DevDB/Patroni)
  dashboard <role>                            Show everything a user/group can access
  show dbs                                    List databases (owner, size, encoding)
  show tables <db>                            List tables (owner, size)
  show structure <db> <table>                 Show table structure (columns/indexes)
  show owner <db> [table]                     Show database/table owner
  show perms <db> [table]                     Show privileges (\dp)
  list <roles|dbs|members <g>|grants <db>>    View roles/dbs/privileges
  check                                       Check connection (which user is connected)
  help                                        This help

Remote connection: export PSQL_ADMIN="psql -h 107.118.210.90 -U dbadmin"
H
}

# ---------- interactive menu ----------
_run()   { ( "$@" ) || echo "  (finished with an error — see above)"; }
_pause() { read -rp "  ↵ Press Enter to return to menu..." _ || true; }

menu() {
  while true; do
    cat <<M

============== AX DB MANAGER ==============
 Connection: ${PSQL_ADMIN}
------------------------------------------
  1) Create DB admin (SUPERUSER)
  2) Create user admin (CREATEROLE+CREATEDB)
  3) Create regular user
  4) Create database
  5) Create group roles (readonly/readwrite)
  6) GRANT privileges on a table
  7) REVOKE privileges on a table
  8) Change role password
  9) Pin user to IP (bind-ip)
 10) Drop user (safe)
 11) Drop database (safe)
 12) View roles / dbs / members / grants
 13) Check connection (test)
 14) Create table (create table)
 15) Change table owner (set-owner)
 16) Change database owner (set-db-owner)
 17) Role dashboard (user/group access)
 18) Show / inspect (dbs/tables/structure/owner/perms)
  0) Exit
==========================================
M
    read -rp "Select [0-18]: " ch || exit 0
    case "$ch" in
      1) _run cmd_create_admin ;;
      2) _run cmd_create_user_admin ;;
      3) read -rp "User name: " u; read -rp "Group (empty if none): " g; _run cmd_create_user "$u" "$g" ;;
      4) _run cmd_create_db ;;
      5) _run cmd_setup_groups ;;
      6) read -rp "Role: " r; read -rp "Database: " d; read -rp "Table (or ALL TABLES IN SCHEMA public): " t; read -rp "Privileges (e.g. SELECT,INSERT): " p; _run cmd_grant_revoke grant "$r" "$d" "$t" "$p" ;;
      7) read -rp "Role: " r; read -rp "Database: " d; read -rp "Table: " t; read -rp "Privileges: " p; _run cmd_grant_revoke revoke "$r" "$d" "$t" "$p" ;;
      8) _run cmd_passwd ;;
      9) read -rp "User: " u; read -rp "IP (1.1.1.1,1.1.1.2) or --unpin: " a; read -rp "Mode [Enter=auto / --file / --patroni]: " m; _run cmd_bind_ip "$u" "$a" "${m:-auto}" ;;
      10) _run cmd_drop_user ;;
      11) _run cmd_drop_db ;;
      12) read -rp "View [roles/dbs/members/grants]: " s
          case "$s" in
            members) read -rp "Group: " g; _run cmd_list members "$g";;
            grants)  read -rp "Database: " d; _run cmd_list grants "$d";;
            *)       _run cmd_list "$s";;
          esac ;;
      13) _run cmd_check ;;
      14) read -rp "Database: " d; read -rp "Table name: " t; read -rp "Columns (id serial PRIMARY KEY, name text ...): " c; read -rp "Owner (empty=admin): " o; _run cmd_create_table "$d" "$t" "$c" "$o" ;;
      15) read -rp "Database: " d; read -rp "Table name: " t; read -rp "New owner: " o; _run cmd_set_owner "$d" "$t" "$o" ;;
      16) read -rp "Database: " d; read -rp "New owner: " o; _run cmd_set_db_owner "$d" "$o" ;;
      17) read -rp "User/Group role: " r; _run cmd_dashboard "$r" ;;
      18) read -rp "Show [dbs/tables/structure/owner/perms]: " s
          case "$s" in
            dbs)       _run cmd_show dbs;;
            tables)    read -rp "Database: " d; _run cmd_show tables "$d";;
            structure) read -rp "Database: " d; read -rp "Table: " t; _run cmd_show structure "$d" "$t";;
            owner)     read -rp "Database: " d; read -rp "Table (blank=all): " t; _run cmd_show owner "$d" "$t";;
            perms)     read -rp "Database: " d; read -rp "Table (blank=all): " t; _run cmd_show perms "$d" "$t";;
            *)         echo "Invalid.";;
          esac ;;
      0) echo "Bye."; exit 0 ;;
      *) echo "Invalid choice." ;;
    esac
    _pause
  done
}

# ---------- dispatch ----------
cmd="${1:-menu}"; shift || true
case "$cmd" in
  menu)               menu;;
  create-admin)       cmd_create_admin "$@";;
  create-user-admin)  cmd_create_user_admin "$@";;
  create-user)        cmd_create_user "$@";;
  create-db)          cmd_create_db "$@";;
  create-table)       cmd_create_table "$@";;
  setup-groups)       cmd_setup_groups "$@";;
  schema)             cmd_schema "$@";;
  perm)               cmd_perm "$@";;
  grant)              cmd_grant_revoke grant "$@";;
  revoke)             cmd_grant_revoke revoke "$@";;
  set-owner)          cmd_set_owner "$@";;
  set-db-owner)       cmd_set_db_owner "$@";;
  passwd)             cmd_passwd "$@";;
  drop-user)          cmd_drop_user "$@";;
  drop-db)            cmd_drop_db "$@";;
  bind-ip)            cmd_bind_ip "$@";;
  dashboard)          cmd_dashboard "$@";;
  show)               cmd_show "$@";;
  list)               cmd_list "$@";;
  check)              cmd_check "$@";;
  help|-h|--help)     usage;;
  *) echo "Invalid command: $cmd"; echo; usage; exit 1;;
esac
