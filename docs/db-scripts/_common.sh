#!/usr/bin/env bash
# ============================================================================
# _common.sh — shared source for PostgreSQL admin scripts (source into other scripts)
# ----------------------------------------------------------------------------
# How to connect with admin privileges:
#   - Default: run DIRECTLY ON THE DB server, using the socket as user postgres.
#   - Run REMOTELY: export PSQL_ADMIN="psql -h 107.118.210.90 -U dbadmin"
#                 (will prompt for the dbadmin password, or set PGPASSWORD)
# ============================================================================
set -euo pipefail

PSQL_ADMIN="${PSQL_ADMIN:-sudo -u postgres psql}"
PSQL="$PSQL_ADMIN -v ON_ERROR_STOP=1 -X -q"

role_exists() { [ "$($PSQL -tAc "SELECT 1 FROM pg_roles    WHERE rolname='$1'" 2>/dev/null)" = "1" ]; }
db_exists()   { [ "$($PSQL -tAc "SELECT 1 FROM pg_database WHERE datname='$1'" 2>/dev/null)" = "1" ]; }

# Prompt for a password securely (not shown on screen, not saved in history)
prompt_pw() { local v; read -rsp "$1: " v >&2; echo >&2; printf '%s' "$v"; }

confirm() { local a; read -rp "$1 [y/N]: " a >&2; [ "$a" = y ] || [ "$a" = Y ]; }

die() { echo "ERROR: $*" >&2; exit 1; }

# Note: if postgresql.conf has log_statement='all', create/change password
# statements may be written to the log. In Production, use log_statement='ddl' or 'none'.
