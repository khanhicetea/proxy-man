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
ACME_EMAIL=${ACME_EMAIL:-}
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
GEOIP_DB_DIR=/usr/share/GeoIP
GEOIP_CITY_DB="$GEOIP_DB_DIR/GeoLite2-City.mmdb"
GEOIP_CITY_URL=https://cdn.jsdelivr.net/npm/geolite2-city/GeoLite2-City.mmdb.gz
GEOIP2_MODULES_DIR="$NGINX_DIR/modules-enabled"
GEOIP2_MODULE_PATH="$GEOIP2_MODULES_DIR/ngx_http_geoip2_module.so"
GEOIP2_HTTP_CONF="$CONF_DIR/geoip2.conf"
GEOIP2_UPDATE_SCRIPT=/usr/local/sbin/nginx-proxy-man-geoip2-update
GEOIP2_CRON_FILE=/etc/cron.d/nginx-proxy-man-geoip2
TEMPLATE_DIR="$NGINX_DIR/templates"
ONDEMAND_DIR="$NGINX_DIR/ondemand"
ONDEMAND_HOOK_ID=proxy-man-ondemand
ONDEMAND_PORT=${ONDEMAND_PORT:-9000}
ONDEMAND_TOKEN=${ONDEMAND_TOKEN:-}
ONDEMAND_SECRET=${ONDEMAND_SECRET:-}
WEBHOOK_UNIT_PATH=/etc/systemd/system/proxy-man-webhook.service

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
  status                  Show the proxy health dashboard
  acme [domain] [--dns provider]
                          Issue a certificate (HTTP-01 by default; DNS-01 when specified)
  analyze [domain]        Analyze a domain access log in the GoAccess TUI
  goaccess [domain]       Alias for analyze
  cron                    Renew all recorded certificates when due
  geoip2                  Build GeoIP2 support and configure the public GeoLite2 City database
  ondemand setup [--rotate]
                          Install webhook and expose /_ondemand/<token>
  ondemand show           Show on-demand endpoint and service status
  ondemand disable        Remove the public on-demand endpoint and stop webhook
  ondemand webhook        Internal handler invoked by webhook (not for humans)
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

is_wildcard_domain() {
  [[ "$1" == \*.* ]]
}

validate_acme_domain() {
  local domain=$1
  if is_wildcard_domain "$domain"; then
    validate_domain "${domain#*.}"
  else
    validate_domain "$domain"
  fi
}

lego_certificate_name() {
  # lego stores wildcard certificates with `*` replaced by `_`.
  printf '%s' "${1//\*/_}"
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

ensure_env_file() {
  # Keep configuration beside the standalone script, including when it was
  # downloaded with curl rather than checked out from a repository.
  if [[ -e "$ENV_FILE" || -L "$ENV_FILE" ]]; then
    return 0
  fi

  cat > "$ENV_FILE" <<'EOF'
# Nginx configuration root. Use ./nginx for safe local development/testing.
NGINX_DIR=/etc/nginx

# Email used to register the Let's Encrypt/ACME account. Leave empty to skip ACME.
ACME_EMAIL=
LEGO_DNS_RESOLVERS=1.1.1.1:53,1.0.0.1:53

# DNS-01 credentials are provider-specific lego environment variables. Keep them here
# (for example: CLOUDFLARE_DNS_API_TOKEN=...) when using `acme --dns cloudflare`.

# On-demand provisioning (managed by `ondemand setup`). Do not hand-edit tokens
# unless you also re-run setup so Nginx and webhook stay in sync.
# ONDEMAND_TOKEN=
# ONDEMAND_SECRET=
# ONDEMAND_PORT=9000
EOF
  chmod 0600 "$ENV_FILE"
  log "Created $ENV_FILE. Set ACME_EMAIL before requesting ACME certificates."
}

set_env_var() {
  local key=$1 value=$2 tmp
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "Invalid env key: $key"
  ensure_env_file
  tmp=$(mktemp)
  if grep -qE "^${key}=" "$ENV_FILE"; then
    awk -v key="$key" -v value="$value" '
      BEGIN { prefix = key "=" }
      index($0, prefix) == 1 && !done { print key "=" value; done = 1; next }
      { print }
      END { if (!done) print key "=" value }
    ' "$ENV_FILE" > "$tmp"
  else
    cat "$ENV_FILE" > "$tmp"
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
  fi
  chmod 0600 "$tmp"
  mv "$tmp" "$ENV_FILE"
}

generate_random_token() {
  local bytes=${1:-32}
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes"
    return 0
  fi
  if command -v xxd >/dev/null 2>&1; then
    head -c "$bytes" /dev/urandom | xxd -p -c $((bytes * 2))
    return 0
  fi
  die "openssl or xxd is required to generate on-demand tokens."
}

command_install() {
  require_root
  ensure_env_file
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

build_geoip2_module() {
  local nginx_version tmp nginx_source module_source

  nginx_version=$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9][0-9.]*\).*|\1|p')
  [[ "$nginx_version" =~ ^[0-9]+(\.[0-9]+)+$ ]] || die "Could not determine the installed Nginx version."

  tmp=$(mktemp -d)
  log "Building a GeoIP2 module compatible with Nginx $nginx_version..."
  curl -fsSL "https://nginx.org/download/nginx-$nginx_version.tar.gz" -o "$tmp/nginx.tar.gz"
  curl -fsSL https://github.com/leev/ngx_http_geoip2_module/archive/refs/heads/master.tar.gz -o "$tmp/geoip2.tar.gz"
  tar -xzf "$tmp/nginx.tar.gz" -C "$tmp"
  tar -xzf "$tmp/geoip2.tar.gz" -C "$tmp"
  nginx_source="$tmp/nginx-$nginx_version"
  module_source=$(find "$tmp" -maxdepth 1 -type d -name 'ngx_http_geoip2_module-*' -print -quit)
  [[ -d "$nginx_source" && -n "$module_source" ]] || die "Could not unpack the Nginx or GeoIP2 module source."

  (
    cd "$nginx_source"
    # --with-compat creates a module loadable by the packaged Nginx build
    # without requiring every optional feature from that build to be compiled.
    ./configure --with-compat --add-dynamic-module="$module_source"
    make modules
    install -m 0644 objs/ngx_http_geoip2_module.so "$GEOIP2_MODULE_PATH"
  )
  rm -rf "$tmp"
}

