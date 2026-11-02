#!/bin/zsh
# Captures Yardlet's public screenshots and demo videos from the showcase fixture
# (`--ui-fixture=showcase`, Sources/NativeHarnessClient/Development/ShowcaseFixture.swift). It runs a
# QA copy of a debug build under its own bundle identifier with its own temporary home, so the
# installed app, its settings and ~/.yardlet are never read or changed, and nothing reaches a
# provider, GitHub or a connector.
#
#   ./scripts/showcase/capture.sh [--build] [--app <Yardlet.app>] [--scenes "<scene> ..."]
#       [--appearances "light dark"] [--no-video] [--keep] <output folder>
#
# For each appearance it writes, all in English and all of the window alone (no shadow, nothing
# around it) at the display's scale, 2720×1680 for the 1360×840 window on a Retina display:
#
#   <scene>-<appearance>.png   main        the Codex task with its rail: the dark mode turn, PR #128
#                              split       the Codex task beside the running Claude Code task
#                              review      the review panel on the task's uncommitted changes
#                              accounts    Settings › Accounts with each account's usage
#                              connectors  Settings › Connectors
#   playback-<appearance>.mp4  one round of the playback (`--ui-fixture-playback`): beside the running
#                              Claude Code task, a new task's request typed, the composer's account
#                              list opened and the account with room left chosen, then the Codex
#                              turn streaming, its tools, changes and answer while the Claude Code
#                              task finishes. 17 s, H.264, 60 fps, no sound, from the round's first
#                              frame to the finished tasks, which cut back to it, so it loops.
#
# Outside the window's rounded corners stills and videos alike are black, so a page shows both with
# the window's corner radius.
# Run it only when the person at the Mac has agreed to it, and in the foreground: it puts a window
# on their screen for each scene, never detaches, and stops at the first of these: every output
# written, ten minutes gone, a failed capture, or the app quit by anyone (it is never launched
# again then). The app is launched in the background and never made active; its windows go behind
# the person's own, take no keyboard focus, and let clicks and the pointer pass through.
# The screen must be unlocked and awake: the windows are drawn from the display (which does not
# mark them as shared), only the app's own windows, so other windows may cover them.
# Afterwards, or when it stops, the QA bundle is unregistered from LaunchServices and moved to the
# Trash with its temporary home, unless --keep.
set -euo pipefail
PROJECT_ROOT=${0:A:h:h:h}
TOOLS=${0:A:h}
QA=$PROJECT_ROOT/scripts/browser-host-qa

app=$PROJECT_ROOT/.build/Yardlet.app
build=0
scenes=(main split review accounts connectors)
appearances=(light dark)
video=1
keep=0
output=""
while (( $# > 0 )); do
    case $1 in
        --build) build=1; shift ;;
        --app) app=${2:?--app needs a bundle}; shift 2 ;;
        --scenes) scenes=(${=2}); shift 2 ;;
        --appearances) appearances=(${=2}); shift 2 ;;
        --no-video) video=0; shift ;;
        --keep) keep=1; shift ;;
        -h|--help) /usr/bin/sed -n '2,32p' "$0" | /usr/bin/sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) print -u2 "error: unknown option $1"; exit 2 ;;
        *) output=$1; shift ;;
    esac
done
[[ -n "$output" ]] || { print -u2 "error: name the output folder (see --help)"; exit 2; }

if /usr/sbin/ioreg -n Root -d1 -a | /usr/bin/plutil -extract IOConsoleUsers xml1 -o - - 2>/dev/null \
        | /usr/bin/grep -A1 CGSSessionScreenIsLocked | /usr/bin/grep -q '<true/>'; then
    print -u2 "error: the screen is locked; unlock it and run this again"
    exit 1
fi
if (( build )); then "$PROJECT_ROOT/scripts/build-app.sh" debug; fi
[[ -d "$app" ]] || { print -u2 "error: no app at $app; build one with --build or scripts/build-app.sh debug"; exit 1; }
mkdir -p "$output"
output=${output:A}

