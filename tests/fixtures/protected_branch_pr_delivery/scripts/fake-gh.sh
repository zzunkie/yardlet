#!/usr/bin/env bash
set -euo pipefail

: "${YARDLET_FIXTURE_GH_LOG:?missing gh call log}"
: "${YARDLET_FIXTURE_GH_STATE:?missing gh state path}"
: "${YARDLET_FIXTURE_EXPECTED_OID:?missing expected OID}"
: "${YARDLET_FIXTURE_EXPECTED_HOST:?missing expected GitHub host}"

printf 'CALL\tpid=%s\tpgid=%s\t' "$$" "$(ps -o pgid= -p $$ | tr -d ' ')" \
  >>"$YARDLET_FIXTURE_GH_LOG"
printf '%q ' "$@" >>"$YARDLET_FIXTURE_GH_LOG"
printf '\n' >>"$YARDLET_FIXTURE_GH_LOG"

explicit_host=""
previous=""
for arg in "$@"; do
  [[ "$previous" != "--hostname" ]] || explicit_host="$arg"
  previous="$arg"
done
if [[ "$explicit_host" != "$YARDLET_FIXTURE_EXPECTED_HOST" ]]; then
  printf 'HOST_MISMATCH\texpected=%s\tactual=%s\n' \
    "$YARDLET_FIXTURE_EXPECTED_HOST" "$explicit_host" >>"$YARDLET_FIXTURE_GH_LOG"
  exit 92
fi
printf 'HOST_OK\t%s\n' "$explicit_host" >>"$YARDLET_FIXTURE_GH_LOG"

mode="${YARDLET_FIXTURE_GH_MODE:-normal}"
protected="${YARDLET_FIXTURE_PROTECTED:-true}"
crash_mode="${YARDLET_FIXTURE_CRASH_MODE:-normal}"
event="${YARDLET_FIXTURE_EVENT:-}"

if [[ "${1:-}" == "auth" ]]; then
  [[ "$mode" != "unauthenticated" ]] || exit 1
  exit 0
fi

[[ "${1:-}" == "api" ]] || exit 2

method="GET"
endpoint=""
head_filter=""
base_filter=""
previous=""
for arg in "$@"; do
  if [[ "$previous" == "--method" ]]; then
    method="$arg"
  elif [[ "$previous" == "-f" ]]; then
    case "$arg" in
      head=*) head_filter="${arg#head=}" ;;
      base=*) base_filter="${arg#base=}" ;;
    esac
  elif [[ "$arg" == repos/* ]]; then
    endpoint="$arg"
  fi
  previous="$arg"
done

if [[ "$endpoint" == "repos/fixture-owner/fixture-repo" ]]; then
  full_name="fixture-owner/fixture-repo"
  default_branch="main"
  [[ "$mode" != "repository_mismatch" ]] || full_name="other-owner/other-repo"
  [[ "$mode" != "default_branch_mismatch" ]] || default_branch="trunk"
  printf '{"full_name":"%s","default_branch":"%s","permissions":{"push":true}}\n' \
    "$full_name" "$default_branch"
  exit 0
fi

if [[ "$endpoint" == "repos/fixture-owner/fixture-repo/branches/main" ]]; then
  printf '{"protected":%s}\n' "$protected"
  exit 0
fi

if [[ "$endpoint" == "repos/fixture-owner/fixture-repo/pulls" && "$method" == "POST" ]]; then
  printf 'PR_CREATE_BEGIN\n' >>"$YARDLET_FIXTURE_GH_LOG"
  if [[ "$crash_mode" == "before_pr_create" ]]; then
    printf '%s\n' "$$" >"${event:?missing event path}.pid"
    : >"$event"
    while :; do sleep 1; done
  fi
  if [[ ! -e "$YARDLET_FIXTURE_GH_STATE" ]]; then
    printf 'open\n' >"$YARDLET_FIXTURE_GH_STATE"
    printf 'PR_CREATE_SUCCESS\n' >>"$YARDLET_FIXTURE_GH_LOG"
  fi
  if [[ "$crash_mode" == "after_pr_create" ]]; then
    printf '%s\n' "$$" >"${event:?missing event path}.pid"
    : >"$event"
    while :; do sleep 1; done
  fi
  printf '{}\n'
  exit 0
fi

if [[ "$endpoint" == "repos/fixture-owner/fixture-repo/pulls" && "$method" == "GET" ]]; then
  printf 'PR_LOOKUP\thead=%s\tbase=%s\n' "$head_filter" "$base_filter" \
    >>"$YARDLET_FIXTURE_GH_LOG"
  if [[ ! -e "$YARDLET_FIXTURE_GH_STATE" ]]; then
    printf '[]\n'
    exit 0
  fi
  head="${head_filter#fixture-owner:}"
  base="$base_filter"
  [[ "$mode" != "pr_head_mismatch" ]] || head="other-run-head"
  [[ "$mode" != "pr_base_mismatch" ]] || base="other-base"
  printf '[{"number":17,"state":"open","head":{"ref":"%s","sha":"%s"},"base":{"ref":"%s","sha":"unused"}}]\n' \
    "$head" "$YARDLET_FIXTURE_EXPECTED_OID" "$base"
  exit 0
fi

exit 3