write_geoip2_http_conf() {
  cat > "$GEOIP2_HTTP_CONF" <<EOF
# Managed by nginx-proxy-man. This file is included from the http block.
# GeoLite2-City also contains country data. It only defines variables; add them
# to an individual server/location yourself, for example:
# proxy_set_header X-GeoIP-Country \$geoip2_data_country_code;
geoip2 "$GEOIP_CITY_DB" {
    auto_reload 4h;
    \$geoip2_data_country_code default=ZZ source=\$remote_addr country iso_code;
    \$geoip2_data_country_name default=Unknown source=\$remote_addr country names en;
    \$geoip2_data_continent_code default=ZZ source=\$remote_addr continent code;
    \$geoip2_data_city_name default=Unknown source=\$remote_addr city names en;
    \$geoip2_data_city_subdivision default=Unknown source=\$remote_addr subdivisions 0 names en;
    \$geoip2_data_city_latitude default=0 source=\$remote_addr location latitude;
    \$geoip2_data_city_longitude default=0 source=\$remote_addr location longitude;
}
EOF
  chmod 0644 "$GEOIP2_HTTP_CONF"
}

ensure_geoip2_module_include() {
  local nginx_conf="$NGINX_DIR/nginx.conf" tmp include_line
  [[ -f "$nginx_conf" ]] || return 1
  grep -Fq "$GEOIP2_MODULES_DIR/*.conf" "$nginx_conf" && return 0

  include_line="include \"$GEOIP2_MODULES_DIR/*.conf\";"
  tmp=$(mktemp "$NGINX_DIR/.nginx.conf.XXXXXX")
  if ! awk -v line="$include_line" '
    /^[[:space:]]*events[[:space:]]*\{/ && !inserted {
      print line
      print ""
      inserted = 1
    }
    { print }
    END { if (!inserted) exit 1 }
  ' "$nginx_conf" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  cat "$tmp" > "$nginx_conf"
  rm -f "$tmp"
}

write_geoip2_update_script() {
  cat > "$GEOIP2_UPDATE_SCRIPT" <<EOF
#!/bin/sh
# Managed by nginx-proxy-man. Download atomically so Nginx never reads a partial database.
set -eu
umask 022
download=\$(mktemp)
database=\$(mktemp "$GEOIP_DB_DIR/.GeoLite2-City.mmdb.XXXXXX")
cleanup() { rm -f "\$download" "\$database"; }
trap cleanup EXIT HUP INT TERM
curl -fsSL "$GEOIP_CITY_URL" -o "\$download"
gzip -dc "\$download" > "\$database"
test -s "\$database"
chmod 0644 "\$database"
mv -f "\$database" "$GEOIP_CITY_DB"
EOF
  chmod 0755 "$GEOIP2_UPDATE_SCRIPT"
}

write_geoip2_cron() {
  cat > "$GEOIP2_CRON_FILE" <<EOF
# Managed by nginx-proxy-man. GeoLite2-City is published on Tuesday and Friday.
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 4 * * 2,5 root $GEOIP2_UPDATE_SCRIPT >>$LOG_DIR/geoip2-update.log 2>&1
EOF
  chmod 0644 "$GEOIP2_CRON_FILE"
}

restore_geoip2_file() {
  local target=$1 backup=$2
  if [[ -e "$backup.absent" ]]; then
    rm -f "$target"
  else
    cp -a "$backup" "$target"
  fi
}

command_geoip2() {
  local module_path backup_dir target name
  local module_conf nginx_conf="$NGINX_DIR/nginx.conf"

  require_root
  command -v apt-get >/dev/null 2>&1 || die "The geoip2 command currently requires apt to build a module for the installed Nginx."
  command -v nginx >/dev/null 2>&1 || die "Nginx is not installed. Run '$0 install' and '$0 init' first."
  [[ -f "$nginx_conf" && -d "$CONF_DIR" ]] || die "Run '$0 init' before configuring GeoIP2."

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential curl gzip libmaxminddb-dev libpcre2-dev tar zlib1g-dev

  install -d -m 0755 "$GEOIP_DB_DIR" "$GEOIP2_MODULES_DIR"
  build_geoip2_module
  module_path=$GEOIP2_MODULE_PATH
  write_geoip2_update_script
  log "Downloading the public GeoLite2 City database..."
  if ! "$GEOIP2_UPDATE_SCRIPT"; then
    die "Could not download or unpack the GeoLite2 City database. No Nginx GeoIP2 configuration was added."
  fi
  [[ -s "$GEOIP_CITY_DB" ]] || die "The GeoLite2 City database download did not produce a database."

  module_conf="$GEOIP2_MODULES_DIR/50-geoip2.conf"
  backup_dir=$(mktemp -d)
  for target in "$module_conf" "$GEOIP2_HTTP_CONF" "$nginx_conf"; do
    name=$(basename "$target")
    if [[ -e "$target" ]]; then
      cp -a "$target" "$backup_dir/$name"
    else
      : > "$backup_dir/$name.absent"
    fi
  done

  printf 'load_module %s;\n' "$module_path" > "$module_conf"
  chmod 0644 "$module_conf"
  write_geoip2_http_conf
  if ! ensure_geoip2_module_include || ! nginx_test; then
    restore_geoip2_file "$module_conf" "$backup_dir/$(basename "$module_conf")"
    restore_geoip2_file "$GEOIP2_HTTP_CONF" "$backup_dir/$(basename "$GEOIP2_HTTP_CONF")"
    restore_geoip2_file "$nginx_conf" "$backup_dir/$(basename "$nginx_conf")"
    rm -rf "$backup_dir"
    die "Nginx rejected the GeoIP2 module/configuration; it was restored. Re-run geoip2 to rebuild the module for the current Nginx build."
  fi
  rm -rf "$backup_dir"

  write_proxy_geoip_snippet
  write_geoip2_cron
  reload_nginx
  log "GeoIP2 is configured. Databases update Tuesday and Friday through $GEOIP2_CRON_FILE."
  log "Include $SNIPPET_DIR/proxy-geoip.conf in a proxy location to pass country and city headers upstream."
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

include "$GEOIP2_MODULES_DIR/*.conf";

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
                     max_size=5g inactive=30d use_temp_path=off;
    proxy_cache_path "$PRIVATE_CACHE_DIR" levels=1:2 keys_zone=private_zone:50m
                     max_size=1g inactive=7d use_temp_path=off;

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

write_proxy_geoip_snippet() {
  cat > "$SNIPPET_DIR/proxy-geoip.conf" <<'EOF'
# Include from a proxy location to pass GeoIP2 data to its upstream.
# proxy_set_header directives at location scope replace inherited ones, so this
# file repeats proxy-host.conf's standard headers before adding GeoIP headers.
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Host $host;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Port $server_port;
proxy_set_header X-GeoIP-Country $geoip2_data_country_code;
proxy_set_header X-GeoIP-City $geoip2_data_city_name;
EOF
  chmod 0644 "$SNIPPET_DIR/proxy-geoip.conf"
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

  write_proxy_geoip_snippet

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

ondemand_location_block() {
  [[ -n "${ONDEMAND_TOKEN:-}" ]] || return 0
  cat <<EOF

    # On-demand provisioning endpoint (managed by ondemand setup).
    location = /_ondemand/${ONDEMAND_TOKEN} {
        access_log off;
        client_max_body_size 1m;
        proxy_connect_timeout 5s;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Content-Type \$http_content_type;
        proxy_pass http://127.0.0.1:${ONDEMAND_PORT:-9000}/hooks/${ONDEMAND_HOOK_ID};
    }
EOF
}

write_default_host() {
  local ondemand_location
  ondemand_location=$(ondemand_location_block || true)
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
    # Local-only connection metrics for the proxy-man status command.
    location = /status {
        allow 127.0.0.1;
        deny all;
        access_log off;
        stub_status;
    }${ondemand_location}
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

    # Keep the status endpoint off the public network, including HTTPS.
    location = /status {
        allow 127.0.0.1;
        deny all;
        access_log off;
        stub_status;
    }${ondemand_location}
    location / { return 404; }
}
EOF
}

command_init() {
  require_config_root
  if [[ -z "$ACME_EMAIL" ]]; then
    warn "ACME_EMAIL is empty. Set it in $ENV_FILE before using '$0 acme' to obtain TLS certificates."
  fi
  install -d -m 0755 "$NGINX_DIR" "$CONF_DIR" "$SNIPPET_DIR" "$SSL_DIR" \
    "$GEOIP2_MODULES_DIR" "$ACME_WEBROOT/.well-known/acme-challenge" "$PUBLIC_CACHE_DIR" \
    "$PRIVATE_CACHE_DIR" "$LOG_DIR" "$LEGO_DIR" "$TEMPLATE_DIR" "$ONDEMAND_DIR"

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
        # Optional GeoIP2 headers for the upstream (after running '$0 geoip2'):
        # include "$SNIPPET_DIR/proxy-geoip.conf";
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

acme_record_status() {
  local domain=$1 method provider
  [[ -f "$DOMAIN_FILE" ]] || return 1
  read -r method provider < <(awk -v domain="$domain" '$1 == domain { print ($2 == "" ? "http" : $2), $3; exit }' "$DOMAIN_FILE")
  case "$method" in
    http) printf 'http-01' ;;
    dns) printf 'dns-01 (%s)' "$provider" ;;
    *) return 1 ;;
  esac
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
    acme=$(acme_record_status "$domain" || printf 'no')
    printf '%-*s  %s\n' "$width" "$domain" "$acme"
  done
}

