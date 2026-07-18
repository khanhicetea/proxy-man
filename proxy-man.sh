#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ENV_FILE="$SCRIPT_DIR/.env"

# .env is a trusted shell-style configuration file.
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

NGINX_DIR=${NGINX_DIR:-/etc/nginx}
ACME_EMAIL=${ACME_EMAIL:-proxyman@example.com}
if [[ "$NGINX_DIR" != /* ]]; then
  NGINX_DIR="$SCRIPT_DIR/${NGINX_DIR#./}"
fi
NGINX_DIR=${NGINX_DIR%/}

CONF_DIR="$NGINX_DIR/conf.d"
SNIPPET_DIR="$NGINX_DIR/snippets"
SSL_DIR="$NGINX_DIR/ssl"
ACME_WEBROOT="$NGINX_DIR/acme-webroot"
LEGO_DIR="$NGINX_DIR/lego"
DOMAIN_FILE="$NGINX_DIR/acme-domains.txt"
if [[ "$NGINX_DIR" == /etc/nginx ]]; then
  NGINX_PID=/var/run/nginx.pid
  LOG_DIR=/var/log/nginx
  CACHE_DIR=/var/cache/nginx
else
  NGINX_PID="$NGINX_DIR/nginx.pid"
  LOG_DIR="$NGINX_DIR/logs"
  CACHE_DIR="$NGINX_DIR/cache"
fi
PUBLIC_CACHE_DIR="$CACHE_DIR/public_zone"
PRIVATE_CACHE_DIR="$CACHE_DIR/private_zone"

log() { printf '[proxy-man] %s\n' "$*"; }
warn() { printf '[proxy-man] WARNING: %s\n' "$*" >&2; }
die() { printf '[proxy-man] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./proxy-man.sh <command> [arguments]

Commands:
  install                 Install Nginx, lego, and GoAccess
  init                    Create an optimized Nginx configuration
  proxy [domain] [url]    Create conf.d/<domain>.conf
  list                    List configured domains and ACME status
  acme [domain]           Issue an HTTP-01 certificate with lego
  analyze [domain]        Analyze a domain access log in the GoAccess TUI
  goaccess [domain]       Alias for analyze
  cron                    Renew all recorded certificates when due
  help                    Show this help
EOF
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "This command must be run as root."
}

require_config_root() {
  if [[ "$NGINX_DIR" == /etc/* || "$NGINX_DIR" == /usr/* || "$NGINX_DIR" == /var/* ]]; then
    require_root
  fi
}

prompt_value() {
  local message=$1 default=${2:-} value
  if [[ -n "$default" ]]; then
    read -r -p "$message [$default]: " value || true
    printf '%s' "${value:-$default}"
  else
    read -r -p "$message: " value || true
    printf '%s' "$value"
  fi
}

prompt_yes_no() {
  local message=$1 default=${2:-y} answer
  if [[ "$default" == y ]]; then
    read -r -p "$message [Y/n]: " answer || true
    answer=${answer:-y}
  else
    read -r -p "$message [y/N]: " answer || true
    answer=${answer:-n}
  fi
  [[ "$answer" =~ ^[Yy]$ ]]
}

validate_domain() {
  local domain=$1 label
  [[ ${#domain} -le 253 && "$domain" == *.* ]] || return 1
  [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  [[ "$domain" != .* && "$domain" != *. && "$domain" != *..* ]] || return 1
  IFS=. read -r -a labels <<< "$domain"
  for label in "${labels[@]}"; do
    [[ -n "$label" && ${#label} -le 63 ]] || return 1
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
}

validate_upstream() {
  local upstream=$1
  local pattern='^https?://(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9._-]+)(:[0-9]{1,5})?$'
  [[ "$upstream" =~ $pattern ]]
}

nginx_test() {
  if ! command -v nginx >/dev/null 2>&1; then
    warn "nginx is not installed; configuration test skipped."
    return 0
  fi
  nginx -t -p "$NGINX_DIR/" -c "$NGINX_DIR/nginx.conf"
}

reload_nginx() {
  nginx_test || return 1
  if [[ "$NGINX_DIR" == /etc/nginx ]] && command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
    systemctl reload nginx
  elif [[ -f "$NGINX_PID" ]] && kill -0 "$(cat "$NGINX_PID")" 2>/dev/null; then
    nginx -s reload -p "$NGINX_DIR/" -c "$NGINX_DIR/nginx.conf"
  else
    warn "Nginx is not running; configuration was written but not reloaded."
  fi
}

install_nginx_apt() {
  local distro codename
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}" in
    debian) distro=debian ;;
    ubuntu) distro=ubuntu ;;
    *)
      if [[ " ${ID_LIKE:-} " == *" debian "* ]]; then
        distro=ubuntu
      else
        die "Unsupported apt distribution: ${ID:-unknown}"
      fi
      ;;
  esac
  codename=${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}
  if [[ -z "$codename" ]] && command -v lsb_release >/dev/null 2>&1; then
    codename=$(lsb_release -cs)
  fi
  [[ -n "$codename" ]] || die "Could not determine the distribution codename."

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg openssl tar dnsutils goaccess
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor --yes -o /usr/share/keyrings/nginx-archive-keyring.gpg
  printf 'deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/%s %s nginx\n' \
    "$distro" "$codename" > /etc/apt/sources.list.d/nginx.list
  cat > /etc/apt/preferences.d/99nginx <<'EOF'
Package: *
Pin: origin nginx.org
Pin-Priority: 900
EOF
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y nginx
}

install_nginx_rpm() {
  local manager
  if command -v dnf >/dev/null 2>&1; then manager=dnf; else manager=yum; fi
  "$manager" install -y ca-certificates curl openssl tar bind-utils
  cat > /etc/yum.repos.d/nginx.repo <<'EOF'
[nginx-stable]
name=nginx stable repo
baseurl=http://nginx.org/packages/centos/$releasever/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
EOF
  "$manager" install -y nginx
  if ! "$manager" install -y goaccess; then
    log "GoAccess was not found in the enabled repositories; enabling EPEL..."
    "$manager" install -y epel-release
    "$manager" install -y goaccess
  fi
}

tune_os_for_nginx() {
  log "Tuning operating-system limits and TCP settings for an Nginx proxy..."

  cat > /etc/sysctl.d/99-nginx-proxy-man.conf <<'EOF'
# Managed by nginx-proxy-man.
fs.file-max = 2097152
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_tw_reuse = 1
EOF

  install -d -m 0755 /etc/security/limits.d
  cat > /etc/security/limits.d/99-nginx-proxy-man.conf <<'EOF'
# Managed by nginx-proxy-man.
nginx soft nofile 65535
nginx hard nofile 65535
www-data soft nofile 65535
www-data hard nofile 65535
EOF

  # PAM limits do not apply to systemd services, so set the service limit too.
  if command -v systemctl >/dev/null 2>&1; then
    install -d -m 0755 /etc/systemd/system/nginx.service.d
    cat > /etc/systemd/system/nginx.service.d/limits.conf <<'EOF'
[Service]
LimitNOFILE=65535
EOF
    if [[ -d /run/systemd/system ]]; then
      systemctl daemon-reload
      systemctl try-restart nginx || warn "Could not restart Nginx; the new file limit will apply on its next restart."
    fi
  fi

  sysctl --system >/dev/null 2>&1 || warn "Some sysctl settings could not be applied now; they remain installed for the next boot."
}

install_lego() {
  local machine arch latest_url tag version archive tmp
  machine=$(uname -m)
  case "$machine" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    armv7l|armv7) arch=armv7 ;;
    i386|i686) arch=386 ;;
    *) die "lego has no configured download for architecture: $machine" ;;
  esac

  latest_url=$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/go-acme/lego/releases/latest)
  tag=${latest_url##*/}
  [[ "$tag" =~ ^v[0-9] ]] || die "Could not determine the latest lego release."
  version=${tag#v}
  archive="lego_v${version}_linux_${arch}.tar.gz"
  tmp=$(mktemp -d)
  log "Downloading lego $tag..."
  if ! curl -fsSL "https://github.com/go-acme/lego/releases/download/${tag}/${archive}" -o "$tmp/lego.tar.gz"; then
    rm -rf "$tmp"
    die "Failed to download $archive"
  fi
  tar -xzf "$tmp/lego.tar.gz" -C "$tmp" lego
  install -m 0755 "$tmp/lego" /usr/local/bin/lego
  rm -rf "$tmp"
}

command_install() {
  require_root
  if command -v apt-get >/dev/null 2>&1; then
    install_nginx_apt
  elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    install_nginx_rpm
  else
    die "Only apt, dnf, and yum systems are supported."
  fi
  install_lego
  tune_os_for_nginx
  log "Installed $(nginx -v 2>&1)"
  log "Installed $(lego --version 2>&1)"
  log "Installed GoAccess."
  log "Next: run '$0 init'."
}

make_self_signed_cert() {
  local cert_dir="$SSL_DIR/default"
  install -d -m 0755 "$cert_dir"
  if [[ ! -s "$cert_dir/fullchain.pem" || ! -s "$cert_dir/privkey.pem" ]]; then
    command -v openssl >/dev/null 2>&1 || die "openssl is required to generate the default certificate."
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
      -subj '/CN=default.invalid' \
      -addext 'subjectAltName=DNS:default.invalid' \
      -keyout "$cert_dir/privkey.pem" -out "$cert_dir/fullchain.pem"
    chmod 0600 "$cert_dir/privkey.pem"
    chmod 0644 "$cert_dir/fullchain.pem"
  fi
}

write_mime_types() {
  [[ -f "$NGINX_DIR/mime.types" ]] && return 0
  cat > "$NGINX_DIR/mime.types" <<'EOF'
types {
    text/html                             html htm shtml;
    text/css                              css;
    text/plain                            txt;
    application/javascript               js mjs;
    application/json                     json;
    application/xml                      xml;
    image/avif                            avif;
    image/gif                             gif;
    image/jpeg                            jpeg jpg;
    image/png                             png;
    image/svg+xml                         svg svgz;
    image/webp                            webp;
    image/x-icon                          ico;
    font/ttf                              ttf;
    font/woff                             woff;
    font/woff2                            woff2;
    application/octet-stream             bin exe dll;
    application/pdf                      pdf;
    application/wasm                     wasm;
}
EOF
}

write_nginx_conf() {
  local worker_user
  if id nginx >/dev/null 2>&1; then
    worker_user=nginx
  elif id www-data >/dev/null 2>&1; then
    worker_user=www-data
  else
    worker_user=$(id -un)
  fi

  cat > "$NGINX_DIR/nginx.conf" <<EOF
user $worker_user;
worker_processes auto;
worker_rlimit_nofile 65535;
pid "$NGINX_PID";
error_log "$LOG_DIR/error.log" warn;

events {
    worker_connections 4096;
    multi_accept on;
}

http {
    include "$NGINX_DIR/mime.types";
    include "$SNIPPET_DIR/block-bot-map.conf";
    default_type application/octet-stream;

    log_format proxy_timing '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                            '\$status \$body_bytes_sent "\$http_referer" "\$http_user_agent" '
                            'request_time=\$request_time connect=\$upstream_connect_time '
                            'header=\$upstream_header_time response=\$upstream_response_time';
    access_log "$LOG_DIR/access.log" proxy_timing;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    keepalive_requests 1000;
    server_tokens off;
    types_hash_max_size 4096;
    client_max_body_size 100m;

    gzip on;
    gzip_vary on;
    gzip_comp_level 5;
    gzip_min_length 1024;
    gzip_types text/plain text/css application/json application/javascript application/xml image/svg+xml;

    # Modern mobile clients can choose ChaCha20 when AES acceleration is weak,
    # while AES-GCM remains fast on devices with hardware support.
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384';
    ssl_conf_command Ciphersuites 'TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_256_GCM_SHA384';
    ssl_ecdh_curve X25519:prime256v1:secp384r1;
    ssl_prefer_server_ciphers off;

    # Shared stateful resumption avoids repeated handshakes without persistent
    # session-ticket keys; this also supports TLS 1.3 resumption in OpenSSL.
    ssl_session_cache shared:SSL:20m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        ''      close;
    }

    proxy_cache_path "$PUBLIC_CACHE_DIR" levels=1:2 keys_zone=public_zone:50m
                     max_size=10g inactive=30d use_temp_path=off;
    proxy_cache_path "$PRIVATE_CACHE_DIR" levels=1:2 keys_zone=private_zone:50m
                     max_size=10g inactive=30d use_temp_path=off;

    include "$CONF_DIR/*.conf";
}
EOF
}

