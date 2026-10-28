import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// M12f (D12): every harness's conversation in one look, the Codex timeline's: its turn and item
/// spacing, its sent bubble in the conversation font (which follows the interface size), one "Show
/// more" length, a provider's working notes captioned "Commentary", and "Thinking" under a turn
/// that has not written yet.
///
/// The same conversation drawn as a Codex thread and as a Claude Code and an OpenCode (ACP)
/// transcript must draw the same pixels; only what the provider itself offers differs (a turn menu
/// where the provider has one, a running turn's live time where the provider reports it). Review
/// images go to `.build/conversation-m12f-qa/`.
@MainActor
final class ConversationOneLookTests: XCTestCase {
    private let decoder = CodexTaskDecoder()
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private static let workspace = URL(filePath: "/tmp/yardlet-one-look", directoryHint: .isDirectory)

    // MARK: - The same conversation in every harness

    /// One finished turn — a request, thinking, working notes and an answer — draws the same pixels
    /// whichever harness it came from, at both widths and in both appearances. Codex and Claude Code
    /// both offer their turn's actions on its messages, out of sight until hovered; OpenCode offers
    /// none, so it is compared with Claude Code without them.
    func testOneFinishedTurnDrawsTheSamePixelsInEveryHarness() throws {
        let directory = try WindowlessRender.directory("conversation-m12f-qa")
        for width in [720, 1_100] {
            for appearance in WindowlessRender.Appearance.allCases {
                let size = NSSize(width: width, height: 640)
                let codex = try ConversationDrawing.draw(
                    ConversationTimeline(source: .codex(finishedThread(), workspaceURL: Self.workspace,
                                                        historySelection: nil),
                                         actions: ConversationActions(forkCodexTurn: { _ in })),
                    size: size, appearance: appearance
                )
                let claude = try ConversationDrawing.draw(
                    transcript(.claudeCode, finishedEntries(), status: .ready, actions: claudeActions()),
                    size: size, appearance: appearance
                )
                let claudeWithoutMenu = try ConversationDrawing.draw(
                    transcript(.claudeCode, finishedEntries(), status: .ready), size: size, appearance: appearance
                )
                let opencode = try ConversationDrawing.draw(
                    transcript(.openCode, finishedEntries(), status: .ready), size: size, appearance: appearance
                )
                let label = "\(width) \(appearance.suffix)"
                for (name, drawing) in [("codex", codex), ("claude-code", claude), ("opencode", opencode)] {
                    try WindowlessRender.writePNG(drawing.capture.bitmap, to: directory.appending(
                        path: "same-turn-\(name)-\(appearance.suffix)-\(width).png"))
                }
                XCTAssertEqual(ConversationDrawing.differingBytes(codex.capture.bitmap, claude.capture.bitmap), 0,
                               "Codex and Claude Code draw the same turn differently (\(label))")
                XCTAssertEqual(
                    ConversationDrawing.differingBytes(claudeWithoutMenu.capture.bitmap, opencode.capture.bitmap), 0,
                    "Claude Code and OpenCode draw the same turn differently (\(label))"
                )
                // The same elements, the provider's name aside.
                XCTAssertEqual(named(codex.elements), named(claude.elements), label)
                XCTAssertEqual(named(claudeWithoutMenu.elements), named(opencode.elements), label)
            }
        }
    }

