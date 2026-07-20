#!/usr/bin/env bash
# Point this repository's Git hooks at .githooks/ (run once after clone).
set -euo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

git config core.hooksPath .githooks
chmod +x .githooks/pre-commit scripts/build.sh

printf 'setup-hooks: core.hooksPath=.githooks\n'
printf 'setup-hooks: pre-commit will rebuild dist/proxy-man.sh from src/\n'
