import AppKit
import Observation
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Each turn draws in a hosting view of its own (`ConversationTurnHost`): a streamed fragment of words
/// goes to the running turn's message alone, a transcript's or a Codex thread's, and leaves every
/// turn's graph as it was (`ConversationStreamedText`), a conversation shown again finds its turns
/// kept with its task, and a change in how the conversation looks reaches every turn.
@MainActor
final class ConversationTurnHostTests: XCTestCase {
    @Observable
    final class Feed {
        var entries: [TranscriptEntry]
        var isShown = true
        var scheme: ColorScheme = .light
        init(_ entries: [TranscriptEntry]) { self.entries = entries }
    }

    private struct Host: View {
        let feed: Feed
        let renderState: ConversationRenderState
        var body: some View {
            Group {
                if feed.isShown {
                    TaskConversationView(harness: .claudeCode, workspaceURL: LongConversationFixture.workspace,
                                         entries: feed.entries, sessionStatus: .running, renderState: renderState)
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
        return (feed, host, answer)
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
        feed.isShown = false
        host.settle(passes: 4)
        feed.isShown = true
        host.settle(passes: 6)
        XCTAssertEqual(ViewBodyCensus[.conversationTurnHosting], 0, "No turn view was made again")
        XCTAssertEqual(ViewBodyCensus[.conversationTurn], 0, "No kept turn was drawn again")
        let texts = TranscriptProseRenderingTests.proseTextViews(in: host.hosting)
        XCTAssertTrue(texts.contains { $0.string.contains("Done in turn 3") }, "The kept turns are in the window again")
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
