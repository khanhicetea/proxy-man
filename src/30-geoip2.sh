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
