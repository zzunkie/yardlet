#!/usr/bin/env bash
# Starts the Linux host built in BIN_DIR in a home of its own, as a person would from a terminal, and checks what
# docs/LINUX_HOST.md says of it: it answers `status` while it runs and says it is not running otherwise, a second host
# for the same account refuses to start, a project can be added, and SIGTERM ends it with exit 0. It prints what the
# host left in its home, for the list in docs/LINUX_HOST.md, "What it keeps".
#
#   scripts/linux/check-host.sh BIN_DIR
set -euo pipefail
bin=${1:?usage: check-host.sh BIN_DIR}
yardlet=$bin/yardlet
home=$(mktemp -d)
export HOME=$home
unset XDG_DATA_HOME XDG_CONFIG_HOME XDG_RUNTIME_DIR
log=$home/../host-$$.log

"$yardlet" --version
echo '--- linked libraries'
ldd "$yardlet" | sed -e 's/ (0x[0-9a-f]*)//'

echo '--- status before the host starts'
set +e
"$yardlet" host status
code=$?
set -e
[[ $code -eq 3 ]] || { echo "status exited $code, not 3, with no host running"; exit 1; }

"$yardlet" host start --name 'CI host' > "$log" 2>&1 &
pid=$!
trap 'kill -KILL $pid 2>/dev/null || true; cat "$log"' EXIT
for _ in $(seq 120); do
  if "$yardlet" host status > /dev/null 2>&1; then break; fi
  kill -0 $pid || { echo 'The host ended at start'; exit 1; }
  sleep 1
done
echo '--- status'
"$yardlet" host status
"$yardlet" host status --json > "$home/status.json"
grep -q '"name":"CI host"' "$home/status.json"

echo '--- a second host'
set +e
"$yardlet" host start > /dev/null 2>&1
code=$?
set -e
[[ $code -eq 1 ]] || { echo "a second host exited $code, not 1"; exit 1; }

echo '--- a project'
mkdir -p "$home/work/project"
(cd "$home/work" && "$yardlet" host project add project)
"$yardlet" host project list | grep -q "$home/work/project"

echo '--- stop'
kill -TERM $pid
set +e
wait $pid
code=$?
set -e
trap - EXIT
cat "$log"
[[ $code -eq 0 ]] || { echo "the host exited $code after SIGTERM"; exit 1; }
set +e
"$yardlet" host status > /dev/null 2>&1
code=$?
set -e
[[ $code -eq 3 ]] || { echo "status exited $code, not 3, after the host stopped"; exit 1; }

echo '--- what the host left in its home'
(cd "$home" && find . -path ./status.json -prune -o -print | sort)
