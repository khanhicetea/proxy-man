#!/usr/bin/env bash
# Development launcher: sources src/*.sh with SCRIPT_DIR pinned to the repo root.
# End users should download the built standalone script instead:
#   curl -fsSLO https://raw.githubusercontent.com/khanhicetea/proxy-man/main/dist/proxy-man.sh
set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SRC_DIR="$SCRIPT_DIR/src"

if [[ ! -d "$SRC_DIR" ]]; then
  printf 'proxy-man: src/ not found. Download dist/proxy-man.sh for standalone use.\n' >&2
  exit 1
fi

shopt -s nullglob
modules=("$SRC_DIR"/*.sh)
shopt -u nullglob
if ((${#modules[@]} == 0)); then
  printf 'proxy-man: no source modules in %s\n' "$SRC_DIR" >&2
  exit 1
fi

for module in "${modules[@]}"; do
  # shellcheck disable=SC1090
  source "$module"
done
