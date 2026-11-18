#!/bin/zsh
# Checks the Simulator tab in the running app against a throwaway simulator: builds a debug bundle without the
# browser engine, copies it as a QA bundle (prepare-qa.sh), makes a device named "Yardlet Sim QA <random>" and boots
# it without a window (no Simulator.app), then launches the bundle in the background with a temporary home
# (qa-launch.sh: never active, its windows past every screen) and the DEBUG fixture SimulatorPanelQA
# (`--ui-fixture-simulator-check`). The fixture follows the Simulator switch as the app does at launch, opens the
# tab, attaches the device, checks its live screen and a click through the bundle's simulator host, hands this script
# the task's yardlet-mcp launch for drive-tools.py to call the agent's simulator tools with (the fixture allows the
# approval card they raise), turns the switch off and checks the tab closes, capturing each step in both appearances. However the run ends, the script
# ends the app by its PID, shuts the device down and deletes it, and removes the QA bundle and home; devices it did
# not make are left alone. It exits 1 when a check failed or the fixture did not finish. The captures, result.json
# and the app's log go to .build/simulator-qa/panel-<time>/.
#
#   YARDLET_SIMULATOR_QA_DEVICE_TYPE   the device type to make (com.apple.CoreSimulator.SimDeviceType.iPhone-17)
#   YARDLET_SIMULATOR_QA_RUNTIME       the runtime (the newest available iOS runtime)
#
# usage: scripts/simulator-qa/run-panel-check.sh
set -euo pipefail
ROOT=${0:A:h:h:h}
cd "$ROOT"
device_type=${YARDLET_SIMULATOR_QA_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17}
output="$ROOT/.build/simulator-qa/panel-$(/bin/date +%Y%m%d-%H%M%S)"
qa_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp/}yardlet-simulator-panel-qa.XXXXXX")
qa_app="$qa_root/browser-host-qa/Yardlet Simulator Panel QA.app"
qa_home="$qa_root/browser-host-qa/home"
mkdir -p "$output"

YARDLET_WITHOUT_CEF=1 "$ROOT/scripts/build-app.sh" debug
"$ROOT/scripts/browser-host-qa/prepare-qa.sh" "$ROOT/.build/Yardlet.app" "$qa_app" com.zzunkie.yardletqa.simulatorpanel

runtime=${YARDLET_SIMULATOR_QA_RUNTIME:-$(/usr/bin/xcrun simctl list runtimes -j | /usr/bin/python3 -I -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"] if r.get("platform") == "iOS" and r.get("isAvailable")]
runtimes.sort(key=lambda r: [int(part) for part in r["version"].split(".")])
print(runtimes[-1]["identifier"] if runtimes else "")
')}
[[ -n "$runtime" ]] || { print -u2 "error: no iOS simulator runtime is installed"; exit 1; }

name="Yardlet Sim QA $(/usr/bin/openssl rand -hex 3)"
udid=$(/usr/bin/xcrun simctl create "$name" "$device_type" "$runtime")
app_pid=""
cleanup() {
    if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
        kill "$app_pid" 2>/dev/null || true
        for _ in {1..50}; do kill -0 "$app_pid" 2>/dev/null || break; sleep 0.1; done
    fi
    # The simulator host ends when the app does; anything still running from the QA bundle is ended by its PID.
    local pid command
    /bin/ps -axo pid=,command= | while read -r pid command; do
        [[ "$command" == "$qa_app/"* || "$command" == "/private$qa_app/"* ]] && kill "$pid" 2>/dev/null || true
    done
    /usr/bin/xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    /usr/bin/xcrun simctl delete "$udid" >/dev/null 2>&1 || true
    print "Deleted $name ($udid)"
    rm -rf "${qa_root:?}/browser-host-qa"
    rmdir "${qa_root:?}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
print "Made $name ($udid) on $runtime"
/usr/bin/xcrun simctl boot "$udid"
/usr/bin/xcrun simctl bootstatus "$udid" >/dev/null
# A first boot keeps setting up the home screen for a while after it reports booted.
sleep 15

app_pid=$("$ROOT/scripts/browser-host-qa/qa-launch.sh" "$qa_app" "$qa_home" "$output/app.log" \
    "YARDLET_SIMULATOR_QA_DEVICE=$udid" -- \
    --ui-fixture=conversation --ui-fixture-browser-ignore-occlusion --ui-fixture-simulator-check="$output")
print "QA app $app_pid"
deadline=$(( SECONDS + 600 ))
tools=0
while [[ ! -e "$output/finished" ]] && kill -0 "$app_pid" 2>/dev/null && (( SECONDS < deadline )); do
    if [[ -e "$output/tools-ready" && ! -e "$output/tools-done" ]]; then
        set +e
        /usr/bin/python3 -I "$ROOT/scripts/simulator-qa/drive-tools.py" "$output/tools-launch.json" "$udid" "$output" \
            | tee "$output/tools.log"
        tools=${pipestatus[1]}
        set -e
        # The launch holds the task's tool token.
        rm -f "$output/tools-launch.json"
        print done > "$output/tools-done"
    fi
    sleep 1
done

[[ -e "$output/finished" ]] || { print -u2 "error: the fixture did not finish; see $output/app.log"; exit 1; }
result=$(( tools == 0 ? 0 : 1 ))
/usr/bin/python3 -I - "$output/result.json" <<'EOF' || result=1
import json, sys
checks = json.load(open(sys.argv[1]))["checks"]
for check in checks:
    print(("ok    " if check["ok"] else "FAIL  ") + check["check"] + ("" if check["ok"] else "  " + check["detail"]))
sys.exit(0 if checks and all(check["ok"] for check in checks) else 1)
EOF
print "Captures and result: $output"
exit $result
