# AGENTS.md

Guidance for coding agents working on **nginx-proxy-man**.

## What this project is

Bash tool that installs and manages an Nginx reverse proxy: official nginx.org packages, HTTP/2 + HTTP/3 config, per-domain proxies, lego ACME certificates, GoAccess, GeoIP2, and optional on-demand provisioning via webhook.

## Source of truth

- **Edit `src/*.sh` only.** Modules are numbered for concat order (`00-header` → `90-main`).
- **Do not read or edit `dist/proxy-man.sh`.** It is a generated standalone artifact. Reading it wastes context and can drift from real source. Rebuild instead of inspecting it.
- Root `proxy-man.sh` is a thin dev launcher that sources `src/` with `SCRIPT_DIR` pinned to the repo root.
- Users install from `dist/proxy-man.sh` (see README).

## Build and hooks

```bash
./scripts/build.sh         # write dist/proxy-man.sh from src/
./scripts/setup-hooks.sh   # core.hooksPath=.githooks (once per clone)
```

Pre-commit rebuilds and stages `dist/proxy-man.sh` when it changes. After source edits, run `./scripts/build.sh` and keep the artifact in sync before finishing.

## Conventions

- `bash` with `set -Eeuo pipefail`
- `.env` beside the script (`SCRIPT_DIR`); treated as trusted shell input
- Prefer small, focused modules; put new commands near related helpers
- Validate with `bash -n` on changed `src/` files and the rebuilt dist (syntax only—do not open dist to “understand” behavior)
- Update README when user-facing commands, install URL, or behavior change

## Quick checks

```bash
bash -n src/*.sh proxy-man.sh
./scripts/build.sh
bash -n dist/proxy-man.sh
./proxy-man.sh help
./test.sh                 # isolated tmp NGINX_DIR; skips real ACME issuance
```
