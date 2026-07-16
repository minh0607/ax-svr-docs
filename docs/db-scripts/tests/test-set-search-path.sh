#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
trap pg_down EXIT
pg_up
dq -c "CREATE ROLE app_user LOGIN PASSWORD 'x';" >/dev/null

# helper: the effective search_path string stored for the role (empty if none)
cfg() { dq -tAc "SELECT COALESCE(array_to_string(rolconfig,'|'),'') FROM pg_roles WHERE rolname='app_user'"; }

# single schema -> contains the schema AND public appended
./axdb.sh set-search-path app_user finance
V="$(cfg)"
assert_contains "$V" "search_path=" "single: search_path set"
assert_contains "$V" "finance" "single: contains schema finance"
assert_contains "$V" "public" "single: public auto-appended"

# public given explicitly -> still valid, contains hr + public (exactly one public)
./axdb.sh set-search-path app_user "hr,public"
V="$(cfg)"
assert_contains "$V" "hr" "multi: contains hr"
assert_eq "$(printf '%s' "$V" | grep -o public | wc -l | tr -d ' ')" "1" "multi: public not duplicated"

# reset -> no rolconfig
./axdb.sh set-search-path app_user --reset
assert_eq "$(cfg)" "" "reset clears search_path"

finish
