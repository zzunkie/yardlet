#!/usr/bin/env bash
set -u

: "${YARDLET_FIXTURE_REAL_GIT:?missing real git path}"
: "${YARDLET_FIXTURE_GIT_LOG:?missing Git call log}"

for arg in "$@"; do
  case "$arg" in
    http://* | https://* | ssh://* | git@*)
      printf 'PUBLIC_REMOTE_REJECTED\t%s\n' "$arg" >>"$YARDLET_FIXTURE_GIT_LOG"
      exit 96
      ;;
  esac
done

printf 'CALL\tpid=%s\tpgid=%s\t' "$$" "$(ps -o pgid= -p $$ | tr -d ' ')" \
  >>"$YARDLET_FIXTURE_GIT_LOG"
printf '%q ' "$@" >>"$YARDLET_FIXTURE_GIT_LOG"
printf '\n' >>"$YARDLET_FIXTURE_GIT_LOG"

is_push=0
refspec=""
for arg in "$@"; do
  [[ "$arg" == "push" ]] && is_push=1
  [[ "$arg" == *":refs/heads/"* ]] && refspec="$arg"
done

mode="${YARDLET_FIXTURE_CRASH_MODE:-normal}"
if [[ "$is_push" -eq 1 && "$refspec" == *":refs/heads/yardlet/runs/"* \
  && "$mode" == "before_head_push" ]]; then
  printf '%s\n' "$$" >"${YARDLET_FIXTURE_EVENT:?missing event path}.pid"
  : >"$YARDLET_FIXTURE_EVENT"
  while :; do sleep 1; done
fi

"$YARDLET_FIXTURE_REAL_GIT" "$@"
status=$?

if [[ "$is_push" -eq 1 && "$status" -eq 0 ]]; then
  printf 'PUSH_SUCCESS\t%s\n' "$refspec" >>"$YARDLET_FIXTURE_GIT_LOG"
  if [[ "$refspec" == *":refs/heads/yardlet/runs/"* \
    && "$mode" == "after_head_push" ]]; then
    printf '%s\n' "$$" >"${YARDLET_FIXTURE_EVENT:?missing event path}.pid"
    : >"$YARDLET_FIXTURE_EVENT"
    while :; do sleep 1; done
  fi
fi

exit "$status"
