#!/usr/bin/env bash
set -eu
printf 'unexpected worker invocation\n' >>"${YARDLET_FIXTURE_WORKER_LOG:?missing worker log path}"
exit 97

