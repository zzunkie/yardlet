#!/bin/zsh
# Checks the Simulator tab with a real Android phone on USB: builds a debug bundle without the browser engine, copies it
# as a QA bundle (prepare-qa.sh) and launches it in the background with a temporary home (qa-launch.sh: never active,
# its windows past every screen) and the DEBUG fixture SimulatorPanelQA (`--ui-fixture-simulator-check`,
# `YARDLET_SIMULATOR_QA_ANDROID_DEVICE`). The fixture lists the phone by the serial number it reports, opens Settings on
# it, shows it live and scrolls Settings through the tab, lets the agents' tools take its screenshot, swipe and read its
# elements after its card, goes Home and turns the switch off, which ends the server on the phone. Nothing else on the
# phone is opened, changed or installed, and adb commands go to that phone and to emulators alone.
#
# The phone must be listed ready by `adb devices`, awake and unlocked: the check never wakes or unlocks it, and stops
# otherwise. It leaves the screen on Home for the phone's own timeout to turn off; turning it off at once would lock
# it. However the run ends, the app is ended by its process ID, any server file of Yardlet's left in the phone's
# /data/local/tmp is deleted and named, and the QA bundle and home go to the Trash. The adb server is left running.
# Captures and result.json go to .build/simulator-qa/android-device-<time>/; they show the phone's Settings, which may
# hold the person's account.
#
#   ANDROID_HOME   the SDK (~/Library/Android/sdk by default)
#
# usage: scripts/simulator-qa/run-android-device-check.sh <adb serial>
set -euo pipefail
ROOT=${0:A:h:h:h}
cd "$ROOT"
serial=${1:?usage: run-android-device-check.sh <adb serial>}
if [[ -z "${YARDLET_HEAVY_LOCK_HELD:-}" ]]; then
    print "Waiting for the heavy-build lock…"
    exec /usr/bin/env YARDLET_HEAVY_LOCK_HELD=1 /usr/bin/lockf -t 21600 "$HOME/Library/Caches/yardlet-heavy-build.lock" \
        /bin/zsh "$0" "$@"
fi
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}
adb="$sdk/platform-tools/adb"
[[ -x "$adb" ]] || { print -u2 "error: no adb at $adb"; exit 1; }
"$adb" devices | /usr/bin/awk -v s="$serial" '$1 == s && $2 == "device" { found = 1 } END { exit !found }' \
    || { print -u2 "error: $serial is not listed ready by adb devices"; exit 1; }
"$adb" -s "$serial" shell 'dumpsys power | grep mWakefulness=' | /usr/bin/grep -q 'mWakefulness=Awake' \
    || { print -u2 "error: the phone's screen is off; wake and unlock it first"; exit 1; }
"$adb" -s "$serial" shell 'dumpsys window | grep isKeyguardShowing' | /usr/bin/grep -q 'isKeyguardShowing=true' \
    && { print -u2 "error: the phone is locked; unlock it first"; exit 1; }

output="$ROOT/.build/simulator-qa/android-device-$(/bin/date +%Y%m%d-%H%M%S)"
qa_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp/}yardlet-android-device-qa.XXXXXX")
qa_app="$qa_root/browser-host-qa/Yardlet Android Device QA.app"
qa_home="$qa_root/browser-host-qa/home"
mkdir -p "$output" "$qa_home"
app_pid=""
cleanup() {
    if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
        kill "$app_pid" 2>/dev/null || true
        for _ in {1..50}; do kill -0 "$app_pid" 2>/dev/null || break; sleep 0.1; done
    fi
    local left
    left=$("$adb" -s "$serial" shell 'ls /data/local/tmp' 2>/dev/null | /usr/bin/tr -d '\r' | /usr/bin/grep '^yardlet-scrcpy-' || true)
    for file in ${(f)left}; do
        "$adb" -s "$serial" shell "rm -f /data/local/tmp/$file" >/dev/null 2>&1 || true
        print "deleted /data/local/tmp/$file from the phone"
    done
    /usr/bin/trash "${qa_root:?}" 2>/dev/null || print -u2 "warning: $qa_root was not moved to the Trash"
}
trap cleanup EXIT INT TERM

YARDLET_WITHOUT_CEF=1 "$ROOT/scripts/build-app.sh" debug
"$ROOT/scripts/browser-host-qa/prepare-qa.sh" "$ROOT/.build/Yardlet.app" "$qa_app" com.zzunkie.yardletqa.androiddevice
app_pid=$("$ROOT/scripts/browser-host-qa/qa-launch.sh" "$qa_app" "$qa_home" "$output/app.log" \
    "YARDLET_SIMULATOR_QA_ANDROID_DEVICE=$serial" "ANDROID_HOME=$sdk" -- \
    --ui-fixture=conversation --ui-fixture-browser-ignore-occlusion --ui-fixture-simulator-check="$output")
print "QA app $app_pid"
deadline=$(( SECONDS + 600 ))
while [[ ! -e "$output/finished" ]] && kill -0 "$app_pid" 2>/dev/null && (( SECONDS < deadline )); do sleep 1; done
[[ -e "$output/finished" ]] || { print -u2 "error: the fixture did not finish; see $output/app.log"; exit 1; }
result=0
/usr/bin/python3 -I - "$output/result.json" <<'EOF' || result=1
import json, sys
checks = json.load(open(sys.argv[1]))["checks"]
for check in checks:
    print(("ok    " if check["ok"] else "FAIL  ") + check["check"] + ("" if check["ok"] else "  " + check["detail"]))
sys.exit(0 if checks and all(check["ok"] for check in checks) else 1)
EOF
print "Captures and result: $output"
exit $result
