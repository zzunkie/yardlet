import AppKit
import XCTest
@testable import NativeHarnessClient

/// The part of `ConversationBlankFrameTests` that runs with the quick tests: the conversation never
/// draws blank while the person switches between loaded tasks, and a task whose history is not read
/// yet says it is loading until the history draws. They mount the same whole window
/// (`ConversationBlankFrameTests.makeWindow`) and read every frame it commits; the scenarios that
/// stream, fold, read back through long conversations or toggle the rail stay in
/// `ConversationBlankFrameTests`.
@MainActor
final class ConversationSwitchFrameTests: XCTestCase {
    /// Loaded tasks of every length and harness, opened one after another and back and forth quickly.
    func testSwitchingTasksNeverDrawsABlankConversation() throws {
        let window = try ConversationBlankFrameTests.makeWindow(
            [.claude("Short", turns: 2), .claude("Long", turns: 90), .codex("Codex", turns: 60)], for: self)
        defer { window.close() }
        window.show(0)
        window.measure("switch to a long task") { window.select(1) }
        window.measure("switch to a short task") { window.select(0) }
        window.measure("switch to a long Codex task") { window.select(2) }
        window.measure("switch back and forth quickly", seconds: 0) {
            for step in 0..<9 { window.probe.run("open \(step % 3)", for: 0.06) { window.select(step % 3) } }
            window.probe.run("settle", for: 1.2)
        }
        window.report()
    }

    /// A Claude Code task opened for the first time this launch, with nothing in Yardlet's reading
    /// cache: its conversation is read from Claude Code's file. Until it arrives the conversation
    /// says it is loading — never "Start a conversation", which reads as an empty task — and the read
    /// starts as the task is chosen, not once its surface has been built.
    func testOpeningATaskWhoseHistoryIsNotReadYetShowsItLoading() throws {
        let window = try ConversationBlankFrameTests.makeWindow(
            [.claude("Short", turns: 3), .savedClaude("Saved", turns: 80)], for: self)
        defer { window.close() }
        window.show(0)
        var sawEmptyState = false, sawLoading = false
        window.measure("open a task whose history is not read yet", seconds: 0, loads: true) {
            window.select(1)
            window.probe.run("opened", for: 0.016)
            // What the conversation says while its history is on its way.
            let shown = window.host.accessibilityElements(visibleOnly: true).map(\.description)
            sawEmptyState = shown.contains { $0.contains(L10n.string("Start a conversation")) }
            sawLoading = shown.contains { $0.contains(L10n.string("Loading conversation")) }
            window.readUntilDrawn(then: 1.5)
        }
        let firstDrawn = window.probe.frames.first { $0.ink >= BlankFrameProbe.blankInk }
        print("[blank-frames] conversation drew after \(Int((firstDrawn?.time ?? -1) * 1000)) ms")
        XCTAssertFalse(sawEmptyState, "A task with history read as empty while it loaded")
        XCTAssertTrue(sawLoading, "The conversation said it was loading")
        XCTAssertNotNil(firstDrawn, "The conversation drew once its history arrived")
        XCTAssertGreaterThanOrEqual(window.conversationInk, BlankFrameProbe.blankInk)
        // Once it drew, it never went blank again.
        let drawn = window.probe.frames.drop { $0.ink < BlankFrameProbe.blankInk }
        XCTAssertFalse(drawn.contains { $0.ink < BlankFrameProbe.blankInk }, window.probe.summary)
    }
}
