#!/bin/zsh
# Checks Android screens against a throwaway emulator: builds the tests, makes an AVD named "yardlet_sim_qa_<random>"
# in a folder of its own (not the SDK's or the person's AVD folder), starts it without a window, sound or a saved
# snapshot on a free console port, runs AndroidScreenQATests against it, then stops it with `emu kill` (its process by
# ID if it lingers) and deletes the AVD, also when a step fails. Emulators and AVDs it did not make, and the adb server,
# are left alone. The screenshots and logs go to .build/simulator-qa/android-<time>/.
#
#   ANDROID_HOME                     the SDK (~/Library/Android/sdk by default)
#   YARDLET_ANDROID_QA_IMAGE         the system image to make the AVD from
#                                    (system-images;android-34;google_apis;arm64-v8a); it must be installed
#   YARDLET_ANDROID_QA_DEVICE        the hardware profile (pixel_6)
#   YARDLET_ANDROID_QA_SERVER        the scrcpy server file (the one scripts/build-app.sh caches by default)
#
# usage: scripts/simulator-qa/run-android-check.sh
set -euo pipefail
ROOT=${0:A:h:h:h}
cd "$ROOT"
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}
adb="$sdk/platform-tools/adb"
emulator="$sdk/emulator/emulator"
avdmanager="$sdk/cmdline-tools/latest/bin/avdmanager"
image=${YARDLET_ANDROID_QA_IMAGE:-"system-images;android-34;google_apis;arm64-v8a"}
profile=${YARDLET_ANDROID_QA_DEVICE:-pixel_6}
server=${YARDLET_ANDROID_QA_SERVER:-$HOME/Library/Caches/Yardlet/scrcpy/scrcpy-server-v5.0.1}
for tool in "$adb" "$emulator" "$avdmanager"; do
    [[ -x "$tool" ]] || { print -u2 "error: $tool is missing; set ANDROID_HOME to an SDK with it"; exit 1; }
done
[[ -d "$sdk/${image//;//}" ]] || { print -u2 "error: the system image $image is not installed"; exit 1; }
[[ -f "$server" ]] || { print -u2 "error: no scrcpy server at $server; scripts/build-app.sh downloads it"; exit 1; }
output="$ROOT/.build/simulator-qa/android-$(/bin/date +%Y%m%d-%H%M%S)"
avd_home="$output/avd"
mkdir -p "$avd_home"

# Builds and test runs take turns with other agents' through the heavy-build lock (scripts/heavy-lock.sh).
heavy() {
    if [[ -n "${CI:-}" || -n "${YARDLET_HEAVY_LOCK_HELD:-}" ]]; then "$@"; return; fi
    /usr/bin/nice -n 10 /usr/bin/lockf -t 21600 "$HOME/Library/Caches/yardlet-heavy-build.lock" "$@"
}
heavy swift build --build-system native --build-tests

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

name="yardlet_sim_qa_$(/usr/bin/openssl rand -hex 3)"
pid=""
cleanup() {
    if [[ -n "$pid" ]]; then
        "$adb" -s "$serial" emu kill >/dev/null 2>&1 || true
        for _ in {1..60}; do /bin/kill -0 "$pid" 2>/dev/null || break; /bin/sleep 0.5; done
        /bin/kill "$pid" 2>/dev/null || true
    fi
    rm -rf "${avd_home:?}"
    print "Stopped and deleted $name"
}
trap cleanup EXIT INT TERM
print "no" | ANDROID_AVD_HOME="$avd_home" "$avdmanager" create avd -n "$name" -k "$image" -d "$profile" >/dev/null
ANDROID_AVD_HOME="$avd_home" "$emulator" -avd "$name" -no-window -gpu host -no-boot-anim -no-audio -no-snapshot \
    -port "$port" >"$output/emulator.log" 2>&1 &
pid=$!
print "Started $name on $serial (process $pid)"
"$adb" -s "$serial" wait-for-device
for _ in {1..180}; do
    [[ "$("$adb" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]] && break
    /bin/sleep 1
done
[[ "$("$adb" -s "$serial" shell getprop sys.boot_completed | tr -d '\r')" == 1 ]] || {
    print -u2 "error: $name did not finish booting"; exit 1; }
# A first boot keeps setting up the launcher for a while after it reports booted.
/bin/sleep 15

set +e
YARDLET_ANDROID_QA_SERIAL=$serial \
YARDLET_ANDROID_QA_AVD=$name \
YARDLET_ANDROID_QA_ADB=$adb \
YARDLET_ANDROID_QA_SERVER=$server \
YARDLET_ANDROID_QA_OUTPUT=$output \
    heavy swift test --build-system native --skip-build --filter AndroidScreenQATests 2>&1 | tee "$output/test.log"
result=${pipestatus[1]}
set -e
print "Screenshots and logs: $output"
exit $result
