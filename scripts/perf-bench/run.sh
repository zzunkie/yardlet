#!/bin/zsh
# Yardlet's performance bench (docs/PERFORMANCE_BENCH.md). It runs fixed scenes of the whole app in a QA copy
# of a debug build, and the in-process benchmarks of the test suite, and writes one JSON result that it
# compares with the previous one, marking what got worse. It fails (status 1) when a number is over its
# budget in budgets.json or a scene could not be set up.
#
#   ./scripts/perf-bench/run.sh [--build] [--app <Yardlet.app>] [--scenes "<scene> ..."] [--no-micro]
#       [--micro-only] [--repeat <n>] [--compare <result.json>] [--tolerance <fraction>]
#       [--cycle-seconds <seconds>] [--cycle-rest-seconds <seconds>] [--hang-log on|off]
#       [--memory-census] [--no-event-pulse] [--keep] [--app-arguments "<argument> ..."]
#
# Scenes: launch idle-running stream-claude stream-codex codex-history subagent sidebar browser-tabs codex-switch
# memory-cycle composer-input home conversation-scroll (all by
# default; `PerfBenchFixture` in Sources/NativeHarnessClient/Development says what each holds). Each runs
# in a fresh launch of the QA copy: its own bundle identifier (com.zzunkie.yardletqa.perf), a temporary
# home, windows off every screen, never the active app (`QABackground`). Tasks that stream talk to fake
# Codex and Claude Code CLIs (fake-codex.py, fake-claude.py); no model, account, network or installed app
# is used. The app measures its main thread and frames; this script samples the process tree's CPU and
# memory over the same phases (`sampler.swift` from scripts/browser-host-qa).
#
# --build        build .build/Yardlet.app (debug) first
# --app          the debug bundle to copy (default .build/Yardlet.app); a release bundle has no fixture
# --no-micro     skip the in-process benchmarks (`swift test` with NHC_PERF_BENCH=1)
# --micro-only   only the in-process benchmarks
# --repeat <n>   run each scene n times and keep the median of each number (default 1)
# --compare      a result file, or a commit whose newest result to compare with (default: the newest
#                earlier result)
# --tolerance    how much worse a number must be to be marked, as a fraction (default 0.15)
# --keep         keep the QA copy, its home and the logs in .build/perf-bench/run
# --cycle-seconds duration of memory-cycle's fixed-history revisits (10..86400, default 60)
# --cycle-rest-seconds recovery interval after revisits (15..3600, default 15)
# --hang-log     main-thread diagnostics in the QA process only (on or off, default on)
# --memory-census count created/live/released conversation objects (diagnostic)
# --no-event-pulse omit memory-cycle's AppKit event boundaries (diagnostic control only)
# --app-arguments more arguments for every launch of the app, such as a setting to measure with
#                (`-Yardlet.conversationTableTimeline YES`); the result records them
#
# Results: ~/Library/Caches/Yardlet/perf-bench/results/<time>-<commit>.json ($YARDLET_PERF_RESULTS), shared by
# every checkout and worktree on this Mac, so one branch compares with another. The bench waits for the shared heavy-build lock
# (~/Library/Caches/yardlet-heavy-build.lock) so builds and other benches do not run beside it. Close
# what you can: other work on the Mac shows up in the numbers. It never takes the screen or keyboard.
set -euo pipefail
PROJECT_ROOT=${0:A:h:h:h}
TOOLS=${0:A:h}
QA=$PROJECT_ROOT/scripts/browser-host-qa

if [[ -z "${YARDLET_HEAVY_LOCK_HELD:-}" ]]; then
    print "Waiting for the heavy-build lock…"
    exec /usr/bin/env YARDLET_HEAVY_LOCK_HELD=1 /usr/bin/lockf -t 21600 "$HOME/Library/Caches/yardlet-heavy-build.lock" \
        /bin/zsh "$0" "$@"
fi

