#!/usr/bin/env bash
set -u

: "${YARDLET_FIXTURE_REAL_GIT:?missing real git path}"
: "${YARDLET_FIXTURE_GIT_LOG:?missing wrapper log path}"
: "${YARDLET_FIXTURE_ROOT:?missing fixture root}"
: "${YARDLET_FIXTURE_PYTHON:?missing python path}"

mode="${YARDLET_FIXTURE_CRASH_MODE:-normal}"
is_commit=0
is_merge=0
is_push=0
refspec=""
push_destination=""
saw_push=0
after_separator=0
git_prefix=()
for arg in "$@"; do
  if [[ "$saw_push" -eq 0 ]]; then
    if [[ "$arg" == "push" ]]; then
      is_push=1
      saw_push=1
    else
      git_prefix+=("$arg")
      [[ "$arg" == "commit" || "$arg" == "commit-tree" ]] && is_commit=1
      [[ "$arg" == "merge" ]] && is_merge=1
    fi
  fi
  if [[ "$arg" == *":refs/heads/"* ]]; then
    refspec="$arg"
  fi
  if [[ "$saw_push" -eq 1 && "$after_separator" -eq 1 ]]; then
    push_destination="$arg"
    after_separator=0
  elif [[ "$saw_push" -eq 1 && "$arg" == "--" ]]; then
    after_separator=1
  fi
done

if [[ "$is_push" -eq 1 ]]; then
  if [[ -z "$push_destination" ]]; then
    printf 'PUSH_REJECTED\treason=unresolved_destination\n' >>"$YARDLET_FIXTURE_GIT_LOG"
    exit 97
  fi
  if ! validated_destinations="$(
    "$YARDLET_FIXTURE_PYTHON" - "$YARDLET_FIXTURE_ROOT" "$push_destination" \
      "$YARDLET_FIXTURE_REAL_GIT" "${git_prefix[@]}" <<'PY'
import os
import subprocess
import sys
from urllib.parse import unquote, urlsplit

root = os.path.realpath(sys.argv[1])
destination_arg = sys.argv[2]
real_git = sys.argv[3]
git_prefix = sys.argv[4:]

resolved = subprocess.run(
    [real_git, *git_prefix, "remote", "get-url", "--push", "--all", destination_arg],
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    check=False,
)
if resolved.returncode == 0:
    try:
        destinations = resolved.stdout.decode("utf-8", errors="strict").splitlines()
    except UnicodeDecodeError:
        raise SystemExit(1)
else:
    rewrites = subprocess.run(
        [
            real_git,
            *git_prefix,
            "config",
            "--null",
            "--get-regexp",
            r"^url\..*\.(pushinsteadof|insteadof)$",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if rewrites.returncode not in (0, 1):
        raise SystemExit(1)
    for record in rewrites.stdout.split(b"\0"):
        if not record:
            continue
        try:
            _, prefix = record.split(b"\n", 1)
            prefix = prefix.decode("utf-8", errors="strict")
        except (ValueError, UnicodeDecodeError):
            raise SystemExit(1)
        if destination_arg.startswith(prefix):
            # A literal repository argument with a matching rewrite cannot be
            # proven equivalent to the path that Git will push to. Fail closed.
            raise SystemExit(1)
    destinations = [destination_arg]

if not destinations:
    raise SystemExit(1)

targets = []
for destination in destinations:
    if not destination or any(ord(char) < 32 or ord(char) == 127 for char in destination):
        raise SystemExit(1)
    parsed = urlsplit(destination)
    if parsed.scheme:
        if (
            parsed.scheme != "file"
            or parsed.netloc not in ("", "localhost")
            or parsed.query
            or parsed.fragment
        ):
            raise SystemExit(1)
        path = unquote(parsed.path)
    else:
        if destination.startswith("//") or ":" in destination:
            raise SystemExit(1)
        path = destination
    if any(ord(char) < 32 or ord(char) == 127 for char in path):
        raise SystemExit(1)
    if not os.path.isabs(path):
        path = os.path.join(os.getcwd(), path)
    target = os.path.realpath(path)
    try:
        allowed = target != root and os.path.commonpath((root, target)) == root
    except ValueError:
        allowed = False
    if not allowed:
        raise SystemExit(1)
    targets.append(target)

print("\n".join(targets))
PY
  )"; then
    printf 'PUSH_REJECTED\treason=destination_outside_fixture\n' >>"$YARDLET_FIXTURE_GIT_LOG"
    exit 97
  fi
  while IFS= read -r destination; do
    printf 'PUSH_RESOLVED\t%q\n' "$destination" >>"$YARDLET_FIXTURE_GIT_LOG"
  done <<<"$validated_destinations"
fi

printf 'CALL\tpid=%s\tpgid=%s\t' "$$" "$(ps -o pgid= -p $$ | tr -d ' ')" >>"$YARDLET_FIXTURE_GIT_LOG"
printf '%q ' "$@" >>"$YARDLET_FIXTURE_GIT_LOG"
printf '\n' >>"$YARDLET_FIXTURE_GIT_LOG"

stop_here() {
  local point="$1"
  printf '%s\n' "$$" >"${YARDLET_FIXTURE_EVENT:?missing event path}.pid"
  printf '%s\n' "$point" >"$YARDLET_FIXTURE_EVENT"
  while :; do sleep 1; done
}

if [[ "$is_commit" -eq 1 && "$mode" == "before_commit" ]]; then
  stop_here before_commit
fi
if [[ "$is_push" -eq 1 && "$mode" == "before_push" ]]; then
  stop_here before_push
fi

"$YARDLET_FIXTURE_REAL_GIT" "$@"
status=$?

if [[ "$status" -eq 0 && "$is_commit" -eq 1 ]]; then
  printf 'COMMIT_SUCCESS\n' >>"$YARDLET_FIXTURE_GIT_LOG"
  [[ "$mode" == "after_commit" ]] && stop_here after_commit
fi
if [[ "$status" -eq 0 && "$is_merge" -eq 1 ]]; then
  printf 'MERGE_SUCCESS\n' >>"$YARDLET_FIXTURE_GIT_LOG"
  [[ "$mode" == "after_merge" ]] && stop_here after_merge
fi
if [[ "$status" -eq 0 && "$is_push" -eq 1 ]]; then
  printf 'PUSH_SUCCESS\t%s\n' "$refspec" >>"$YARDLET_FIXTURE_GIT_LOG"
  [[ "$mode" == "after_push" ]] && stop_here after_push
fi

exit "$status"
