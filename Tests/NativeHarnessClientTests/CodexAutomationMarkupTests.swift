import Foundation
import XCTest
@testable import NativeHarnessClient

/// The Codex app's markup read the way the app reads it: an
/// automation's heartbeat and its reply, a skipped run, the directives the app does not show, and how
/// a long sent message clips. Every text here is made up in the shape of the real ones.
final class CodexAutomationMarkupTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - The heartbeat a scheduled task sends

    private let heartbeat = """
    <heartbeat>
      <automation_id>nightly-build-check</automation_id>
      <current_time_iso>2026-10-13T09:00:00Z</current_time_iso>
      <instructions>
    Look at the nightly build.
    Tell me only if something failed.
      </instructions>
    </heartbeat>
    """

    func testAHeartbeatIsItsInstructionsWithItsAutomationAndTime() throws {
        let message = try XCTUnwrap(ConversationScheduledTaskMessage.parse(heartbeat))
        XCTAssertEqual(message.instructions, "Look at the nightly build.\nTell me only if something failed.")
        XCTAssertEqual(message.automationID, "nightly-build-check")
        XCTAssertEqual(message.currentTimeISO, "2026-10-13T09:00:00Z")
        // Space around the element is no part of it.
        XCTAssertEqual(ConversationScheduledTaskMessage.parse("\n  \(heartbeat)\n\n"), message)
    }

    func testAHeartbeatNeedsItsTimeAndInstructionsButNotItsAutomation() throws {
        let anonymous = "<heartbeat><current_time_iso>t</current_time_iso><instructions>Check</instructions></heartbeat>"
        XCTAssertEqual(ConversationScheduledTaskMessage.parse(anonymous),
                       ConversationScheduledTaskMessage(instructions: "Check", automationID: nil, currentTimeISO: "t"))
        XCTAssertNil(ConversationScheduledTaskMessage.parse(
            "<heartbeat><automation_id>a</automation_id><instructions>Check</instructions></heartbeat>"))
        XCTAssertNil(ConversationScheduledTaskMessage.parse(
            "<heartbeat><automation_id>a</automation_id><current_time_iso>t</current_time_iso></heartbeat>"))
        // Empty instructions are still a heartbeat; the bubble then has nothing to show.
        XCTAssertEqual(ConversationScheduledTaskMessage.parse(
            "<heartbeat><current_time_iso>t</current_time_iso><instructions>  </instructions></heartbeat>")?.instructions, "")
    }

    func testAHeartbeatIsReadAsTheAppReadsItsTags() throws {
        // The inner tags match without regard to case and the first of each counts; the outer tag is
        // matched as written.
        let mixed = """
        <heartbeat><CURRENT_TIME_ISO>t</CURRENT_TIME_ISO><Instructions>First</Instructions>\
        <instructions>Second</instructions></heartbeat>
        """
        XCTAssertEqual(ConversationScheduledTaskMessage.parse(mixed)?.instructions, "First")
        XCTAssertNil(ConversationScheduledTaskMessage.parse(heartbeat.replacingOccurrences(of: "heartbeat>", with: "HEARTBEAT>")))
    }

    func testMalformedOrPartialHeartbeatsAreText() {
        let unclosed = "<heartbeat><current_time_iso>t</current_time_iso><instructions>Check the build"
        let unclosedInstructions = "<heartbeat><current_time_iso>t</current_time_iso><instructions>Check</heartbeat>"
        for text in [unclosed, unclosedInstructions, "<heartbeat></heartbeat>", "", "heartbeat"] {
            XCTAssertNil(ConversationScheduledTaskMessage.parse(text), text)
        }
    }

    func testAHeartbeatInsideOtherTextIsNotOne() {
        XCTAssertNil(ConversationScheduledTaskMessage.parse("What does this do?\n\(heartbeat)"))
        XCTAssertNil(ConversationScheduledTaskMessage.parse("\(heartbeat)\nWhy did it fire twice?"))
        XCTAssertNil(ConversationScheduledTaskMessage.parse("```xml\n\(heartbeat)\n```"))
    }

    // MARK: - The reply

    private let notify = """
    <heartbeat>
      <automation_id>nightly-build-check</automation_id>
      <decision>NOTIFY</decision>
      <message>The nightly build failed in the parser tests.</message>
    </heartbeat>
    """
    private let quiet = """
    <heartbeat>
      <automation_id>nightly-build-check</automation_id>
      <decision>DONT_NOTIFY</decision>
      <message>The build is still green.</message>
    </heartbeat>
    """

    func testAReplyIsItsDecisionWordsAndMessage() throws {
        let bare = try XCTUnwrap(CodexHeartbeatReply.parse(notify))
        XCTAssertEqual(bare, CodexHeartbeatReply(decision: .notify, visibleText: "",
                                                 notificationMessage: "The nightly build failed in the parser tests."))
        let withWords = try XCTUnwrap(CodexHeartbeatReply.parse("Two tests broke overnight.\n\n\(notify)"))
        XCTAssertEqual(withWords.visibleText, "Two tests broke overnight.")
        let fenced = try XCTUnwrap(CodexHeartbeatReply.parse("Two tests broke.\n```xml\n\(quiet)\n```"))
        XCTAssertEqual(fenced.decision, .dontNotify)
        XCTAssertEqual(fenced.visibleText, "Two tests broke.")
        // The decision's case does not matter; a CDATA message is read out of its section; the last
        // element decides.
        let cdata = "<heartbeat><decision>dont_notify</decision><message><![CDATA[ All quiet ]]></message></heartbeat>"
        XCTAssertEqual(CodexHeartbeatReply.parse(cdata),
                       CodexHeartbeatReply(decision: .dontNotify, visibleText: "", notificationMessage: "All quiet"))
        XCTAssertEqual(CodexHeartbeatReply.parse("\(quiet)\n\(notify)")?.decision, .notify)
    }

    func testAReplyWithoutADecisionOrElementIsNotOne() {
        XCTAssertNil(CodexHeartbeatReply.parse("<heartbeat><message>Hi</message></heartbeat>"))
        XCTAssertNil(CodexHeartbeatReply.parse("All fine."))
        XCTAssertNil(CodexHeartbeatReply.parse("<heartbeat><decision>NOTIFY</decision>"), "an unclosed element")
        XCTAssertNil(CodexHeartbeatReply.parse("DONT_NOTIFY"))
        // In a heartbeat's turn a bare quiet decision is a reply, alone or in a padded CDATA section.
        XCTAssertEqual(CodexHeartbeatReply.parseInHeartbeatTurn(" DONT_NOTIFY\n")?.decision, .dontNotify)
        XCTAssertEqual(CodexHeartbeatReply.parseInHeartbeatTurn("<![CDATA[ DONT_NOTIFY ]]>")?.decision, .dontNotify)
        XCTAssertNil(CodexHeartbeatReply.parseInHeartbeatTurn("NOTIFY"))
    }

    func testACodexReplyShowsItsWordsElseItsMessage() {
        func shown(_ text: String, inHeartbeatTurn: Bool = false, streaming: Bool = false) -> String? {
            ConversationAutomationText.agentMessage(text, harness: .codex, inHeartbeatTurn: inHeartbeatTurn,
                                                    isStreaming: streaming)
        }
        XCTAssertEqual(shown(notify), "The nightly build failed in the parser tests.")
        XCTAssertEqual(shown(quiet), "The build is still green.")
        XCTAssertEqual(shown("Two tests broke overnight.\n\n\(notify)"), "Two tests broke overnight.")
        XCTAssertEqual(shown("<heartbeat><decision>DONT_NOTIFY</decision></heartbeat>"),
                       L10n.string("Heartbeat completed quietly."))
        XCTAssertNil(shown("<heartbeat><decision>NOTIFY</decision></heartbeat>"), "nothing to show")
        // Outside a heartbeat's turn, XML without a decision and a bare decision are the model's text.
        let undecided = "<heartbeat><message>Hi</message></heartbeat>"
        XCTAssertEqual(shown(undecided), undecided)
        XCTAssertEqual(shown("DONT_NOTIFY"), "DONT_NOTIFY")
        // In one, they read as the app reads them.
        XCTAssertEqual(shown(undecided, inHeartbeatTurn: true), "Hi")
        XCTAssertEqual(shown("DONT_NOTIFY", inHeartbeatTurn: true), L10n.string("Heartbeat completed quietly."))
        XCTAssertEqual(shown("Checked again.\n\(undecided)", inHeartbeatTurn: true), "Checked again.")
    }

    func testAReplyBeingWrittenStopsWhereItsXMLBegins() {
        func shown(_ text: String, inHeartbeatTurn: Bool) -> String? {
            ConversationAutomationText.agentMessage(text, harness: .codex, inHeartbeatTurn: inHeartbeatTurn,
                                                    isStreaming: true)
        }
        XCTAssertEqual(shown("The build failed.\n<heartbeat>\n  <decision>NO", inHeartbeatTurn: true), "The build failed.")
        XCTAssertEqual(shown("The build failed.\n<heart", inHeartbeatTurn: true), "The build failed.")
        XCTAssertEqual(shown("The build failed.\n```xml\n<heartbeat><decision>", inHeartbeatTurn: true), "The build failed.")
        XCTAssertEqual(shown("The build failed.\n```x", inHeartbeatTurn: true), "The build failed.")
        // A fence that closes one already open is the model's text.
        XCTAssertEqual(shown("```swift\nlet a = 1\n```", inHeartbeatTurn: true), "```swift\nlet a = 1\n```")
        XCTAssertNil(shown("<heartbeat><decision>NOTIFY</deci", inHeartbeatTurn: true), "nothing written yet")
        // Outside a heartbeat's turn the app reads nothing of a message until it is written.
        XCTAssertEqual(shown("Partial <heartbeat><decision>NOTIFY", inHeartbeatTurn: false),
                       "Partial <heartbeat><decision>NOTIFY")
    }

    func testOtherHarnessesReadOnlyExactlyAReply() {
        func shown(_ text: String) -> String? {
            ConversationAutomationText.agentMessage(text, harness: .claudeCode, inHeartbeatTurn: true, isStreaming: false)
        }
        XCTAssertEqual(shown("  \(notify)\n"), "The nightly build failed in the parser tests.")
        XCTAssertEqual(shown("Two tests broke.\n\(notify)"), "Two tests broke.\n\(notify)")
        XCTAssertEqual(shown("DONT_NOTIFY"), "DONT_NOTIFY")
        XCTAssertEqual(shown("```xml\n\(notify)\n```"), "```xml\n\(notify)\n```")
        // Directives are the Codex app's; another harness's text keeps them.
        XCTAssertEqual(shown("Done.\n::git-commit{cwd=\"/tmp/a\"}"), "Done.\n::git-commit{cwd=\"/tmp/a\"}")
    }

    func testASkippedRunReadsNoUpdateOnceWritten() {
        for harness in [HarnessKind.codex, .claudeCode] {
            XCTAssertEqual(ConversationAutomationText.agentMessage(
                ":: SKIP_COMPLETION ::", harness: harness, inHeartbeatTurn: false, isStreaming: false
            ), L10n.string("No update from this run"))
            XCTAssertNil(ConversationAutomationText.agentMessage(
                "::SKIP_COMPLETION::", harness: harness, inHeartbeatTurn: false, isStreaming: true
            ))
        }
        XCTAssertEqual(ConversationAutomationText.agentMessage(
            "Skipped: ::SKIP_COMPLETION::", harness: .codex, inHeartbeatTurn: false, isStreaming: false
        ), "Skipped: ::SKIP_COMPLETION::")
    }

    // MARK: - Directives

    func testTheDirectivesTheAppActsOnAreLeftOut() {
        func shown(_ text: String, streaming: Bool = false) -> String {
            CodexDirectiveMarkup.displayText(text, isStreaming: streaming)
        }
        XCTAssertEqual(shown("Fixed the flaky test.\n\n::inbox-item{title=\"Fix flaky test\" summary=\"Ready for review\"}"),
                       "Fixed the flaky test.")
        XCTAssertEqual(shown("""
        Pushed the branch.

        ::git-stage{cwd="/tmp/repo"}
        ::git-commit{cwd="/tmp/repo"}
        ::git-push{cwd="/tmp/repo" branch="fix/parser"}

        The pull request is next.
        """), "Pushed the branch.\n\nThe pull request is next.")
        // Braces inside a quoted value, a label, and spaces before or after the directive.
        XCTAssertEqual(shown("A\n  ::inbox-item[Note]{title=\"a } b\" summary=\"c\"}  \nB"), "A\nB")
        XCTAssertEqual(shown("Charted it.\n::codex-live-vis{}"), "Charted it.")
        // A finished message keeps its review comments for their card; one being written leaves them out.
        let comment = "::code-comment{title=\"Off by one\" body=\"Use <=\" file=\"a.swift\" start=3}"
        XCTAssertEqual(shown(comment), comment)
        XCTAssertEqual(shown("Reviewed.\n\(comment)", streaming: true), "Reviewed.")
    }

    func testOtherDirectivesAndLookalikesStayText() {
        let kept = [
            "::archive{reason=\"done\"}",
            "::codex-inline-vis{file=\"chart.html\"}",
            ":::inbox-item{title=\"a\"}",
            "    ::inbox-item{title=\"indented code\"}",
            "::inbox-item{title=\"a\"} and some words",
            "::inbox-item{title=\"unclosed\"",
            "Use `::inbox-item{title=\"x\"}` to file one.",
            "```\n::git-commit{cwd=\"/tmp/repo\"}\n```",
            "~~~md\n::inbox-item{title=\"a\"}\n~~~"
        ]
        for text in kept {
            XCTAssertEqual(CodexDirectiveMarkup.displayText(text, isStreaming: false), text, text)
        }
        // After a closed fence, a directive is a directive again.
        XCTAssertEqual(CodexDirectiveMarkup.displayText("```\ncode\n```\n::git-commit{cwd=\"/a\"}", isStreaming: false),
                       "```\ncode\n```")
    }

    func testADirectiveBeingWrittenIsLeftOutBeforeItIsWhole() {
        func shown(_ text: String) -> String { CodexDirectiveMarkup.displayText(text, isStreaming: true) }
        XCTAssertEqual(shown("Working on it\n::git-com"), "Working on it")
        XCTAssertEqual(shown("Working on it\n::"), "Working on it")
        XCTAssertEqual(shown("Working on it\n::inbox-item{title=\"half"), "Working on it")
        XCTAssertEqual(shown("Working on it\n::zebra"), "Working on it\n::zebra")
        XCTAssertEqual(shown("::git-commit{cwd=\"/a\"}\nStill working"), "Still working")
    }

    func testACodexMessageOfOnlyDirectivesShowsNothing() {
        XCTAssertNil(ConversationAutomationText.agentMessage(
            "::git-stage{cwd=\"/a\"}\n::git-commit{cwd=\"/a\"}", harness: .codex, inHeartbeatTurn: false, isStreaming: false
        ))
        // A reply's words are Markdown too.
        XCTAssertEqual(ConversationAutomationText.agentMessage(
            "Filed it.\n::inbox-item{title=\"t\" summary=\"s\"}\n\(notify)", harness: .codex, inHeartbeatTurn: true,
            isStreaming: false
        ), "Filed it.")
    }

    // MARK: - Projections

    func testACodexThreadDrawsItsHeartbeatTurnAsTheAppDoes() throws {
        let state = codexThread(turns: [
            turn("turn-1", items: [user("u1", heartbeat), agent("a1", "final_answer", notify)]),
            turn("turn-2", items: [user("u2", heartbeat), agent("a2", "final_answer", quiet)]),
            turn("turn-3", items: [user("u3", "What failed?"),
                                   agent("a3", "final_answer", "The parser.\n\n::inbox-item{title=\"Parser\" summary=\"Fix\"}")])
        ])
        let presentation = CodexConversationProjection.presentation(
            state, workspaceURL: URL(filePath: "/tmp/qa"), historySelection: nil
        )
        let scheduled = try XCTUnwrap(ConversationScheduledTaskMessage.parse(heartbeat))
        XCTAssertEqual(presentation.turns.map { $0.prompt.map(\.kind) }, [
            [.scheduledTaskMessage(scheduled)], [.scheduledTaskMessage(scheduled)],
            [.userMessage(text: "What failed?", images: [])]
        ])
        XCTAssertEqual(presentation.turns.map { $0.answers.map(\.kind) }, [
            [.answer(text: "The nightly build failed in the parser tests.", isStreaming: false)],
            [.answer(text: "The build is still green.", isStreaming: false)],
            [.answer(text: "The parser.", isStreaming: false)]
        ])
        // The record stays reachable: "Copy item details" still carries the reply as Codex wrote it.
        XCTAssertTrue(presentation.turns[0].answers[0].copyDetails?.contains("<decision>NOTIFY</decision>") == true)
        // Find reads what is drawn.
        let units = ConversationFindSource.conversation(presentation).units
        XCTAssertEqual(units.first?.body, .plain(scheduled.instructions))
        XCTAssertFalse(units.contains { unit in
            switch unit.body {
            case let .plain(text), let .markdown(text, _): text.contains("<heartbeat>") || text.contains("::inbox-item")
            }
        })
    }

    func testARunningHeartbeatTurnThinksUntilItsReplyHasWords() {
        var state = codexThread(turns: [
            turn("turn-1", status: "inProgress", items: [user("u1", heartbeat),
                                                        agent("a1", "final_answer", "<heartbeat>\n  <decision>NOT")])
        ])
        state.thread?.turns[0].items[1].lifecycle = .inProgress
        let running = CodexConversationProjection.presentation(state, workspaceURL: URL(filePath: "/tmp/qa"),
                                                               historySelection: nil).turns[0]
        XCTAssertEqual(running.answers, [])
        XCTAssertEqual(running.progress, .thinking)

        state.thread?.turns[0].items[1] = agent("a1", "final_answer", "The build broke.\n<heartbeat>\n  <decision>NOT")
        state.thread?.turns[0].items[1].lifecycle = .inProgress
        let writing = CodexConversationProjection.presentation(state, workspaceURL: URL(filePath: "/tmp/qa"),
                                                               historySelection: nil).turns[0]
        XCTAssertEqual(writing.answers.map(\.kind), [.answer(text: "The build broke.", isStreaming: true)])
        XCTAssertEqual(writing.progress, .none)
    }

    func testADetachedCodexTranscriptReadsTheSame() throws {
        let entries = [
            entry(0, .user(text: heartbeat)),
            entry(1, .assistant(text: "Checking the build.", isStreaming: false)),
            entry(2, .assistant(text: quiet, isStreaming: false)),
            entry(3, .user(text: "And now?")),
            entry(4, .assistant(text: "Done.\n::git-commit{cwd=\"/tmp/repo\"}", isStreaming: false))
        ]
        let turns = TranscriptConversationProjection.presentation(
            from: entries, harness: .codex, status: .ready, latestTurnIsComplete: true
        ).turns
        XCTAssertEqual(turns[0].prompt.map(\.kind), [.scheduledTaskMessage(try XCTUnwrap(ConversationScheduledTaskMessage.parse(heartbeat)))])
        // A transcript carries no phases, so what was said before the last message is said to the person.
        XCTAssertEqual(turns[0].work.map(\.kind), [.answer(text: "Checking the build.", isStreaming: false)])
        XCTAssertEqual(turns[0].answers.map(\.kind), [.answer(text: "The build is still green.", isStreaming: false)])
        XCTAssertEqual(turns[1].answers.map(\.kind), [.answer(text: "Done.", isStreaming: false)])
    }

    func testAnotherHarnessReadsOnlyTheExactShapes() throws {
        let entries = [
            entry(0, .user(text: heartbeat)),
            entry(1, .assistant(text: notify, isStreaming: false)),
            entry(2, .user(text: "Why did this fire?\n\(heartbeat)")),
            entry(3, .assistant(text: "It runs hourly.\n\(quiet)", isStreaming: false))
        ]
        let turns = TranscriptConversationProjection.presentation(
            from: entries, harness: .claudeCode, status: .ready, latestTurnIsComplete: true
        ).turns
        XCTAssertEqual(turns[0].prompt.map(\.kind), [.scheduledTaskMessage(try XCTUnwrap(ConversationScheduledTaskMessage.parse(heartbeat)))])
        XCTAssertEqual(turns[0].answers.map(\.kind),
                       [.answer(text: "The nightly build failed in the parser tests.", isStreaming: false)])
        XCTAssertEqual(turns[1].prompt.map(\.kind), [.userMessage(text: "Why did this fire?\n\(heartbeat)", images: [])])
        XCTAssertEqual(turns[1].answers.map(\.kind), [.answer(text: "It runs hourly.\n\(quiet)", isStreaming: false)])
    }

    // MARK: - Clipping a long sent message

    func testASentMessageClipsPastTwentyLinesAndAHeartbeatPastTwo() {
        let sent = ConversationMessageClip.sentMessage
        XCTAssertEqual(sent.lineCount, 20)
        XCTAssertEqual(sent.visibleLineCount, 19)
        XCTAssertTrue(sent.showsEllipsisLine)
        let scheduled = ConversationMessageClip.scheduledTaskMessage
        XCTAssertEqual(scheduled.visibleLineCount, 2)
        XCTAssertFalse(scheduled.showsEllipsisLine)

        let twentyFive = (1...25).map { "Line \($0)" }.joined(separator: "\n")
        let folded = sent.prefix(of: twentyFive)
        XCTAssertFalse(folded.isWhole)
        XCTAssertEqual(folded.text, (1...20).map { "Line \($0)" }.joined(separator: "\n"))
        XCTAssertTrue(sent.clips(isWhole: folded.isWhole, height: 0, heightAtLineCount: 0), "more lines than it lays out")

        let twenty = (1...20).map { "Line \($0)" }.joined(separator: "\n")
        XCTAssertEqual(sent.prefix(of: twenty).text, twenty)
        XCTAssertTrue(sent.prefix(of: twenty + "\n  \n").isWhole, "spaces after the last line are nothing more")
        XCTAssertEqual(scheduled.prefix(of: "One\nTwo\nThree").text, "One\nTwo")

        // One long line is laid out only as far as the lines a folded message can show.
        let long = String(repeating: "word ", count: 4_000)
        let longFolded = sent.prefix(of: long)
        XCTAssertFalse(longFolded.isWhole)
        XCTAssertEqual(longFolded.text.count, 20 * ConversationMessageClip.charactersPerLine)

        // A whole text clips only when it runs taller than its lines by more than a point.
        XCTAssertFalse(sent.clips(isWhole: true, height: 400, heightAtLineCount: 400))
        XCTAssertFalse(sent.clips(isWhole: true, height: 400.5, heightAtLineCount: 400))
        XCTAssertTrue(sent.clips(isWhole: true, height: 420, heightAtLineCount: 400))
        XCTAssertFalse(sent.clips(isWhole: true, height: 420, heightAtLineCount: 0), "not measured yet")
    }

    // MARK: - Fixtures

    private func entry(_ seconds: TimeInterval, _ content: TranscriptEntryContent) -> TranscriptEntry {
        TranscriptEntry(createdAt: start.addingTimeInterval(seconds), content: content)
    }

    private let decoder = CodexTaskDecoder()

    private func user(_ id: String, _ text: String) -> CodexItemState {
        decoder.item(from: .object([
            "id": .string(id), "type": .string("userMessage"),
            "content": .array([.object(["type": .string("text"), "text": .string(text)])])
        ]), fallbackID: id, lifecycle: .completed)
    }

    private func agent(_ id: String, _ phase: String, _ text: String) -> CodexItemState {
        decoder.item(from: .object([
            "id": .string(id), "type": .string("agentMessage"), "text": .string(text), "phase": .string(phase)
        ]), fallbackID: id, lifecycle: .completed)
    }

    private func turn(_ id: String, status: String = "completed", items: [CodexItemState]) -> CodexTurnState {
        var turn = decoder.turn(from: .object(["id": .string(id), "status": .string(status), "items": .array([])]),
                                fallbackID: id)!
        turn.items = items
        return turn
    }

    private func codexThread(turns: [CodexTurnState]) -> CodexTaskState {
        var thread = decoder.thread(from: .object(["id": .string("thread-markup")]))!
        thread.turns = turns
        return CodexTaskState(thread: thread)
    }
}
