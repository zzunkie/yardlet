#!/usr/bin/env bash
set -u

: "${YARDLET_FIXTURE_REAL_GIT:?missing real git path}"
: "${YARDLET_FIXTURE_GIT_LOG:?missing wrapper log path}"

mode="${YARDLET_FIXTURE_CRASH_MODE:-normal}"
is_push=0
refspec=""
for arg in "$@"; do
  if [[ "$arg" == "push" ]]; then
    is_push=1
  fi
  if [[ "$arg" == *":refs/heads/"* ]]; then
    refspec="$arg"
  fi
done

printf 'CALL\tpid=%s\tpgid=%s\t' "$$" "$(ps -o pgid= -p $$ | tr -d ' ')" >>"$YARDLET_FIXTURE_GIT_LOG"
printf '%q ' "$@" >>"$YARDLET_FIXTURE_GIT_LOG"
printf '\n' >>"$YARDLET_FIXTURE_GIT_LOG"

if [[ "$is_push" -eq 1 && "$mode" == "before_push" ]]; then
  printf '%s\n' "$$" >"${YARDLET_FIXTURE_EVENT:?missing event path}.pid"
  : >"$YARDLET_FIXTURE_EVENT"
  while :; do sleep 1; done
fi

"$YARDLET_FIXTURE_REAL_GIT" "$@"
status=$?

if [[ "$is_push" -eq 1 && "$status" -eq 0 ]]; then
  printf 'PUSH_SUCCESS\t%s\n' "$refspec" >>"$YARDLET_FIXTURE_GIT_LOG"
  if [[ "$mode" == "after_push" ]]; then
    printf '%s\n' "$$" >"${YARDLET_FIXTURE_EVENT:?missing event path}.pid"
    : >"$YARDLET_FIXTURE_EVENT"
    while :; do sleep 1; done
  fi
fi

exit "$status"

