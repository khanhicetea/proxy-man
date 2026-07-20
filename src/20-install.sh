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
# Optional executable run after each ondemand webhook finishes (success or failure).
# Receives the result JSON on stdin and in ONDEMAND_TRIGGER_JSON; also sets
# ONDEMAND_TRIGGER_CODE, ONDEMAND_TRIGGER_DOMAIN, ONDEMAND_TRIGGER_CONFIG,
# ONDEMAND_TRIGGER_ACTION, and ONDEMAND_TRIGGER_STATUS.
# ONDEMAND_TRIGGER=/usr/local/bin/proxy-man-ondemand-hook
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
