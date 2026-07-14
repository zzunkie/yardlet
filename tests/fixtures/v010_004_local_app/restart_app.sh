#!/usr/bin/env bash
set -euo pipefail

python_bin="${1:?python executable is required}"
app_script="${2:?app script is required}"
port="${3:?port is required}"
log_prefix="${4:?log prefix is required}"

exec "$python_bin" "$app_script" --port "$port" \
  >"${log_prefix}.stdout.log" 2>"${log_prefix}.stderr.log"
