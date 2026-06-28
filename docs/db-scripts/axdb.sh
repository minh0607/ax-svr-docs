#!/usr/bin/env bash
# ============================================================================
# axdb.sh — Script TỔNG quản trị PostgreSQL (AX Svr). Self-contained.
# Gộp: tạo admin/user/db, group role, phân quyền, đổi mk, xoá an toàn, pin IP.
# ----------------------------------------------------------------------------
# Kết nối quyền admin:
#   - Mặc định: chạy trên DB server, dùng socket as 'postgres'.
#   - Từ xa:    export PSQL_ADMIN="psql -h 107.118.210.90 -U dbadmin"
# Dùng: ./axdb.sh <command> [args]   |   ./axdb.sh help
# Lưu ý: SQL có biến đưa qua STDIN (heredoc) vì `psql -c` KHÔNG nội suy :var.
# ============================================================================
set -euo pipefail

PSQL_ADMIN="${PSQL_ADMIN:-sudo -u postgres psql}"
PSQL="$PSQL_ADMIN -v ON_ERROR_STOP=1 -X -q"
PROTECTED_ROLES="postgres dbadmin useradmin replicator"
PROTECTED_DBS="postgres template0 template1"

# ---------- helpers ----------
die()  { echo "LỖI: $*" >&2; exit 1; }
confirm() { local a; read -rp "$1 [y/N]: " a; [ "$a" = y ] || [ "$a" = Y ]; }
prompt_pw() { local v; read -rsp "$1: " v; echo >&2; printf '%s' "$v"; }
role_exists() { [ "$($PSQL -tAc "SELECT 1 FROM pg_roles    WHERE rolname='$1'" 2>/dev/null)" = "1" ]; }
db_exists()   { [ "$($PSQL -tAc "SELECT 1 FROM pg_database WHERE datname='$1'" 2>/dev/null)" = "1" ]; }
is_protected_role() { for p in $PROTECTED_ROLES; do [ "$1" = "$p" ] && return 0; done; return 1; }

# ---------- commands ----------
cmd_create_admin() {            # <name>
  local n="${1:-}"; [ -n "$n" ] || read -rp "Tên DB admin (vd dbadmin): " n
  [ "$n" = postgres ] && die "Đừng dùng tên 'postgres'."
  role_exists "$n" && die "Role '$n' đã tồn tại."
  local pw; pw="$(prompt_pw "Mật khẩu cho $n")"; [ -n "$pw" ] || die "Mật khẩu rỗng."
  $PSQL -v n="$n" -v pw="$pw" <<'SQL'
CREATE ROLE :"n" LOGIN SUPERUSER CREATEDB CREATEROLE PASSWORD :'pw';
SQL
  echo ">> Tạo DB ADMIN (SUPERUSER): $n"
}

cmd_create_user_admin() {       # <name>
  local n="${1:-}"; [ -n "$n" ] || read -rp "Tên user admin: " n
  role_exists "$n" && die "Role '$n' đã tồn tại."
  local pw; pw="$(prompt_pw "Mật khẩu cho $n")"; [ -n "$pw" ] || die "Mật khẩu rỗng."
  $PSQL -v n="$n" -v pw="$pw" <<'SQL'
CREATE ROLE :"n" LOGIN CREATEROLE CREATEDB PASSWORD :'pw';
SQL
  echo ">> Tạo USER ADMIN (CREATEROLE+CREATEDB, không superuser): $n"
}

cmd_create_user() {             # <user> [group]
  local n="${1:-}" g="${2:-}"; [ -n "$n" ] || read -rp "Tên user: " n
  role_exists "$n" && die "Role '$n' đã tồn tại."
  local pw; pw="$(prompt_pw "Mật khẩu cho $n")"; [ -n "$pw" ] || die "Mật khẩu rỗng."
  $PSQL -v n="$n" -v pw="$pw" <<'SQL'
CREATE ROLE :"n" LOGIN PASSWORD :'pw';
SQL
  echo ">> Tạo user: $n"
  if [ -n "$g" ]; then
    role_exists "$g" || die "Group '$g' chưa tồn tại."
    $PSQL -v n="$n" -v g="$g" <<'SQL'
GRANT :"g" TO :"n";
SQL
    echo ">> Gán $n vào nhóm $g"
  fi
}

