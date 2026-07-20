#!/usr/bin/env bash
# Integration tests for proxy-man commands.
# Renders into an isolated temp directory (NGINX_DIR=./nginx). Does not issue
# real ACME certificates (needs a public domain / DNS).
set -Eeuo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BUILD_SCRIPT="$ROOT_DIR/scripts/build.sh"
DIST_SCRIPT="$ROOT_DIR/dist/proxy-man.sh"

PASS=0
FAIL=0
SKIP=0
TEST_ROOT=
PM=
NGINX_TREE=

cleanup() {
  local code=$?
  if [[ -n "${TEST_ROOT:-}" && -d "${TEST_ROOT:-}" ]]; then
    rm -rf "$TEST_ROOT"
  fi
  return "$code"
}
trap cleanup EXIT

color() {
  local name=$1
  shift
  if [[ -t 1 ]]; then
    case "$name" in
      green) printf '\033[32m%s\033[0m' "$*" ;;
      red) printf '\033[31m%s\033[0m' "$*" ;;
      yellow) printf '\033[33m%s\033[0m' "$*" ;;
      dim) printf '\033[2m%s\033[0m' "$*" ;;
      *) printf '%s' "$*" ;;
    esac
  else
    printf '%s' "$*"
  fi
}

pass() {
  PASS=$((PASS + 1))
  printf '  %s %s\n' "$(color green PASS)" "$*"
}

fail() {
  FAIL=$((FAIL + 1))
  printf '  %s %s\n' "$(color red FAIL)" "$*"
}

skip() {
  SKIP=$((SKIP + 1))
  printf '  %s %s\n' "$(color yellow SKIP)" "$*"
}

section() {
  printf '\n%s\n' "$(color dim "=== $* ===")"
}

# Run $PM and capture combined output + exit code without tripping set -e.
run_pm() {
  local out_file ec
  out_file=$(mktemp)
  set +e
  "$PM" "$@" >"$out_file" 2>&1
  ec=$?
  set -e
  RUN_OUT=$(cat "$out_file")
  RUN_EC=$ec
  rm -f "$out_file"
  return 0
}

assert_ok() {
  local name=$1
  shift
  run_pm "$@"
  if [[ "$RUN_EC" -eq 0 ]]; then
    pass "$name"
  else
    fail "$name (exit $RUN_EC)"
    printf '%s\n' "$RUN_OUT" | sed 's/^/    /'
  fi
}

assert_fail() {
  local name=$1
  shift
  run_pm "$@"
  if [[ "$RUN_EC" -ne 0 ]]; then
    pass "$name"
  else
    fail "$name (expected non-zero exit)"
    printf '%s\n' "$RUN_OUT" | sed 's/^/    /'
  fi
}

assert_fail_matches() {
  local name=$1 pattern=$2
  shift 2
  run_pm "$@"
  if [[ "$RUN_EC" -ne 0 ]] && grep -Eq -- "$pattern" <<<"$RUN_OUT"; then
    pass "$name"
  else
    fail "$name (exit $RUN_EC, pattern /$pattern/)"
    printf '%s\n' "$RUN_OUT" | sed 's/^/    /'
  fi
}

assert_ok_matches() {
  local name=$1 pattern=$2
  shift 2
  run_pm "$@"
  if [[ "$RUN_EC" -eq 0 ]] && grep -Eq -- "$pattern" <<<"$RUN_OUT"; then
    pass "$name"
  else
    fail "$name (exit $RUN_EC, pattern /$pattern/)"
    printf '%s\n' "$RUN_OUT" | sed 's/^/    /'
  fi
}

assert_file() {
  local name=$1 path=$2
  if [[ -f "$path" ]]; then
    pass "$name"
  else
    fail "$name (missing $path)"
  fi
}

assert_dir() {
  local name=$1 path=$2
  if [[ -d "$path" ]]; then
    pass "$name"
  else
    fail "$name (missing dir $path)"
  fi
}

assert_file_matches() {
  local name=$1 path=$2 pattern=$3
  if [[ -f "$path" ]] && grep -Eq -- "$pattern" "$path"; then
    pass "$name"
  else
    fail "$name (/$pattern/ in $path)"
  fi
}

