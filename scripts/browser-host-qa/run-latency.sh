#!/bin/zsh
# Runs the DEBUG browser latency fixture against a QA bundle made by prepare-qa.sh: serves the QA
# pages, launches the app in the background with a temporary home, waits for it to finish and prints
# latency.json. The output directory must be under a directory named browser-host-qa; the QA home
# is its sibling qa-home.
# usage: run-latency.sh <qa app> <output dir> [app arguments ...]
set -uo pipefail
TOOLS=${0:A:h}
app=$1
out=$2
shift 2
[[ "$out" == */browser-host-qa/* ]] || { echo "output must be under a browser-host-qa directory" >&2; exit 2; }
rm -rf "$out"
mkdir -p "$out/server"
python3 "$TOOLS/form-server.py" --output-dir "$out/server" >"$out/server/stdout.log" 2>&1 &
server_pid=$!
# The page server can take seconds to start on a slow Mac, such as CI's.
for _ in {1..300}; do [[ -s "$out/server/port" ]] && break; sleep 0.1; done
[[ -s "$out/server/port" ]] || { echo "the QA page server did not start" >&2; kill "$server_pid"; exit 1; }
port=$(<"$out/server/port")
app_pid=$("$TOOLS/qa-launch.sh" "$app" "${out:h}/qa-home" "$out/app.log" -- \
    --ui-fixture=conversation --ui-fixture-browser-latency="$out" \
    --ui-fixture-browser-url="http://127.0.0.1:$port/" --ui-fixture-browser-ignore-occlusion "$@") || { kill "$server_pid"; exit 1; }
echo "$app_pid" > "$out/app.pid"
echo "app pid $app_pid, pages on port $port"
deadline=$(( SECONDS + 180 ))
while kill -0 "$app_pid" 2>/dev/null && (( SECONDS < deadline )); do sleep 0.5; done
if kill -0 "$app_pid" 2>/dev/null; then
    echo "app still running after the deadline; terminating"
    kill "$app_pid"
fi
kill "$server_pid" 2>/dev/null
wait "$server_pid" 2>/dev/null
cat "$out/latency.json" 2>/dev/null
