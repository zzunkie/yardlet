#!/bin/zsh
# The conversation's tests again with the eager stack (`ConversationRowListSwitch` off), while the stack
# can still be turned back on in place of the row list that draws conversations: a change to the
# conversation that breaks only the stack shows here, though every other run draws the row list. CI runs
# it after scripts/test-fast.sh, and it goes away with the stack.
# `-v` prints every test's output, `--filter` and `--skip` narrow the selection as for scripts/test-fast.sh.
# On a Mac it first waits for the shared heavy-build lock (scripts/heavy-lock.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
arguments=("$@")
# The classes that draw conversations, and of the prose's rendering tests the one that does: the rest
# draw a message alone, the same with either renderer.
suites='\.(ConversationBlankFrame|ConversationFind|ConversationSelection|TranscriptReading|TranscriptAutoFollow|ConversationTopLoading|ConversationSendJump|ConversationSwitchFrame|ConversationTurnWindowRendering|ConversationTurnHost|ConversationReopenGap|CodexTimelineReading|CodexTimelineNavigation|ConversationAnchorMigration|StreamingWindowRedraw|ConversationFollowUpPlacement|TaskWorkspaceRestoration|ConversationScrollOverCodeBlock)Tests/|\.TranscriptProseRenderingTests/testGoingToAMatchInATextOrATableBringsItToTheMiddle$'
selection=()
verbose=()
while (( $# )); do
  case $1 in
    -v|--verbose) verbose=(-v) ;;
    --filter|--skip)
      (( $# >= 2 )) || { print -u2 "test-conversation-stack.sh: $1 needs a value"; exit 2; }
      selection+=("$1" "$2")
      shift ;;
    *) print -u2 "test-conversation-stack.sh: unknown option $1"; exit 2 ;;
  esac
  shift
done
source scripts/heavy-lock.sh && take_heavy_lock "${0:A}" "${arguments[@]}"

swift build --build-system native --build-tests -j 4
bundles=("$(swift build --build-system native --show-bin-path)"/*PackageTests.xctest(N))
(( ${#bundles} == 1 )) || { print -u2 "test-conversation-stack.sh: expected one test bundle, found ${#bundles}"; exit 1; }
tests=$(mktemp -t yardlet-conversation-stack-tests)
trap 'rm -f "$tests"' EXIT
swift test --build-system native list --skip-build --disable-swift-testing > "$tests"
export YARDLET_CONVERSATION_ROW_LIST=0
python3 -I scripts/xctest-batches.py --bundle "$bundles[1]" --tests "$tests" --filter "$suites" \
  "${selection[@]}" "${verbose[@]}"
