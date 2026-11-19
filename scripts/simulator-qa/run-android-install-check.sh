#!/bin/zsh
# Installs the Android SDK for real through the Simulator tab's Install, into a QA home, and removes it again: builds a
# debug bundle without the browser engine, copies it as a QA bundle (prepare-qa.sh) and launches it in the background
# with a temporary home (qa-launch.sh: never active, its windows past every screen) and the DEBUG fixture
# SimulatorPanelQA (`--ui-fixture-simulator-check`, `YARDLET_SIMULATOR_QA_ANDROID_INSTALL`). The fixture refuses to
# start unless every SDK and AVD folder the install could use is in the QA folder. It takes the offer from Google's
# lists, downloads and unpacks it as the tab does, with its progress, checks the licenses' acceptance against the
# hashes sdkmanager writes, lists the AVD it made, starts it without a window or sound and shows it live. This script
# then reads the new SDK with the command-line tools, when they are installed, in a sandbox that lets them write nowhere
# in the home folder: the Android CLI that sdkmanager now hands to (`android sdk list`, without its usage data) must know
# each package's revision, and avdmanager must load the AVD. Last, the fixture turns the switch off, answers the removal question
# with Remove, and checks that the emulator had stopped by then and that only what Yardlet installed is gone.
#
# It downloads about 2.3 GB and needs YARDLET_ANDROID_INSTALL_QA_MIN_FREE_GB free (20 by default), checked once it holds
# the shared heavy-build lock. The app talks to an adb server of its own, on another port, which this script starts
# with the adb on this Mac in a sandbox: no USB and no device access (IOKit), no network beyond this Mac, no look for
# emulators (`ADB_EMU=0`; the QA emulator announces itself) and no connection to another emulator's ports, so no phone
# and no other emulator is asked anything, and the adb server already running is left alone. It makes its key in the
# QA home, where the emulator finds it as it would in a real home. The new SDK's adb must be the same build as this
# Mac's, which the check compares first: another build would restart the server it finds. However the run ends, the
# app, the QA adb server and anything else running from the QA folder are ended by their process IDs, and the QA
# folder goes to the Trash. Captures, result.json, install.json and the tools' output go to
# .build/simulator-qa/android-install-<time>/.
#
#   ANDROID_HOME   the SDK whose adb and command-line tools are compared and used (~/Library/Android/sdk by default)
#
# usage: scripts/simulator-qa/run-android-install-check.sh
set -euo pipefail
ROOT=${0:A:h:h:h}
cd "$ROOT"
if [[ -z "${YARDLET_HEAVY_LOCK_HELD:-}" ]]; then
    print "Waiting for the heavy-build lock…"
    exec /usr/bin/env YARDLET_HEAVY_LOCK_HELD=1 /usr/bin/lockf -t 21600 "$HOME/Library/Caches/yardlet-heavy-build.lock" \
        /bin/zsh "$0" "$@"