    /// A running turn that has not written yet reads "Thinking", and once it writes, its working notes
    /// read "Commentary" with no harness label, for every harness. The two
    /// transcript harnesses draw it in the same pixels; Codex adds the live time it reports.
    func testARunningTurnReadsTheSameInEveryHarness() throws {
        let directory = try WindowlessRender.directory("conversation-m12f-qa")
        let size = NSSize(width: 760, height: 520)
        for (stage, entries, codex) in [
            ("thinking", runningEntries(writing: false), runningThread(writing: false)),
            ("writing", runningEntries(writing: true), runningThread(writing: true))
        ] {
            let claude = try ConversationDrawing.draw(transcript(.claudeCode, entries, status: .running),
                                                     size: size, appearance: .light)
            let opencode = try ConversationDrawing.draw(transcript(.openCode, entries, status: .running),
                                                       size: size, appearance: .light)
            let thread = try ConversationDrawing.draw(
                ConversationTimeline(source: .codex(codex, workspaceURL: Self.workspace, historySelection: nil)),
                size: size, appearance: .light
            )
            XCTAssertEqual(ConversationDrawing.differingBytes(claude.capture.bitmap, opencode.capture.bitmap), 0, stage)
            for (name, drawing) in [("codex", thread), ("claude-code", claude), ("opencode", opencode)] {
                try WindowlessRender.writePNG(drawing.capture.bitmap,
                                              to: directory.appending(path: "running-\(stage)-\(name)-light.png"))
                let texts = drawing.elements.map(\.description).joined(separator: "\n")
                // The live line reads "Thinking", then the turn's steps and time where the header
                // does not read them (2026-10-16, `ConversationLiveWork`).
                let thinking = drawing.elements.contains {
                    $0.value == L10n.string("Thinking") || $0.value.hasPrefix(L10n.string("Thinking") + ", ")
                }
                XCTAssertEqual(thinking, stage == "thinking", "\(name) \(stage):\n\(texts)")
                XCTAssertEqual(drawing.elements.contains { $0.value == L10n.string("Commentary") },
                               stage == "writing", "\(name) \(stage):\n\(texts)")
                XCTAssertFalse(drawing.elements.contains { $0.role == "AXUnknown" && $0.label == name }, texts)
            }
        }
    }

    /// A turn's error is what the turn ended on, so its card reads after everything the turn wrote, for
    /// every harness, while the turn still streams as well (a Codex error was drawn under the turn's
    /// header, above the work it streamed). The card offers Retry only for an error its provider says
    /// can pass, on a turn that has ended: Codex's busy server, not its sign-in failure; Claude Code's
    /// API error the adapter read as transient, not any other.
    func testATurnsErrorComesAfterWhatTheTurnWroteAndOffersRetryOnlyWhenItCanPass() throws {
        let directory = try WindowlessRender.directory("conversation-m12f-qa")
        let size = NSSize(width: 760, height: 520)
        let wrote = "Running the tests first."
        let actions = ConversationActions(retryTurn: { _ in })
        func failedThread(_ errorInfo: String, status: String = "failed") -> CodexTaskState {
            var state = thread(turn: [
                "id": .string("turn-1"), "status": .string(status),
                "items": .array([
                    .object(["id": .string("u1"), "type": .string("userMessage"),
                             "content": .array([.object(["type": .string("text"), "text": .string(sentText)])])]),
                    .object(["id": .string("m1"), "type": .string("agentMessage"), "text": .string(wrote),
                             "phase": .string("commentary")])
                ]),
                "error": .object(["message": .string("The request could not be completed."),
                                  "codexErrorInfo": .string(errorInfo)])
            ])
            state.thread?.status = status == "failed" ? .idle : .active(flags: [])
            return state
        }
        func failedEntries(transient: Bool?) -> [TranscriptEntry] {
            [TranscriptEntry(createdAt: start, content: .user(text: sentText)),
             TranscriptEntry(createdAt: start.addingTimeInterval(1), content: .assistant(text: wrote, isStreaming: false)),
             TranscriptEntry(createdAt: start.addingTimeInterval(2), content: .error(
                message: "API Error: 529 Overloaded", recoverable: true, transient: transient))]
        }
        let cases: [(name: String, view: AnyView, title: String, retries: Bool)] = [
            ("codex-busy", AnyView(ConversationTimeline(
                source: .codex(failedThread("serverOverloaded"), workspaceURL: Self.workspace, historySelection: nil),
                actions: actions)), L10n.string("Server is busy."), true),
            // The final `error` notification reaches the turn before `turn/completed` does.
            ("codex-streaming", AnyView(ConversationTimeline(
                source: .codex(failedThread("serverOverloaded", status: "inProgress"), workspaceURL: Self.workspace,
                               historySelection: nil),
                actions: actions)), L10n.string("Server is busy."), false),
            ("codex-signed-out", AnyView(ConversationTimeline(
                source: .codex(failedThread("unauthorized"), workspaceURL: Self.workspace, historySelection: nil),
                actions: actions)), L10n.format("%@ could not complete the request", HarnessKind.codex.displayName), false),
            ("claude-code-busy", AnyView(transcript(.claudeCode, failedEntries(transient: true), status: .failed,
                                                    actions: actions)),
             L10n.format("%@ could not complete the request", HarnessKind.claudeCode.displayName), true),
            ("claude-code-failed", AnyView(transcript(.claudeCode, failedEntries(transient: nil), status: .failed,
                                                      actions: actions)),
             L10n.format("%@ could not complete the request", HarnessKind.claudeCode.displayName), false)
        ]
        for (name, view, title, retries) in cases {
            for appearance in WindowlessRender.Appearance.allCases {
                let drawing = try ConversationDrawing.draw(view, size: size, appearance: appearance)
                try WindowlessRender.writePNG(drawing.capture.bitmap,
                                              to: directory.appending(path: "error-\(name)-\(appearance.suffix).png"))
                let texts = drawing.elements.map(\.description).joined(separator: "\n")
                let written = drawing.elements.firstIndex { $0.label.contains(wrote) || $0.value.contains(wrote) }
                let card = drawing.elements.firstIndex { $0.label == title || $0.value == title }
                let retry = drawing.elements.firstIndex { $0.role == "AXButton" && $0.label == L10n.string("Retry") }
                guard let written, let card else { return XCTFail("\(name): the turn's words and its error card\n\(texts)") }
                XCTAssertLessThan(written, card, "\(name):\n\(texts)")
                XCTAssertEqual(retry != nil, retries, "\(name):\n\(texts)")
                if let retry { XCTAssertGreaterThan(retry, card, "\(name):\n\(texts)") }
            }
        }
    }