write_upstreams_conf() {
  # Preserve this file on later init runs because it is intended to be edited.
  [[ -e "$CONF_DIR/upstreams.conf" ]] && return 0
  cat > "$CONF_DIR/upstreams.conf" <<'EOF'
# Reusable upstream groups. Uncomment and adapt a block, then use its name in
# proxy_pass (for example: proxy_pass http://example_app;). The addresses below
# are RFC 5737 documentation/test addresses and will not route to real hosts.
#
# upstream example_app {
#     server 192.0.2.10:3000;
#     server 192.0.2.11:3000 backup;
#
#     keepalive 32;
#     keepalive_requests 1000;
#     keepalive_timeout 60s;
# }
#
# upstream example_api {
#     least_conn;
#     server 198.51.100.10:8080;
#     server 198.51.100.11:8080;
#
#     keepalive 64;
#     keepalive_requests 1000;
#     keepalive_timeout 60s;
# }
#
# HTTP upstream keepalive also requires proxy_http_version 1.1 (already set by
# snippets/proxy-host.conf) and a cleared Connection header for non-WebSocket
# hosts: proxy_set_header Connection "";
EOF
}

write_snippets() {
  # These directives are valid at server scope and are inherited by each
  # proxy location. Per-host files only need to provide values that vary.
  cat > "$SNIPPET_DIR/proxy-host.conf" <<'EOF'
listen 443 ssl;
listen [::]:443 ssl;
listen 443 quic;
listen [::]:443 quic;
http2 on;
http3 on;
quic_retry on;
add_header Alt-Svc 'h3=":443"; ma=86400' always;

proxy_http_version 1.1;
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Host $host;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Port $server_port;
proxy_connect_timeout 10s;
proxy_send_timeout 60s;
proxy_read_timeout 60s;
proxy_buffering on;

# Do not expose hidden files or directories through the upstream. Keep the
# standardized .well-known namespace available for ACME and application use.
location ~ /\.(?!well-known(?:/|$)) {
    return 404;
}
EOF

  # The map must be loaded at http scope. Known crawlers are checked before the
  # generic deny rule, and ordinary browsers fall through to the allowed default.
  cat > "$SNIPPET_DIR/block-bot-map.conf" <<'EOF'
# User-Agent strings are self-reported and easily spoofed. This filter deters
# basic crawlers; it is not authentication or a replacement for rate limiting.
map $http_user_agent $block_bot {
    default 0;

    # Reject clients that omit User-Agent entirely.
    "" 1;

    # AI and LLM crawlers explicitly allowed by policy.
    ~*(?:GPTBot|ChatGPT-User|OAI-SearchBot|ClaudeBot|Claude-User|Claude-SearchBot|anthropic-ai|PerplexityBot|Perplexity-User|CCBot|Meta-ExternalAgent|meta-externalfetcher|cohere-ai|Omgilibot|FacebookBot) 0;

    # Major search, archive, preview, and social-media crawlers.
    ~*(?:Googlebot|GoogleOther|Google-InspectionTool|AdsBot-Google|Mediapartners-Google|bingbot|BingPreview|MicrosoftPreview|Slurp|DuckDuckBot|Baiduspider|YandexBot|Sogou.*Spider|Exabot|ia_archiver|Applebot|facebookexternalhit|Facebot|Twitterbot|LinkedInBot|Pinterestbot|WhatsApp|TelegramBot|Discordbot|Slackbot|SkypeUriPreview) 0;

    # Unknown bots and common scraping/automation clients.
    ~*(?:bot|spider|crawl|scrap|python|curl|wget|aiohttp|httpx|http-client|go-http-client|libwww|perl|mechanize|scrapy|headlesschrome|phantomjs|selenium|puppeteer|playwright|apache-httpclient|okhttp|java/|node-fetch|axios|postmanruntime|insomnia|aws-sdk) 1;
}
EOF

  # This server-scope snippet is intentionally opt-in from proxy-host.conf.
  cat > "$SNIPPET_DIR/block-bot.conf" <<'EOF'
if ($block_bot) {
    return 403;
}
EOF

  # Keep legacy snippets while an existing host still includes either one.
  if ! grep -RqsE 'proxy-(common|websocket)\.conf' "$CONF_DIR"; then
    rm -f "$SNIPPET_DIR/proxy-common.conf" "$SNIPPET_DIR/proxy-websocket.conf"
  fi
}