assert_json_status() {
  local name=$1 expected=$2
  shift 2
  # Remaining args are env assignments (KEY=val) followed by optional -- then ignored.
  local -a env_vars=()
  while (( $# > 0 )); do
    case "$1" in
      --) shift; break ;;
      *=*) env_vars+=("$1"); shift ;;
      *) break ;;
    esac
  done

  local out_file ec
  out_file=$(mktemp)
  set +e
  env "${env_vars[@]}" "$PM" ondemand webhook >"$out_file" 2>&1
  ec=$?
  set -e
  RUN_OUT=$(cat "$out_file")
  RUN_EC=$ec
  rm -f "$out_file"

  local json
  json=$(printf '%s\n' "$RUN_OUT" | grep -E '^\{.*"status":' | tail -n1 || true)
  if [[ "$expected" == ok ]]; then
    if [[ "$RUN_EC" -eq 0 && "$json" == *'"status":"ok"'* ]]; then
      pass "$name"
    else
      fail "$name (exit $RUN_EC, expected ok JSON)"
      printf '%s\n' "$RUN_OUT" | sed 's/^/    /'
    fi
  else
    if [[ "$RUN_EC" -ne 0 && "$json" == *'"status":"error"'* ]]; then
      pass "$name"
    else
      fail "$name (exit $RUN_EC, expected error JSON)"
      printf '%s\n' "$RUN_OUT" | sed 's/^/    /'
    fi
  fi
}

write_env() {
  # Use ${1-...} (not :- ) so an explicit empty email is preserved.
  local email=${1-test@example.com}
  cat >"$TEST_ROOT/.env" <<EOF
NGINX_DIR=./nginx
ACME_EMAIL=$email
EOF
}

