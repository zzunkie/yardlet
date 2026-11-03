#!/bin/zsh
# Runs the DEBUG browser panel QA fixture against a QA bundle made by prepare-qa.sh: serves the QA
# pages, launches the app in the background with a temporary home (qa-launch.sh: never active, no Dock
# icon, its windows past every screen), samples the app's process tree (the browser host and its
# Chromium helpers are its descendants) at every phase marker, and checks that nothing is left running
# afterwards, that the run's processes left no crash report beyond the renderers the fixture ends on
# purpose, that Chromium's code-sign clones of the host were removed, and that none of the run's
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
identifier=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Contents/Info.plist") || exit 1
[[ "${app:A}" == */browser-host-qa/*.app && "$identifier" != "com.zzunkie.yardlet" ]] || {
    echo "app must be a QA bundle with a separate identifier under browser-host-qa" >&2; exit 2; }
host_identifier=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Contents/Frameworks/Yardlet Browser Host.app/Contents/Info.plist") || exit 1
# Runs sharing a host identifier share Chromium's clone directory. Hold this lock until exit,
# including interruption cleanup, and fail instead of disturbing another run's output or app.
if [[ "$host_identifier" == "$identifier.browser-host" ]]; then
    zmodload zsh/system || exit 1
    clone_lock="${TMPDIR:-/tmp/}yardlet-qa-${host_identifier}.lock"
    touch "$clone_lock" || exit 1
    zsystem flock -t 0 -f clone_lock_fd "$clone_lock" || { echo "QA already running for $host_identifier" >&2; exit 1; }
fi
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
clones="$(dirname "$(getconf DARWIN_USER_TEMP_DIR)")/X/$host_identifier.code_sign_clone"

# Chromium can remove the host executable before failing to remove the clone directory. Match the
# remaining bundle metadata, signature resources and helper executable to this canonical QA bundle.
# The per-identifier lock and starting inventory exclude other runs; production host identifiers,
# changed or unrecognizable bundles and anything still used by a process are always preserved.
manage_clones() {
    # A provisioning-profile QA host keeps its production identifier. Its shared clone directory
    # also belongs to the installed app: do not inspect, count or clean anything there.
    [[ "$host_identifier" == "$identifier.browser-host" ]] || return 0
    python3 - "$1" "$app" "$clones" "$out/clone-ownership.json" <<'PYTHON'
import ctypes
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

mode, app, root, manifest = sys.argv[1:]
app = Path(app).resolve()
host = app / "Contents/Frameworks/Yardlet Browser Host.app"
with (host / "Contents/Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
executable = info["CFBundleExecutable"]
if Path(executable).name != executable:
    raise SystemExit("Invalid host executable name")
with (app / "Contents/Info.plist").open("rb") as stream:
    app_id = plistlib.load(stream)["CFBundleIdentifier"]
is_qa = app_id != "com.zzunkie.yardlet" and info["CFBundleIdentifier"] == app_id + ".browser-host"
if not is_qa:
    sys.exit(0)
root = Path(root).resolve()
proof_files = ["Contents/Info.plist", "Contents/_CodeSignature/CodeResources",
               "Contents/Frameworks/Yardlet Helper.app/Contents/MacOS/Yardlet Helper"]

def fingerprints(bundle):
    result = {}
    for relative in proof_files:
        path = bundle / relative
        if not path.resolve().is_relative_to(bundle):
            raise ValueError("Bundle file resolves outside the bundle")
        result[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result

def directories():
    return [path for path in root.glob("code_sign_clone.*") if path.is_dir() and not path.is_symlink()]

def identity(path):
    stat = path.stat()
    return [stat.st_dev, stat.st_ino]

if mode == "start":
    state = {"existing": [path.name for path in directories()], "owned": {}, "app": str(app),
             "proof": fingerprints(host)}
else:
    with open(manifest) as stream:
        state = json.load(stream)

for path in directories():
    if str(app) != state["app"] or path.name in state["existing"] or path.name in state["owned"]:
        continue
    bundle = path / "Yardlet Browser Host.app.bundle"
    try:
        if bundle.is_symlink() or not (bundle / "Contents/MacOS" / executable).resolve().is_relative_to(path):
            continue
        with (bundle / "Contents/Info.plist").open("rb") as stream:
            cloned = plistlib.load(stream)
        if (cloned.get("CFBundleIdentifier") == info["CFBundleIdentifier"]
                and cloned.get("CFBundleExecutable") == executable
                and fingerprints(bundle) == state["proof"]):
            state["owned"][path.name] = identity(path)
    except (OSError, ValueError, plistlib.InvalidFileException):
        # A partially removed or not-yet-complete clone may have no ownership proof.
        continue

if mode == "clean":
    # The kernel's executable path can name the clone while argv still names the QA app.
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    live = []
    uncertain = False
    for row in subprocess.check_output(["ps", "-axo", "pid=,uid=,stat="], text=True).splitlines():
        pid, uid, status = row.split()
        if int(uid) != os.getuid() or status.startswith("Z"):
            continue
        buffer = ctypes.create_string_buffer(4096)
        if libproc.proc_pidpath(int(pid), buffer, len(buffer)) > 0:
            live.append(Path(os.fsdecode(buffer.value)).resolve())
        else:
            try:
                os.kill(int(pid), 0)
                uncertain = True
            except ProcessLookupError:
                pass
    trash = None
    for name, recorded in state["owned"].items():
        path = root / name
        if not path.exists():
            continue
        try:
            unchanged = fingerprints(path / "Yardlet Browser Host.app.bundle") == state["proof"]
        except (OSError, ValueError):
            unchanged = False
        if (path.is_symlink() or identity(path) != recorded or not unchanged or uncertain
                or any(binary.is_relative_to(app) or binary.is_relative_to(path) for binary in live)):
            print("Preserved code-sign clone still in use or not verifiable: " + name, file=sys.stderr)
            continue
        if trash is None:
            location = Path.home() / ".Trash"
            location.mkdir(exist_ok=True)
            trash = Path(tempfile.mkdtemp(prefix="Yardlet-QA-clones-", dir=location))
        path.rename(trash / name)
        print("Moved code-sign clone to Trash: " + str(trash / name))

with open(manifest, "w") as stream:
    json.dump(state, stream)
if mode == "clean":
    remaining = [path.name for path in directories() if path.name not in state["existing"]]
    if remaining:
        print("FAIL code-sign clones left (preserved): " + ", ".join(remaining), file=sys.stderr)
        sys.exit(1)
PYTHON
}
manage_clones start || exit 1

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
    manage_clones observe || true
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
trap 'end_run; manage_clones clean; exit 130' INT TERM HUP
for _ in {1..50}; do [[ -s "$out/server/port" ]] && break; sleep 0.1; done
port=$(<"$out/server/port")
echo "QA pages on http://127.0.0.1:$port/ (pid $server_pid)"

app_pid=$("$TOOLS/qa-launch.sh" "$app" "${out:h}/qa-home" "$out/app.log" -- \
    --ui-fixture=conversation --ui-fixture-browser-check="$out" \
    --ui-fixture-browser-url="http://127.0.0.1:$port/" --ui-fixture-browser-ignore-occlusion "$@") || { end_run; manage_clones clean; exit 1; }
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
# code-sign clones, which Chromium's cleanup helper normally deletes once the host has exited.
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
end_run
manage_clones clean || failed=1
trap - INT TERM HUP
"$TOOLS/verdict.sh" "$out" || failed=1
exit $failed
