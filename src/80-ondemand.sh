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

install_gomplate() {
  local machine arch url sha256 tmp expected actual
  local version=v5.2.0
  if command -v gomplate >/dev/null 2>&1; then
    log "gomplate already installed: $(command -v gomplate) ($(gomplate --version 2>&1 || true))"
    return 0
  fi

  machine=$(uname -m)
  case "$machine" in
    x86_64|amd64)
      arch=amd64
      sha256=a235564c12f12e755c06e3ab2af414ab1e3f5b1f142eb82ea2d8086145670a81
      ;;
    aarch64|arm64)
      arch=arm64
      sha256=f445888455c30fa80a3ddce1643baadcdbe1a0207eb6c0de300a38a2c3fb64a2
      ;;
    *) die "gomplate has no configured download for architecture: $machine" ;;
  esac

  url="https://github.com/hairyhenderson/gomplate/releases/download/${version}/gomplate_linux-${arch}"
  tmp=$(mktemp -d)
  log "Downloading gomplate ${version} (${arch})..."
  if ! curl -fsSL "$url" -o "$tmp/gomplate"; then
    rm -rf "$tmp"
    die "Failed to download gomplate from $url"
  fi

  actual=$(sha256sum "$tmp/gomplate" | awk '{print $1}')
  expected=$sha256
  if [[ "$actual" != "$expected" ]]; then
    rm -rf "$tmp"
    die "gomplate checksum mismatch (expected $expected, got $actual)"
  fi

  install -m 0755 "$tmp/gomplate" /usr/local/bin/gomplate
  rm -rf "$tmp"
  command -v gomplate >/dev/null 2>&1 || die "gomplate install failed."
  log "Installed gomplate: $(command -v gomplate) ($(gomplate --version 2>&1 || true))"
}

