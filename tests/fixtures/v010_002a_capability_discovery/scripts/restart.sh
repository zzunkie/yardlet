#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  printf 'usage: %s <yardlet-bin> <workspace> <output-json>\n' "$0" >&2
  exit 64
fi

cd "$2"
exec "$1" planning show --json >"$3"
