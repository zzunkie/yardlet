#!/bin/zsh
# The conversation's tests again with the eager stack (`ConversationRowListSwitch` off), while the stack
# can still be turned back on in place of the row list that draws conversations: a change to the
# conversation that breaks only the stack shows here, though every other run draws the row list. CI runs
# it after scripts/test-fast.sh on main and on pull requests touching conversation views, projections, or
# transcripts, and it goes away with the stack.
# `-v` prints every test's output, `--filter` and `--skip` narrow the selection as for scripts/test-fast.sh,
# `--num-workers` sets concurrency, `--skip-build` reuses an already-built test bundle, and `--times-file`
# sets where stack test durations are kept for LPT scheduling (default `.build/xctest-stack-times.tsv`).
# On a Mac it first waits for the shared heavy-build lock (scripts/heavy-lock.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
arguments=("$@")
# The classes that draw conversations, and of the prose's rendering tests the one that does: the rest
# draw a message alone, the same with either renderer.
suites='\.(ConversationBlankFrame|ConversationFind|ConversationSelection|TranscriptReading|TranscriptAutoFollow|ConversationTopLoading|ConversationSendJump|ConversationSwitchFrame|ConversationTurnWindowRendering|ConversationTurnHost|ConversationReopenGap|CodexTimelineReading|CodexTimelineNavigation|ConversationAnchorMigration|StreamingWindowRedraw|ConversationFollowUpPlacement|TaskWorkspaceRestoration|ConversationScrollOverCodeBlock)Tests/|\.TranscriptProseRenderingTests/testGoingToAMatchInATextOrATableBringsItToTheMiddle$'
selection=()
skip_build=0
verbose=()
workers=4
times_file=".build/xctest-stack-times.tsv"
while (( $# )); do
  case $1 in
    --skip-build) skip_build=1 ;;
    -v|--verbose) verbose=(-v) ;;
    --filter|--skip|--num-workers|--times-file)
      (( $# >= 2 )) || { print -u2 "test-conversation-stack.sh: $1 needs a value"; exit 2; }
      case $1 in
        --num-workers) workers=$2 ;;
        --times-file) times_file=$2 ;;
        *) selection+=("$1" "$2") ;;
      esac
      shift ;;
    *) print -u2 "test-conversation-stack.sh: unknown option $1"; exit 2 ;;
  esac
  shift
done
source scripts/heavy-lock.sh && take_heavy_lock "${0:A}" "${arguments[@]}"

if (( ! skip_build )); then
  build_jobs=()
  [[ -n "${CI:-}" ]] || build_jobs=(-j 4)
  swift build --build-system native --build-tests "${build_jobs[@]}"
fi
bundles=("$(swift build --build-system native --show-bin-path)"/*PackageTests.xctest(N))
(( ${#bundles} == 1 )) || { print -u2 "test-conversation-stack.sh: expected one test bundle, found ${#bundles}"; exit 1; }
tests=$(mktemp -t yardlet-conversation-stack-tests)
trap 'rm -f "$tests"' EXIT
swift test --build-system native list --skip-build --disable-swift-testing > "$tests"
export YARDLET_CONVERSATION_ROW_LIST=0
times_args=()
[[ -n "$times_file" ]] && times_args=(--times-file "$times_file")
python3 -I scripts/xctest-batches.py --bundle "$bundles[1]" --tests "$tests" --workers "$workers" \
  "${times_args[@]}" --filter "$suites" "${selection[@]}" "${verbose[@]}"
