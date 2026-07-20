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
    include "$ONDEMAND_CONF_DIR/*.conf";
}
EOF
}

ensure_ondemand_conf_dir() {
  # Nginx fails the include glob when the directory is empty, so keep a harmless
  # placeholder that list/status skip (not a valid domain name).
  install -d -m 0755 "$ONDEMAND_CONF_DIR"
  local placeholder="$ONDEMAND_CONF_DIR/00-placeholder.conf"
  if [[ ! -e "$placeholder" ]]; then
    cat > "$placeholder" <<EOF
# Managed by nginx-proxy-man.
# Placeholder so include $ONDEMAND_CONF_DIR/*.conf always matches at least one file.
EOF
    chmod 0644 "$placeholder"
  fi
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
  ensure_ondemand_conf_dir

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
