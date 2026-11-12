import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Renders Claude's follow-up queue offscreen into `.build/claude-followup-qa`: a message Claude
/// Code holds, one Yardlet holds and a failed one, running and paused; and a follow-up Claude read
/// in the middle of a turn, as the conversation shows it. No provider, window server interaction or
/// app launch is involved.
@MainActor
final class ClaudeFollowUpRenderingTests: XCTestCase {
    func testClaudesQueueShowsWhatClaudeHoldsWhatWaitsAndThePause() throws {
        let directory = try WindowlessRender.directory("claude-followup-qa")
        let queue = [
            CodexQueuedSubmission(draft: CodexComposerDraft(inputs: [.text("Use Python instead")]), state: .sent,
                                  providerMessageID: UUID().uuidString.lowercased()),
            CodexQueuedSubmission(draft: CodexComposerDraft(inputs: [.text("Then update the README")])),
            CodexQueuedSubmission(draft: CodexComposerDraft(inputs: [.text("And bump the version")]), state: .failed,
                                  failureMessage: "Claude Code did not take this message.")
        ]
        for (paused, appearance) in [(false, ColorScheme.light), (true, .dark), (false, .dark)] {
            let composer = PromptComposer(
                harness: .claudeCode, composerDraft: TaskComposerDraft(),
                isRunning: !paused, canSteer: !paused, codexQueue: paused ? Array(queue.dropFirst()) : queue,
                isCodexQueuePaused: paused,
                actions: ComposerActions(
                    submitFollowUp: { _, _ in }, removeQueued: { _ in }, retryQueued: { _ in },
                    moveQueued: { _, _ in }, sendQueuedNow: { _ in }, editQueued: { _ in nil }, resumeQueue: {}
                )
            )
            .frame(width: 900)
            .background(ParityTheme.canvas)
            .environment(\.colorScheme, appearance)
            let bitmap = try render(composer, size: NSSize(width: 900, height: 220))
            let name = "composer-queue-\(paused ? "paused" : "running")-\(appearance == .dark ? "dark" : "light").png"
            try WindowlessRender.writePNG(bitmap, to: directory.appending(path: name))
        }
    }

    /// A follow-up Claude read while it worked is drawn once, where Claude read it: after the work it
    /// interrupted and before the reply, in the running turn, as the Codex app keeps a steered message
    /// (D13).
    func testAFollowUpClaudeReadMidTurnIsDrawnWhereItWasRead() throws {
        let directory = try WindowlessRender.directory("claude-followup-qa")
        let entries = [
            TranscriptEntry(content: .user(text: "Port the script to Swift")),
            TranscriptEntry(content: .assistant(text: "Reading the script first.", isStreaming: false)),
            TranscriptEntry(content: .activity(HarnessActivity(id: "toolu_read", kind: "Read", title: "Read",
                                                               input: "script.sh"), state: .completed)),
            TranscriptEntry(content: .user(text: "Use Python instead"), joinsRunningTurn: true),
            TranscriptEntry(content: .assistant(text: "Switching to Python.", isStreaming: true))
        ]
        for appearance in WindowlessRender.Appearance.allCases {
            // The messages' copy actions show only on hover; the drawing shows them to count them.
            let drawing = try ConversationDrawing.draw(
                TaskConversationView(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/yardlet"),
                                     entries: entries, sessionStatus: .running)
                    .environment(\.revealsSentMessageActions, true),
                size: NSSize(width: 760, height: 520), appearance: appearance
            )
            try WindowlessRender.writePNG(drawing.capture.bitmap,
                                          to: directory.appending(path: "conversation-read-\(appearance.suffix).png"))
            let texts = drawing.elements.map(\.description)
            XCTAssertEqual(texts.filter { $0.contains("Use Python instead") }.count, 1, texts.joined(separator: "\n"))
            let request = try XCTUnwrap(texts.firstIndex { $0.contains("Port the script to Swift") })
            let followUp = try XCTUnwrap(texts.firstIndex { $0.contains("Use Python instead") })
            let reply = try XCTUnwrap(texts.firstIndex { $0.contains("Switching to Python.") })
            XCTAssertLessThan(request, followUp)
            XCTAssertLessThan(followUp, reply)
            let read = try XCTUnwrap(texts.firstIndex { $0.contains("script.sh") || $0.contains("“Read”") })
            XCTAssertLessThan(read, followUp, "after the work it interrupted")
            // One turn (no rail), still running: the reply is in progress, with no copy button yet.
            XCTAssertFalse(drawing.elements.contains { ConversationDrawing.isRailTurn($0.label) },
                           texts.joined(separator: "\n"))
            XCTAssertEqual(texts.filter { $0.contains(L10n.string("Copy response")) }.count, 1,
                           texts.joined(separator: "\n"))
        }
    }

    /// The queue-or-steer menu's rows, laid out as its popover lays them out, with the key that sends
    /// each way: by default Return sends now (Codex's Steer, Claude Code's Send now) and ⌘Return
    /// queues; with Queue set in Settings, the other way round (2026-10-16).
    func testTheQueueOrSteerMenuShowsTheKeyForEachWay() throws {
        let directory = try WindowlessRender.directory("composer-stream-qa")
        for (policy, preferred) in [(FollowUpPolicy.claudeCode, FollowUpMode.steer), (.claudeCode, .queue),
                                    (.codex, .steer)] {
            let name = "queue-or-steer-\(policy == .codex ? "codex" : "claude")-\(preferred.rawValue)"
            try WindowlessRender.hostedInBothAppearances(name, in: directory, size: NSSize(width: 300, height: 90)) {
                VStack(alignment: .leading, spacing: 4) {
                    Button {} label: {
                        ComposerFollowUpMenuRow(title: FollowUpPolicy.afterTurnPhrase, systemImage: "text.append",
                                                key: preferred == .queue ? "↩" : "⌘↩")
                    }
                    .buttonStyle(.borderless)
                    Button {} label: {
                        ComposerFollowUpMenuRow(title: policy.steerPhrase ?? "", systemImage: "arrow.turn.up.right",
                                                key: preferred == .steer ? "↩" : "⌘↩")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(8)
                .frame(minWidth: 150, alignment: .leading)
                .fixedSize()
                .background(ParityTheme.input)
                .environment(\.colorScheme, $0.colorScheme)
                .frame(width: 300, height: 90)
                .background(ParityTheme.canvas)
            }
        }
    }

    private func render<Content: View>(_ view: Content, size: NSSize) throws -> NSBitmapImageRep {
        try WindowlessRender.hosted(view, size: size, passes: 6).bitmap
    }
}
