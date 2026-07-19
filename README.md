# nginx-proxy-man

A small Bash tool for installing and managing an Nginx reverse-proxy server. It installs the official **stable nginx.org package**, creates an HTTP/2 and HTTP/3 configuration, manages one proxy file per domain, and issues/renews certificates with the [lego](https://go-acme.github.io/lego/) ACME client.

![nginx-proxy-man-logo](./proxy-man.jpg)

## Features

- Installs stable Nginx from nginx.org and the GoAccess terminal log analyzer on apt, dnf, or yum systems
- Installs the latest lego release for amd64, arm64, armv7, or 386
- Tunes file-descriptor limits, listen queues, connection backlog, and TCP lifecycle settings
- HTTP/2 and HTTP/3 (QUIC), tuned TLS 1.2/1.3, gzip, and optimized worker settings
- Catch-all HTTP/HTTPS host that returns 404
- Long-lived self-signed default certificate, also used by new proxies until ACME succeeds
- Reverse-proxy headers for client IP, forwarded host, port, and scheme
- Optional WebSocket forwarding
- Optional public cache for static assets, plus an opt-in private cache zone
- Separate buffered access log per domain, including request and upstream timing data
- Interactive per-domain traffic analysis with the GoAccess TUI
- HTTP-01 certificate issuance after checking the domain's public A record, with opt-in DNS-01 through any lego-supported provider
- One-command health dashboard for domains, upstream reachability and latency, certificate expiry, Nginx state, and recent errors
- Domain listing with ACME challenge status, plus non-interactive certificate renewal for cron

## Requirements

- A Debian/Ubuntu or RHEL-compatible Linux server
- Root access for production installation and `/etc/nginx` changes
- Ports **80/tcp**, **443/tcp**, and **443/udp** open in the firewall
- A public DNS A record pointing at the server (or a load balancer/CDN that forwards HTTP-01 requests)

The generated configuration uses the current Nginx HTTP/3 directives. Use the nginx.org package installed by this tool rather than an older distribution build.

## Standalone download

The tool is a single shell file. Download and run it without cloning the repository:

```bash
curl -fsSLO https://raw.githubusercontent.com/khanhicetea/proxy-man/main/proxy-man.sh
chmod +x proxy-man.sh
sudo ./proxy-man.sh install
```

`install` creates `.env` next to `proxy-man.sh` when it does not already exist:

```dotenv
NGINX_DIR=/etc/nginx
ACME_EMAIL=
```

Set an email before requesting ACME/TLS certificates:

```bash
sudoedit .env
```

## Configuration

The script reads `.env` beside `proxy-man.sh`. `install` creates it automatically, but you can also create it before installation from `.env.example`:

```bash
cp .env.example .env
$EDITOR .env
```

```dotenv
NGINX_DIR=/etc/nginx
ACME_EMAIL=admin@example.com
```

`NGINX_DIR` defaults to `/etc/nginx`; `ACME_EMAIL` is intentionally empty by default. A relative `NGINX_DIR` is resolved from the project directory. The file is also where DNS-provider credentials are set when using DNS-01; lego reads its provider-specific environment variables directly. For local generation/testing, use:

```dotenv
NGINX_DIR=./nginx
ACME_EMAIL=admin@example.com
```

`.env` and the generated `nginx/` directory are ignored by Git. Because `.env` is loaded as a trusted shell file, do not use an untrusted file.

## Quick start

```bash
curl -fsSLO https://raw.githubusercontent.com/khanhicetea/proxy-man/main/proxy-man.sh
chmod +x proxy-man.sh
sudo ./proxy-man.sh install
sudoedit .env # Set ACME_EMAIL before using ACME/TLS.
sudo ./proxy-man.sh init
sudo ./proxy-man.sh proxy
sudo ./proxy-man.sh acme
```

Commands prompt for omitted values. Domain and upstream can also be supplied directly:

```bash
sudo ./proxy-man.sh proxy app.example.com http://127.0.0.1:3000
sudo ./proxy-man.sh list
sudo ./proxy-man.sh status
sudo ./proxy-man.sh acme app.example.com
sudo ./proxy-man.sh acme app.example.com --dns cloudflare
sudo ./proxy-man.sh acme '*.example.com' --dns cloudflare
sudo ./proxy-man.sh analyze app.example.com
```

### `install`

```bash
sudo ./proxy-man.sh install
```

Creates `.env` beside the script if it is missing, with `NGINX_DIR=/etc/nginx` and an empty `ACME_EMAIL`. It then adds the official stable nginx.org repository, installs Nginx, GoAccess, and DNS/TLS utilities, and downloads the latest lego binary to `/usr/local/bin/lego`. On RHEL-compatible systems, EPEL is enabled if GoAccess is not already available.

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

Creates the directory layout, default self-signed certificate, snippets, cache, logs, catch-all 404 hosts, an editable `upstreams.conf` template, and `nginx.conf`. If `ACME_EMAIL` is empty, it prints a warning; initialization continues with self-signed certificates, but set the email in `.env` before using `acme`. It also installs logrotate when needed and writes `/etc/logrotate.d/nginx` for system configuration roots. Nginx logs are checked daily, rotated once they reach 100 MiB, compressed, and limited to two retained rotations; Nginx is signaled to reopen its logs after rotation. Development trees outside `/etc`, `/usr`, and `/var` skip system logrotate setup. The generated default HTTP and HTTPS hosts expose Nginx `stub_status` at `/status` only to `127.0.0.1`; all other clients receive an access denial.

The upstream template contains commented examples using documentation-only test IPs and upstream keepalive settings; later `init` runs preserve it so configured upstreams are not lost. An existing `nginx.conf` is backed up with a timestamp. The package's `conf.d/default.conf`, when present, is renamed with a `.disabled.<timestamp>` suffix to prevent a default-server conflict. On a production `/etc/nginx` installation, Nginx is enabled and restarted after a successful configuration test.

Important generated paths (using the production default `NGINX_DIR=/etc/nginx`):

```text
/etc/nginx/nginx.conf
/etc/nginx/conf.d/00-default.conf
/etc/nginx/conf.d/upstreams.conf
/etc/nginx/snippets/proxy-host.conf
/etc/nginx/snippets/block-bot-map.conf
/etc/nginx/snippets/block-bot.conf
/etc/nginx/ssl/default/
/etc/nginx/acme-webroot/
/etc/nginx/acme-domains.txt
/etc/logrotate.d/nginx
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

It creates exactly one file at `conf.d/<domain>.conf`. HTTP requests redirect to HTTPS except for the ACME challenge path. Shared HTTPS listener, protocol, header, timeout, buffering, and hidden-path protection are inherited from `snippets/proxy-host.conf`; requests for dotfiles or dot-directories return 404 instead of reaching the upstream, while the standardized `.well-known` namespace remains available. The per-domain file keeps the domain, certificate paths, upstream, and enabled option overrides. Requests handled by the primary HTTPS `location /` are written to `/var/log/nginx/<domain>.access.log` (or `logs/<domain>.access.log` under a development `NGINX_DIR`), using a 64 KiB buffer flushed at least every 60 seconds. The HTTPS proxy initially uses a copy of the default self-signed certificate, so Nginx remains valid before a public certificate is issued.

User-Agent bot filtering is available but disabled by default. Each generated `conf.d/<domain>.conf` contains a commented include for `snippets/block-bot.conf`; review `snippets/block-bot-map.conf`, then uncomment that per-host include to return HTTP 403 for empty User-Agents, unknown bot/crawler identifiers, and common automation clients. Known search, social, and AI crawlers are allowed before the generic bot rule. User-Agent values are trivial to spoof, so use rate limiting or a WAF when stronger protection is required.

With static caching enabled, common image, font, CSS, and JavaScript extensions use the shared `public_zone` cache. Successful responses are cached for 30 days, while 301 and 302 redirects are cached for 4 hours. Static-route access logging is disabled, keeping the per-domain log focused on `location /`. Remove cached files manually after an urgent asset replacement, or use versioned asset URLs.

The generated static-cache directive notes that `private_zone` can be used for private routes. Only enable it when upstream responses are safe to cache; a separate cache zone does not by itself make personalized or authenticated responses safe for caching.

### `list`

```bash
sudo ./proxy-man.sh list
```

Lists every domain-named `conf.d/*.conf` file in a two-column table. The `ACME` column is `yes` when the domain is registered in `acme-domains.txt` for certificate renewal.

### `status`

```bash
sudo ./proxy-man.sh status
```

Prints a health dashboard for every configured proxy domain. It calls Nginx's local-only `http://127.0.0.1/status` endpoint and prints its `stub_status` connection metrics. Each upstream is requested directly at its configured origin with a 3-second connect timeout and 5-second total timeout; the result includes the HTTP status and total request latency. The command also shows each installed certificate's expiration date and days remaining, whether Nginx is running, and the number of `error`-or-higher entries in the current Nginx error log from the last 24 hours. An HTTP response of any status confirms upstream reachability; `DOWN` means the origin could not be reached within the check. Run `init` once after upgrading to add `/status` to an existing generated configuration.

### `analyze`

```bash
sudo ./proxy-man.sh analyze app.example.com
```

Opens the GoAccess terminal dashboard for the domain's current access log. `goaccess` is also accepted as a command alias for `analyze`. Omit the domain to be prompted. Exit the dashboard with `q`. Since writes are buffered for up to 60 seconds, the newest requests may take a short time to appear.

### `acme`

```bash
sudo ./proxy-man.sh acme app.example.com
sudo ./proxy-man.sh acme app.example.com --dns cloudflare
```

HTTP-01 is the default. It validates that the proxy exists, resolves and checks the domain's public A record with `dig`, and warns when it does not contain the server's detected public IPv4. It then runs lego using the HTTP webroot under `acme-webroot/`. HTTP port 80 must remain reachable during issuance and renewal. The A-record mismatch is only a warning because a CDN or load balancer can forward the challenge.

DNS-01 is used **only** when `--dns <lego-provider>` is supplied. Put that provider's [lego DNS environment variables](https://go-acme.github.io/lego/dns/) in the script-side `.env` file; for example, `CLOUDFLARE_DNS_API_TOKEN` for `--dns cloudflare`. `.env` is loaded for both manual issuance and `cron`, so DNS-01 renewals use the same credentials. Use a least-privilege, zone-scoped token and keep `.env` mode `0600`.

Wildcard names require DNS-01 and do not require a matching proxy file:

```bash
sudo ./proxy-man.sh acme '*.example.com' --dns cloudflare
```

Lego stores wildcard files with `*` replaced by `_`; proxy-man installs the result under `ssl/_.example.com/`. Point any hand-written wildcard Nginx server at that directory. After a successful issuance, proxy-man tests and reloads Nginx and records the domain's challenge method in `acme-domains.txt`. Records use `domain<TAB>http` or `domain<TAB>dns<TAB>provider`; old one-column records remain HTTP-01 compatible.

### `cron`

```bash
sudo ./proxy-man.sh cron
```

Reads `acme-domains.txt`, including each domain's recorded HTTP-01 or DNS-01 provider, asks lego to renew certificates expiring within 30 days, and installs successful results. It loads `.env` before running, so provider credentials are available to DNS-01 renewals. After processing every domain, it tests the complete configuration once and reloads Nginx once, so a batch renewal does not test or reload separately for each certificate. It uses a lock directory to prevent overlapping runs.

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

WebSocket mode additionally forwards `Upgrade` and `Connection`. Nginx's access format records `$request_time`, `$upstream_connect_time`, `$upstream_header_time`, and `$upstream_response_time`.

TLS is limited to TLS 1.2 and 1.3 with ECDHE, AES-GCM, and ChaCha20-Poly1305 suites. Client cipher preference is retained so mobile clients without fast AES hardware can select ChaCha20, while clients with AES acceleration can use AES-GCM. X25519 is the preferred key-exchange group, with P-256 and P-384 fallbacks. The shared session cache provides stateful resumption while persistent session tickets remain disabled.

## Operational notes

- Back up `/etc/nginx` before first use on a server with an existing hand-written configuration.
- `init` owns `nginx.conf`, `00-default.conf`, `snippets/proxy-host.conf`, the two `block-bot*.conf` snippets, and `/etc/logrotate.d/nginx` for system configuration roots. It creates `upstreams.conf` only when missing, preserving later edits.
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
./proxy-man.sh list
./proxy-man.sh status
./proxy-man.sh acme [domain] [--dns provider]
./proxy-man.sh analyze [domain]
./proxy-man.sh cron
```
