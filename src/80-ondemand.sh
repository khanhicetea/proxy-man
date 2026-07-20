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