nginx_status() {
  local pid
  if [[ "$NGINX_DIR" == /etc/nginx ]] && command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
    printf 'running (systemd)'
  elif [[ -r "$NGINX_PID" ]]; then
    read -r pid < "$NGINX_PID" || true
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      printf 'running (pid %s)' "$pid"
    else
      printf 'stopped (stale PID file)'
    fi
  elif command -v nginx >/dev/null 2>&1; then
    printf 'stopped'
  else
    printf 'not installed'
  fi
}

nginx_local_status() {
  local result
  if ! command -v curl >/dev/null 2>&1; then
    printf 'unavailable (curl is not installed)'
    return
  fi
  if ! result=$(curl --output - --silent --show-error --fail --noproxy '*' \
      --connect-timeout 1 --max-time 3 http://127.0.0.1/status 2>/dev/null); then
    printf 'unavailable (local /status did not respond)'
    return
  fi
  printf '%s' "$result"
}

recent_nginx_error_count() {
  local cutoff
  [[ -r "$LOG_DIR/error.log" ]] || { printf 'unavailable'; return; }
  cutoff=$(date -d '24 hours ago' '+%Y/%m/%d %H:%M:%S' 2>/dev/null) || {
    printf 'unavailable'
    return
  }

  # Nginx error logs start with a lexically sortable YYYY/MM/DD timestamp.
  # Count error and more severe levels, rather than routine warnings/notices.
  awk -v cutoff="$cutoff" '
    ($1 " " $2) >= cutoff && /\[(error|crit|alert|emerg)\]/ { count++ }
    END { print count + 0 }
  ' "$LOG_DIR/error.log"
}

upstream_for_domain() {
  awk '
    /^[[:space:]]*proxy_pass[[:space:]]+https?:\/\// {
      upstream = $2
      sub(/;$/, "", upstream)
      print upstream
      exit
    }
  ' "$CONF_DIR/$1.conf"
}

