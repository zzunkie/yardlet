#!/bin/zsh
# Runs the DEBUG browser panel QA fixture against a QA bundle made by prepare-qa.sh: serves the QA
# pages, launches the app in the background with a temporary home (qa-launch.sh: never active, no Dock
# icon, its windows past every screen), samples the app's process tree (the browser host and its
# Chromium helpers are its descendants) at every phase marker, and checks that nothing is left running
# afterwards, that the run's processes left no crash report beyond the renderers the fixture ends on
# purpose, that Chromium's code-sign clones of the host were deleted, and that none of the run's
# processes held secure keyboard entry (the QA records it instead, BrowserSecureInputRecorder). However
# the run ends (done, past its deadline, interrupted), the QA app, every process inside its bundle and
# the page server are ended. It exits 1 when any of these checks or any of the fixture's own fails, or
# when the fixture did not reach its end (verdict.sh). The output directory must be under a directory
# named browser-host-qa; the QA home is its sibling qa-home.
# usage: run-check.sh <qa app> <output dir> [app arguments ...]
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
media_fixtures="${out:h}/bin/media-fixtures"
if [[ ! -x "$media_fixtures" ]]; then
    swiftc -O -o "$media_fixtures" "$TOOLS/media-fixtures.swift" || exit 1
fi
rm -rf "$out"
mkdir -p "$out/samples" "$out/server"
"$media_fixtures" "$out/server/media" || exit 1
touch "$out/.started"
identifier=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Contents/Info.plist")
clones="$(dirname "$(getconf DARWIN_USER_TEMP_DIR)")/X/$identifier.browser-host.code_sign_clone"

# The bundle's processes start under either form of its path: Yardlet starts the browser host under
# /tmp/... when the bundle is in /private/tmp, while Chromium's helpers run under /private/tmp/...
bundle=${${app:A}#/private}

python3 "$TOOLS/form-server.py" --output-dir "$out/server" >"$out/server/stdout.log" 2>&1 &
server_pid=$!
app_pid=""
seen_tree=()
# The app's process tree: its browser host and the host's Chromium helpers.
tree() {
    local child
    for child in $(pgrep -P "$1"); do echo "$child"; tree "$child"; done
}
# `open` launches the app outside this script's process tree, so it is ended here by PID: the app this
# run launched and the processes it started, collected before it goes.
end_run() {
    local started=($seen_tree)
    [[ -n "$app_pid" ]] && started+=($(tree "$app_pid"))
    [[ -n "$app_pid" ]] && kill "$app_pid" 2>/dev/null
    kill "$server_pid" 2>/dev/null
    sleep 2
    local pid
    for pid in $started; do
        # Still this bundle's process, not another that took its PID since.
        local command=$(ps -o command= -p "$pid" 2>/dev/null)
        [[ "$command" == "$bundle/"* || "$command" == "/private$bundle/"* ]] && kill "$pid" 2>/dev/null
    done
    return 0
}
trap 'end_run; exit 130' INT TERM HUP
# The page server can take seconds to start on a slow Mac, such as CI's.
for _ in {1..300}; do [[ -s "$out/server/port" ]] && break; sleep 0.1; done
[[ -s "$out/server/port" ]] || { echo "FAIL the QA page server did not start" >&2; end_run; exit 1; }
port=$(<"$out/server/port")
echo "QA pages on http://127.0.0.1:$port/ (pid $server_pid)"

app_pid=$("$TOOLS/qa-launch.sh" "$app" "${out:h}/qa-home" "$out/app.log" -- \
    --ui-fixture=conversation --ui-fixture-browser-check="$out" \
    --ui-fixture-browser-url="http://127.0.0.1:$port/" --ui-fixture-browser-ignore-occlusion "$@") || { kill "$server_pid"; exit 1; }
echo "$app_pid" > "$out/app.pid"
echo "app pid $app_pid"

failed=0
typeset -A sampled
deadline=$(( SECONDS + 600 ))
while kill -0 "$app_pid" 2>/dev/null && (( SECONDS < deadline )); do
    seen_tree=($(tree "$app_pid"))
    # Left on, secure keyboard entry holds back the person's other apps' input.
    secure_pid=$(ioreg -l -d 1 -w 0 | grep -o '"kCGSSessionSecureInputPID"=[0-9]*' | grep -o '[0-9]*$' | head -1)
    [[ -n "$secure_pid" && " $app_pid ${seen_tree[*]} " == *" $secure_pid "* ]] && echo "$secure_pid" >> "$out/secure-input.txt"
    for marker in "$out"/markers/*.json(N); do
        name=${marker:t:r}
        [[ -n "${sampled[$name]:-}" ]] && continue
        sampled[$name]=1
        "$sampler" "$app_pid" "$name" 3 > "$out/samples/$name.json" 2>/dev/null
        footprint -p "$app_pid" > "$out/samples/$name-footprint.txt" 2>&1
        echo "sampled $name"
    done
    sleep 0.5
done
if kill -0 "$app_pid" 2>/dev/null; then
    echo "FAIL app still running after the deadline; terminating" >&2
    failed=1
    kill "$app_pid"
    sleep 3
fi
kill "$server_pid" 2>/dev/null
wait "$server_pid" 2>/dev/null
sleep 2
[[ -s "$out/secure-input.txt" ]] && { echo "FAIL secure keyboard entry held by this run's process $(sort -u "$out/secure-input.txt" | tr '\n' ' ')" >&2; failed=1; }
# What this run left: processes from inside this QA bundle, and its page server.
{ pgrep -fl "^(/private)?$bundle/"; pgrep -fl "form-server.py --output-dir $out/server"; } > "$out/leftover-processes.txt" 2>&1
[[ -s "$out/leftover-processes.txt" ]] && { echo "FAIL leftover processes" >&2; failed=1; }
echo "leftover processes:"; cat "$out/leftover-processes.txt"
# Crash reports from this bundle's processes (ReportCrash writes them within seconds), and the host's
# code-sign clones, which Chromium's cleanup helper deletes once the host has exited; a host the fixture
# kills on purpose keeps its clone.
sleep 3
: > "$out/crash-reports.txt"
for report in ~/Library/Logs/DiagnosticReports/*.ips(N); do
    [[ "$report" -nt "$out/.started" ]] || continue
    head -1 "$report" | grep -Eq "\"bundleID\":\"${identifier//./\\.}[.\"]" && echo "${report:t}" >> "$out/crash-reports.txt"
done
renderers=$(grep -c "^Yardlet Helper (Renderer)-" "$out/crash-reports.txt")
allowed=$(jq '.intentionalRendererCrashes // 0' "$out/result.json" 2>/dev/null || echo 0)
unexpected=$(( $(wc -l < "$out/crash-reports.txt") - (renderers < allowed ? renderers : allowed) ))
(( unexpected > 0 )) && { echo "FAIL crash reports: $unexpected beyond the $allowed renderer(s) ended on purpose" >&2; failed=1; }
echo "crash reports:"; cat "$out/crash-reports.txt"
left_clones=($clones/*(N/e:'[[ $REPLY -nt $out/.started ]]':))
killed=$(jq '.intentionalHostKills // 0' "$out/result.json" 2>/dev/null || echo 0)
(( ${#left_clones} > killed )) && { echo "FAIL code-sign clones left: ${(j:, :)${(@)left_clones:t}} (hosts killed on purpose: $killed)" >&2; failed=1; }
end_run
trap - INT TERM HUP
"$TOOLS/verdict.sh" "$out" || failed=1
exit $failed
