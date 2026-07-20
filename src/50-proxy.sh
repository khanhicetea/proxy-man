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