upstream_health() {
  local upstream=$1 result http_code seconds milliseconds
  if ! command -v curl >/dev/null 2>&1; then
    printf 'unavailable (curl is not installed)'
    return
  fi

  if ! result=$(curl --output /dev/null --silent --show-error --insecure --noproxy '*' \
      --connect-timeout 3 --max-time 5 --write-out '%{http_code} %{time_total}' "$upstream" 2>/dev/null); then
    printf 'DOWN'
    return
  fi
  read -r http_code seconds <<< "$result"
  if [[ ! "$http_code" =~ ^[0-9]{3}$ || "$http_code" == 000 || ! "$seconds" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf 'DOWN'
    return
  fi
  milliseconds=$(awk -v seconds="$seconds" 'BEGIN { printf "%.0f", seconds * 1000 }')
  printf 'UP HTTP %s (%sms)' "$http_code" "$milliseconds"
}

certificate_status() {
  local domain=$1 cert="$SSL_DIR/$1/fullchain.pem" expiration expiration_epoch now days expiration_date
  [[ -e "$cert" ]] || { printf 'missing'; return; }
  [[ -r "$cert" ]] || { printf 'unreadable'; return; }
  command -v openssl >/dev/null 2>&1 || { printf 'unavailable (openssl is not installed)'; return; }

  expiration=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null) || { printf 'invalid'; return; }
  expiration=${expiration#notAfter=}
  expiration_epoch=$(date -d "$expiration" +%s 2>/dev/null) || { printf 'unknown'; return; }
  expiration_date=$(date -d "@$expiration_epoch" +%F 2>/dev/null || printf '%s' "$expiration")
  now=$(date +%s)
  if (( expiration_epoch <= now )); then
    printf 'EXPIRED %s' "$expiration_date"
    return
  fi
  days=$(( (expiration_epoch - now + 86399) / 86400 ))
  printf '%s (%dd)' "$expiration_date" "$days"
}

command_status() {
  [[ -d "$CONF_DIR" ]] || die "Run '$0 init' first."

  local file domain upstream health certificate nginx_state local_status error_count line
  local domain_width=6 upstream_width=8 certificate_width=11
  local -a domains=() upstream_cells=() certificate_cells=()
  shopt -s nullglob
  for file in "$CONF_DIR"/*.conf; do
    domain=${file##*/}
    domain=${domain%.conf}
    validate_domain "$domain" || continue
    domains+=("$domain")

    upstream=$(upstream_for_domain "$domain")
    if [[ -n "$upstream" ]]; then
      health=$(upstream_health "$upstream")
      upstream="$upstream — $health"
    else
      upstream='not found'
    fi
    certificate=$(certificate_status "$domain")
    upstream_cells+=("$upstream")
    certificate_cells+=("$certificate")
    (( ${#domain} > domain_width )) && domain_width=${#domain}
    (( ${#upstream} > upstream_width )) && upstream_width=${#upstream}
    (( ${#certificate} > certificate_width )) && certificate_width=${#certificate}
  done
  shopt -u nullglob

  nginx_state=$(nginx_status)
  local_status=$(nginx_local_status)
  error_count=$(recent_nginx_error_count)
  printf 'Nginx: %s\n' "$nginx_state"
  printf 'Nginx local status (/status):\n'
  while IFS= read -r line; do
    printf '  %s\n' "$line"
  done <<< "$local_status"
  printf 'Nginx errors (last 24h, error+): %s\n\n' "$error_count"
  printf '%-*s  %-*s  %s\n' "$domain_width" DOMAIN "$upstream_width" UPSTREAM CERTIFICATE
  printf '%-*s  %-*s  %s\n' "$domain_width" "$(printf '%*s' "$domain_width" '' | tr ' ' '-')" "$upstream_width" "$(printf '%*s' "$upstream_width" '' | tr ' ' '-')" '-----------'
  if (( ${#domains[@]} == 0 )); then
    printf 'No proxy domains configured.\n'
    return
  fi
  for ((i = 0; i < ${#domains[@]}; i++)); do
    printf '%-*s  %-*s  %s\n' "$domain_width" "${domains[i]}" "$upstream_width" "${upstream_cells[i]}" "${certificate_cells[i]}"
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
  local domain=$1 test_mode=${2:-immediate} certificate_name
  certificate_name=$(lego_certificate_name "$domain")
  local source_cert="$LEGO_DIR/certificates/$certificate_name.crt" source_key="$LEGO_DIR/certificates/$certificate_name.key"
  local target="$SSL_DIR/$certificate_name" backup
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

validate_dns_provider() {
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]
}

record_domain() {
  local domain=$1 method=$2 provider=${3:-} tmp
  touch "$DOMAIN_FILE"
  tmp=$(mktemp "${DOMAIN_FILE}.XXXXXX")
  # Replace legacy one-column records and existing records for this domain.
  awk -v domain="$domain" '$1 != domain' "$DOMAIN_FILE" > "$tmp"
  if [[ "$method" == dns ]]; then
    printf '%s\tdns\t%s\n' "$domain" "$provider" >> "$tmp"
  else
    printf '%s\thttp\n' "$domain" >> "$tmp"
  fi
  chmod 0644 "$tmp"
  mv "$tmp" "$DOMAIN_FILE"
}

lego_common_args() {
  local domain=$1 method=$2 provider=${3:-}
  LEGO_ARGS=(--accept-tos --email="$ACME_EMAIL" --path="$LEGO_DIR" --domains="$domain")
  if [[ "$method" == dns ]]; then
    LEGO_ARGS+=(--dns "$provider")
  else
    LEGO_ARGS+=(--http --http.webroot="$ACME_WEBROOT")
  fi
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
  local domain=$1 method=$2 provider=${3:-} major
  local -a LEGO_ARGS
  lego_common_args "$domain" "$method" "$provider"
  major=$(lego_major_version)
  if (( major >= 5 )); then
    # lego v5 moved ACME and challenge flags from the global scope to `run`.
    lego run "${LEGO_ARGS[@]}"
  else
    lego "${LEGO_ARGS[@]}" run
  fi
}

lego_renew() {
  local domain=$1 method=$2 provider=${3:-} major
  local -a LEGO_ARGS
  lego_common_args "$domain" "$method" "$provider"
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

  local domain='' method=http provider=''
  while (( $# > 0 )); do
    case "$1" in
      --dns)
        (( $# >= 2 )) || die "--dns requires a lego DNS provider name."
        method=dns
        provider=$2
        shift 2
        ;;
      --dns=*)
        method=dns
        provider=${1#--dns=}
        shift
        ;;
      -*) die "Unknown acme option: $1" ;;
      *)
        [[ -z "$domain" ]] || die "Only one domain may be supplied."
        domain=$1
        shift
        ;;
    esac
  done
  [[ -n "$domain" ]] || domain=$(prompt_value "Domain to secure")
  domain=${domain,,}
  validate_acme_domain "$domain" || die "Invalid domain: $domain"
  [[ "$ACME_EMAIL" == *@*.* ]] || die "Set a valid ACME_EMAIL in $ENV_FILE."
  if ! is_wildcard_domain "$domain"; then
    [[ -f "$CONF_DIR/$domain.conf" ]] || die "Create the proxy first with '$0 proxy $domain'."
  fi

  if [[ "$method" == dns ]]; then
    validate_dns_provider "$provider" || die "Invalid lego DNS provider: $provider"
    log "Using DNS-01 with lego provider '$provider'; credentials are read from $ENV_FILE."
  else
    is_wildcard_domain "$domain" && die "Wildcard certificates require DNS-01; use --dns <provider>."
    check_dns_a "$domain"
  fi

  local certificate_name
  certificate_name=$(lego_certificate_name "$domain")
  if [[ -s "$LEGO_DIR/certificates/$certificate_name.crt" ]]; then
    log "A lego certificate already exists; requesting renewal if needed."
    lego_renew "$domain" "$method" "$provider"
  else
    lego_issue "$domain" "$method" "$provider"
  fi
  deploy_lego_cert "$domain"
  record_domain "$domain" "$method" "$provider"
  reload_nginx
  log "Certificate installed for $domain; it was added to $DOMAIN_FILE."
}

renew_one_domain() {
  local domain=$1 method=${2:-http} provider=${3:-}
  validate_acme_domain "$domain" || { warn "Skipping invalid domain in $DOMAIN_FILE: $domain"; return 1; }
  [[ "$method" == http || "$method" == dns ]] || { warn "Skipping $domain: invalid ACME method '$method'."; return 1; }
  if is_wildcard_domain "$domain" && [[ "$method" != dns ]]; then
    warn "Skipping $domain: wildcard certificates require DNS-01."
    return 1
  fi
  if [[ "$method" == dns ]] && ! validate_dns_provider "$provider"; then
    warn "Skipping $domain: invalid or missing DNS provider."
    return 1
  fi
  if ! is_wildcard_domain "$domain" && [[ ! -f "$CONF_DIR/$domain.conf" ]]; then
    warn "Skipping $domain: proxy configuration is missing."
    return 1
  fi
  if lego_renew "$domain" "$method" "$provider"; then
    # Cron validates all deployed certificates together before its single reload.
    deploy_lego_cert "$domain" deferred
    log "Renewal check completed for $domain ($method-01)."
  else
    warn "Renewal failed for $domain."
    return 1
  fi
}

command_cron() {
  require_config_root
  command -v lego >/dev/null 2>&1 || die "lego is not installed."
  [[ -s "$DOMAIN_FILE" ]] || { log "No domains are recorded in $DOMAIN_FILE."; return 0; }

  [[ "$ACME_EMAIL" == *@*.* ]] || die "Set a valid ACME_EMAIL in $ENV_FILE."

  local lock="$NGINX_DIR/.proxy-man-cron.lock" line domain method provider extra failures=0 cleanup
  if ! mkdir "$lock" 2>/dev/null; then
    die "Another renewal process appears to be running ($lock exists)."
  fi
  printf -v cleanup 'rmdir %q 2>/dev/null || true' "$lock"
  trap "$cleanup" EXIT

  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%%#*}
    read -r domain method provider extra <<< "$line"
    [[ -n "$domain" ]] || continue
    # Old one-column records remain valid and mean HTTP-01.
    method=${method:-http}
    [[ -z "$extra" ]] || { warn "Skipping malformed record for $domain in $DOMAIN_FILE."; failures=$((failures + 1)); continue; }
    renew_one_domain "$domain" "$method" "$provider" || failures=$((failures + 1))
  done < "$DOMAIN_FILE"

  reload_nginx || failures=$((failures + 1))
  if (( failures > 0 )); then
    die "$failures certificate renewal(s) or checks failed."
  fi
  log "All certificate renewal checks completed."
}

json_escape() {
  # Escape a value for inclusion inside a JSON string.
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

as_bool() {
  # Return 0 when the value is a recognized true token.
  case "${1,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

install_webhook() {
  local github_hint='Download a release from https://github.com/adnanh/webhook/releases, install the binary on PATH, and re-run ondemand setup.'
  if command -v webhook >/dev/null 2>&1; then
    log "webhook already installed: $(command -v webhook) ($(webhook -version 2>&1 || true))"
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y webhook || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y webhook || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y webhook || true
  else
    die "No supported package manager found. $github_hint"
  fi

  if ! command -v webhook >/dev/null 2>&1; then
    die "Could not install webhook via the package manager. $github_hint"
  fi
  log "Installed webhook: $(command -v webhook) ($(webhook -version 2>&1 || true))"
}

write_default_ondemand_template() {
  install -d -m 0755 "$TEMPLATE_DIR"
  local tpl="$TEMPLATE_DIR/default.tpl"
  [[ -e "$tpl" ]] && return 0
  cat > "$tpl" <<'EOF'
# On-demand vhost template.
# Placeholders: DOMAIN, UPSTREAM, ACME_WEBROOT, SSL_DIR, LOG_DIR, SNIPPET_DIR, NGINX_DIR
# (each wrapped in double underscores when used below).
server {
    listen 80;
    listen [::]:80;
    server_name __DOMAIN__;

    location ^~ /.well-known/acme-challenge/ {
        root "__ACME_WEBROOT__";
        default_type text/plain;
        try_files $uri =404;
    }
    location / { return 301 https://$host$request_uri; }
}

server {
    include "__SNIPPET_DIR__/proxy-host.conf";

    # Optional UA filter; review block-bot-map.conf before enabling.
    # include "__SNIPPET_DIR__/block-bot.conf";

    server_name __DOMAIN__;
    ssl_certificate "__SSL_DIR__/__DOMAIN__/fullchain.pem";
    ssl_certificate_key "__SSL_DIR__/__DOMAIN__/privkey.pem";

    location / {
        # Optional GeoIP2 headers for the upstream (after running geoip2):
        # include "__SNIPPET_DIR__/proxy-geoip.conf";
        access_log "__LOG_DIR__/__DOMAIN__.access.log" proxy_timing buffer=64k flush=60s;
        proxy_pass __UPSTREAM__;
    }
}
EOF
  chmod 0644 "$tpl"
  log "Created template $tpl"
}

write_ondemand_hooks() {
  local hooks_file="$ONDEMAND_DIR/hooks.json" script workdir secret
  [[ -n "$ONDEMAND_SECRET" ]] || die "ONDEMAND_SECRET is not set."
  install -d -m 0755 "$ONDEMAND_DIR"
  script=$(json_escape "$SCRIPT_DIR/proxy-man.sh")
  workdir=$(json_escape "$SCRIPT_DIR")
  secret=$(json_escape "$ONDEMAND_SECRET")
  cat > "$hooks_file" <<EOF
[
  {
    "id": "$ONDEMAND_HOOK_ID",
    "execute-command": "$script",
    "command-working-directory": "$workdir",
    "http-methods": ["POST"],
    "include-command-output-in-response": true,
    "include-command-output-in-response-on-error": true,
    "pass-arguments-to-command": [
      {"source": "string", "name": "ondemand"},
      {"source": "string", "name": "webhook"}
    ],
    "pass-environment-to-command": [
      {"source": "payload", "name": "template", "envname": "OD_TEMPLATE"},
      {"source": "payload", "name": "domain", "envname": "OD_DOMAIN"},
      {"source": "payload", "name": "upstream", "envname": "OD_UPSTREAM"},
      {"source": "payload", "name": "acme", "envname": "OD_ACME"},
      {"source": "payload", "name": "replace", "envname": "OD_REPLACE"},
      {"source": "payload", "name": "callback_url", "envname": "OD_CALLBACK_URL"}
    ],
    "trigger-rule": {
      "match": {
        "type": "value",
        "value": "$secret",
        "parameter": {
          "source": "header",
          "name": "X-Proxy-Man-Token"
        }
      }
    },
    "trigger-rule-mismatch-http-response-code": 401
  }
]
EOF
  chmod 0600 "$hooks_file"
  log "Wrote webhook hooks to $hooks_file"
}

write_ondemand_webhook_unit() {
  local hooks_file="$ONDEMAND_DIR/hooks.json" binary
  binary=$(command -v webhook) || die "webhook is not installed."
  cat > "$WEBHOOK_UNIT_PATH" <<EOF
[Unit]
Description=nginx-proxy-man on-demand webhook receiver
Documentation=https://github.com/khanhicetea/proxy-man
After=network.target

[Service]
Type=simple
ExecStart=$binary -nopanic -hooks $hooks_file -ip 127.0.0.1 -port ${ONDEMAND_PORT}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$WEBHOOK_UNIT_PATH"
}

ondemand_setup() {
  local rotate=n arg binary
  for arg in "$@"; do
    case "$arg" in
      --rotate) rotate=y ;;
      -*) die "Unknown ondemand setup option: $arg" ;;
      *) die "Unexpected argument: $arg" ;;
    esac
  done

  require_root
  require_config_root
  [[ -f "$NGINX_DIR/nginx.conf" && -f "$CONF_DIR/00-default.conf" ]] || die "Run '$0 init' first."

  install_webhook
  # Avoid the package unit binding :9000 if someone later drops /etc/webhook.conf.
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl disable --now webhook.service 2>/dev/null || true
  fi
  install -d -m 0755 "$TEMPLATE_DIR" "$ONDEMAND_DIR"
  write_default_ondemand_template

  if [[ "$rotate" == y || -z "$ONDEMAND_TOKEN" ]]; then
    ONDEMAND_TOKEN=$(generate_random_token 32)
  fi
  if [[ "$rotate" == y || -z "$ONDEMAND_SECRET" ]]; then
    ONDEMAND_SECRET=$(generate_random_token 32)
  fi
  [[ "$ONDEMAND_PORT" =~ ^[0-9]+$ && "$ONDEMAND_PORT" -ge 1 && "$ONDEMAND_PORT" -le 65535 ]] \
    || die "ONDEMAND_PORT must be a valid TCP port."

  set_env_var ONDEMAND_TOKEN "$ONDEMAND_TOKEN"
  set_env_var ONDEMAND_SECRET "$ONDEMAND_SECRET"
  set_env_var ONDEMAND_PORT "$ONDEMAND_PORT"
  export ONDEMAND_TOKEN ONDEMAND_SECRET ONDEMAND_PORT

  write_ondemand_hooks
  write_default_host

  binary=$(command -v webhook)
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    write_ondemand_webhook_unit
    systemctl daemon-reload
    systemctl enable --now proxy-man-webhook.service
    systemctl restart proxy-man-webhook.service
    log "Enabled systemd service proxy-man-webhook.service (127.0.0.1:${ONDEMAND_PORT})."
  else
    warn "systemd is unavailable; start webhook manually:"
    warn "  $binary -nopanic -hooks $ONDEMAND_DIR/hooks.json -ip 127.0.0.1 -port $ONDEMAND_PORT"
  fi

  reload_nginx || die "Nginx rejected the on-demand endpoint configuration."
  log "On-demand endpoint path: /_ondemand/${ONDEMAND_TOKEN}"
  log "Authenticate requests with header: X-Proxy-Man-Token: <ONDEMAND_SECRET from $ENV_FILE>"
  log "Templates directory: $TEMPLATE_DIR"
  log "Example:"
  log "  curl -X POST \"https://<host>/_ondemand/${ONDEMAND_TOKEN}\" \\"
  log "    -H 'Content-Type: application/json' \\"
  log "    -H \"X-Proxy-Man-Token: \$ONDEMAND_SECRET\" \\"
  log "    -d '{\"template\":\"default.tpl\",\"domain\":\"app.example.com\",\"upstream\":\"http://127.0.0.1:3000\",\"acme\":true}'"
}

ondemand_disable() {
  require_root
  require_config_root
  [[ -f "$CONF_DIR/00-default.conf" ]] || die "Run '$0 init' first."

  ONDEMAND_TOKEN=
  write_default_host
  reload_nginx || die "Nginx rejected the configuration after disabling on-demand."

  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl disable --now proxy-man-webhook.service 2>/dev/null || true
  fi
  log "On-demand public endpoint removed from the default host."
  log "Tokens remain in $ENV_FILE; run '$0 ondemand setup' to re-enable."
}

ondemand_show() {
  local service_state=unavailable hooks_file="$ONDEMAND_DIR/hooks.json" template count=0

  printf 'On-demand configuration\n'
  printf '  enabled in Nginx: %s\n' "$([[ -n "$ONDEMAND_TOKEN" ]] && printf yes || printf no)"
  if [[ -n "$ONDEMAND_TOKEN" ]]; then
    printf '  path: /_ondemand/%s\n' "$ONDEMAND_TOKEN"
  else
    printf '  path: (not configured; run ondemand setup)\n'
  fi
  printf '  secret header: X-Proxy-Man-Token (%s)\n' \
    "$([[ -n "$ONDEMAND_SECRET" ]] && printf 'set in .env' || printf 'missing')"
  printf '  webhook listen: 127.0.0.1:%s\n' "$ONDEMAND_PORT"
  printf '  hooks file: %s (%s)\n' "$hooks_file" "$([[ -f "$hooks_file" ]] && printf present || printf missing)"
  printf '  templates dir: %s\n' "$TEMPLATE_DIR"

  if [[ -d "$TEMPLATE_DIR" ]]; then
    shopt -s nullglob
    for template in "$TEMPLATE_DIR"/*.tpl; do
      printf '    - %s\n' "${template##*/}"
      count=$((count + 1))
    done
    shopt -u nullglob
  fi
  (( count > 0 )) || printf '    (no .tpl files)\n'

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl cat proxy-man-webhook.service >/dev/null 2>&1; then
      if systemctl is-active --quiet proxy-man-webhook.service; then
        service_state=active
      elif systemctl is-enabled --quiet proxy-man-webhook.service 2>/dev/null; then
        service_state=inactive
      else
        service_state=disabled
      fi
    else
      service_state='unit not installed'
    fi
  fi
  printf '  webhook service: %s\n' "$service_state"
}

ondemand_emit_result() {
  local status=$1 message=$2 acme_state=${3:-n/a} code=1 json
  [[ "$status" == ok ]] && code=0
  printf -v json \
    '{"domain":"%s","status":"%s","code":%s,"message":"%s","acme":"%s","config":"%s"}' \
    "$(json_escape "${ONDEMAND_CB_DOMAIN:-}")" \
    "$(json_escape "$status")" \
    "$code" \
    "$(json_escape "$message")" \
    "$(json_escape "$acme_state")" \
    "$(json_escape "${ONDEMAND_CB_CONFIG:-}")"

  if [[ -n "${ONDEMAND_CB_URL:-}" ]]; then
    if [[ "$ONDEMAND_CB_URL" =~ ^https?://[^[:space:]]+$ ]]; then
      curl --silent --show-error --noproxy '*' \
        --connect-timeout 5 --max-time 15 \
        -X POST -H 'Content-Type: application/json' \
        --data "$json" "$ONDEMAND_CB_URL" >/dev/null \
        || warn "callback_url request failed for $ONDEMAND_CB_URL"
    else
      warn "Ignoring invalid callback_url: $ONDEMAND_CB_URL"
    fi
  fi
  printf '%s\n' "$json"
}

ondemand_provision_acme() {
  local domain=$1 certificate_name
  [[ "$ACME_EMAIL" == *@*.* ]] || { warn "Set a valid ACME_EMAIL in $ENV_FILE."; return 1; }
  command -v lego >/dev/null 2>&1 || { warn "lego is not installed."; return 1; }
  check_dns_a "$domain"
  certificate_name=$(lego_certificate_name "$domain")
  if [[ -s "$LEGO_DIR/certificates/$certificate_name.crt" ]]; then
    log "A lego certificate already exists for $domain; requesting renewal if needed."
    lego_renew "$domain" http
  else
    lego_issue "$domain" http
  fi
  deploy_lego_cert "$domain"
  record_domain "$domain" http
  reload_nginx
}

ondemand_render_template() {
  local template_path=$1 output_path=$2 domain=$3 upstream=$4 line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line//__DOMAIN__/$domain}
    line=${line//__UPSTREAM__/$upstream}
    line=${line//__ACME_WEBROOT__/$ACME_WEBROOT}
    line=${line//__SSL_DIR__/$SSL_DIR}
    line=${line//__LOG_DIR__/$LOG_DIR}
    line=${line//__SNIPPET_DIR__/$SNIPPET_DIR}
    line=${line//__NGINX_DIR__/$NGINX_DIR}
    printf '%s\n' "$line"
  done < "$template_path" > "$output_path"
}

ondemand_webhook() {
  local domain=${OD_DOMAIN:-} template=${OD_TEMPLATE:-} upstream=${OD_UPSTREAM:-}
  local callback_url=${OD_CALLBACK_URL:-} replace_raw=${OD_REPLACE:-} acme_raw=${OD_ACME:-}
  local config='' backup='' template_path='' rendered='' acme_state=skipped replace=n want_acme=n

  ONDEMAND_CB_URL=
  ONDEMAND_CB_DOMAIN=
  ONDEMAND_CB_CONFIG=

  if [[ "$NGINX_DIR" == /etc/* || "$NGINX_DIR" == /usr/* || "$NGINX_DIR" == /var/* ]]; then
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
      ondemand_emit_result error "ondemand webhook must run as root for $NGINX_DIR"
      exit 1
    fi
  fi
  if [[ ! -f "$NGINX_DIR/nginx.conf" || ! -d "$TEMPLATE_DIR" ]]; then
    ondemand_emit_result error "Run init and ondemand setup first"
    exit 1
  fi

  domain=${domain,,}
  domain=${domain//$'\r'/}
  template=${template//$'\r'/}
  upstream=${upstream//$'\r'/}
  callback_url=${callback_url//$'\r'/}
  as_bool "$replace_raw" && replace=y
  as_bool "$acme_raw" && want_acme=y

  ONDEMAND_CB_URL=$callback_url
  ONDEMAND_CB_DOMAIN=$domain

  [[ -n "$domain" ]] || { ondemand_emit_result error "domain is required"; exit 1; }
  [[ -n "$template" ]] || { ondemand_emit_result error "template is required"; exit 1; }
  [[ -n "$upstream" ]] || { ondemand_emit_result error "upstream is required"; exit 1; }
  [[ "$template" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.tpl$ ]] || {
    ondemand_emit_result error "template must be a basename ending in .tpl"
    exit 1
  }
  validate_domain "$domain" || {
    ondemand_emit_result error "Invalid domain: $domain"
    exit 1
  }
  validate_upstream "$upstream" || {
    ondemand_emit_result error "Upstream must be an origin such as http://127.0.0.1:3000"
    exit 1
  }

  template_path="$TEMPLATE_DIR/$template"
  [[ -f "$template_path" ]] || {
    ondemand_emit_result error "Template not found: $template"
    exit 1
  }

  config="$CONF_DIR/$domain.conf"
  ONDEMAND_CB_CONFIG=$config
  if [[ -e "$config" && "$replace" != y ]]; then
    ondemand_emit_result error "Proxy already exists for $domain (pass replace=true to overwrite)"
    exit 1
  fi

  if [[ -e "$config" ]]; then
    backup=$(mktemp)
    cp -a "$config" "$backup"
  fi

  ensure_domain_cert "$domain"
  rendered=$(mktemp)
  ondemand_render_template "$template_path" "$rendered" "$domain" "$upstream"
  cp "$rendered" "$config"
  rm -f "$rendered"
  chmod 0644 "$config"

  if ! reload_nginx; then
    if [[ -n "$backup" ]]; then
      cp -a "$backup" "$config"
      rm -f "$backup"
      ondemand_emit_result error "Nginx rejected the new proxy configuration; previous file restored"
    else
      rm -f "$config"
      ondemand_emit_result error "Nginx rejected the new proxy configuration; file removed"
    fi
    exit 1
  fi
  [[ -n "$backup" ]] && rm -f "$backup"
  log "On-demand proxy created for $domain -> $upstream from $template"

  if [[ "$want_acme" == y ]]; then
    # Run in a subshell so helpers that call die/exit cannot skip JSON output.
    if ( ondemand_provision_acme "$domain" ); then
      acme_state=issued
    else
      acme_state=failed
      ondemand_emit_result error "Proxy written but ACME provisioning failed" "$acme_state"
      exit 1
    fi
  fi

  ondemand_emit_result ok "Proxy ready for $domain" "$acme_state"
}

command_ondemand() {
  local subcommand=${1:-}
  shift || true
  case "$subcommand" in
    setup) ondemand_setup "$@" ;;
    show) ondemand_show "$@" ;;
    disable) ondemand_disable "$@" ;;
    webhook) ondemand_webhook "$@" ;;
    help|-h|--help)
      cat <<'EOF'
Usage: ./proxy-man.sh ondemand <subcommand>

Subcommands:
  setup [--rotate]   Install webhook, write hooks, expose /_ondemand/<token>
  show               Show endpoint path, templates, and webhook service status
  disable            Remove the public endpoint and stop the webhook service
  webhook            Internal handler used by adnanh/webhook
EOF
      ;;
    *)
      die "Unknown ondemand subcommand: ${subcommand:-<missing>}. Try '$0 ondemand help'."
      ;;
  esac
}

main() {
  local command=${1:-help}
  shift || true
  case "$command" in
    install) command_install "$@" ;;
    init) command_init "$@" ;;
    proxy) command_proxy "$@" ;;
    list) command_list "$@" ;;
    status) command_status "$@" ;;
    acme) command_acme "$@" ;;
    analyze|goaccess) command_analyze "$@" ;;
    cron) command_cron "$@" ;;
    geoip2) command_geoip2 "$@" ;;
    ondemand) command_ondemand "$@" ;;
    help|-h|--help) usage ;;
    *) usage >&2; die "Unknown command: $command" ;;
  esac
}

main "$@"