all_scenes=("${(@f)$(/usr/bin/python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["scenes"]))' "$TOOLS/contract.json")}")
app=$PROJECT_ROOT/.build/Yardlet.app
build=0
scenes=($all_scenes)
micro=1
app_scenes=1
repeat=1
compare=""
tolerance=0.15
keep=0
app_arguments=()
cycle_seconds=60
cycle_rest_seconds=15
hang_log=on
memory_census=0
event_pulse=1
while (( $# > 0 )); do
    case $1 in
        --build) build=1; shift ;;
        --app) app=${2:?--app needs a bundle}; shift 2 ;;
        --scenes) scenes=(${=2}); shift 2 ;;
        --no-micro) micro=0; shift ;;
        --micro-only) app_scenes=0; shift ;;
        --repeat) repeat=${2:?--repeat needs a number}; shift 2 ;;
        --compare) compare=${2:?--compare needs a result}; shift 2 ;;
        --tolerance) tolerance=${2:?--tolerance needs a fraction}; shift 2 ;;
        --keep) keep=1; shift ;;
        --app-arguments) app_arguments=(${=2}); shift 2 ;;
        --cycle-seconds) cycle_seconds=${2:?--cycle-seconds needs a duration}; shift 2 ;;
        --cycle-rest-seconds) cycle_rest_seconds=${2:?--cycle-rest-seconds needs a duration}; shift 2 ;;
        --hang-log) hang_log=${2:?--hang-log needs on or off}; shift 2 ;;
        --memory-census) memory_census=1; shift ;;
        --event-pulse) event_pulse=1; shift ;;
        --no-event-pulse) event_pulse=0; shift ;;
        -h|--help) /usr/bin/sed -n '2,35p' "$0" | /usr/bin/sed 's/^# \{0,1\}//'; exit 0 ;;
        *) print -u2 "error: unknown argument $1 (see --help)"; exit 2 ;;
    esac
done
[[ "$repeat" == <-> ]] && (( repeat > 0 )) || { print -u2 "error: --repeat must be a positive integer"; exit 2; }
[[ "$cycle_seconds" == <-> ]] && (( cycle_seconds >= 10 && cycle_seconds <= 86400 )) \
    || { print -u2 "error: --cycle-seconds must be an integer from 10 to 86400"; exit 2; }
[[ "$cycle_rest_seconds" == <-> ]] && (( cycle_rest_seconds >= 15 && cycle_rest_seconds <= 3600 )) \
    || { print -u2 "error: --cycle-rest-seconds must be an integer from 15 to 3600"; exit 2; }