    /// The sent bubble follows the interface size setting for every harness, Codex included (it was
    /// a fixed 13 pt in the Codex timeline).
    func testTheSentMessageFollowsTheInterfaceSize() throws {
        func drawnHeight(_ view: some View, scale: CGFloat) throws -> Int {
            let drawing = try ConversationDrawing.draw(
                view.environment(\.yardletInterfaceScale, scale), size: NSSize(width: 760, height: 400),
                appearance: .light
            )
            return try nonCanvasRows(drawing.capture.bitmap)
        }
        let codex = ConversationTimeline(source: .codex(sentOnlyThread(), workspaceURL: Self.workspace,
                                                        historySelection: nil))
        let claude = transcript(.claudeCode, [TranscriptEntry(createdAt: start, content: .user(text: sentText))],
                                status: .ready)
        // The Codex turn adds its header under the message (its menu and status), so the two grow by
        // the same amount rather than standing as tall.
        let codexGrowth = try drawnHeight(codex, scale: 1.3) - drawnHeight(codex, scale: 1)
        let claudeGrowth = try drawnHeight(claude, scale: 1.3) - drawnHeight(claude, scale: 1)
        XCTAssertGreaterThan(codexGrowth, 0, "the Codex sent message ignores the interface size")
        XCTAssertGreaterThan(claudeGrowth, 0, "the Claude Code sent message ignores the interface size")
        XCTAssertEqual(codexGrowth, claudeGrowth)
    }

    /// A long answer shows its first 5,000 characters and "Show more" in every harness (the shared
    /// transcript showed 32,000).
    func testALongAnswerFoldsAtTheSameLengthInEveryHarness() throws {
        let answer = (1...140).map { "Line \($0) of a long answer that keeps going past the fold." }.joined(separator: " ")
        XCTAssertGreaterThan(answer.count, ConversationLayout.messageCharacterLimit)
        let entries = [
            TranscriptEntry(createdAt: start, content: .user(text: "Explain it at length")),
            TranscriptEntry(createdAt: start.addingTimeInterval(3), content: .assistant(text: answer, isStreaming: false))
        ]
        var thread = finishedThread()
        thread.thread?.turns[0].items = [
            item(.object(["id": .string("u1"), "type": .string("userMessage"),
                          "content": .array([.object(["type": .string("text"), "text": .string("Explain it at length")])])])),
            item(.object(["id": .string("a1"), "type": .string("agentMessage"), "text": .string(answer),
                          "phase": .string("final_answer")]))
        ]
        let views: [(String, AnyView)] = [
            ("codex", AnyView(ConversationTimeline(source: .codex(thread, workspaceURL: Self.workspace,
                                                                  historySelection: nil)))),
            ("claude-code", AnyView(transcript(.claudeCode, entries, status: .ready))),
            ("opencode", AnyView(transcript(.openCode, entries, status: .ready)))
        ]
        for (name, view) in views {
            let drawing = try ConversationDrawing.draw(view, size: NSSize(width: 760, height: 3_000), appearance: .light)
            XCTAssertTrue(drawing.elements.contains { $0.label == L10n.string("Show more") },
                          "\(name) shows the whole answer")
        }
    }