# Everything temporary lives in one folder outside the repository, named after nobody. Its real
# path (/private/var/…, not /var/…) is the one the launched app's process shows, which is how the
# QA scripts find it.
work=$(/usr/bin/mktemp -d "${${TMPDIR:-/tmp}%/}/yardlet-showcase.XXXXXX")
work=${work:A}
qa_dir=$work/browser-host-qa
qa_app="$qa_dir/Yardlet Showcase.app"
qa_home=$qa_dir/home
log=$work/app.log
pid=""
quit_app() {
    [[ -n "$pid" ]] || return 0
    kill "$pid" 2>/dev/null || true
    for _ in {1..50}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    /usr/bin/pkill -f "$qa_app/" 2>/dev/null || true
    pid=""
}
retire() {
    setopt local_options no_err_exit
    quit_app
    (( keep )) && { print "Kept $work"; return; }
    local trash="Yardlet showcase capture $(date '+%Y-%m-%d %H%M%S')"
    [[ -d "$qa_app" ]] && "$QA/cleanup-qa.sh" "$qa_app" "$trash" >/dev/null
    mkdir -p "$HOME/.Trash/$trash"
    mv "$work" "$HOME/.Trash/$trash/" && print "Moved the QA bundle and its home to the Trash ($trash)"
}
trap retire EXIT

print "Preparing the QA bundle and the demo projects in $work"
mkdir -p "$work/bin"
swiftc -O -o "$work/bin/record-window" "$TOOLS/record-window.swift" > "$work/swiftc.log" 2>&1 \
    || { cat "$work/swiftc.log" >&2; exit 1; }
"$QA/prepare-qa.sh" "$app" "$qa_app" com.zzunkie.yardletqa.showcase >/dev/null
mkdir -p "$qa_home"
"$TOOLS/make-projects.sh" "$qa_home/Developer" >/dev/null

deadline=$(( SECONDS + 600 ))
stop() { print -u2 "Stopped: $1"; exit 1; }
# The app must still be the one this script launched, and time must be left.
check() {
    kill -0 "$pid" 2>/dev/null || stop "the app was quit; it is not launched again"
    (( SECONDS < deadline )) || stop "ten minutes passed"
}

launch() {
    local appearance=$1; shift
    (( SECONDS < deadline )) || stop "ten minutes passed"
    quit_app
    pid=$("$QA/qa-launch.sh" "$qa_app" "$qa_home" "$log" -- \
        --ui-fixture=showcase --ui-fixture-workspace="$qa_home/Developer" --ui-fixture-window=1360x840 \
        --ui-fixture-appearance="$appearance" --ui-fixture-ignore-pointer \
        -AppleLanguages "(en)" -AppleLocale en_US "$@")
    # Launched in the background, the app may come up without its window; a reopen in the
    # background makes it, as clicking the Dock icon would, without bringing the app forward.
    sleep 2
    check
    /usr/bin/open -g "$qa_app"
}

scene_arguments() {
    case $1 in
        main) ;;
        split) print -- --ui-fixture-split=right ;;
        review) print -- --ui-fixture-surface=diff ;;
        accounts) print -- --ui-fixture-settings-section=accounts ;;
        connectors) print -- --ui-fixture-settings-section=connectors ;;
        *) print -u2 "error: unknown scene $1"; return 1 ;;
    esac
}

for appearance in $appearances; do
    for scene in $scenes; do
        launch "$appearance" $(scene_arguments "$scene")
        # The window lays out, the rail reads Git, and Settings opens.
        sleep 6
        check
        "$work/bin/record-window" shot "$pid" "$output/$scene-$appearance.png" --size 1360x840
        check
    done
    if (( video )); then
        launch "$appearance" --ui-fixture-playback
        sleep 1.5
        check
        "$work/bin/record-window" record "$pid" "$output/playback-$appearance.mp4" --size 1360x840 --wait-loop
        check
    fi
done
quit_app
print "Wrote $output"
