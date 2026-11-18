#!/bin/zsh
# Checks the simulator host against a throwaway simulator: builds the helper and the tests, makes a device named
# "Yardlet Sim QA <random>", boots it without a window (no Simulator.app), runs SimulatorHostQATests against it with
# the helper started responsible for itself (no screen recording or accessibility permission of its own), then shuts
# the device down and deletes it, also when a step fails. Devices it did not make are left alone. The screenshots and
# the helper's log go to .build/simulator-qa/<time>/.
#
#   DEVELOPER_DIR                      the Xcode to use (xcode-select's by default)
#   YARDLET_SIMULATOR_QA_DEVICE_TYPE   the device type to make (com.apple.CoreSimulator.SimDeviceType.iPhone-17)
#   YARDLET_SIMULATOR_QA_RUNTIME       the runtime (the newest available iOS runtime)
#   YARDLET_SIMULATOR_QA_HELPER        another helper executable to check, such as a bundle's
#                                      Contents/Helpers/Yardlet Simulator Host.app/Contents/MacOS/Yardlet Simulator Host
#   YARDLET_SIMULATOR_QA_SETTINGS      the Settings icon as "x,y" fractions of the screen, for another device type
#
# usage: scripts/simulator-qa/run-check.sh
set -euo pipefail
ROOT=${0:A:h:h:h}
cd "$ROOT"
developer_dir=${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}
device_type=${YARDLET_SIMULATOR_QA_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17}
output="$ROOT/.build/simulator-qa/$(/bin/date +%Y%m%d-%H%M%S)"
mkdir -p "$output"

# Builds and test runs take turns with other agents' through the heavy-build lock (scripts/heavy-lock.sh).
heavy() {
    if [[ -n "${CI:-}" || -n "${YARDLET_HEAVY_LOCK_HELD:-}" ]]; then "$@"; return; fi
    /usr/bin/nice -n 10 /usr/bin/lockf -t 21600 "$HOME/Library/Caches/yardlet-heavy-build.lock" "$@"
}
heavy swift build --build-system native --product YardletSimulatorHost
heavy swift build --build-system native --build-tests

runtime=${YARDLET_SIMULATOR_QA_RUNTIME:-$(/usr/bin/xcrun simctl list runtimes -j | /usr/bin/python3 -I -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"] if r.get("platform") == "iOS" and r.get("isAvailable")]
runtimes.sort(key=lambda r: [int(part) for part in r["version"].split(".")])
print(runtimes[-1]["identifier"] if runtimes else "")
')}
[[ -n "$runtime" ]] || { print -u2 "error: no iOS simulator runtime is installed"; exit 1; }

name="Yardlet Sim QA $(/usr/bin/openssl rand -hex 3)"
udid=$(/usr/bin/xcrun simctl create "$name" "$device_type" "$runtime")
cleanup() {
    /usr/bin/xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    /usr/bin/xcrun simctl delete "$udid" >/dev/null 2>&1 || true
    print "Deleted $name ($udid)"
}
trap cleanup EXIT INT TERM
print "Made $name ($udid) on $runtime"
/usr/bin/xcrun simctl boot "$udid"
/usr/bin/xcrun simctl bootstatus "$udid" >/dev/null
# A first boot keeps setting up the home screen for a while after it reports booted.
sleep 15

set +e
YARDLET_SIMULATOR_QA_DEVICE=$udid \
YARDLET_SIMULATOR_QA_DEVELOPER_DIR=$developer_dir \
YARDLET_SIMULATOR_QA_OUTPUT=$output \
    heavy swift test --build-system native --skip-build --filter SimulatorHostQATests 2>&1 | tee "$output/test.log"
result=${pipestatus[1]}
set -e
print "Screenshots and logs: $output"
exit $result
