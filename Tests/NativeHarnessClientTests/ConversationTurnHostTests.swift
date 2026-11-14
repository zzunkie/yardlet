import AppKit
import Observation
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Each turn draws in a hosting view of its own (`ConversationTurnHost`): a streamed fragment of words
/// goes to the running turn's message alone, a transcript's or a Codex thread's, leaves every turn's
/// graph as it was (`ConversationStreamedText`) and lays the conversation out a time or two, a
/// conversation shown again finds its turns kept with its task, a change in how the conversation
/// looks reaches every turn, and the task's limit state only the turn that draws a limit card.
@MainActor
final class ConversationTurnHostTests: XCTestCase {
    @Observable
    final class Feed {
        var entries: [TranscriptEntry]
        var isShown = true
        var scheme: ColorScheme = .light
        var notices: TaskProviderNotices?
        init(_ entries: [TranscriptEntry]) { self.entries = entries }
    }

    private struct Host: View {
        let feed: Feed
        let renderState: ConversationRenderState
        var body: some View {
            Group {
                if feed.isShown {
                    TaskConversationView(harness: .claudeCode, workspaceURL: LongConversationFixture.workspace,
                                         entries: feed.entries, sessionStatus: .running,
                                         actions: ConversationActions(providerNotices: feed.notices), renderState: renderState)
                } else {
                    Color.clear
                }
            }
            .environment(\.colorScheme, feed.scheme)
            .frame(width: 900, height: 700)
        }
    }

    private func makeHost(finishedTurns: Int) -> (Feed, WindowlessRender.Host<Host>, TranscriptEntry) {
        var entries = LongConversationFixture.claude(turns: finishedTurns)
        entries.append(TranscriptEntry(content: .user(text: "Write up what changed")))
        let answer = TranscriptEntry(content: .assistant(text: "Working", isStreaming: true))
        entries.append(answer)
        let feed = Feed(entries)
        return (feed, mount(feed), answer)
    }

    private func mount(_ feed: Feed) -> WindowlessRender.Host<Host> {
        let host = WindowlessRender.Host(Host(feed: feed, renderState: ConversationRenderState()),
                                         size: NSSize(width: 900, height: 700), appearance: .light)
        host.settle(passes: 20)
        ViewBodyCensus.isEnabled = true
        ViewBodyCensus.reset()
        addTeardownBlock { @MainActor in
            ViewBodyCensus.isEnabled = false
            ViewBodyCensus.reset()
            host.close()
        }
        return host
    }

    func testAFragmentGoesToTheRunningMessageAndDrawsNoTurnAgain() {
        let (feed, host, answer) = makeHost(finishedTurns: 9)
        var text = "Working"
        for fragment in 0..<20 {
            text += " word\(fragment)"
            feed.entries[feed.entries.count - 1] = TranscriptEntry(
                id: answer.id, createdAt: answer.createdAt, content: .assistant(text: text, isStreaming: true))
            host.settle(passes: 1, interval: 0.005)
        }
        XCTAssertEqual(ViewBodyCensus[.conversationTurn], 0, "A fragment of words drew a turn whole")
        XCTAssertEqual(ViewBodyCensus[.conversationTurnHosting], 0)
        // The running turn's live line keeps its time without a `TimelineView`, which had each fragment
        // lay the conversation out again a dozen times or more: 41 times for these 20, 249 to 308 with one.
        XCTAssertLessThanOrEqual(ViewBodyCensus[.conversationLayout], 80, "A fragment laid the conversation out again and again")
        let texts = TranscriptProseRenderingTests.proseTextViews(in: host.hosting)
        XCTAssertTrue(texts.contains { $0.string == text }, "The running message reads its latest words")
    }

    @Observable
    final class CodexFeed {
        var state: CodexTaskState
        init(_ state: CodexTaskState) { self.state = state }
    }

    private struct CodexHost: View {
        let feed: CodexFeed
        let renderState: ConversationRenderState
        var body: some View {
            TaskConversationView(harness: .codex, workspaceURL: LongConversationFixture.workspace, entries: [],
                                 sessionStatus: .running, codexTaskState: feed.state, renderState: renderState)
                .frame(width: 900, height: 700)
        }
    }

