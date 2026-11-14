#!/bin/zsh
# The conversation's tests again with its row list on (`ConversationRowListSwitch`), while the row list
# and the eager stack both draw conversations: a change to the conversation that breaks only the row
# list shows here, though every other run draws the stack. CI runs it after scripts/test-fast.sh, and it
# goes away with the switch once the row list draws every conversation.
# `pending` names the tests the row list does not pass yet, as `Class/test`; it shrinks as the row list
# takes over what the stack does, and a test in it that passes fails the run, so the list stays true.
# `-v` prints every test's output, `--filter` and `--skip` narrow the selection as for scripts/test-fast.sh.
# On a Mac it first waits for the shared heavy-build lock (scripts/heavy-lock.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
arguments=("$@")
suites='\.(ConversationBlankFrame|ConversationFind|ConversationSelection|TranscriptReading|TranscriptAutoFollow|ConversationTopLoading|ConversationSendJump|ConversationSwitchFrame|ConversationTurnWindowRendering|ConversationTurnHost|ConversationReopenGap|CodexTimelineReading|CodexTimelineNavigation|ConversationAnchorMigration|StreamingWindowRedraw|ConversationFollowUpPlacement|TaskWorkspaceRestoration|TranscriptProseRendering|ConversationScrollOverCodeBlock)Tests/'
pending=(
  ConversationAnchorMigrationTests/testASavedClaudeWorkspaceReadsItsRowPlaceAsTheTurnThatHoldsIt
  ConversationAnchorMigrationTests/testASavedPlaceInATurnTheWindowLeavesOutWidensTheWindow
  ConversationBlankFrameTests/testOpeningASavedCodexTaskWithNoReadingCacheShowsItLoading
  ConversationBlankFrameTests/testReadingALongCodexThreadBackNeverDrawsABlankConversation
  ConversationBlankFrameTests/testReadingALongSavedConversationBackNeverDrawsABlankConversation
  ConversationBlankFrameTests/testStreamingAndFoldingWhileReadingTheRunningTurnNeverDrawsABlankConversation
  ConversationFindTests/testACodexMatchOutsideTheTurnWindowWidensItAndIsShown
  ConversationFindTests/testAMatchOutsideTheTurnWindowWidensItAndIsShown
  ConversationFindTests/testRendersTheFindBarAndItsMarksInBothConversations
  ConversationSendJumpTests/testSendingAfterPausingNearTheEndNeverDrawsABlankConversation
  ConversationSendJumpTests/testSendingFromEarlierTurnsNeverDrawsABlankConversation
  ConversationSwitchFrameTests/testATaskShownAgainKeepsItsOwnViewsAndPlace
  ConversationTopLoadingTests/testACodexPageAskedForAtTheTopArrivesWithoutMovingTheReader
  ConversationTopLoadingTests/testAMouseWheelToTheTopBringsEarlierTurnsIn
  ConversationTopLoadingTests/testAScrollThroughLaidOutTurnsDrawsNothingAgain
  ConversationTopLoadingTests/testScrollingToTheTopOfATranscriptBringsEarlierTurnsInOnceAndKeepsThePlace
  ConversationTopLoadingTests/testTheRailReadsMoreOfAClaudeFileAndKeepsThePlace
  ConversationTurnHostTests/testAConversationShownAgainFindsItsTurnsKept
  ConversationTurnHostTests/testAConversationShownElsewhereLeavesTheKeptViewsTheirTurns
  ConversationTurnWindowRenderingTests/testACodexThreadWindowsItsLoadedTurnsBeforeAskingForEarlierPages
  ConversationTurnWindowRenderingTests/testAHistoryResultOutsideTheWindowWidensIt
  ConversationTurnWindowRenderingTests/testALongRunningTurnIsDrawnInPartsThatReadAsOneTurn
  ConversationTurnWindowRenderingTests/testASavedCodexPlaceOutsideTheWindowWidensIt
  TranscriptProseRenderingTests/testGoingToAMatchInATextOrATableBringsItToTheMiddle
)
selection=()
verbose=()
while (( $# )); do
  case $1 in
    -v|--verbose) verbose=(-v) ;;
    --filter|--skip)
      (( $# >= 2 )) || { print -u2 "test-row-list.sh: $1 needs a value"; exit 2; }
      selection+=("$1" "$2")
      shift ;;
    *) print -u2 "test-row-list.sh: unknown option $1"; exit 2 ;;
  esac
  shift
done
source scripts/heavy-lock.sh && take_heavy_lock "${0:A}" "${arguments[@]}"

swift build --build-system native --build-tests -j 4
bundles=("$(swift build --build-system native --show-bin-path)"/*PackageTests.xctest(N))
(( ${#bundles} == 1 )) || { print -u2 "test-row-list.sh: expected one test bundle, found ${#bundles}"; exit 1; }
tests=$(mktemp -t yardlet-row-list-tests)
pending_tests=$(mktemp -t yardlet-row-list-pending)
trap 'rm -f "$tests" "$pending_tests"' EXIT
swift test --build-system native list --skip-build --disable-swift-testing > "$tests"
export YARDLET_CONVERSATION_ROW_LIST=1
skips=()
for test in "${pending[@]}"; do skips+=(--skip "\\.${test}\$"); done
python3 -I scripts/xctest-batches.py --bundle "$bundles[1]" --tests "$tests" --filter "$suites" "${skips[@]}" \
  "${selection[@]}" "${verbose[@]}"
(( ${#pending} )) || exit 0
# The pending tests, each expected to fail: one that passes comes off the list.
filters=()
for test in "${pending[@]}"; do filters+=(--filter "\\.${test}\$"); done
print "Pending with the row list (expected to fail):"
passed=()
python3 -I scripts/xctest-batches.py --bundle "$bundles[1]" --tests "$tests" "${filters[@]}" -v \
  > "$pending_tests" 2>&1 || true
for test in "${pending[@]}"; do
  grep -q -F "Test Case '-[NativeHarnessClientTests.${test/\// }]' passed" "$pending_tests" && passed+=("$test")
done
if (( ${#passed} )); then
  print -u2 "test-row-list.sh: these pass with the row list now; take them off \`pending\`: ${passed[*]}"
  exit 1
fi
print "${#pending} pending tests still fail with the row list."
