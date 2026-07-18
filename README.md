# nginx-proxy-man

A small Bash tool for installing and managing an Nginx reverse-proxy server. It installs the official **stable nginx.org package**, creates an HTTP/2 and HTTP/3 configuration, manages one proxy file per domain, and issues/renews certificates with the [lego](https://go-acme.github.io/lego/) ACME client.

## Features

- Installs stable Nginx from nginx.org on apt, dnf, or yum systems
- Installs the latest lego release for amd64, arm64, armv7, or 386
- Tunes file-descriptor limits, listen queues, connection backlog, and TCP lifecycle settings
- HTTP/2 and HTTP/3 (QUIC), TLS 1.2/1.3, gzip, and optimized worker settings
- Catch-all HTTP/HTTPS host that returns 404
- Long-lived self-signed default certificate, also used by new proxies until ACME succeeds
- Reverse-proxy headers for client IP, forwarded host, port, and scheme
- Optional WebSocket forwarding
- Optional public cache for static assets, plus an opt-in private cache zone
- Access logs include request and upstream connection/header/response timings
- HTTP-01 certificate issuance after checking the domain's public A record
- Domain registry and non-interactive renewal command for cron

## Requirements

- A Debian/Ubuntu or RHEL-compatible Linux server
- Root access for production installation and `/etc/nginx` changes
- Ports **80/tcp**, **443/tcp**, and **443/udp** open in the firewall
- A public DNS A record pointing at the server (or a load balancer/CDN that forwards HTTP-01 requests)

The generated configuration uses the current Nginx HTTP/3 directives. Use the nginx.org package installed by this tool rather than an older distribution build.

## Configuration

Copy the example and edit it:

```bash
cp .env.example .env
$EDITOR .env
```

```dotenv
NGINX_DIR=/etc/nginx
ACME_EMAIL=admin@example.com
```

Defaults are `/etc/nginx` and `proxyman@example.com`. A relative `NGINX_DIR` is resolved from the project directory. For local generation/testing, use:

```dotenv
NGINX_DIR=./nginx
ACME_EMAIL=admin@example.com
```

`.env` and the generated `nginx/` directory are ignored by Git. Because `.env` is loaded as a trusted shell file, do not use an untrusted file.

## Quick start

```bash
chmod +x proxy-man.sh
sudo ./proxy-man.sh install
sudo ./proxy-man.sh init
sudo ./proxy-man.sh proxy
sudo ./proxy-man.sh acme
```

Commands prompt for omitted values. Domain and upstream can also be supplied directly:

```bash
sudo ./proxy-man.sh proxy app.example.com http://127.0.0.1:3000
sudo ./proxy-man.sh acme app.example.com
```

### `install`

```bash
sudo ./proxy-man.sh install
```

Adds the official stable nginx.org repository, installs Nginx and DNS/TLS utilities, then downloads the latest lego binary to `/usr/local/bin/lego`.

It also installs production proxy tuning in:

```text
/etc/sysctl.d/99-nginx-proxy-man.conf
/etc/security/limits.d/99-nginx-proxy-man.conf
/etc/systemd/system/nginx.service.d/limits.conf
```

These settings raise Nginx's open-file limit to 65,535 and tune socket queues, ephemeral ports, SYN backlog, keepalive, and closed-connection reuse. The generated `nginx.conf` also sets `worker_rlimit_nofile 65535`, preventing `worker_connections exceed open file resource limit` warnings. Sysctl settings are applied immediately when supported and are loaded again at boot.

### `init`

```bash
sudo ./proxy-man.sh init
```

Creates the directory layout, default self-signed certificate, snippets, cache, logs, catch-all 404 hosts, an editable `upstreams.conf` template, and `nginx.conf`. The upstream template contains commented examples using documentation-only test IPs and upstream keepalive settings; later `init` runs preserve it so configured upstreams are not lost. An existing `nginx.conf` is backed up with a timestamp. The package's `conf.d/default.conf`, when present, is renamed with a `.disabled.<timestamp>` suffix to prevent a default-server conflict. On a production `/etc/nginx` installation, Nginx is enabled and restarted after a successful configuration test.

Important generated paths (using the production default `NGINX_DIR=/etc/nginx`):

```text
/etc/nginx/nginx.conf
/etc/nginx/conf.d/00-default.conf
/etc/nginx/conf.d/upstreams.conf
/etc/nginx/snippets/proxy-host.conf
/etc/nginx/ssl/default/
/etc/nginx/acme-webroot/
/etc/nginx/acme-domains.txt
/var/log/nginx/
/var/cache/nginx/public_zone/
/var/cache/nginx/private_zone/
```

As with the nginx.org package, access/error logs are stored in `/var/log/nginx`. Public and private proxy-cache data are separated under `/var/cache/nginx/public_zone` and `/var/cache/nginx/private_zone`. For a development `NGINX_DIR` such as `./nginx`, both logs and cache data remain safely contained under that directory as `logs/` and `cache/`.

### `proxy`

```bash
sudo ./proxy-man.sh proxy
```

Prompts for:

1. Main domain
2. Upstream HTTP/HTTPS origin (for example, `http://127.0.0.1:3000`, without a path)
3. WebSocket support
4. Static asset caching

It creates exactly one file at `conf.d/<domain>.conf`. HTTP requests redirect to HTTPS except for the ACME challenge path. Shared HTTPS listener, protocol, header, timeout, and buffering directives are inherited from `snippets/proxy-host.conf`; the per-domain file keeps the domain, certificate paths, upstream, and enabled option overrides. The HTTPS proxy initially uses a copy of the default self-signed certificate, so Nginx remains valid before a public certificate is issued.

With static caching enabled, common image, font, CSS, and JavaScript extensions use the shared `public_zone` cache. Successful responses are cached for 30 days, while 301 and 302 redirects are cached for 4 hours. Static access logging is disabled. Remove cached files manually after an urgent asset replacement, or use versioned asset URLs.

The generated static-cache directive notes that `private_zone` can be used for private routes. Only enable it when upstream responses are safe to cache; a separate cache zone does not by itself make personalized or authenticated responses safe for caching.

### `acme`

```bash
sudo ./proxy-man.sh acme app.example.com
```

The command:

1. Validates that the proxy exists
2. Resolves and checks the domain's public A record with `dig`
3. Warns if the A records do not contain the server's detected public IPv4
4. Runs lego with the HTTP-01 webroot under `acme-webroot/`
5. Replaces the domain certificate and private key only after lego succeeds
6. Tests and reloads Nginx
7. Adds the domain once to `acme-domains.txt`

The A-record mismatch is a warning because a correctly configured CDN or load balancer can still forward the challenge. HTTP port 80 must remain reachable during issuance and renewal.

### `cron`

```bash
sudo ./proxy-man.sh cron
```

Reads `acme-domains.txt`, asks lego to renew certificates expiring within 30 days, and installs successful results. After processing every domain, it tests the complete configuration once and reloads Nginx once, so a batch renewal does not test or reload separately for each certificate. It uses a lock directory to prevent overlapping runs.

Add it to root's crontab with the **absolute path** to this checkout:

```cron
17 3 * * * /absolute/path/nginx-proxy-man/proxy-man.sh cron >>/var/log/nginx-proxy-man-cron.log 2>&1
```

The script always reads `.env` beside `proxy-man.sh`, so cron does not depend on its working directory. Keep the checkout at that path, or update the cron entry after moving it.

## Generated proxy behavior

The upstream receives these headers:

```text
Host
X-Real-IP
X-Forwarded-For
X-Forwarded-Host
X-Forwarded-Proto
X-Forwarded-Port
```

WebSocket mode additionally forwards `Upgrade` and `Connection`. Nginx's access format records `$request_time`, `$upstream_addr`, `$upstream_connect_time`, `$upstream_header_time`, and `$upstream_response_time`.

## Operational notes

- Back up `/etc/nginx` before first use on a server with an existing hand-written configuration.
- `init` owns `nginx.conf`, `00-default.conf`, and `snippets/proxy-host.conf`. It creates `upstreams.conf` only when missing, preserving later edits.
- `install` owns the `99-nginx-proxy-man` sysctl/limits files and the Nginx systemd limit override.
- A proxy file is only removed automatically when Nginx rejects a newly created configuration. An existing proxy replacement is never performed without confirmation.
- Certificate private keys are written with mode `0600`.
- lego account and certificate state is stored under `${NGINX_DIR}/lego` and should be included in backups.
- HTTP/3 requires UDP/443 and a client/network path that supports QUIC; HTTPS continues to work over TCP when QUIC is unavailable.

## Command summary

```text
./proxy-man.sh install
./proxy-man.sh init
./proxy-man.sh proxy [domain] [upstream-url]
./proxy-man.sh acme [domain]
./proxy-man.sh cron
```