    /// A Codex answer written after many calls: its fragments go to the message alone, as a
    /// transcript's do, and a call the turn adds after it draws the turn whole.
    func testACodexFragmentGoesToTheRunningMessageAndANewCallDrawsTheTurn() {
        let running = LongConversationFixture.runningCodexTurn(1, request: "Write up what changed", calls: 40, paragraphs: 1)
        var state = LongConversationFixture.codex(threadID: "thread-host", turns: [LongConversationFixture.codexTurn(0), running])
        let turn = 1, answer = state.thread!.turns[turn].items.count - 1
        // The answer is being written, as the App Server's first delta leaves it.
        state.thread!.turns[turn].items[answer].lifecycle = .inProgress
        let feed = CodexFeed(state)
        let host = WindowlessRender.Host(CodexHost(feed: feed, renderState: ConversationRenderState()),
                                         size: NSSize(width: 900, height: 700), appearance: .light)
        host.settle(passes: 20)
        ViewBodyCensus.isEnabled = true
        ViewBodyCensus.reset()
        addTeardownBlock { @MainActor in
            ViewBodyCensus.isEnabled = false
            ViewBodyCensus.reset()
            host.close()
        }
        var text = "Working"
        for fragment in 0..<20 {
            text += " word\(fragment)"
            guard case var .agentMessage(message) = feed.state.thread!.turns[turn].items[answer].content else {
                return XCTFail("The answer is not a message")
            }
            message.text = text
            feed.state.thread!.turns[turn].items[answer].content = .agentMessage(message)
            host.settle(passes: 1, interval: 0.005)
        }
        XCTAssertEqual(ViewBodyCensus[.conversationTurn], 0, "A fragment of words drew a Codex turn whole")
        let texts = TranscriptProseRenderingTests.proseTextViews(in: host.hosting)
        XCTAssertTrue(texts.contains { $0.string == text }, "The running message reads its latest words")

        feed.state.thread!.turns[turn].items.append(CodexTaskDecoder().item(from: .object([
            "id": .string("command-after"), "type": .string("commandExecution"), "command": .string("swift build"),
            "cwd": .string(LongConversationFixture.workspace.path), "status": .string("inProgress")
        ]), fallbackID: "command-after", lifecycle: .inProgress))
        host.settle(passes: 6)
        XCTAssertEqual(ViewBodyCensus[.conversationTurn], 1, "A new call drew no turn, or more than its own")
    }

    func testAConversationShownAgainFindsItsTurnsKept() {
        let (feed, host, _) = makeHost(finishedTurns: 9)
        // The turns in the window: all the stack draws, or the row list's near its end.
        func texts() -> Set<String> { Set(TranscriptProseRenderingTests.proseTextViews(in: host.hosting).map(\.string)) }
        let drawn = texts()
        XCTAssertFalse(drawn.isEmpty)
        feed.isShown = false
        host.settle(passes: 4)
        feed.isShown = true
        host.settle(passes: 6)
        XCTAssertEqual(ViewBodyCensus[.conversationTurnHosting], 0, "No turn view was made again")
        XCTAssertEqual(ViewBodyCensus[.conversationTurn], 0, "No kept turn was drawn again")
        XCTAssertTrue(drawn.isSubset(of: texts()), "The kept turns are in the window again")
    }

    // MARK: - Turns out of view

    /// With VoiceOver or Switch Control on, every turn the conversation draws is in the window, and so
    /// in its accessibility tree, wherever the view is, as when the conversation was drawn whole; the row
    /// list otherwise keeps only the turns near its view.
    func testAnAssistiveAppFindsEveryTurnInTheWindow() {
        let isOn = ConversationAssistiveReading.isOn
        ConversationAssistiveReading.isOn = { true }
        defer { ConversationAssistiveReading.isOn = isOn }
        let (_, host, _) = makeHost(finishedTurns: 9)
        let texts = TranscriptProseRenderingTests.proseTextViews(in: host.hosting)
        for turn in 0..<9 {
            XCTAssertTrue(texts.contains { $0.string.hasPrefix(LongConversationFixture.request(turn)) }, "turn \(turn)")
        }
    }