seed_ondemand_template() {
  install -d -m 0755 "$NGINX_TREE/templates"
  cat >"$NGINX_TREE/templates/default.tpl" <<'EOF'
server {
    listen 80;
    listen [::]:80;
    server_name {{ .domain }};

    location ^~ /.well-known/acme-challenge/ {
        root "{{ .acme_webroot }}";
        default_type text/plain;
        try_files $uri =404;
    }
    location / { return 301 https://$host$request_uri; }
}

server {
    include "{{ .snippet_dir }}/proxy-host.conf";
    server_name {{ .domain }};
    ssl_certificate "{{ .ssl_dir }}/{{ .domain }}/fullchain.pem";
    ssl_certificate_key "{{ .ssl_dir }}/{{ .domain }}/privkey.pem";

    location / {
        access_log "{{ .log_dir }}/{{ .domain }}.access.log" proxy_timing buffer=64k flush=60s;
        proxy_pass {{ .upstream }};
    }
}
EOF
}

setup_fixture() {
  TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/proxy-man-test.XXXXXX")
  cp "$DIST_SCRIPT" "$TEST_ROOT/proxy-man.sh"
  chmod +x "$TEST_ROOT/proxy-man.sh"
  write_env
  PM="$TEST_ROOT/proxy-man.sh"
  NGINX_TREE="$TEST_ROOT/nginx"
}

# --- prepare ---
section "build"
if [[ ! -x "$BUILD_SCRIPT" ]]; then
  printf 'test: missing %s\n' "$BUILD_SCRIPT" >&2
  exit 2
fi
"$BUILD_SCRIPT"
[[ -f "$DIST_SCRIPT" ]] || { printf 'test: dist script missing after build\n' >&2; exit 2; }
pass "built dist/proxy-man.sh"

setup_fixture
section "fixture $TEST_ROOT"

# --- help / errors before init ---
section "help and pre-init guards"
assert_ok_matches "help" "Commands:" help
assert_ok_matches "help via -h" "ondemand" -h
assert_fail_matches "unknown command" "Unknown command" nosuchcmd
assert_fail_matches "list before init" "init" list
assert_fail_matches "status before init" "init" status
assert_fail_matches "proxy before init" "init" proxy app.example.com http://127.0.0.1:3000

# --- init ---
section "init"
assert_ok_matches "init" "Initialized Nginx" init
assert_file "nginx.conf" "$NGINX_TREE/nginx.conf"
assert_file "default host" "$NGINX_TREE/conf.d/00-default.conf"
assert_file "upstreams template" "$NGINX_TREE/conf.d/upstreams.conf"
assert_file "mime.types" "$NGINX_TREE/mime.types"
assert_file "proxy-host snippet" "$NGINX_TREE/snippets/proxy-host.conf"
assert_file "default fullchain" "$NGINX_TREE/ssl/default/fullchain.pem"
assert_file "default privkey" "$NGINX_TREE/ssl/default/privkey.pem"
assert_file "acme domain list" "$NGINX_TREE/acme-domains.txt"
assert_dir "conf.d/ondemand" "$NGINX_TREE/conf.d/ondemand"
assert_dir "acme-webroot" "$NGINX_TREE/acme-webroot"
assert_dir "cache" "$NGINX_TREE/cache"
assert_dir "logs" "$NGINX_TREE/logs"
assert_file_matches "http3 enabled" "$NGINX_TREE/snippets/proxy-host.conf" "http3"
assert_file_matches "http2 enabled" "$NGINX_TREE/snippets/proxy-host.conf" "http2"
assert_file_matches "ondemand include" "$NGINX_TREE/nginx.conf" "ondemand/\\*\\.conf"
assert_ok_matches "init is idempotent" "Initialized Nginx" init

if command -v nginx >/dev/null 2>&1; then
  if nginx -t -p "$NGINX_TREE/" -c "$NGINX_TREE/nginx.conf" >/dev/null 2>&1; then
    pass "nginx -t on generated tree"
  else
    fail "nginx -t on generated tree"
    nginx -t -p "$NGINX_TREE/" -c "$NGINX_TREE/nginx.conf" 2>&1 | sed 's/^/    /' || true
  fi
else
  skip "nginx not installed; config test skipped"
fi

# --- proxy ---
section "proxy"
# WebSocket + static cache prompts (defaults are y/y; answer explicitly).
run_pm proxy app.example.com http://127.0.0.1:3000 <<'EOF'
y
y
EOF
if [[ "$RUN_EC" -eq 0 ]] && grep -Eq "Created proxy https://app.example.com" <<<"$RUN_OUT"; then
  pass "proxy create app.example.com"
else
  fail "proxy create app.example.com (exit $RUN_EC)"
  printf '%s\n' "$RUN_OUT" | sed 's/^/    /'
fi

assert_file "proxy conf" "$NGINX_TREE/conf.d/app.example.com.conf"
assert_file "domain cert fullchain" "$NGINX_TREE/ssl/app.example.com/fullchain.pem"
assert_file "domain cert privkey" "$NGINX_TREE/ssl/app.example.com/privkey.pem"
assert_file_matches "proxy_pass upstream" "$NGINX_TREE/conf.d/app.example.com.conf" \
  'proxy_pass http://127\.0\.0\.1:3000;'
assert_file_matches "websocket upgrade header" "$NGINX_TREE/conf.d/app.example.com.conf" \
  'proxy_set_header Upgrade'
assert_file_matches "static cache zone" "$NGINX_TREE/conf.d/app.example.com.conf" \
  'proxy_cache public_zone'
assert_file_matches "acme challenge location" "$NGINX_TREE/conf.d/app.example.com.conf" \
  'acme-challenge'

run_pm proxy 'not a domain' http://127.0.0.1:1 <<'EOF'
y
y
EOF
if [[ "$RUN_EC" -ne 0 ]] && grep -Eq "Invalid domain" <<<"$RUN_OUT"; then
  pass "proxy rejects invalid domain"
else
  fail "proxy rejects invalid domain"
  printf '%s\n' "$RUN_OUT" | sed 's/^/    /'
fi

run_pm proxy bad-up.example.com 'ftp://127.0.0.1:21' <<'EOF'
y
y
EOF
if [[ "$RUN_EC" -ne 0 ]] && grep -Eq "Upstream must be" <<<"$RUN_OUT"; then
  pass "proxy rejects invalid upstream"
else
  fail "proxy rejects invalid upstream"
  printf '%s\n' "$RUN_OUT" | sed 's/^/    /'
fi

# Prompt order is: WebSocket, cache, then replace (only when conf exists).
# Decline replace — conf must stay unchanged.
cp -a "$NGINX_TREE/conf.d/app.example.com.conf" "$TEST_ROOT/app.conf.bak"
run_pm proxy app.example.com http://127.0.0.1:3001 <<'EOF'
n
n
n
EOF
if [[ "$RUN_EC" -ne 0 ]] && grep -Eq "No changes made" <<<"$RUN_OUT" \
  && cmp -s "$TEST_ROOT/app.conf.bak" "$NGINX_TREE/conf.d/app.example.com.conf"; then
  pass "proxy decline replace keeps conf"
else
  fail "proxy decline replace keeps conf"
  printf '%s\n' "$RUN_OUT" | sed 's/^/    /'
fi

# Accept replace with no websocket / no cache.
run_pm proxy app.example.com http://127.0.0.1:3001 <<'EOF'
n
n
y
EOF
if [[ "$RUN_EC" -eq 0 ]] \
  && grep -Eq 'proxy_pass http://127\.0\.0\.1:3001;' "$NGINX_TREE/conf.d/app.example.com.conf" \
  && ! grep -Eq 'proxy_set_header Upgrade' "$NGINX_TREE/conf.d/app.example.com.conf" \
  && ! grep -Eq 'proxy_cache public_zone' "$NGINX_TREE/conf.d/app.example.com.conf"; then
  pass "proxy replace without websocket/cache"
else
  fail "proxy replace without websocket/cache"
  printf '%s\n' "$RUN_OUT" | sed 's/^/    /'
fi

# Second domain for list/status breadth.
run_pm proxy api.example.com http://127.0.0.1:4000 <<'EOF'
n
y
EOF
if [[ "$RUN_EC" -eq 0 ]]; then
  pass "proxy create api.example.com"
else
  fail "proxy create api.example.com (exit $RUN_EC)"
  printf '%s\n' "$RUN_OUT" | sed 's/^/    /'
fi

# --- list / status ---
section "list and status"
assert_ok_matches "list shows domains" "app.example.com" list
assert_ok_matches "list acme no" $'app.example.com[[:space:]]+no' list
assert_ok_matches "status header" "Nginx:" status
assert_ok_matches "status shows upstream" "app.example.com" status
assert_ok_matches "status certificate cell" "CERTIFICATE" status

# Simulate a recorded ACME method without talking to Let's Encrypt.
printf 'app.example.com\thttp\n' >"$NGINX_TREE/acme-domains.txt"
assert_ok_matches "list shows http-01 after record" $'app.example.com[[:space:]]+http-01' list
printf 'api.example.com\tdns\tcloudflare\n' >>"$NGINX_TREE/acme-domains.txt"
assert_ok_matches "list shows dns-01 provider" $'api.example.com[[:space:]]+dns-01 \(cloudflare\)' list
# Reset domain file for later cron empty/non-empty checks.
: >"$NGINX_TREE/acme-domains.txt"

# --- acme guards (no real issuance) ---
section "acme guards (no real LE/DNS)"
assert_fail_matches "acme requires existing proxy" "Create the proxy first" acme missing.example.com
assert_fail_matches "acme unknown option" "Unknown acme option" acme app.example.com --bogus
assert_fail_matches "acme dns missing provider" "--dns requires" acme app.example.com --dns
assert_fail_matches "acme wildcard needs dns" "Wildcard certificates require DNS-01" \
  acme '*.example.com'
assert_fail_matches "acme http needs public A (or dig)" \
  "(no public A record|dig is required)" acme app.example.com

write_env ""
assert_fail_matches "acme requires ACME_EMAIL" "ACME_EMAIL" acme app.example.com
write_env "test@example.com"

# --- cron ---
section "cron"
assert_ok_matches "cron with empty domain list" "No domains are recorded" cron

# --- analyze ---
section "analyze"
# nginx -t may create empty per-domain log files; remove so the guard is testable.
rm -f "$NGINX_TREE/logs/app.example.com.access.log"
if command -v goaccess >/dev/null 2>&1; then
  assert_fail_matches "analyze without log" "No access log exists" analyze app.example.com
else
  assert_fail_matches "analyze without goaccess" "GoAccess is not installed" analyze app.example.com
fi
assert_fail_matches "analyze unknown domain" "No proxy configuration" analyze nope.example.com

# --- ondemand (template render path; no public endpoint / no real ACME) ---
section "ondemand webhook (local render, acme=false)"
assert_ok_matches "ondemand help" "setup" ondemand help
assert_ok_matches "ondemand show before templates" "templates dir" ondemand show
assert_fail_matches "ondemand unknown subcommand" "Unknown ondemand subcommand" ondemand nope

if ! command -v gomplate >/dev/null 2>&1; then
  skip "gomplate not installed; ondemand webhook create/delete skipped"
else
  seed_ondemand_template
  assert_file "seeded default.tpl" "$NGINX_TREE/templates/default.tpl"
  assert_ok_matches "ondemand show lists template" "default.tpl" ondemand show

  assert_json_status "ondemand create od.example.com" ok \
    OD_ACTION=create \
    OD_TEMPLATE=default.tpl \
    OD_DOMAIN=od.example.com \
    OD_UPSTREAM=http://127.0.0.1:5000 \
    OD_ACME=false \
    OD_REPLACE=false

  assert_file "ondemand conf written" "$NGINX_TREE/conf.d/ondemand/od.example.com.conf"
  assert_file_matches "ondemand conf proxy_pass" \
    "$NGINX_TREE/conf.d/ondemand/od.example.com.conf" \
    'proxy_pass http://127\.0\.0\.1:5000;'
  assert_file "ondemand domain cert" "$NGINX_TREE/ssl/od.example.com/fullchain.pem"
  assert_ok_matches "list includes ondemand domain" "od.example.com" list

  # Manual proxy must refuse domains already owned by ondemand.
  run_pm proxy od.example.com http://127.0.0.1:5001 <<'EOF'
y
y
EOF
  if [[ "$RUN_EC" -ne 0 ]] && grep -Eq "managed by ondemand" <<<"$RUN_OUT"; then
    pass "proxy blocks ondemand-owned domain"
  else
    fail "proxy blocks ondemand-owned domain"
    printf '%s\n' "$RUN_OUT" | sed 's/^/    /'
  fi

  # Create without replace must fail when conf exists.
  assert_json_status "ondemand create without replace fails" error \
    OD_ACTION=create \
    OD_TEMPLATE=default.tpl \
    OD_DOMAIN=od.example.com \
    OD_UPSTREAM=http://127.0.0.1:5002 \
    OD_ACME=false \
    OD_REPLACE=false

  assert_json_status "ondemand replace od.example.com" ok \
    OD_ACTION=create \
    OD_TEMPLATE=default.tpl \
    OD_DOMAIN=od.example.com \
    OD_UPSTREAM=http://127.0.0.1:5002 \
    OD_ACME=false \
    OD_REPLACE=true
  assert_file_matches "ondemand conf replaced upstream" \
    "$NGINX_TREE/conf.d/ondemand/od.example.com.conf" \
    'proxy_pass http://127\.0\.0\.1:5002;'

  assert_json_status "ondemand create rejects bad upstream" error \
    OD_ACTION=create \
    OD_TEMPLATE=default.tpl \
    OD_DOMAIN=badup.example.com \
    OD_UPSTREAM=not-a-url \
    OD_ACME=false

  assert_json_status "ondemand create rejects missing template" error \
    OD_ACTION=create \
    OD_TEMPLATE=missing.tpl \
    OD_DOMAIN=miss.example.com \
    OD_UPSTREAM=http://127.0.0.1:1 \
    OD_ACME=false

  assert_json_status "ondemand create rejects invalid domain" error \
    OD_ACTION=create \
    OD_TEMPLATE=default.tpl \
    OD_DOMAIN='not a domain' \
    OD_UPSTREAM=http://127.0.0.1:1 \
    OD_ACME=false

  # Conflict: ondemand must not overwrite a manual conf.d proxy.
  assert_json_status "ondemand refuses manual conf.d domain" error \
    OD_ACTION=create \
    OD_TEMPLATE=default.tpl \
    OD_DOMAIN=app.example.com \
    OD_UPSTREAM=http://127.0.0.1:1 \
    OD_ACME=false \
    OD_REPLACE=true

  assert_json_status "ondemand delete od.example.com" ok \
    OD_ACTION=delete \
    OD_DOMAIN=od.example.com

  if [[ ! -e "$NGINX_TREE/conf.d/ondemand/od.example.com.conf" ]]; then
    pass "ondemand conf removed after delete"
  else
    fail "ondemand conf removed after delete"
  fi

  assert_json_status "ondemand delete missing domain" error \
    OD_ACTION=delete \
    OD_DOMAIN=od.example.com

  assert_json_status "ondemand unknown action" error \
    OD_ACTION=nope \
    OD_DOMAIN=x.example.com
fi

# Real ACME issuance is intentionally not exercised here (needs a public domain).
section "acme issuance"
skip "real ACME/lego issuance (requires public domain + HTTP-01 or DNS-01 credentials)"

# --- summary ---
section "summary"
printf 'Passed: %s  Failed: %s  Skipped: %s\n' "$PASS" "$FAIL" "$SKIP"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
