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
