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
                          Install webhook + gomplate and expose /_ondemand/<token>
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

# Resolve conf.d/<domain>.conf or conf.d/ondemand/<domain>.conf.
proxy_conf_for_domain() {
  local domain=$1
  if [[ -f "$ONDEMAND_CONF_DIR/$domain.conf" ]]; then
    printf '%s\n' "$ONDEMAND_CONF_DIR/$domain.conf"
    return 0
  fi
  if [[ -f "$CONF_DIR/$domain.conf" ]]; then
    printf '%s\n' "$CONF_DIR/$domain.conf"
    return 0
  fi
  return 1
}

# Print validated proxy domains from conf.d and conf.d/ondemand (unique).
list_proxy_domains() {
  local file domain
  local -A seen=()
  shopt -s nullglob
  for file in "$CONF_DIR"/*.conf "$ONDEMAND_CONF_DIR"/*.conf; do
    domain=${file##*/}
    domain=${domain%.conf}
    validate_domain "$domain" || continue
    [[ -z ${seen[$domain]+x} ]] || continue
    seen[$domain]=1
    printf '%s\n' "$domain"
  done
  shopt -u nullglob
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