[[ "$hang_log" == on || "$hang_log" == off ]] || { print -u2 "error: --hang-log must be on or off"; exit 2; }
(( ! app_scenes || ${#scenes} > 0 )) || { print -u2 "error: select at least one scene"; exit 2; }
(( app_scenes || micro )) || { print -u2 "error: no benchmarks selected"; exit 2; }
if (( build )) && [[ ${app:A} != "$PROJECT_ROOT/.build/Yardlet.app" ]]; then
    print -u2 "error: --build builds this checkout's .build/Yardlet.app; omit --app"
    exit 2
fi
for scene in $scenes; do
    (( ${all_scenes[(Ie)$scene]} )) || { print -u2 "error: unknown scene $scene"; exit 2; }
done

root=$PROJECT_ROOT/.build/perf-bench
results=${YARDLET_PERF_RESULTS:-$HOME/Library/Caches/Yardlet/perf-bench/results}
work=$root/run/browser-host-qa
qa_app="$work/Yardlet Perf.app"
qa_home=$work/home
bench=$work/bench
stamp=$(date '+%Y%m%d-%H%M%S')
out=$root/run/$stamp
# An interrupted older run must not make LaunchServices reuse its process without this run's home,
# arguments or environment. Refuse before changing the QA copy or registering its cleanup trap.
/usr/bin/python3 - "$qa_app/Contents/MacOS/Yardlet" <<'PY'
from pathlib import Path
import subprocess, sys
executable = str(Path(sys.argv[1]).resolve())
for line in subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True).splitlines():
    fields = line.strip().split(None, 1)
    if len(fields) == 2 and (fields[1] == executable or fields[1].startswith(executable + ' ')):
        raise SystemExit(f'error: this QA copy is already running (PID {fields[0]}); finish that run before starting another')
PY
mkdir -p "$results" "$out/logs"
if [[ -n "$compare" && ! -f "$compare" ]]; then
    # A commit: its newest result, found before the run.
    revision=$(git -C "$PROJECT_ROOT" rev-parse --short=8 "$compare" 2>/dev/null) \
        || { print -u2 "error: $compare is neither a result file nor a commit"; exit 2; }
    matches=("$results"/*-$revision.json(N.om))
    (( ${#matches} )) || { print -u2 "error: no result for $revision in $results"; exit 2; }
    compare=${matches[1]}
fi

app_pid=""
server_pid=""
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
quit_app() {
    [[ -n "$app_pid" ]] || return 0
    kill "$app_pid" 2>/dev/null || true
    for _ in {1..50}; do kill -0 "$app_pid" 2>/dev/null || break; sleep 0.1; done
    kill -9 "$app_pid" 2>/dev/null || true
    app_pid=""
}
retire() {
    setopt local_options no_err_exit
    quit_app
    [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null
    (( keep )) && { print "Kept $root/run"; return; }
    if [[ -d "$qa_app" ]]; then
        for nested in "$qa_app"/Contents/Frameworks/*.app/Contents/Frameworks/*.app(N) "$qa_app"/Contents/Frameworks/*.app(N) "$qa_app"; do
            "$LSREGISTER" -u "$nested" 2>/dev/null
        done
    fi
    # Everything here is this script's own: the QA copy, its home and the logs, and the settings macOS keeps for
    # the copy's identifiers (its window's frame) outside the temporary home. The result stays in results/.
    rm -rf "${root:?}/run"
    for plist in "$HOME"/Library/Preferences/com.zzunkie.yardletqa.perf*.plist(N); do
        /usr/bin/defaults delete "${plist:t:r}" 2>/dev/null
        rm -f "${plist:?}"
    done
}
trap retire EXIT
trap 'exit 130' INT TERM

machine_info() {
    local model=$(/usr/sbin/sysctl -n hw.model) cpus=$(/usr/sbin/sysctl -n hw.ncpu)
    local memory=$(( $(/usr/sbin/sysctl -n hw.memsize) / 1073741824 ))
    local chip=$(/usr/sbin/sysctl -n machdep.cpu.brand_string 2>/dev/null || print "")
    print -r -- "{\"model\": \"$model\", \"chip\": \"$chip\", \"cpus\": $cpus, \"memoryGiB\": $memory, \"macOS\": \"$(/usr/bin/sw_vers -productVersion)\"}"
}
load_average() { /usr/sbin/sysctl -n vm.loadavg | /usr/bin/awk '{print $2}'; }

commit=$(git -C "$PROJECT_ROOT" rev-parse --short=8 HEAD)
dirty=$([[ -n "$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=no)" ]] && print true || print false)
cat > "$out/meta.json" <<EOF
{"commit": "$commit", "dirty": $dirty, "branch": "$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD)",
 "startedAt": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')", "machine": $(machine_info), "loadAtStart": $(load_average),
 "repeat": $repeat, "appArguments": "${app_arguments[*]}"}
EOF
/usr/bin/python3 - "$out/meta.json" "$TOOLS/contract.json" "$micro" "$app_scenes" "$cycle_seconds" "$cycle_rest_seconds" "$hang_log" "$memory_census" "$event_pulse" $scenes <<'PY'
import json, sys
path, contract_path, micro, app_scenes, cycle_seconds, cycle_rest_seconds, hang_log, memory_census, event_pulse, *scenes = sys.argv[1:]
contract = json.load(open(contract_path))
meta = json.load(open(path))
if len(scenes) != len(set(scenes)):
    raise SystemExit('error: a scene may only be selected once')
meta['plan'] = {'scenes': {name: contract['scenes'][name] for name in scenes} if app_scenes == '1' else {},
                'micro': contract['micro'] if micro == '1' else [],
                'metrics': {name: contract.get('metrics', {}).get(name, {}) for name in scenes} if app_scenes == '1' else {}}
meta['parameters'] = {'memoryCycleSeconds': int(cycle_seconds), 'memoryCycleRestSeconds': int(cycle_rest_seconds),
                      'hangLogEnabled': hang_log == 'on', 'memoryCensusEnabled': memory_census == '1', 'eventPulseEnabled': event_pulse == '1'}
with open(path, 'w') as stream:
    json.dump(meta, stream, indent=2)
PY

if (( app_scenes )); then
    identity_arguments=()
    if (( build )); then
        /usr/bin/python3 "$TOOLS/report.py" source-state "$PROJECT_ROOT" > "$out/build-source.json"
        nice -n 10 "$PROJECT_ROOT/scripts/build-app.sh" debug
        identity_arguments=(--built-source "$out/build-source.json")
    fi
    [[ -d "$app" ]] || { print -u2 "error: no app at $app; build one with --build or scripts/build-app.sh debug"; exit 1; }
    /usr/bin/python3 "$TOOLS/report.py" artifact "$PROJECT_ROOT" "$app" $identity_arguments > "$out/artifact.json"
    print "Preparing the QA copy in $work"
    mkdir -p "$work/bin" "$out/logs"
    nice -n 10 swiftc -O -o "$work/bin/sampler" "$QA/sampler.swift" > "$out/logs/swiftc.log" 2>&1 \
        || { cat "$out/logs/swiftc.log" >&2; exit 1; }
    "$QA/prepare-qa.sh" "$app" "$qa_app" com.zzunkie.yardletqa.perf >/dev/null
    executable="$qa_app/Contents/MacOS/Yardlet"
    /usr/bin/python3 - "$out/artifact.json" "$executable" <<'PY'
import hashlib, json, sys
path, executable = sys.argv[1:]
artifact = json.load(open(path))
artifact['qaExecutableSHA256'] = hashlib.sha256(open(executable, 'rb').read()).hexdigest()
with open(path, 'w') as stream:
    json.dump(artifact, stream, indent=2)
PY
    /usr/bin/grep -q -a -F -- '--ui-fixture=perf' "$executable" \
        || { print -u2 "error: $app has no performance fixture; use a debug build of this checkout"; exit 1; }
    rm -rf "${qa_home:?}" "${bench:?}"
    mkdir -p "$qa_home" "$bench/bin"
    cp "$TOOLS/fake-codex.py" "$bench/bin/codex"
    cp "$TOOLS/fake-claude.py" "$bench/bin/claude"
    chmod 700 "$bench/bin/codex" "$bench/bin/claude"
    browser_arguments=()
    if (( ${scenes[(Ie)browser-tabs]} )); then
        mkdir -p "$work/server"
        python3 "$QA/form-server.py" --output-dir "$work/server" > "$out/logs/server.log" 2>&1 &
        server_pid=$!
        for _ in {1..50}; do [[ -s "$work/server/port" ]] && break; sleep 0.1; done
        browser_arguments=(--ui-fixture-browser-url="http://127.0.0.1:$(<"$work/server/port")/"
                           --ui-fixture-browser-ignore-occlusion)
    fi

    # One scene in a fresh launch: <scene> <its output folder> <log name>.
    run_scene() {
        local scene=$1 scene_out=$2 name=$3 markers=$bench/scenes/$1/markers extra=() attempt ready marker seconds deadline
        mkdir -p "$scene_out/samples"
        rm -rf "${bench:?}/scenes/${scene:?}"
        print -r -- "{\"loadBefore\": $(load_average)}" > "$scene_out/run.json"
        [[ $scene == browser-tabs ]] && extra=($browser_arguments)
        [[ $scene == memory-cycle ]] && extra+=(--ui-fixture-perf-cycle-seconds="$cycle_seconds")
        extra+=(--ui-fixture-perf-cycle-rest-seconds="$cycle_rest_seconds" --ui-fixture-perf-hang-log="$hang_log")
        (( memory_census )) && extra+=(--ui-fixture-perf-memory-census)
        (( ! event_pulse )) && extra+=(--ui-fixture-perf-no-event-pulse)
        app_pid=$("$QA/qa-launch.sh" "$qa_app" "$qa_home" "$out/logs/$name.log" -- \
            --ui-fixture=perf --ui-fixture-perf-scene="$scene" --ui-fixture-perf-dir="$bench" $extra $app_arguments \
            -AppleLanguages "(en)" -AppleLocale en_US)
        # Launched in the background the app makes its window only when opened again, as clicking the Dock
        # icon would, and the fixture starts in the window: open it again as soon as the app has launched.
        for _ in {1..300}; do [[ -e "$markers/launched" ]] && break; sleep 0.05; done
        for attempt in {1..10}; do
            /usr/bin/open -g "$qa_app"
            for _ in {1..60}; do [[ -e "$markers/window" ]] && break; sleep 0.05; done
            [[ -e "$markers/window" ]] && break
        done
        print -r -- "{\"loadBefore\": $(load_average), \"reopens\": $attempt}" > "$scene_out/run.json"
        deadline=$(( SECONDS + 240 ))
        [[ $scene == memory-cycle ]] && deadline=$(( deadline + cycle_seconds + cycle_rest_seconds ))
        while kill -0 "$app_pid" 2>/dev/null && (( SECONDS < deadline )); do
            [[ -e "$markers/finished" ]] && break
            for ready in "$markers"/*.ready(N); do
                marker=${ready:t:r}
                [[ -e "$markers/$marker.go" ]] && continue
                seconds=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["seconds"])' "$ready")
                : > "$markers/$marker.go"
                "$work/bin/sampler" "$app_pid" "$marker" "$seconds" > "$scene_out/samples/$marker.json" 2>/dev/null || true
                print -n "${marker#*-} "
            done
            sleep 0.05
        done
        for _ in {1..100}; do kill -0 "$app_pid" 2>/dev/null || break; sleep 0.1; done
        quit_app
        cp "$bench/scenes/$scene/progress.log" "$scene_out/" 2>/dev/null || true
        for picture in "$bench/scenes/$scene"/*.png(N); do cp "$picture" "$scene_out/"; done
        if [[ -f "$bench/scenes/$scene/scene.json" ]]; then
            cp "$bench/scenes/$scene/scene.json" "$scene_out/scene.json"
            print "done"
        else
            print "no result (see $out/logs/$name.log)"
        fi
    }

    # A fresh copy's first launch reads and checks its code for the first time and is much slower than the
    # next. One launch nobody measures goes first, so every scene measures a launch like the person's next one.
    print -n "warm-up launch: "
    run_scene launch "$out/warm-up" warm-up
    for (( round = 1; round <= repeat; round++ )); do
        for scene in $scenes; do
            print -n "$scene (round $round): "
            run_scene "$scene" "$out/scenes/$scene/$round" "$scene-$round"
        done
    done
fi

if (( micro )); then
    print "In-process benchmarks (swift test, NHC_PERF_BENCH=1)…"
    filter=$(/usr/bin/python3 -c 'import json,re,sys; print("|".join(re.escape(t["test"]) + "$" for t in json.load(open(sys.argv[1]))["micro"]))' "$TOOLS/contract.json")
    micro_exit=0
    (cd "$PROJECT_ROOT" && NHC_PERF_BENCH=1 NHC_PERF_BENCH_SECONDS=20 NHC_PERF_BENCH_OUTPUT="$out/micro.jsonl" \
        nice -n 10 swift test --build-system native --filter "$filter") > "$out/micro.log" 2>&1 \
        || micro_exit=$?
    print -r -- "{\"exitCode\": $micro_exit}" > "$out/micro-status.json"
    cp "$out/micro.log" "$results/$stamp-$commit-micro.log"
fi

arguments=(collect "$out" "$results/$stamp-$commit.json" --tolerance "$tolerance")
if [[ -n "$compare" ]]; then
    arguments+=(--compare "$compare")
else
    previous=("$results"/*.json(N.om))
    (( ${#previous} )) && arguments+=(--compare "${previous[1]}")
fi
/usr/bin/python3 "$TOOLS/report.py" $arguments
