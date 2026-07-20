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
