#!/bin/zsh
# Launches a QA Yardlet bundle in the background (`open -g`, and YARDLET_QA_BACKGROUND=1: the app is
# never active, has no Dock icon, menu bar or ⌘Tab entry, and keeps its windows and the browser host's
# past every screen, `QABackground`) with a temporary Yardlet home (CFFIXED_USER_HOME, which Foundation
# honors for ~/.yardlet and Application Support) and the visual fixture, so no real session index,
# draft, or provider runtime is read or started, and the person using the Mac keeps focus. The
# browser keeps the mock keychain even in a Developer ID build, so QA never makes or reads the
# installed app's "Chromium Safe Storage" item.
# Prints the app's PID.
# usage: qa-launch.sh <app bundle> <qa home> <log file> [VAR=value ...] -- [app arguments ...]
set -euo pipefail
app=$1
qa_home=$2
log=$3
shift 3
[[ "$qa_home" == */browser-host-qa/* ]] || { echo "QA home must be under a browser-host-qa directory" >&2; exit 2; }
mkdir -p "$qa_home"
# LaunchServices starts the app in /, where a relative home (or log) names a folder on the read-only system volume and
# Chromium stops at once without its cache folder: both go as absolute real paths.
qa_home=${qa_home:A}
log=${log:A}
environment=(--env "CFFIXED_USER_HOME=$qa_home" --env "HOME=$qa_home" --env "YARDLET_QA_BACKGROUND=1"
    --env "YARDLET_BROWSER_KEYCHAIN=mock")
while (( $# > 0 )) && [[ "$1" != "--" ]]; do
    environment+=(--env "$1")
    shift
done
(( $# > 0 )) && shift
# LaunchServices starts the bundle at its real path; a bundle under $TMPDIR (/var/folders/.../T/, which ends
# in a slash) runs as /private/var/folders/..., and its helpers may show either form.
executable="${app:A}/Contents/MacOS/Yardlet"
/usr/bin/open -g -n -F "${environment[@]}" --stdout "$log" --stderr "$log" "$app" --args "$@"
for _ in {1..100}; do
    pid=$(pgrep -n -f "^(/private)?${executable#/private}" || true)
    [[ -n "$pid" ]] && { echo "$pid"; exit 0; }
    sleep 0.1
done
echo "QA app did not start" >&2
exit 1