cmd_create_db() {               # <db> [owner]
  local d="${1:-}" o="${2:-}"
  [ -n "$d" ] || read -rp "Tên database: " d
  [ -n "$o" ] || read -rp "Owner: " o
  db_exists "$d" && die "Database '$d' đã tồn tại."
  role_exists "$o" || die "Owner '$o' chưa tồn tại."
  $PSQL -v d="$d" -v o="$o" <<'SQL'
CREATE DATABASE :"d" OWNER :"o" ENCODING UTF8;
SQL
  $PSQL -d "$d" -v d="$d" <<'SQL'
REVOKE ALL ON DATABASE :"d" FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
SQL
  echo ">> Tạo database: $d (owner $o), đã thu hồi PUBLIC."
}

cmd_setup_groups() {            # <db>
  local d="${1:-}"; [ -n "$d" ] || read -rp "Database: " d
  db_exists "$d" || die "Database '$d' chưa tồn tại."
  local ro="${d}_readonly" rw="${d}_readwrite"
  role_exists "$ro" || $PSQL -v g="$ro" <<'SQL'
CREATE ROLE :"g" NOLOGIN;
SQL
  role_exists "$rw" || $PSQL -v g="$rw" <<'SQL'
CREATE ROLE :"g" NOLOGIN;
SQL
  $PSQL -d "$d" -v db="$d" -v ro="$ro" -v rw="$rw" <<'SQL'
GRANT CONNECT ON DATABASE :"db" TO :"ro", :"rw";
GRANT USAGE ON SCHEMA public TO :"ro", :"rw";
GRANT SELECT ON ALL TABLES IN SCHEMA public TO :"ro";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO :"rw";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO :"rw";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO :"ro";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"rw";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO :"rw";
SQL
  echo ">> Tạo nhóm: $ro (đọc), $rw (đọc+ghi) + default privileges."
}

cmd_grant_revoke() {            # <grant|revoke> <role> <db> <table> <privs>
  local act="$1" role="${2:-}" db="${3:-}" tbl="${4:-}" privs="${5:-}"
  [ -n "$role" ] && [ -n "$db" ] && [ -n "$tbl" ] && [ -n "$privs" ] || die "Thiếu tham số."
  role_exists "$role" || die "Role '$role' chưa tồn tại."
  db_exists "$db" || die "Database '$db' chưa tồn tại."
  # $privs/$tbl: bash expand (heredoc không quote); :"r": psql nội suy
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
  role_exists "$n" || die "Role '$n' không tồn tại."
  local p1 p2; p1="$(prompt_pw "Mật khẩu MỚI cho $n")"; p2="$(prompt_pw "Nhập lại")"
  [ -n "$p1" ] || die "Rỗng."; [ "$p1" = "$p2" ] || die "Không khớp."
  $PSQL -v n="$n" -v pw="$p1" <<'SQL'
ALTER ROLE :"n" PASSWORD :'pw';
SQL
  echo ">> Đổi mật khẩu: $n"
}

cmd_drop_user() {               # <user> [reassign_to]
  local n="${1:-}" t="${2:-dbadmin}"; [ -n "$n" ] || read -rp "User cần xoá: " n
  is_protected_role "$n" && die "'$n' là role được bảo vệ, không xoá."
  role_exists "$n" || die "Role '$n' không tồn tại."
  role_exists "$t" || die "Role nhận quyền '$t' không tồn tại."
  confirm "Xoá '$n' (object chuyển cho $t)?" || { echo "Hủy."; return 0; }
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
  echo ">> Đã xoá role: $n"
}

cmd_drop_db() {                 # <db>
  local d="${1:-}"; [ -n "$d" ] || read -rp "Database cần xoá: " d
  for p in $PROTECTED_DBS; do [ "$d" = "$p" ] && die "'$d' là db hệ thống."; done
  db_exists "$d" || die "Database '$d' không tồn tại."
  local size conn
  size="$($PSQL -tAc "SELECT pg_size_pretty(pg_database_size('$d'))")"
  conn="$($PSQL -tAc "SELECT count(*) FROM pg_stat_activity WHERE datname='$d'")"
  echo "DB: $d | dung lượng: $size | kết nối: $conn"
  echo "⚠️  XOÁ KHÔNG HOÀN TÁC — đã backup chưa? (Phase 5)"
  local typed; read -rp "Gõ lại CHÍNH XÁC tên db để xác nhận: " typed
  [ "$typed" = "$d" ] || die "Không khớp. Hủy."
  $PSQL -v d="$d" <<'SQL'
DROP DATABASE IF EXISTS :"d" WITH (FORCE);
SQL
  echo ">> Đã xoá database: $d"
}