    // MARK: - Review renders

    /// The three harnesses' richer conversations, as a person reviews them: the Codex visual fixture,
    /// a Claude Code task waiting on its requests, and the OpenCode task of the harness fixture, at
    /// 720 and 1,100 wide in both appearances (`.build/conversation-m12f-qa/<harness>-<appearance>-<width>.png`).
    func testReviewRenders() throws {
#if DEBUG
        let directory = try WindowlessRender.directory("conversation-m12f-qa")
        var actions = ClaudeConversationFixture.actions()
        actions.branch = { _ in }
        let opencode = ConversationFixtures.harnessTranscripts()
        let opencodeSession = try XCTUnwrap(opencode.sessions.first { $0.harness == .openCode })
        let opencodeEntries = try XCTUnwrap(opencode.transcripts[opencodeSession.id])
        let renders: [(String, AnyView, CGFloat)] = [
            ("codex", AnyView(ConversationTimeline(
                source: .codex(ConversationFixtures.codexTimeline(), workspaceURL: ConversationFixtures.workspace,
                               historySelection: nil),
                actions: ConversationActions(retryTurn: { _ in }, forkCodexTurn: { _ in }, implementCodexPlan: { _ in })
            )), 4_400),
            ("claude-code", AnyView(TaskConversationView(
                harness: .claudeCode, workspaceURL: ClaudeConversationFixture.workspace,
                entries: ClaudeConversationFixture.waiting(), sessionStatus: .waitingForApproval, actions: actions
            ).environment(\.claudeShellCommands, ClaudeConversationFixture.shellCommands())), 3_000),
            ("opencode", AnyView(TaskConversationView(
                harness: .openCode, workspaceURL: ConversationFixtures.workspace, entries: opencodeEntries,
                sessionStatus: opencodeSession.status,
                latestTurnIsComplete: opencodeSession.completionState == .completed,
                actions: ConversationActions(chooseOption: { _, _ in }, answer: { _, _ in })
            )), 1_700)
        ]
        for (name, view, height) in renders {
            for width in [720, 1_100] {
                for appearance in WindowlessRender.Appearance.allCases {
                    let drawing = try ConversationDrawing.draw(
                        view.environment(\.transcriptWorkspaceURL, ClaudeConversationFixture.workspace),
                        size: NSSize(width: CGFloat(width), height: height), appearance: appearance
                    )
                    try WindowlessRender.writePNG(drawing.capture.bitmap, to: directory.appending(
                        path: "\(name)-\(appearance.suffix)-\(width).png"))
                    let texts = drawing.elements.map(\.description).joined(separator: "\n")
                    XCTAssertTrue(drawing.elements.contains { $0.role == "AXGroup" && $0.label == L10n.string("You") },
                                  "\(name):\n\(texts)")
                }
            }
        }
#endif
    }

    // MARK: - Fixtures

    private let sentText = "Fix the failing build and tell me what broke"

    /// A request, thinking, working notes and an answer, over two seconds.
    private func finishedEntries() -> [TranscriptEntry] {
        [
            TranscriptEntry(createdAt: start, content: .user(text: sentText)),
            TranscriptEntry(createdAt: start.addingTimeInterval(0.5),
                            content: .reasoning(text: "The cache is stale.", isStreaming: false)),
            TranscriptEntry(createdAt: start.addingTimeInterval(1),
                            content: .assistant(text: "Running the tests first.", isStreaming: false)),
            TranscriptEntry(createdAt: start.addingTimeInterval(2), content: .assistant(
                text: "The build passes now. **The cache** was stale; `swift test` ran cleanly.", isStreaming: false
            ))
        ]
    }