fi
min_free=${YARDLET_ANDROID_INSTALL_QA_MIN_FREE_GB:-20}
free_before=$(( $(/bin/df -k / | /usr/bin/awk 'NR==2 {print $4}') / 1048576 ))
(( free_before >= min_free )) || { print -u2 "error: ${free_before} GiB free, under ${min_free} GiB"; exit 1; }
print "Free before: ${free_before} GiB"
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}
adb="$sdk/platform-tools/adb"
[[ -x "$adb" ]] || { print -u2 "error: no adb at $adb to compare with"; exit 1; }
output="$ROOT/.build/simulator-qa/android-install-$(/bin/date +%Y%m%d-%H%M%S)"
qa_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp/}yardlet-android-install-qa.XXXXXX")
qa_app="$qa_root/browser-host-qa/Yardlet Android Install QA.app"
qa_home="$qa_root/browser-host-qa/home"
mkdir -p "$output" "$qa_home"
app_pid=""
adb_pid=""
cleanup() {
    local pid command
    for pid in "$app_pid" "$adb_pid"; do
        [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null || continue
        kill "$pid" 2>/dev/null || true
        for _ in {1..50}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    done
    # The app's helpers, and an emulator, its crash handler or netsimd started from the SDK in the QA home.
    /bin/ps -axo pid=,command= | while read -r pid command; do
        [[ "$command" == "$qa_root/"* || "$command" == "/private$qa_root/"* ]] && kill "$pid" 2>/dev/null || true
    done
    sleep 1
    /usr/bin/trash "${qa_root:?}" 2>/dev/null || print -u2 "warning: $qa_root was not moved to the Trash"
    print "Free after: $(( $(/bin/df -k / | /usr/bin/awk 'NR==2 {print $4}') / 1048576 )) GiB"
}
trap cleanup EXIT INT TERM

# Google's current platform-tools must be the build of the adb that runs the server.
/usr/bin/python3 -I - "$qa_root/platform-tools-check" "$output/platform-tools.txt" <<'EOF'
import hashlib, re, sys, urllib.request, zipfile, os
folder, report = sys.argv[1], sys.argv[2]
base = "https://dl.google.com/android/repository/"
xml = urllib.request.urlopen(base + "repository2-3.xml", timeout=60).read().decode()
for match in re.finditer(r'<remotePackage path="platform-tools">(.*?)</remotePackage>', xml, re.S):
    body = match.group(1)
    if 'channelRef ref="channel-0"' not in body:
        continue
    for archive in re.finditer(r"<archive>(.*?)</archive>", body, re.S):
        if "<host-os>macosx</host-os>" in archive.group(1):
            sha1 = re.search(r"<checksum[^>]*>([0-9a-f]+)<", archive.group(1)).group(1)
            url = base + re.search(r"<url>([^<]+)<", archive.group(1)).group(1)
            break
    break
os.makedirs(folder)
path = os.path.join(folder, "platform-tools.zip")
urllib.request.urlretrieve(url, path)
assert hashlib.sha1(open(path, "rb").read()).hexdigest() == sha1, "platform-tools download damaged"
zipfile.ZipFile(path).extract("platform-tools/adb", folder)
os.chmod(os.path.join(folder, "platform-tools/adb"), 0o755)
open(report, "w").write(url + "\n")
EOF
new_version=$("$qa_root/platform-tools-check/platform-tools/adb" version | /usr/bin/grep '^Version')
old_version=$("$adb" version | /usr/bin/grep '^Version')
print "adb on this Mac: $old_version; Google's: $new_version" | tee -a "$output/platform-tools.txt"
[[ "$new_version" == "$old_version" ]] || { print -u2 "error: another adb build would restart the adb server"; exit 1; }
rm -rf "${qa_root:?}/platform-tools-check"

YARDLET_WITHOUT_CEF=1 "$ROOT/scripts/build-app.sh" debug
"$ROOT/scripts/browser-host-qa/prepare-qa.sh" "$ROOT/.build/Yardlet.app" "$qa_app" com.zzunkie.yardletqa.androidinstall

# The QA adb server: its own port and key, in a sandbox that keeps it from devices, the network and other emulators.
adb_port=$(/usr/bin/python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
deny=""
/bin/ps -axo pid=,command= | while read -r pid command; do
    [[ "$command" == *qemu-system* && "$command" != "$qa_root/"* ]] || continue
    /usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -a -p "$pid" 2>/dev/null | /usr/bin/awk 'NR > 1 { sub(/.*:/, "", $9); print $9 }'
done | /usr/bin/sort -un > "$qa_root/other-emulator-ports"
while read -r port; do deny+="(remote ip \"localhost:$port\")"; done < "$qa_root/other-emulator-ports"
adb_profile="(version 1)(allow default)(deny file-write* (subpath \"$HOME\"))(deny iokit-open)(deny network-outbound)"
adb_profile+="(allow network-outbound (remote ip \"localhost:*\"))${deny:+(deny network-outbound $deny)}"
adb_settings=("ANDROID_ADB_SERVER_PORT=$adb_port" "ADB_USB=0" "ADB_EMU=0" "ADB_MDNS=0")
mkdir -p "$qa_home/.android" "$qa_root/adb-tmp"
/usr/bin/env -i HOME="$qa_home" PATH=/usr/bin:/bin TMPDIR="$qa_root/adb-tmp/" "${adb_settings[@]}" ADB_REJECT_KILL_SERVER=1 \
    /usr/bin/sandbox-exec -p "$adb_profile" "$adb" -P "$adb_port" nodaemon server > "$output/adb-server.log" 2>&1 &
adb_pid=$!
for _ in {1..50}; do [[ -s "$qa_home/.android/adbkey.pub" ]] && break; sleep 0.1; done
/usr/bin/env -i HOME="$qa_home" PATH=/usr/bin:/bin "${adb_settings[@]}" "$adb" -P "$adb_port" devices > "$output/adb-devices-before.txt"
/usr/bin/grep -q '[[:space:]]' <(/usr/bin/sed 1d "$output/adb-devices-before.txt") \
    && { print -u2 "error: the QA adb server lists a device"; exit 1; }
print "QA adb server $adb_pid on port $adb_port, other emulators' ports: $(/usr/bin/tr '\n' ' ' < "$qa_root/other-emulator-ports")"

started=$SECONDS
# Empty values keep any Android variable the session has from pointing the install outside the QA home.
app_pid=$("$ROOT/scripts/browser-host-qa/qa-launch.sh" "$qa_app" "$qa_home" "$output/app.log" \
    "YARDLET_SIMULATOR_QA_ANDROID_INSTALL=$qa_root" "ANDROID_HOME=" "ANDROID_SDK_ROOT=" "ANDROID_AVD_HOME=" \
    "ANDROID_USER_HOME=" "ANDROID_EMULATOR_HOME=" "ANDROID_SDK_HOME=" "${adb_settings[@]}" -- \
    --ui-fixture=conversation --ui-fixture-browser-ignore-occlusion --ui-fixture-simulator-check="$output")
print "QA app $app_pid"

# While the SDK is there: Google's command-line tools read it, writing nowhere in the home folder.
deadline=$(( SECONDS + 5400 ))
while [[ ! -e "$output/sdk-ready" && ! -e "$output/finished" ]] && kill -0 "$app_pid" 2>/dev/null \
    && (( SECONDS < deadline )); do sleep 2; done
tools="$sdk/cmdline-tools/latest/bin"
java_home="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
new_sdk="$qa_home/Library/Android/sdk"
if [[ -e "$output/sdk-ready" ]]; then
    if [[ -x "$tools/android" && -x "$tools/avdmanager" && -d "$java_home" ]]; then
        profile="(version 1)(allow default)(deny file-write* (subpath \"$HOME\"))"
        run_tool() {
            /usr/bin/env HOME="$qa_home" JAVA_HOME="$java_home" ANDROID_USER_HOME="$qa_home/.android" \
                ANDROID_AVD_HOME="$qa_home/.android/avd" SDKMANAGER_OPTS="-Duser.home=$qa_home" \
                AVDMANAGER_OPTS="-Duser.home=$qa_home -Dcom.android.sdkmanager.toolsdir=$new_sdk/cmdline-tools/latest" \
                /usr/bin/perl -e 'alarm 300; exec @ARGV' \
                /usr/bin/sandbox-exec -p "$profile" "$@" </dev/null 2>&1 || true
        }
        before=$(/bin/ls -A "$new_sdk")
        run_tool "$tools/android" --no-metrics --sdk="$new_sdk" sdk list > "$output/android-sdk-list.txt"
        # avdmanager reads the SDK it is installed in unless its tools folder is said to be in another.
        mkdir -p "$new_sdk/cmdline-tools/latest"
        run_tool "$tools/avdmanager" list avd > "$output/avdmanager-list.txt"
        # What the tools wrote in the SDK is theirs, not Yardlet's: it goes, so the removal is Yardlet's alone.
        after=$(/bin/ls -A "$new_sdk")
        print -r -- "${after}" | /usr/bin/grep -vxF -f <(print -r -- "${before}") > "$output/tools-wrote.txt" || true
        while read -r written; do [[ -n "$written" ]] && rm -rf "${new_sdk:?}/${written:?}"; done < "$output/tools-wrote.txt"
    else
        print "no command-line tools or Java to read the SDK with" > "$output/android-sdk-list.txt"
    fi
    print "checked" > "$output/sdk-checked"
fi

while [[ ! -e "$output/finished" ]] && kill -0 "$app_pid" 2>/dev/null && (( SECONDS < deadline )); do sleep 2; done
print "Took $(( SECONDS - started )) s"
[[ -e "$output/finished" ]] || { print -u2 "error: the fixture did not finish; see $output/app.log"; exit 1; }
result=0
/usr/bin/python3 -I - "$output/result.json" "$output" <<'EOF' || result=1
import json, os, re, sys
checks = json.load(open(sys.argv[1]))["checks"]
listed = os.path.join(sys.argv[2], "android-sdk-list.txt")
if os.path.exists(listed) and "no command-line tools" not in open(listed).read():
    text = open(listed).read()
    installed = text.split("Installed packages:")[-1].split("Available")[0]
    rows = [line.split() for line in installed.splitlines() if line.strip()]
    checks.append({"check": "tools: the Android CLI knows the revision of each package installed", "detail": installed.strip(),
                   "ok": len(rows) == 3 and all(len(row) > 1 and re.match(r"\d", row[1]) for row in rows)})
    avds = open(os.path.join(sys.argv[2], "avdmanager-list.txt")).read()
    checks.append({"check": "tools: avdmanager loads the AVD Yardlet made", "detail": avds.strip(),
                   "ok": "Name: Yardlet_Phone" in avds and "could not be loaded" not in avds})
for check in checks:
    print(("ok    " if check["ok"] else "FAIL  ") + check["check"] + ("" if check["ok"] else "  " + check["detail"]))
sys.exit(0 if checks and all(check["ok"] for check in checks) else 1)
EOF
print "Captures and result: $output"
exit $result