# bind-ip: tự nhận biết Patroni (DCS) hay file; ép bằng --file / --patroni
cmd_bind_ip() {                 # <user> <ip[,ip2]|--unpin> [--file|--patroni]
  local user="${1:-}" action="${2:-}" mode="${3:-auto}"
  [ -n "$user" ] && [ -n "$action" ] || die "Dùng: bind-ip <user> <ip[,ip2]|--unpin> [--file|--patroni]"
  role_exists "$user" || die "Role '$user' không tồn tại."
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
  [ -f "$hba" ] || die "Không thấy $hba (đặt HBA=...)."
  peruser="$(dirname "$hba")/pg_hba_peruser.conf"
  sudo cp -a "$hba" "$hba.bak" 2>/dev/null || true
  sudo touch "$peruser"; sudo chown --reference="$hba" "$peruser" 2>/dev/null || true; sudo chmod 640 "$peruser" 2>/dev/null || true
  grep -qxF "$inc" "$hba" || { sudo sed -i "1i $inc" "$hba"; echo "  + thêm include vào đầu $hba"; }
  sudo sed -i "/^# >>> peruser:$user$/,/^# <<< peruser:$user$/d" "$peruser"
  if [ "$action" = "--unpin" ]; then
    echo ">> [file] Bỏ pin '$user'."
  else
    local blk="# >>> peruser:$user"$'\n'; local ip
    IFS=',' read -ra arr <<< "$action"
    for ip in "${arr[@]}"; do case "$ip" in */*) ;; *) ip="$ip/32";; esac; blk+="host all $user $ip scram-sha-256"$'\n'; done
    blk+="host all $user 0.0.0.0/0 reject"$'\n'"host all $user ::0/0 reject"$'\n'"# <<< peruser:$user"
    printf '%s\n' "$blk" | sudo tee -a "$peruser" >/dev/null
    echo ">> [file] Pin '$user' -> $action (IP khác reject)."
  fi
  $PSQL -c "SELECT pg_reload_conf();" >/dev/null
  $PSQL -c "SELECT line_number,error FROM pg_hba_file_rules WHERE error IS NOT NULL;"
}

_bind_patroni() {               # <user> <action>
  local user="$1" action="$2"
  local conf="${PATRONI_CONF:-/etc/patroni/patroni.yml}" pctl
  pctl="patronictl -c $conf"
  python3 -c "import yaml" 2>/dev/null || die "thiếu python3-yaml"
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
    sys.stderr.write("DCS chưa có pg_hba — dừng để tránh wipe rule gốc.\n"); sys.exit(2)
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
  echo ">> [patroni] Cập nhật pg_hba per-user cho '$user' (cụm $cluster)."
}

cmd_list() {                    # <roles|dbs|members <g>|grants <db>>
  case "${1:-roles}" in
    roles) $PSQL -c "\du";;
    dbs)   $PSQL -c "\l";;
    members) [ -n "${2:-}" ] || die "Thiếu group."
      $PSQL -v g="$2" -tA <<'SQL'
SELECT m.rolname FROM pg_auth_members am
JOIN pg_roles g ON g.oid=am.roleid
JOIN pg_roles m ON m.oid=am.member
WHERE g.rolname=:'g' ORDER BY 1;
SQL
      ;;
    grants) [ -n "${2:-}" ] || die "Thiếu db."; db_exists "$2" || die "DB không tồn tại."; $PSQL -d "$2" -c "\dp";;
    *) die "list <roles|dbs|members <g>|grants <db>>";;
  esac
}

usage() {
cat <<'H'
axdb.sh — quản trị PostgreSQL (AX Svr)

  (chạy KHÔNG tham số  ->  mở MENU tương tác)
  menu                                        Mở menu tương tác

  create-admin <name>                         Tạo DB admin (SUPERUSER)
  create-user-admin <name>                    Tạo user admin (CREATEROLE+CREATEDB)
  create-user <user> [group]                  Tạo user thường (+gán nhóm)
  create-db <db> [owner]                      Tạo database + thu hồi PUBLIC
  setup-groups <db>                           Tạo <db>_readonly/_readwrite + default priv
  grant  <role> <db> <table> "<privs>"        Cấp quyền (table hoặc "ALL TABLES IN SCHEMA public")
  revoke <role> <db> <table> "<privs>"        Thu hồi quyền
  passwd <role>                               Đổi mật khẩu
  drop-user <user> [reassign_to=dbadmin]      Xoá user an toàn
  drop-db <db>                                Xoá database an toàn (gõ lại tên)
  bind-ip <user> <ip[,ip2]|--unpin> [--file|--patroni]
                                              Pin user chỉ từ IP (tự nhận DevDB/Patroni)
  list <roles|dbs|members <g>|grants <db>>    Xem role/db/quyền
  help                                        Trợ giúp này

Kết nối từ xa: export PSQL_ADMIN="psql -h 107.118.210.90 -U dbadmin"
H
}

# ---------- menu tương tác ----------
_run()   { ( "$@" ) || echo "  (kết thúc với lỗi — xem ở trên)"; }
_pause() { read -rp "  ↵ Enter để về menu..." _ || true; }

menu() {
  while true; do
    cat <<M

============== AX DB MANAGER ==============
 Kết nối: ${PSQL_ADMIN}
------------------------------------------
  1) Tạo DB admin (SUPERUSER)
  2) Tạo user admin (CREATEROLE+CREATEDB)
  3) Tạo user thường
  4) Tạo database
  5) Tạo group roles (readonly/readwrite)
  6) GRANT quyền theo bảng
  7) REVOKE quyền theo bảng
  8) Đổi mật khẩu role
  9) Pin user vào IP (bind-ip)
 10) Xoá user (an toàn)
 11) Xoá database (an toàn)
 12) Xem roles / dbs / members / grants
  0) Thoát
==========================================
M
    read -rp "Chọn [0-12]: " ch || exit 0
    case "$ch" in
      1) _run cmd_create_admin ;;
      2) _run cmd_create_user_admin ;;
      3) read -rp "Tên user: " u; read -rp "Group (trống nếu không): " g; _run cmd_create_user "$u" "$g" ;;
      4) _run cmd_create_db ;;
      5) _run cmd_setup_groups ;;
      6) read -rp "Role: " r; read -rp "Database: " d; read -rp "Bảng (hoặc ALL TABLES IN SCHEMA public): " t; read -rp "Quyền (vd SELECT,INSERT): " p; _run cmd_grant_revoke grant "$r" "$d" "$t" "$p" ;;
      7) read -rp "Role: " r; read -rp "Database: " d; read -rp "Bảng: " t; read -rp "Quyền: " p; _run cmd_grant_revoke revoke "$r" "$d" "$t" "$p" ;;
      8) _run cmd_passwd ;;
      9) read -rp "User: " u; read -rp "IP (1.1.1.1,1.1.1.2) hoặc --unpin: " a; read -rp "Mode [Enter=auto / --file / --patroni]: " m; _run cmd_bind_ip "$u" "$a" "${m:-auto}" ;;
      10) _run cmd_drop_user ;;
      11) _run cmd_drop_db ;;
      12) read -rp "Xem [roles/dbs/members/grants]: " s
          case "$s" in
            members) read -rp "Group: " g; _run cmd_list members "$g";;
            grants)  read -rp "Database: " d; _run cmd_list grants "$d";;
            *)       _run cmd_list "$s";;
          esac ;;
      0) echo "Bye."; exit 0 ;;
      *) echo "Lựa chọn không hợp lệ." ;;
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
  setup-groups)       cmd_setup_groups "$@";;
  grant)              cmd_grant_revoke grant "$@";;
  revoke)             cmd_grant_revoke revoke "$@";;
  passwd)             cmd_passwd "$@";;
  drop-user)          cmd_drop_user "$@";;
  drop-db)            cmd_drop_db "$@";;
  bind-ip)            cmd_bind_ip "$@";;
  list)               cmd_list "$@";;
  help|-h|--help)     usage;;
  *) echo "Lệnh không hợp lệ: $cmd"; echo; usage; exit 1;;
esac
