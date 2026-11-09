# Sourced by the scripts that build or test at length. Agents that build and test Yardlet on one
# Mac at the same time take turns through one lock, ~/Library/Caches/yardlet-heavy-build.lock, and
# run at low priority while they hold it, so the person using the Mac keeps a responsive screen.
# take_heavy_lock runs the calling script again under that lock and returns at once when the script
# already holds it: on CI, under a script that took it (YARDLET_HEAVY_LOCK_HELD is set), or under a
# lockf(1) of the same file further up, as in
# `nice -n 10 /usr/bin/lockf -t 21600 ~/Library/Caches/yardlet-heavy-build.lock swift build`.
#
#   source "${0:A:h}/heavy-lock.sh" && take_heavy_lock "${0:A}" "$@"

take_heavy_lock() {
    local script=$1
    shift
    [[ -n "${CI:-}" || -n "${YARDLET_HEAVY_LOCK_HELD:-}" ]] && return 0
    local lock=$HOME/Library/Caches/yardlet-heavy-build.lock pid=$$ line
    local -a words
    while (( pid > 1 )); do
        line=$(/bin/ps -o ppid=,command= -p $pid 2>/dev/null) || break
        words=(${(z)line})
        [[ ${words[2]:t} == lockf && ${words[(I)*${lock:t}]} -gt 0 ]] && return 0
        pid=${words[1]}
    done
    print -u2 "Waiting for the heavy-build lock ($lock)…"
    exec /usr/bin/env YARDLET_HEAVY_LOCK_HELD=1 /usr/bin/nice -n 10 /usr/bin/lockf -t 21600 "$lock" \
        /bin/zsh "$script" "$@"
}