    private func finishedThread() -> CodexTaskState {
        thread(turn: [
            "id": .string("turn-1"), "status": .string("completed"), "durationMs": .integer(2_000),
            "items": .array([
                .object(["id": .string("u1"), "type": .string("userMessage"),
                         "content": .array([.object(["type": .string("text"), "text": .string(sentText)])])]),
                .object(["id": .string("r1"), "type": .string("reasoning"), "summary": .array([]),
                         "content": .array([.string("The cache is stale.")])]),
                .object(["id": .string("m1"), "type": .string("agentMessage"), "text": .string("Running the tests first."),
                         "phase": .string("commentary")]),
                .object(["id": .string("a1"), "type": .string("agentMessage"),
                         "text": .string("The build passes now. **The cache** was stale; `swift test` ran cleanly."),
                         "phase": .string("final_answer")])
            ])
        ])
    }

    private func sentOnlyThread() -> CodexTaskState {
        thread(turn: [
            "id": .string("turn-1"), "status": .string("completed"),
            "items": .array([.object(["id": .string("u1"), "type": .string("userMessage"),
                                      "content": .array([.object(["type": .string("text"), "text": .string(sentText)])])])])
        ])
    }

    private func runningEntries(writing: Bool) -> [TranscriptEntry] {
        var entries = [TranscriptEntry(createdAt: start, content: .user(text: sentText))]
        if writing {
            entries.append(TranscriptEntry(createdAt: start.addingTimeInterval(1),
                                           content: .assistant(text: "Running the tests first.", isStreaming: true)))
        }
        return entries
    }

    private func runningThread(writing: Bool) -> CodexTaskState {
        var items: [JSONValue] = [.object(["id": .string("u1"), "type": .string("userMessage"),
                                           "content": .array([.object(["type": .string("text"), "text": .string(sentText)])])])]
        if writing {
            items.append(.object(["id": .string("m1"), "type": .string("agentMessage"),
                                  "text": .string("Running the tests first."), "phase": .string("commentary")]))
        }
        var state = thread(turn: ["id": .string("turn-1"), "status": .string("inProgress"), "items": .array(items)])
        if writing, let index = state.thread?.turns[0].items.indices.last {
            state.thread?.turns[0].items[index].lifecycle = .inProgress
        }
        return state
    }

    private func thread(turn: [String: JSONValue]) -> CodexTaskState {
        var thread = decoder.thread(from: .object(["id": .string("thread-one-look")]))!
        thread.turns = [decoder.turn(from: .object(turn), fallbackID: "turn-1")!]
        return CodexTaskState(thread: thread)
    }

    private func item(_ value: JSONValue) -> CodexItemState {
        decoder.item(from: value, fallbackID: "item", lifecycle: .completed)
    }

    private func transcript(
        _ harness: HarnessKind, _ entries: [TranscriptEntry], status: SessionStatus,
        actions: ConversationActions = ConversationActions()
    ) -> some View {
        ConversationTimeline(
            source: .transcript(entries: entries, harness: harness, status: status,
                                latestTurnIsComplete: status == .ready),
            actions: actions
        )
    }

    /// Claude Code's turn menu: its edit, file restore and fork of the latest turn.
    private func claudeActions() -> ConversationActions {
        var actions = ConversationActions(rewind: ConversationRewindActions(
            beginCodexEdit: { _ in }, beginClaudeEdit: { _ in }, cancelEdit: {}, loadFilePoints: { [] },
            previewFiles: { _ in throw CancellationError() }, restoreFiles: { _ in throw CancellationError() }
        ))
        actions.branch = { _ in }
        return actions
    }

    /// The elements with every harness's name read as one.
    private func named(_ elements: [WindowlessRender.AccessibilityElement]) -> [String] {
        let names = Set(HarnessCatalog.builtIns.map(\.displayName))
        return elements.map { element in
            names.contains(element.label)
                ? WindowlessRender.AccessibilityElement(role: element.role, label: "<harness>", value: element.value)
                    .description
                : element.description
        }
    }

    /// The rows of `bitmap` that hold anything but the canvas: the height of what was drawn.
    private func nonCanvasRows(_ bitmap: NSBitmapImageRep) throws -> Int {
        let background = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0))
        var rows = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                if let color = bitmap.colorAt(x: x, y: y), color != background { rows += 1; break }
            }
        }
        return rows
    }
}
