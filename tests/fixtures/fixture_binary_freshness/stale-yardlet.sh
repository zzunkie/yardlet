#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == "eval fixtures --list --json" ]]; then
  printf '{"schema_version":1,"fixture_ids":["watch-until-path-exists"]}\n'
  exit 0
fi

: >"${STALE_FIXTURE_BODY_MARKER:?missing stale fixture body marker}"
printf "yardlet: unknown fixture 'fixture-added-after-build'\n" >&2
exit 1
