#!/bin/zsh
# Checks the Simulator tab with an Android emulator in the running app: builds a debug bundle without the browser
# engine, copies it as a QA bundle (prepare-qa.sh), makes an AVD named "yardlet_sim_qa_<random>" in a folder of its
# own and starts it without a window, sound or a saved snapshot on a free console port, then launches the bundle in
# the background with a temporary home (qa-launch.sh: never active, its windows past every screen) and the DEBUG
# fixture SimulatorPanelQA (`--ui-fixture-simulator-check`, `YARDLET_SIMULATOR_QA_ANDROID_AVD`). The fixture lists
# the emulator beside the Mac's iOS simulators, shows it live through the bundle's scrcpy server, presses Recents,
# swipes through the tab, turns the device, connects the same emulator again over `adb connect 127.0.0.1:<adb port>`
# and checks it as a real device (listed by the serial number it reports, live and driven, left alone by the agents'
# tools), turns the switch off and checks the tab closes and the server on the device ends, capturing each step in
# both appearances. The app sends adb commands only to emulators and that address, so a phone on this Mac is never
# sent one. However the run ends, the script ends the app by its PID, disconnects the address, stops the emulator with
# `emu kill` (by its process ID if it lingers), deletes the AVD, and removes the QA bundle and home; emulators, AVDs,
# devices and simulators it did not make, and the adb server, are left alone. It exits 1 when a check
# failed or the fixture did not finish. The captures, result.json and the logs go to
# .build/simulator-qa/android-panel-<time>/.
#
#   ANDROID_HOME                     the SDK (~/Library/Android/sdk by default)
#   YARDLET_ANDROID_QA_IMAGE         the system image to make the AVD from
#                                    (system-images;android-34;google_apis;arm64-v8a); it must be installed
#   YARDLET_ANDROID_QA_DEVICE        the hardware profile (pixel_6)
#
# usage: scripts/simulator-qa/run-android-panel-check.sh
set -euo pipefail
ROOT=${0:A:h:h:h}
cd "$ROOT"
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}
adb="$sdk/platform-tools/adb"
emulator="$sdk/emulator/emulator"
avdmanager="$sdk/cmdline-tools/latest/bin/avdmanager"
image=${YARDLET_ANDROID_QA_IMAGE:-"system-images;android-34;google_apis;arm64-v8a"}
profile=${YARDLET_ANDROID_QA_DEVICE:-pixel_6}
for tool in "$adb" "$emulator" "$avdmanager"; do
    [[ -x "$tool" ]] || { print -u2 "error: $tool is missing; set ANDROID_HOME to an SDK with it"; exit 1; }
done
[[ -d "$sdk/${image//;//}" ]] || { print -u2 "error: the system image $image is not installed"; exit 1; }
output="$ROOT/.build/simulator-qa/android-panel-$(/bin/date +%Y%m%d-%H%M%S)"
qa_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp/}yardlet-android-panel-qa.XXXXXX")
qa_app="$qa_root/browser-host-qa/Yardlet Android Panel QA.app"
qa_home="$qa_root/browser-host-qa/home"
avd_home="$qa_root/avd"
mkdir -p "$output" "$avd_home" "$qa_home"

name="yardlet_sim_qa_$(/usr/bin/openssl rand -hex 3)"
emulator_pid=""
app_pid=""
serial=""
address=""
connected=""
cleanup() {
    if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
        kill "$app_pid" 2>/dev/null || true
        for _ in {1..50}; do kill -0 "$app_pid" 2>/dev/null || break; sleep 0.1; done
    fi
    local pid command
    /bin/ps -axo pid=,command= | while read -r pid command; do
        [[ "$command" == "$qa_app/"* || "$command" == "/private$qa_app/"* ]] && kill "$pid" 2>/dev/null || true
    done
    [[ -n "$connected" ]] && "$adb" disconnect "$address" >/dev/null 2>&1 || true
    if [[ -n "$emulator_pid" ]]; then
        HOME="$qa_home" "$adb" -s "$serial" emu kill >/dev/null 2>&1 || true
        for _ in {1..60}; do kill -0 "$emulator_pid" 2>/dev/null || break; sleep 0.5; done
        kill "$emulator_pid" 2>/dev/null || true
    fi
    print "Stopped and deleted $name"
    rm -rf "${qa_root:?}/browser-host-qa" "${qa_root:?}/avd"
    rmdir "${qa_root:?}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

YARDLET_WITHOUT_CEF=1 "$ROOT/scripts/build-app.sh" debug
"$ROOT/scripts/browser-host-qa/prepare-qa.sh" "$ROOT/.build/Yardlet.app" "$qa_app" com.zzunkie.yardletqa.androidpanel

# A console port no emulator listens on, and its adb port after it.
port=""
for candidate in {5600..5680..2}; do
    if ! /usr/sbin/lsof -nP -iTCP:$candidate -iTCP:$((candidate + 1)) -sTCP:LISTEN >/dev/null 2>&1; then
        port=$candidate
        break
    fi
done
[[ -n "$port" ]] || { print -u2 "error: no free emulator port between 5600 and 5681"; exit 1; }
serial="emulator-$port"
address="127.0.0.1:$((port + 1))"

print "no" | ANDROID_AVD_HOME="$avd_home" "$avdmanager" create avd -n "$name" -k "$image" -d "$profile" >/dev/null
# The emulator writes its console's token in its HOME, the QA home, where the app's adb reads it; its other
# files stay in ~/.android as for any emulator.
HOME="$qa_home" ANDROID_EMULATOR_HOME="$HOME/.android" ANDROID_AVD_HOME="$avd_home" "$emulator" -avd "$name" \
    -no-window -gpu host -no-boot-anim -no-audio -no-snapshot -port "$port" >"$output/emulator.log" 2>&1 &
emulator_pid=$!
print "Started $name on $serial (process $emulator_pid)"
"$adb" -s "$serial" wait-for-device
for _ in {1..180}; do
    [[ "$("$adb" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]] && break
    sleep 1
done
[[ "$("$adb" -s "$serial" shell getprop sys.boot_completed | tr -d '\r')" == 1 ]] || {
    print -u2 "error: $name did not finish booting"; exit 1; }
# A first boot keeps setting up the launcher for a while after it reports booted.
sleep 15
# The same emulator at its adb port, as a device reached over `adb connect` is: its serial is the address.
connected=1
"$adb" connect "$address" >/dev/null
"$adb" -s "$address" wait-for-device

app_pid=$("$ROOT/scripts/browser-host-qa/qa-launch.sh" "$qa_app" "$qa_home" "$output/app.log" \
    "YARDLET_SIMULATOR_QA_ANDROID_AVD=$name" "YARDLET_SIMULATOR_QA_ANDROID_CONNECTED=$address" "ANDROID_HOME=$sdk" \
    "ANDROID_AVD_HOME=$avd_home" -- \
    --ui-fixture=conversation --ui-fixture-browser-ignore-occlusion --ui-fixture-simulator-check="$output")
print "QA app $app_pid"
deadline=$(( SECONDS + 300 ))
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
