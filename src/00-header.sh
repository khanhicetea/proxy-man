#!/usr/bin/env bash
set -Eeuo pipefail

# Allow a thin repo launcher to pin SCRIPT_DIR to the project root before sourcing.
SCRIPT_DIR=${SCRIPT_DIR:-$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
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
ONDEMAND_CONF_DIR="$CONF_DIR/ondemand"
ONDEMAND_HOOK_ID=proxy-man-ondemand
ONDEMAND_PORT=${ONDEMAND_PORT:-9000}
ONDEMAND_TOKEN=${ONDEMAND_TOKEN:-}
ONDEMAND_SECRET=${ONDEMAND_SECRET:-}
ONDEMAND_TRIGGER=${ONDEMAND_TRIGGER:-}
WEBHOOK_UNIT_PATH=/etc/systemd/system/proxy-man-webhook.service