install_and_configure_logrotate() {
  # Development trees should remain self-contained and must not modify /etc.
  if [[ "$NGINX_DIR" != /etc/* && "$NGINX_DIR" != /usr/* && "$NGINX_DIR" != /var/* ]]; then
    log "Skipping system logrotate setup for development NGINX_DIR=$NGINX_DIR."
    return 0
  fi

  if ! command -v logrotate >/dev/null 2>&1; then
    log "Installing logrotate..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y logrotate
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y logrotate
    elif command -v yum >/dev/null 2>&1; then
      yum install -y logrotate
    else
      die "Could not install logrotate: no supported package manager was found."
    fi
  fi

  # Replace the package's broad Nginx rule rather than creating an overlapping
  # rule. All access logs (including per-domain logs) live in this directory.
  cat > /etc/logrotate.d/nginx <<EOF
"$LOG_DIR/*.log" {
    daily
    maxsize 100M
    rotate 2
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        if [ -s "$NGINX_PID" ]; then
            kill -USR1 "\$(cat "$NGINX_PID")" 2>/dev/null || true
        fi
    endscript
}
EOF
  chmod 0644 /etc/logrotate.d/nginx
  log "Configured logrotate for $LOG_DIR/*.log (100 MiB maximum, 2 rotations)."
}

write_default_host() {
  cat > "$CONF_DIR/00-default.conf" <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    location ^~ /.well-known/acme-challenge/ {
        root "$ACME_WEBROOT";
        default_type text/plain;
        try_files \$uri =404;
    }
    location / { return 404; }
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    listen 443 quic reuseport default_server;
    listen [::]:443 quic reuseport default_server;
    http2 on;
    http3 on;
    server_name _;

    ssl_certificate "$SSL_DIR/default/fullchain.pem";
    ssl_certificate_key "$SSL_DIR/default/privkey.pem";
    quic_retry on;
    add_header Alt-Svc 'h3=":443"; ma=86400' always;
    return 404;
}
EOF
}

command_init() {
  require_config_root
  install -d -m 0755 "$NGINX_DIR" "$CONF_DIR" "$SNIPPET_DIR" "$SSL_DIR" \
    "$ACME_WEBROOT/.well-known/acme-challenge" "$PUBLIC_CACHE_DIR" \
    "$PRIVATE_CACHE_DIR" "$LOG_DIR" "$LEGO_DIR"

  if [[ -f "$NGINX_DIR/nginx.conf" ]]; then
    cp -a "$NGINX_DIR/nginx.conf" "$NGINX_DIR/nginx.conf.bak.$(date +%Y%m%d%H%M%S)"
  fi
  make_self_signed_cert
  write_mime_types
  write_upstreams_conf
  write_snippets
  write_nginx_conf
  if [[ -f "$CONF_DIR/default.conf" ]]; then
    mv "$CONF_DIR/default.conf" "$CONF_DIR/default.conf.disabled.$(date +%Y%m%d%H%M%S)"
    log "Disabled the package's default.conf to avoid a default-server conflict."
  fi
  write_default_host
  install_and_configure_logrotate
  touch "$DOMAIN_FILE"
  chmod 0644 "$DOMAIN_FILE"

  if id nginx >/dev/null 2>&1; then
    chown -R nginx:nginx "$CACHE_DIR" "$LOG_DIR"
  elif id www-data >/dev/null 2>&1; then
    chown -R www-data:www-data "$CACHE_DIR" "$LOG_DIR"
  fi

  nginx_test
  if [[ "$NGINX_DIR" == /etc/nginx ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl restart nginx
  fi
  log "Initialized Nginx in $NGINX_DIR (HTTP/2, HTTP/3, TLS, upstream template, proxy cache, and default 404 host)."
}

ensure_domain_cert() {
  local domain=$1 cert_dir="$SSL_DIR/$1"
  install -d -m 0755 "$cert_dir"
  if [[ ! -s "$cert_dir/fullchain.pem" || ! -s "$cert_dir/privkey.pem" ]]; then
    cp "$SSL_DIR/default/fullchain.pem" "$cert_dir/fullchain.pem"
    cp "$SSL_DIR/default/privkey.pem" "$cert_dir/privkey.pem"
    chmod 0644 "$cert_dir/fullchain.pem"
    chmod 0600 "$cert_dir/privkey.pem"
  fi
}

command_proxy() {
  require_config_root
  [[ -f "$NGINX_DIR/nginx.conf" && -f "$CONF_DIR/00-default.conf" ]] || die "Run '$0 init' first."

  local domain=${1:-} upstream=${2:-} websocket cache config ws_headers ws_buffering cache_location backup=''
  [[ -n "$domain" ]] || domain=$(prompt_value "Main domain (for example, app.example.com)")
  domain=${domain,,}
  validate_domain "$domain" || die "Invalid domain: $domain"

  [[ -n "$upstream" ]] || upstream=$(prompt_value "Upstream URL" "http://127.0.0.1:3000")
  validate_upstream "$upstream" || die "Upstream must be an origin such as http://127.0.0.1:3000 (without a path)."

  if prompt_yes_no "Enable WebSocket forwarding?" y; then websocket=y; else websocket=n; fi
  if prompt_yes_no "Cache static files for 30 days?" y; then cache=y; else cache=n; fi

  config="$CONF_DIR/$domain.conf"
  if [[ -e "$config" ]]; then
    if ! prompt_yes_no "$config exists. Replace it?" n; then
      die "No changes made."
    fi
    backup=$(mktemp)
    cp -a "$config" "$backup"
  fi

  ensure_domain_cert "$domain"
  ws_headers=''
  ws_buffering=''
  if [[ "$websocket" == y ]]; then
    # Keep headers at server scope so they merge with the shared proxy headers.
    # A location-level proxy_set_header would replace inherited headers.
    ws_headers=$(cat <<'EOF'

    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
EOF
)
    ws_buffering=$'\n        proxy_buffering off;'
  fi

  cache_location=''
  if [[ "$cache" == y ]]; then
    cache_location=$(cat <<EOF

    location ~* \\.(?:css|js|mjs|jpg|jpeg|gif|png|webp|avif|svg|ico|woff|woff2|ttf|eot|map)\$ {
        proxy_pass $upstream;
        proxy_buffering on;
        proxy_cache public_zone; # Use private_zone for private routes.
        proxy_cache_lock on;
        proxy_cache_valid 200 30d;
        proxy_cache_valid 301 302 4h;
        proxy_cache_valid any 1m;
        expires 30d;
        add_header Cache-Control "public" always;
        add_header X-Proxy-Cache \$upstream_cache_status always;
        access_log off;
    }
EOF
)
  fi

  cat > "$config" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain;

    location ^~ /.well-known/acme-challenge/ {
        root "$ACME_WEBROOT";
        default_type text/plain;
        try_files \$uri =404;
    }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    include "$SNIPPET_DIR/proxy-host.conf";

    # Optional UA filter; review block-bot-map.conf before enabling.
    # include "$SNIPPET_DIR/block-bot.conf";

    server_name $domain;
    ssl_certificate "$SSL_DIR/$domain/fullchain.pem";
    ssl_certificate_key "$SSL_DIR/$domain/privkey.pem";$ws_headers

    location / {$ws_buffering
        access_log "$LOG_DIR/$domain.access.log" proxy_timing buffer=64k flush=60s;
        proxy_pass $upstream;
    }$cache_location
}
EOF

  if ! reload_nginx; then
    if [[ -n "$backup" ]]; then
      cp -a "$backup" "$config"
      rm -f "$backup"
      die "Nginx rejected the new proxy configuration; the previous file was restored."
    fi
    rm -f "$config"
    die "Nginx rejected the new proxy configuration; $config was removed."
  fi
  [[ -n "$backup" ]] && rm -f "$backup"
  log "Created proxy https://$domain -> $upstream in $config"
  log "The self-signed certificate is active until '$0 acme $domain' succeeds."
}

command_list() {
  [[ -d "$CONF_DIR" ]] || die "Run '$0 init' first."

  local file domain acme width=6
  local -a domains=()
  shopt -s nullglob
  for file in "$CONF_DIR"/*.conf; do
    domain=${file##*/}
    domain=${domain%.conf}
    if validate_domain "$domain"; then
      domains+=("$domain")
      (( ${#domain} > width )) && width=${#domain}
    fi
  done
  shopt -u nullglob

  printf '%-*s  %s\n' "$width" DOMAIN ACME
  printf '%-*s  %s\n' "$width" "$(printf '%*s' "$width" '' | tr ' ' '-')" '----'
  for domain in "${domains[@]}"; do
    acme=no
    if [[ -f "$DOMAIN_FILE" ]] && grep -Fxiq -- "$domain" "$DOMAIN_FILE"; then
      acme=yes
    fi
    printf '%-*s  %s\n' "$width" "$domain" "$acme"
  done
}

command_analyze() {
  command -v goaccess >/dev/null 2>&1 || die "GoAccess is not installed. Run '$0 install' first."

  local domain=${1:-} access_log
  [[ -n "$domain" ]] || domain=$(prompt_value "Domain to analyze")
  domain=${domain,,}
  validate_domain "$domain" || die "Invalid domain: $domain"
  [[ -f "$CONF_DIR/$domain.conf" ]] || die "No proxy configuration exists for $domain."

  access_log="$LOG_DIR/$domain.access.log"
  [[ -f "$access_log" ]] || die "No access log exists for $domain yet: $access_log"
  [[ -r "$access_log" ]] || die "Access log is not readable; run this command with sufficient permissions."

  # proxy_timing starts with the standard Nginx combined format; GoAccess
  # safely ignores the timing fields appended after the User-Agent.
  goaccess "$access_log" --log-format=COMBINED
}

check_dns_a() {
  local domain=$1 records public_ip
  command -v dig >/dev/null 2>&1 || die "dig is required (install dnsutils or bind-utils)."
  records=$(dig +short A "$domain" | grep -E '^[0-9]+(\.[0-9]+){3}$' || true)
  [[ -n "$records" ]] || die "$domain has no public A record."
  log "$domain A record(s): $(tr '\n' ' ' <<< "$records")"

  public_ip=$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
  if [[ -n "$public_ip" ]] && ! grep -Fxq "$public_ip" <<< "$records"; then
    warn "This server's public IPv4 ($public_ip) is not in the A records. HTTP-01 may fail (this can be normal behind a CDN/load balancer)."
  fi
}

deploy_lego_cert() {
  local domain=$1 test_mode=${2:-immediate}
  local source_cert="$LEGO_DIR/certificates/$1.crt" source_key="$LEGO_DIR/certificates/$1.key"
  local target="$SSL_DIR/$1" backup
  [[ "$test_mode" == immediate || "$test_mode" == deferred ]] || die "Invalid Nginx test mode: $test_mode"
  [[ -s "$source_cert" && -s "$source_key" ]] || die "lego succeeded but certificate files for $domain were not found."
  install -d -m 0755 "$target"
  backup=$(mktemp -d)
  [[ -f "$target/fullchain.pem" ]] && cp -a "$target/fullchain.pem" "$backup/fullchain.pem"
  [[ -f "$target/privkey.pem" ]] && cp -a "$target/privkey.pem" "$backup/privkey.pem"
  install -m 0644 "$source_cert" "$target/fullchain.pem"
  install -m 0600 "$source_key" "$target/privkey.pem"

  if [[ "$test_mode" == immediate ]] && ! nginx_test; then
    [[ -f "$backup/fullchain.pem" ]] && cp -a "$backup/fullchain.pem" "$target/fullchain.pem"
    [[ -f "$backup/privkey.pem" ]] && cp -a "$backup/privkey.pem" "$target/privkey.pem"
    rm -rf "$backup"
    die "The issued certificate failed the Nginx test; previous files were restored."
  fi
  rm -rf "$backup"
}

record_domain() {
  local domain=$1
  touch "$DOMAIN_FILE"
  grep -Fxiq "$domain" "$DOMAIN_FILE" || printf '%s\n' "$domain" >> "$DOMAIN_FILE"
}

lego_common_args() {
  LEGO_ARGS=(--accept-tos --email="$ACME_EMAIL" --path="$LEGO_DIR" --domains="$1" --http --http.webroot="$ACME_WEBROOT")
}

lego_major_version() {
  local version
  version=$(lego --version 2>&1) || die "Could not determine the installed lego version."
  if [[ "$version" =~ version[[:space:]]+v?([0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    die "Could not parse the installed lego version: $version"
  fi
}

lego_issue() {
  local domain=$1 major
  local -a LEGO_ARGS
  lego_common_args "$domain"
  major=$(lego_major_version)
  if (( major >= 5 )); then
    # lego v5 moved ACME and challenge flags from the global scope to `run`.
    lego run "${LEGO_ARGS[@]}"
  else
    lego "${LEGO_ARGS[@]}" run
  fi
}

lego_renew() {
  local domain=$1 major
  local -a LEGO_ARGS
  lego_common_args "$domain"
  major=$(lego_major_version)
  if (( major >= 5 )); then
    # In lego v5, `run` handles both issuance and renewal.
    lego run "${LEGO_ARGS[@]}" --renew-days 30
  else
    lego "${LEGO_ARGS[@]}" renew --days 30
  fi
}

command_acme() {
  require_config_root
  command -v lego >/dev/null 2>&1 || die "lego is not installed. Run '$0 install' first."
  local domain=${1:-}
  [[ -n "$domain" ]] || domain=$(prompt_value "Domain to secure")
  domain=${domain,,}
  validate_domain "$domain" || die "Invalid domain: $domain"
  [[ -f "$CONF_DIR/$domain.conf" ]] || die "Create the proxy first with '$0 proxy $domain'."
  [[ "$ACME_EMAIL" == *@*.* ]] || die "Set a valid ACME_EMAIL in $ENV_FILE."
  check_dns_a "$domain"

  if [[ -s "$LEGO_DIR/certificates/$domain.crt" ]]; then
    log "A lego certificate already exists; requesting renewal if needed."
    lego_renew "$domain"
  else
    lego_issue "$domain"
  fi
  deploy_lego_cert "$domain"
  record_domain "$domain"
  reload_nginx
  log "Certificate installed for $domain; it was added to $DOMAIN_FILE."
}

renew_one_domain() {
  local domain=$1
  validate_domain "$domain" || { warn "Skipping invalid domain in $DOMAIN_FILE: $domain"; return 1; }
  [[ -f "$CONF_DIR/$domain.conf" ]] || { warn "Skipping $domain: proxy configuration is missing."; return 1; }
  if lego_renew "$domain"; then
    # Cron validates all deployed certificates together before its single reload.
    deploy_lego_cert "$domain" deferred
    log "Renewal check completed for $domain."
  else
    warn "Renewal failed for $domain."
    return 1
  fi
}

command_cron() {
  require_config_root
  command -v lego >/dev/null 2>&1 || die "lego is not installed."
  [[ -s "$DOMAIN_FILE" ]] || { log "No domains are recorded in $DOMAIN_FILE."; return 0; }

  local lock="$NGINX_DIR/.proxy-man-cron.lock" domain failures=0 cleanup
  if ! mkdir "$lock" 2>/dev/null; then
    die "Another renewal process appears to be running ($lock exists)."
  fi
  printf -v cleanup 'rmdir %q 2>/dev/null || true' "$lock"
  trap "$cleanup" EXIT

  while IFS= read -r domain || [[ -n "$domain" ]]; do
    domain=${domain%%#*}
    domain=${domain//[[:space:]]/}
    [[ -n "$domain" ]] || continue
    renew_one_domain "$domain" || failures=$((failures + 1))
  done < "$DOMAIN_FILE"

  reload_nginx || failures=$((failures + 1))
  if (( failures > 0 )); then
    die "$failures certificate renewal(s) or checks failed."
  fi
  log "All certificate renewal checks completed."
}

main() {
  local command=${1:-help}
  shift || true
  case "$command" in
    install) command_install "$@" ;;
    init) command_init "$@" ;;
    proxy) command_proxy "$@" ;;
    list) command_list "$@" ;;
    acme) command_acme "$@" ;;
    analyze|goaccess) command_analyze "$@" ;;
    cron) command_cron "$@" ;;
    help|-h|--help) usage ;;
    *) usage >&2; die "Unknown command: $command" ;;
  esac
}

main "$@"
