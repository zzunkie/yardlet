#!/bin/zsh
# Runs the DEBUG browser panel performance fixture against a QA bundle made by prepare-qa.sh: serves
# the QA pages, launches the app in the background with a temporary home, samples the app's process
# tree at every phase marker (3 s), and prints perf.json and the host's frame statistics afterwards.
# The output directory must be under a directory named browser-host-qa; the QA home is its sibling
# qa-home.
# usage: run-perf.sh <qa app> <output dir> [app arguments ...]
set -uo pipefail
TOOLS=${0:A:h}
app=$1
out=$2
shift 2
[[ "$out" == */browser-host-qa/* ]] || { echo "output must be under a browser-host-qa directory" >&2; exit 2; }
sampler="${out:h}/bin/sampler"
if [[ ! -x "$sampler" ]]; then
    mkdir -p "${sampler:h}"
    swiftc -O -o "$sampler" "$TOOLS/sampler.swift" || exit 1
fi
rm -rf "$out"
mkdir -p "$out/samples" "$out/server"

python3 "$TOOLS/form-server.py" --output-dir "$out/server" >"$out/server/stdout.log" 2>&1 &
server_pid=$!
# The page server can take seconds to start on a slow Mac, such as CI's.
for _ in {1..300}; do [[ -s "$out/server/port" ]] && break; sleep 0.1; done
[[ -s "$out/server/port" ]] || { echo "the QA page server did not start" >&2; kill "$server_pid"; exit 1; }
port=$(<"$out/server/port")
echo "QA pages on http://127.0.0.1:$port/ (pid $server_pid)"

app_pid=$("$TOOLS/qa-launch.sh" "$app" "${out:h}/qa-home" "$out/app.log" -- \
    --ui-fixture=conversation --ui-fixture-browser-perf="$out" \
    --ui-fixture-browser-url="http://127.0.0.1:$port/" "$@") || { kill "$server_pid"; exit 1; }
echo "$app_pid" > "$out/app.pid"
echo "app pid $app_pid"

typeset -A sampled
deadline=$(( SECONDS + 300 ))
while kill -0 "$app_pid" 2>/dev/null && (( SECONDS < deadline )); do
    for marker in "$out"/markers/*.json(N); do
        name=${marker:t:r}
        [[ -n "${sampled[$name]:-}" ]] && continue
        sampled[$name]=1
        if [[ "$name" == 2-animation ]]; then
            # Processes see the QA app under /tmp, not /private/tmp; the executable suffix excludes helpers.
            host_pid=$(pgrep -f "${app:t}/Contents/Frameworks/Yardlet Browser Host.app/Contents/MacOS/Yardlet Browser Host" || true)
            [[ -n "$host_pid" ]] && sample "$host_pid" 3 -mayDie -file "$out/samples/host-animation.sample.txt" >/dev/null 2>&1 &
        fi
        "$sampler" "$app_pid" "$name" 3 > "$out/samples/$name.json" 2>/dev/null
        echo "sampled $name"
    done
    sleep 0.2
done
if kill -0 "$app_pid" 2>/dev/null; then
    echo "app still running after the deadline; terminating"
    kill "$app_pid"
    sleep 3
fi
kill "$server_pid" 2>/dev/null
wait "$server_pid" 2>/dev/null
sleep 1
echo "host statistics:"; grep "Browser Host statistics" "${out:h}/qa-home/Library/Application Support/Yardlet/Browser/Logs/host.log" 2>/dev/null | tail -1
echo "perf.json:"; cat "$out/perf.json" 2>/dev/null