    /// The turn that holds the window's first responder keeps its views in the window when the
    /// conversation scrolls far from it, so what it holds (a field being typed in, with its marked text)
    /// stays as it was.
    func testATurnHoldingTheFirstResponderStaysInTheWindowOutOfView() throws {
        let (_, host, _) = makeHost(finishedTurns: 9)
        let scroll = try XCTUnwrap(BlankFrameProbe.conversationScrollView(in: host.hosting))
        // To the conversation's top or its end, whichever way its document counts.
        func go(toTop top: Bool) {
            guard let document = scroll.documentView else { return }
            let end = max(0, document.frame.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: top == document.isFlipped ? 0 : end))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.settle(passes: 3)
        }
        go(toTop: true)
        var found: TranscriptProseTextView?
        host.settle {
            found = TranscriptProseRenderingTests.proseTextViews(in: host.hosting)
                .first { $0.string.hasPrefix(LongConversationFixture.request(0)) }
            return found != nil
        }
        let first = try XCTUnwrap(found)
        XCTAssertTrue(host.window.makeFirstResponder(first))
        go(toTop: false)
        XCTAssertNotNil(first.window, "The turn is still in the window")
        XCTAssertTrue(host.window.firstResponder === first, "It is still the first responder")
    }

    @Observable
    final class Shown {
        var taskID = UUID()
        var showsElsewhere = false
    }

    /// The window's view of a task, kept while another task is shown (`TaskSurfaceHost`), beside a
    /// second view of the same conversation (another task's side panel shows it as a tab).
    private struct KeptHost: View {
        let shown: Shown
        let taskID: UUID
        let entries: [TranscriptEntry]
        let renderState: ConversationRenderState
        let hostings: TaskSurfaceHostings

        var body: some View {
            HStack(spacing: 0) {
                TaskSurfaceHost(taskID: shown.taskID, hostings: hostings, content: AnyView(Group {
                    if shown.taskID == taskID { conversation } else { Color.clear }
                }))
                if shown.showsElsewhere { conversation }
            }
            .frame(width: 900, height: 700)
        }

        private var conversation: some View {
            TaskConversationView(harness: .claudeCode, workspaceURL: LongConversationFixture.workspace,
                                 entries: entries, sessionStatus: .completed, renderState: renderState)
        }
    }

    /// Another view of a conversation whose turns the window keeps in a hidden task's views makes turn
    /// views of its own, and the task shown again still draws its turns.
    func testAConversationShownElsewhereLeavesTheKeptViewsTheirTurns() {
        let shown = Shown()
        let taskID = shown.taskID
        let host = WindowlessRender.Host(
            KeptHost(shown: shown, taskID: taskID, entries: LongConversationFixture.claude(turns: 9),
                     renderState: ConversationRenderState(), hostings: TaskSurfaceHostings()),
            size: NSSize(width: 900, height: 700), appearance: .light)
        defer { host.close() }
        host.settle(passes: 20)
        // The turns in the window: all the stack draws, or the row list's near its end.
        func texts() -> Int { TranscriptProseRenderingTests.proseTextViews(in: host.hosting).count }
        let drawn = texts()
        XCTAssertGreaterThan(drawn, 0)

        ViewBodyCensus.isEnabled = true
        ViewBodyCensus.reset()
        defer {
            ViewBodyCensus.isEnabled = false
            ViewBodyCensus.reset()
        }
        shown.taskID = UUID()
        shown.showsElsewhere = true
        host.settle(passes: 10)
        XCTAssertEqual(ViewBodyCensus[.conversationTurnHosting], 9, "The second view built its own nine turns")

        shown.showsElsewhere = false
        shown.taskID = taskID
        host.settle(passes: 10)
        XCTAssertEqual(texts(), drawn, "The task shown again draws its turns")
    }

    /// The task's limit state reaches the turn that draws a limit card and no other. Whether the task
    /// can continue changes as each turn starts and ends, and a limit that is close is reported anew
    /// with every response and drawn above the composer: compared for every turn, each of them drew
    /// the ten turns of the window again.
    func testTheTasksLimitStateDrawsOnlyTheTurnWithALimitCard() {
        var entries = LongConversationFixture.claude(turns: 9)
        entries.append(TranscriptEntry(content: .user(text: "Write up what changed")))
        entries.append(TranscriptEntry(content: .usageLimit(HarnessRateLimit(status: .rejected, window: .session))))
        let feed = Feed(entries)
        feed.notices = TaskProviderNotices()
        let host = mount(feed)
        for used in [0.9, 0.91] {
            feed.notices?.limitWarning = HarnessRateLimit(status: .warning, window: .weekly, usedFraction: used)
            host.settle(passes: 4)
        }
        XCTAssertEqual(ViewBodyCensus[.conversationTurn], 0, "A limit that is close drew a turn again")
        feed.notices?.canContinue = true
        host.settle(passes: 4)
        XCTAssertEqual(ViewBodyCensus[.conversationTurn], 1, "Whether the task can continue is its limit card's to read")
    }

    func testAChangeInLookReachesEveryTurn() {
        let (feed, host, _) = makeHost(finishedTurns: 9)
        feed.scheme = .dark
        host.settle(passes: 6)
        XCTAssertEqual(ViewBodyCensus[.conversationTurn], 10, "The ten turns the window draws, drawn dark")
        let text = TranscriptProseRenderingTests.proseTextViews(in: host.hosting).first
        XCTAssertEqual(text?.superview?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
    }
}