write_default_ondemand_template() {
  install -d -m 0755 "$TEMPLATE_DIR"
  local tpl="$TEMPLATE_DIR/default.tpl"
  [[ -e "$tpl" ]] && return 0
  cat > "$tpl" <<'EOF'
{{/*
  On-demand vhost template (gomplate).

  Rendered by `ondemand webhook` with JSON context piped into gomplate
  (`gomplate -f <template> -c .=stdin:?type=application/json`). Use Go template syntax:
    {{ .domain }}  {{ .upstream }}  {{ .ssl_dir }}/{{ .domain }}/fullchain.pem

  Common variables (always present):
    .domain         Requested server_name (validated)
    .upstream       proxy_pass origin URL (validated)
    .acme_webroot   ACME HTTP-01 webroot directory
    .ssl_dir        TLS certificate root (per-domain subdirs)
    .log_dir        Access/error log directory
    .snippet_dir    Shared Nginx snippets directory
    .nginx_dir      Nginx configuration root

  Rendered files are written to conf.d/ondemand/<domain>.conf only
  (subdir membership is what marks a vhost as on-demand).

  Docs: https://docs.gomplate.ca/
*/}}
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

    # Optional UA filter; review block-bot-map.conf before enabling.
    # include "{{ .snippet_dir }}/block-bot.conf";

    server_name {{ .domain }};
    ssl_certificate "{{ .ssl_dir }}/{{ .domain }}/fullchain.pem";
    ssl_certificate_key "{{ .ssl_dir }}/{{ .domain }}/privkey.pem";

    location / {
        # Optional GeoIP2 headers for the upstream (after running geoip2):
        # include "{{ .snippet_dir }}/proxy-geoip.conf";
        access_log "{{ .log_dir }}/{{ .domain }}.access.log" proxy_timing buffer=64k flush=60s;
        proxy_pass {{ .upstream }};
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
      {"source": "payload", "name": "action", "envname": "OD_ACTION"},
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
  install_gomplate
  # Avoid the package unit binding :9000 if someone later drops /etc/webhook.conf.
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl disable --now webhook.service 2>/dev/null || true
  fi
  install -d -m 0755 "$TEMPLATE_DIR" "$ONDEMAND_DIR"
  ensure_ondemand_conf_dir
  if ! grep -qF "include \"$ONDEMAND_CONF_DIR/*.conf\"" "$NGINX_DIR/nginx.conf" 2>/dev/null \
    && ! grep -qE 'include[[:space:]]+.*/ondemand/\*\.conf' "$NGINX_DIR/nginx.conf" 2>/dev/null; then
    die "nginx.conf is missing the ondemand conf include. Re-run '$0 init' then '$0 ondemand setup'."
  fi
  write_default_ondemand_template
  if [[ -n "$ONDEMAND_TRIGGER" ]]; then
    [[ -f "$ONDEMAND_TRIGGER" && -x "$ONDEMAND_TRIGGER" ]] \
      || warn "ONDEMAND_TRIGGER is set but not an executable file: $ONDEMAND_TRIGGER"
  fi

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
  log "On-demand vhost directory: $ONDEMAND_CONF_DIR"
  if [[ -n "$ONDEMAND_TRIGGER" ]]; then
    log "Post-webhook trigger: $ONDEMAND_TRIGGER"
  else
    log "Post-webhook trigger: (unset; optional ONDEMAND_TRIGGER in $ENV_FILE)"
  fi
  log "Example:"
  log "  curl -X POST \"https://<host>/_ondemand/${ONDEMAND_TOKEN}\" \\"
  log "    -H 'Content-Type: application/json' \\"
  log "    -H \"X-Proxy-Man-Token: \$ONDEMAND_SECRET\" \\"
  log "    -d '{\"action\":\"create\",\"template\":\"default.tpl\",\"domain\":\"app.example.com\",\"upstream\":\"http://127.0.0.1:3000\",\"acme\":true}'"
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
  printf '  vhost dir: %s\n' "$ONDEMAND_CONF_DIR"
  if [[ -n "$ONDEMAND_TRIGGER" ]]; then
    printf '  trigger: %s (%s)\n' "$ONDEMAND_TRIGGER" \
      "$([[ -x "$ONDEMAND_TRIGGER" ]] && printf executable || printf 'missing or not executable')"
  else
    printf '  trigger: (unset)\n'
  fi

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
    '{"domain":"%s","status":"%s","code":%s,"message":"%s","acme":"%s","config":"%s","action":"%s"}' \
    "$(json_escape "${ONDEMAND_CB_DOMAIN:-}")" \
    "$(json_escape "$status")" \
    "$code" \
    "$(json_escape "$message")" \
    "$(json_escape "$acme_state")" \
    "$(json_escape "${ONDEMAND_CB_CONFIG:-}")" \
    "$(json_escape "${ONDEMAND_CB_ACTION:-}")"

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
  ONDEMAND_LAST_RESULT_JSON=$json
  ONDEMAND_LAST_RESULT_CODE=$code
  ONDEMAND_LAST_RESULT_STATUS=$status
  printf '%s\n' "$json"
}

ondemand_run_trigger() {
  local json=${1:-} code=${2:-1} status=${3:-} trigger=${ONDEMAND_TRIGGER:-}
  [[ -n "$trigger" ]] || return 0
  if [[ ! -f "$trigger" || ! -x "$trigger" ]]; then
    warn "ONDEMAND_TRIGGER is not an executable file: $trigger"
    return 0
  fi
  [[ -n "$status" ]] || { [[ "$code" -eq 0 ]] && status=ok || status=error; }
  log "Running ONDEMAND_TRIGGER ($status/$code): $trigger"
  # stdout/stderr discarded so webhook HTTP body stays pure JSON.
  if ! printf '%s\n' "$json" | \
    ONDEMAND_TRIGGER_JSON="$json" \
    ONDEMAND_TRIGGER_CODE="$code" \
    ONDEMAND_TRIGGER_STATUS="$status" \
    ONDEMAND_TRIGGER_DOMAIN="${ONDEMAND_CB_DOMAIN:-}" \
    ONDEMAND_TRIGGER_CONFIG="${ONDEMAND_CB_CONFIG:-}" \
    ONDEMAND_TRIGGER_ACTION="${ONDEMAND_CB_ACTION:-}" \
    "$trigger" >/dev/null 2>&1; then
    warn "ONDEMAND_TRIGGER exited non-zero: $trigger"
  fi
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
  local template_path=$1 output_path=$2 domain=$3 upstream=$4 data
  if ! command -v gomplate >/dev/null 2>&1; then
    warn "gomplate is not installed; run '$0 ondemand setup'"
    return 1
  fi
  printf -v data \
    '{"domain":"%s","upstream":"%s","acme_webroot":"%s","ssl_dir":"%s","log_dir":"%s","snippet_dir":"%s","nginx_dir":"%s"}' \
    "$(json_escape "$domain")" \
    "$(json_escape "$upstream")" \
    "$(json_escape "$ACME_WEBROOT")" \
    "$(json_escape "$SSL_DIR")" \
    "$(json_escape "$LOG_DIR")" \
    "$(json_escape "$SNIPPET_DIR")" \
    "$(json_escape "$NGINX_DIR")"
  if ! printf '%s\n' "$data" | gomplate -f "$template_path" -c .=stdin:?type=application/json -o "$output_path"; then
    warn "gomplate failed to render $template_path"
    return 1
  fi
  return 0
}

ondemand_delete_vhost() {
  local domain=$1 config="$ONDEMAND_CONF_DIR/$domain.conf" backup

  if [[ ! -f "$config" ]]; then
    ondemand_emit_result error "On-demand proxy does not exist for $domain"
    exit 1
  fi

  ONDEMAND_CB_CONFIG=$config
  backup=$(mktemp)
  cp -a "$config" "$backup"
  rm -f "$config"

  if ! reload_nginx; then
    cp -a "$backup" "$config"
    rm -f "$backup"
    ondemand_emit_result error "Nginx rejected configuration after deleting $domain; previous file restored"
    exit 1
  fi
  rm -f "$backup"
  log "On-demand proxy deleted for $domain ($config)"
  ondemand_emit_result ok "Proxy deleted for $domain"
}

ondemand_create_vhost() {
  local domain=$1 template=$2 upstream=$3 replace=$4 want_acme=$5
  local config template_path rendered backup='' acme_state=skipped

  [[ -n "$template" ]] || { ondemand_emit_result error "template is required"; exit 1; }
  [[ -n "$upstream" ]] || { ondemand_emit_result error "upstream is required"; exit 1; }
  [[ "$template" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.tpl$ ]] || {
    ondemand_emit_result error "template must be a basename ending in .tpl"
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

  ensure_ondemand_conf_dir
  config="$ONDEMAND_CONF_DIR/$domain.conf"
  ONDEMAND_CB_CONFIG=$config

  if [[ -e "$CONF_DIR/$domain.conf" ]]; then
    ondemand_emit_result error "Domain $domain already has $CONF_DIR/$domain.conf; remove it before ondemand create"
    exit 1
  fi
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
  if ! ondemand_render_template "$template_path" "$rendered" "$domain" "$upstream"; then
    rm -f "$rendered"
    [[ -n "$backup" ]] && rm -f "$backup"
    ondemand_emit_result error "Failed to render template $template"
    exit 1
  fi
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
  log "On-demand proxy created for $domain -> $upstream from $template ($config)"

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

ondemand_webhook() {
  local domain=${OD_DOMAIN:-} template=${OD_TEMPLATE:-} upstream=${OD_UPSTREAM:-}
  local callback_url=${OD_CALLBACK_URL:-} replace_raw=${OD_REPLACE:-} acme_raw=${OD_ACME:-}
  local action=${OD_ACTION:-create}
  local replace=n want_acme=n

  ONDEMAND_CB_URL=
  ONDEMAND_CB_DOMAIN=
  ONDEMAND_CB_CONFIG=
  ONDEMAND_CB_ACTION=
  ONDEMAND_LAST_RESULT_JSON=
  ONDEMAND_LAST_RESULT_CODE=1
  ONDEMAND_LAST_RESULT_STATUS=error
  # Always run optional post-hook after success or failure (keeps webhook body JSON-only).
  trap 'ondemand_run_trigger "${ONDEMAND_LAST_RESULT_JSON-}" "${ONDEMAND_LAST_RESULT_CODE:-1}" "${ONDEMAND_LAST_RESULT_STATUS-}"' EXIT

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
  action=${action,,}
  action=${action//$'\r'/}
  as_bool "$replace_raw" && replace=y
  as_bool "$acme_raw" && want_acme=y

  ONDEMAND_CB_URL=$callback_url
  ONDEMAND_CB_DOMAIN=$domain
  ONDEMAND_CB_ACTION=$action

  [[ -n "$domain" ]] || { ondemand_emit_result error "domain is required"; exit 1; }
  validate_domain "$domain" || {
    ondemand_emit_result error "Invalid domain: $domain"
    exit 1
  }

  ONDEMAND_CB_CONFIG="$ONDEMAND_CONF_DIR/$domain.conf"

  case "$action" in
    create|'')
      ONDEMAND_CB_ACTION=create
      ondemand_create_vhost "$domain" "$template" "$upstream" "$replace" "$want_acme"
      ;;
    delete)
      ONDEMAND_CB_ACTION=delete
      ondemand_delete_vhost "$domain"
      ;;
    *)
      ondemand_emit_result error "action must be create or delete"
      exit 1
      ;;
  esac
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
  setup [--rotate]   Install webhook + gomplate, write hooks, expose /_ondemand/<token>
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
