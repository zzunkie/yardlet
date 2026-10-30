import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// Suggested-task chips drawn by the one conversation renderer with no window on screen, into
/// `.build/task-suggestion-qa/`, light and dark:
///
/// - `claude-chips-*`: a finished Claude Code turn whose calls folded, and two consecutive
///   `spawn_task` calls left in view as one card, "2 suggested tasks", one in a worktree.
/// - `codex-chip-*`: a Codex thread's `yardlet` MCP call as one chip under "New session".
/// - `resolved-*`: three suggestions, one started ("Started", opens its task), one dismissed (gone).
/// - `progress-*`: one being started ("Starting…"), one whose start failed (why, under its summary,
///   with Options, Do it here and Start again), one sent here ("Sent to this session").
/// - `places-*`: where the agent said each starts — "Starts in web-app · In a worktree" and
///   "As a subtask of ‘<parent>’" — before the summary, and a worktree asked for outside Git: "Local",
///   quietly, with the settings.
/// - `options-popover-*`: Options — harness, account, where, Local or New worktree, model and
///   permissions, each a one-level menu, and Start — for a Claude task that bypasses permissions,
///   nested under ‘<parent>’.
/// - `options-outside-git-*`: the same for a folder outside Git the agent wanted a worktree in:
///   Local, quietly, with no menu to choose another.
@MainActor
final class TaskSuggestionRenderingTests: XCTestCase {
    private static let workspace = URL(filePath: "/work/uploader", directoryHint: .isDirectory)
    private static let started = UUID()

    func testClaudeChipsStayInViewAsOneCard() throws {
        let store = TaskSuggestionStore(repository: InMemoryTaskSuggestionRepository())
        let task = UUID()
        let entries = claudeEntries([chip(1, worktree: true), chip(2)])
        let drawings = try draw("claude-chips", height: 560) {
            ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .ready,
                                                     latestTurnIsComplete: true))
                .environment(\.taskSuggestionActions, actions(store: store, task: task))
        }
        for drawing in drawings {
            let texts = drawing.elements.map(\.description).joined(separator: "\n")
            for drawn in [L10n.format("%lld suggested tasks", 2), "Remove the dead retry flag", "Split UploadQueue.swift",
                          L10n.string("In a worktree"), L10n.string("Start"), L10n.string("Do it here"),
                          L10n.string("Options"),
                          L10n.format("Dismiss suggestion %@", "Remove the dead retry flag"),
                          "The retry flag is never read since the queue rewrite."] {
                XCTAssertTrue(texts.contains(drawn), "\(drawn) is not drawn:\n\(texts)")
            }
            XCTAssertFalse(texts.contains("mcp__yardlet__spawn_task"), texts)
            XCTAssertFalse(texts.contains("Delete `retryOnFailure`"), "The prompt waits behind the title:\n\(texts)")
        }
    }

    func testACodexCallIsOneChipUnderNewSession() throws {
        let store = TaskSuggestionStore(repository: InMemoryTaskSuggestionRepository())
        let drawings = try draw("codex-chip", height: 360) {
            ConversationTimeline(source: .codex(codexThread(), workspaceURL: Self.workspace, historySelection: nil),
                                 actions: ConversationActions(forkCodexTurn: { _ in }))
                .environment(\.taskSuggestionActions, actions(store: store, task: UUID()))
        }
        for drawing in drawings {
            let texts = drawing.elements.map(\.description).joined(separator: "\n")
            XCTAssertTrue(texts.contains(L10n.string("New session")), texts)
            XCTAssertTrue(texts.contains("Remove the dead retry flag"), texts)
        }
    }

    func testResolvedSuggestionsShowAsStartedOrAreGone() throws {
        let store = TaskSuggestionStore(repository: InMemoryTaskSuggestionRepository())
        let task = UUID()
        store.markStarted(chip(1).id, in: task, startedTaskID: Self.started)
        store.dismiss(chip(2).id, in: task)
        let entries = claudeEntries([chip(1), chip(2), chip(3)])
        let drawings = try draw("resolved", height: 420) {
            ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .ready,
                                                     latestTurnIsComplete: true))
                .environment(\.taskSuggestionActions, actions(store: store, task: task))
        }
        for drawing in drawings {
            let texts = drawing.elements.map(\.description).joined(separator: "\n")
            XCTAssertTrue(texts.contains(L10n.format("%lld started", 1)), texts)
            XCTAssertTrue(texts.contains(L10n.format("%@: %@", "Remove the dead retry flag", L10n.string("Started"))), texts)
            XCTAssertFalse(texts.contains("Split UploadQueue.swift"), "A dismissed chip is gone:\n\(texts)")
            XCTAssertTrue(texts.contains("Document the upload limits"), texts)
        }
    }

    func testStartingFailedAndSentHereRows() throws {
        let store = TaskSuggestionStore(repository: InMemoryTaskSuggestionRepository())
        let task = UUID()
        store.setProgress(.starting, of: chip(1).id, in: task)
        store.setProgress(.failed("Git could not make the worktree."), of: chip(2).id, in: task)
        store.markSentHere(chip(3).id, in: task)
        let entries = claudeEntries([chip(1), chip(2), chip(3)])
        let drawings = try draw("progress", height: 480) {
            ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .ready,
                                                     latestTurnIsComplete: true))
                .environment(\.taskSuggestionActions, actions(store: store, task: task))
        }
        for drawing in drawings {
            let texts = drawing.elements.map(\.description).joined(separator: "\n")
            XCTAssertTrue(texts.contains(L10n.format("%lld suggested tasks", 3)), texts)
            XCTAssertTrue(texts.contains(L10n.format("%@: %@", "Remove the dead retry flag",
                                                     L10n.string("taskSuggestion.starting"))), texts)
            XCTAssertTrue(texts.contains("Git could not make the worktree."), texts)
            XCTAssertTrue(texts.contains(L10n.format("%@: %@", "Document the upload limits",
                                                     L10n.string("Sent to this session"))), texts)
            XCTAssertEqual(texts.components(separatedBy: L10n.string("Do it here")).count - 1, 1,
                           "Only the failed one offers its buttons again:\n\(texts)")
        }

        // A card whose one suggestion went here is gone: the message in the conversation says it.
        let alone = TaskSuggestionStore(repository: InMemoryTaskSuggestionRepository())
        alone.markSentHere(chip(1).id, in: task)
        let single = try ConversationDrawing.draw(
            ConversationTimeline(source: .transcript(entries: claudeEntries([chip(1)]), harness: .claudeCode,
                                                     status: .ready, latestTurnIsComplete: true))
                .environment(\.taskSuggestionActions, actions(store: alone, task: task)),
            size: NSSize(width: 760, height: 360), appearance: .light)
        let texts = single.elements.map(\.description).joined(separator: "\n")
        XCTAssertFalse(texts.contains("Remove the dead retry flag"), texts)
        XCTAssertFalse(texts.contains(L10n.string("New session")), texts)
    }

    func testTheRowSaysWhereTheAgentSaidItStarts() throws {
        let store = TaskSuggestionStore(repository: InMemoryTaskSuggestionRepository())
        var actions = actions(store: store, task: UUID())
        let places: [String: TaskSuggestionStartPlace] = [
            chip(1).id: TaskSuggestionStartPlace(label: L10n.format("Starts in %@", "web-app"), startsInWorktree: true,
                                                 settings: "Claude Code · Opus High · " + L10n.string("Bypass permissions")),
            chip(2).id: TaskSuggestionStartPlace(label: L10n.format("As a subtask of ‘%@’", "CS replies"), startsInWorktree: false),
            // The agent asked for a worktree in a folder outside Git (`suggestedTaskSettingsLabel`).
            chip(3).id: TaskSuggestionStartPlace(startsInWorktree: false,
                                                 settings: L10n.string("Local") + " · Claude Code · Opus High")
        ]
        actions.startPlace = { places[$0.id] ?? TaskSuggestionStartPlace(startsInWorktree: false) }
        let drawings = try draw("places", height: 600) {
            ConversationTimeline(source: .transcript(entries: claudeEntries([chip(1), chip(2), chip(3, worktree: true)]),
                                                     harness: .claudeCode, status: .ready, latestTurnIsComplete: true))
                .environment(\.taskSuggestionActions, actions)
        }
        for drawing in drawings {
            let texts = drawing.elements.map(\.description).joined(separator: "\n")
            for drawn in [L10n.format("Starts in %@", "web-app") + " · " + L10n.string("In a worktree") + " · "
                            + "Claude Code · Opus High · " + L10n.string("Bypass permissions") + " · The retry flag",
                          L10n.format("As a subtask of ‘%@’", "CS replies") + " · The queue file"] {
                XCTAssertTrue(texts.contains(drawn), "\(drawn) is not drawn:\n\(texts)")
            }
        }
    }

    func testTheChipActs() throws {
        let store = TaskSuggestionStore(repository: InMemoryTaskSuggestionRepository())
        let task = UUID()
        let recorder = Recorder()
        var actions = actions(store: store, task: task)
        actions.start = { recorder.started.append($0) }
        actions.doHere = { recorder.here.append($0) }
        actions.optionsContext = { recorder.options.append($0); return nil }
        actions.openTask = { recorder.opened.append($0) }
        let view = ConversationTimeline(source: .transcript(entries: claudeEntries([chip(1, worktree: true), chip(2)]),
                                                            harness: .claudeCode, status: .ready, latestTurnIsComplete: true))
            .environment(\.taskSuggestionActions, actions)
            .environment(\.colorScheme, .light)
            .frame(width: 760, height: 560, alignment: .top)
            .background(ParityTheme.canvas)
        let host = WindowlessRender.Host(view, size: NSSize(width: 760, height: 560), appearance: .light)
        defer { host.close() }
        host.settle(passes: 10)

        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Start")))
        host.settle(passes: 2)
        XCTAssertEqual(recorder.started.map(\.id), [chip(1).id], "Start hands the window the first suggestion")
        XCTAssertEqual(recorder.started.first?.startsInNewWorktree, true)
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Do it here")))
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Options")))
        host.settle(passes: 2)
        XCTAssertEqual(recorder.here.map(\.id), [chip(1).id])
        XCTAssertEqual(recorder.options.map(\.id), [chip(1).id])

        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.format("Dismiss suggestion %@", "Split UploadQueue.swift")))
        host.settle(passes: 6)
        XCTAssertEqual(store.resolution(of: chip(2).id, in: task)?.outcome, .dismissed)
        let texts = host.accessibilityElements().map(\.description).joined(separator: "\n")
        XCTAssertFalse(texts.contains("Split UploadQueue.swift"), "The dismissed chip leaves at once:\n\(texts)")
        XCTAssertTrue(texts.contains(L10n.string("New session")), "One suggestion left: \(texts)")

        store.markStarted(chip(1).id, in: task, startedTaskID: Self.started)
        host.settle(passes: 6)
        XCTAssertTrue(host.hosting.pressAccessibilityElement(
            labelled: L10n.format("%@: %@", "Remove the dead retry flag", L10n.string("Started"))))
        host.settle(passes: 2)
        XCTAssertEqual(recorder.opened, [Self.started], "A started suggestion opens its task")
    }

    func testOptionsChooseWhatStartStartsWith() throws {
        let repository = URL(filePath: "/work/uploader", directoryHint: .isDirectory)
        let project = Project(name: "uploader", primaryRoot: repository)
        var saved: [TaskSuggestionStartChoice] = []
        var started: [TaskSuggestionStartChoice] = []
        let choice = TaskSuggestionStartChoice(
            harness: .claudeCode, providerOptions: ["model": "opus", "effort": "high", "permissionMode": "bypassPermissions"],
            place: SuggestedTaskPlace(folder: repository, project: project, startsInNewWorktree: true))
        let account = AccountChoice(harness: .claudeCode, connection: nil, snapshot: HarnessAccountSnapshot(
            id: "claude-code", harness: .claudeCode, providerID: nil, state: .signedIn, accountLabel: "you@example.com",
            detail: "", credentialOwner: "Claude Code", checkedAt: Date(), usage: [], canLogin: false, canLogout: false))
        var context = TaskSuggestionOptionsContext(
            choice: { choice }, parentLabel: L10n.format("As a subtask of ‘%@’", "CS replies"), projects: [project],
            harnesses: HarnessCatalog.builtIns.filter { [.claudeCode, .codex].contains($0.id) },
            models: NewTaskModelSource(catalogs: HarnessModelCatalogStore(locations: HarnessModelSettingsLocations(
                claudeConfigDirectory: URL(filePath: "/tmp/suggestion-options-none/claude"),
                codexHome: URL(filePath: "/tmp/suggestion-options-none/codex"),
                codexYardletHome: URL(filePath: "/tmp/suggestion-options-none/y")), environment: [:])) { _, _, _, _ in },
            accounts: { _ in [account] }, runtimeURL: { _ in URL(filePath: "/usr/bin/true") }, defaults: { _ in [:] },
            connection: { _ in nil }, isRepository: { _ in true }, chooseWorkspace: { _ in nil },
            save: { saved.append($0) }, start: { started.append($0) })
        let directory = try WindowlessRender.directory("task-suggestion-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            let view = TaskSuggestionOptionsPopover(context: context, dismiss: {})
                .background(ParityTheme.elevated)
                .environment(\.colorScheme, appearance.colorScheme)
            let host = WindowlessRender.Host(view, size: NSSize(width: 400, height: 340), appearance: appearance)
            defer { host.close() }
            host.settle(passes: 6, interval: 0.05)
            try WindowlessRender.writePNG(try host.capture().bitmap,
                                          to: directory.appending(path: "options-popover-\(appearance.suffix).png"))
            let texts = host.accessibilityElements().map(\.description).joined(separator: "\n")
            for drawn in [L10n.format("As a subtask of ‘%@’", "CS replies"), L10n.string("Harness"), L10n.string("Account"),
                          "you@example.com", L10n.string("taskSuggestion.where"), "uploader", L10n.string("Where to run"),
                          L10n.string("New worktree"), L10n.string("Permissions"), L10n.string("Bypass permissions"),
                          L10n.string("Start")] {
                XCTAssertTrue(texts.contains(drawn), "\(drawn) is not drawn:\n\(texts)")
            }
        }
        XCTAssertEqual(saved, [], "Opening it changes nothing")
        let host = WindowlessRender.Host(TaskSuggestionOptionsPopover(context: context, dismiss: {}),
                                         size: NSSize(width: 400, height: 340), appearance: .light)
        defer { host.close() }
        host.settle(passes: 6)
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Start")))
        host.settle(passes: 2)
        XCTAssertEqual(started, [choice], "Start starts with what it shows")

        // A folder outside Git the agent wanted a worktree in: Local, quietly, with no menu to choose.
        let notes = URL(filePath: "/work/notes", directoryHint: .isDirectory)
        let local = TaskSuggestionStartChoice(harness: .claudeCode, providerOptions: choice.providerOptions,
                                              place: SuggestedTaskPlace(folder: notes, project: nil, startsInNewWorktree: false))
        context.choice = { local }
        context.parentLabel = nil
        context.isRepository = { _ in false }
        context.asksForWorktree = true
        for appearance in WindowlessRender.Appearance.allCases {
            let view = TaskSuggestionOptionsPopover(context: context, dismiss: {})
                .background(ParityTheme.elevated)
                .environment(\.colorScheme, appearance.colorScheme)
            let host = WindowlessRender.Host(view, size: NSSize(width: 400, height: 300), appearance: appearance)
            defer { host.close() }
            host.settle(passes: 6, interval: 0.05)
            try WindowlessRender.writePNG(try host.capture().bitmap,
                                          to: directory.appending(path: "options-outside-git-\(appearance.suffix).png"))
            let texts = host.accessibilityElements().map(\.description).joined(separator: "\n")
            XCTAssertTrue(texts.contains(L10n.string("Where to run")) && texts.contains(L10n.string("Local")),
                          "Local is not drawn:\n\(texts)")
            XCTAssertFalse(texts.contains(L10n.string("New worktree")), "No worktree outside Git:\n\(texts)")
        }
    }

    // MARK: - Fixtures

    private func chip(_ number: Int, worktree: Bool = false) -> ConversationTaskSuggestion {
        let suggestions = [
            ("Remove the dead retry flag", "The retry flag is never read since the queue rewrite. The new task deletes it and its call sites.",
             "Delete `retryOnFailure` from Sources/Uploader/UploadOptions.swift and its two call sites."),
            ("Split UploadQueue.swift", "The queue file mixes scheduling and persistence. A separate task can split them without touching this fix.",
             "Split Sources/Uploader/UploadQueue.swift into a scheduler and a store."),
            ("Document the upload limits", "The 50 MB limit and retry backoff are only in code comments.",
             "Add a section on upload limits to docs/uploads.md.")
        ]
        let (title, tldr, prompt) = suggestions[number - 1]
        return ConversationTaskSuggestion(id: String(format: "task_0000000%d", number), title: title, tldr: tldr,
                                          prompt: prompt, startsInNewWorktree: worktree)
    }

    private func arguments(_ chip: ConversationTaskSuggestion) -> JSONValue {
        var object: [String: JSONValue] = ["title": .string(chip.title ?? ""), "tldr": .string(chip.tldr ?? ""),
                                           "prompt": .string(chip.prompt)]
        if chip.startsInNewWorktree { object["useWorktree"] = .bool(true) }
        return .object(object)
    }

    private func claudeEntries(_ chips: [ConversationTaskSuggestion]) -> [TranscriptEntry] {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        var offset = 0.0
        func entry(_ content: TranscriptEntryContent) -> TranscriptEntry {
            offset += 6
            return TranscriptEntry(createdAt: start.addingTimeInterval(offset), content: content)
        }
        var entries = [
            entry(.user(text: "Fix the retry bug in the upload queue")),
            entry(.assistant(text: "I'll read the queue first.", isStreaming: false)),
            entry(.activity(HarnessActivity(id: "toolu_read", kind: "Read", title: "Read",
                                            input: "Sources/Uploader/UploadQueue.swift", output: "…"), state: .completed))
        ]
        for chip in chips {
            entries.append(entry(.activity(HarnessActivity(
                id: "toolu_\(chip.id)", kind: "mcp__yardlet__spawn_task", title: "mcp__yardlet__spawn_task",
                input: arguments(chip).readableText, output: TaskSuggestionToolCatalog.notedResult(taskID: chip.id)
            ), state: .completed)))
        }
        entries.append(entry(.assistant(text: "The retry bug is fixed; I flagged the rest as separate tasks.", isStreaming: false)))
        return entries
    }

    private func codexThread() -> CodexTaskState {
        let decoder = CodexTaskDecoder()
        var thread = decoder.thread(from: .object(["id": .string("thread-suggest")]))!
        var turn = decoder.turn(from: .object(["id": .string("turn-1"), "status": .string("completed"),
                                               "durationMs": .integer(42_000), "items": .array([])]), fallbackID: "turn-1")!
        let suggestion = chip(1, worktree: true)
        turn.items = [
            decoder.item(from: .object([
                "id": .string("u1"), "type": .string("userMessage"),
                "content": .array([.object(["type": .string("text"), "text": .string("Fix the upload retry bug")])])
            ]), fallbackID: "u1", lifecycle: .completed),
            decoder.item(from: .object([
                "id": .string("mcp-1"), "type": .string("mcpToolCall"), "server": .string("yardlet"),
                "tool": .string("spawn_task"), "status": .string("completed"), "arguments": arguments(suggestion),
                "result": .object(["content": .array([.object([
                    "type": .string("text"), "text": .string(TaskSuggestionToolCatalog.notedResult(taskID: suggestion.id))
                ])])])
            ]), fallbackID: "mcp-1", lifecycle: .completed),
            decoder.item(from: .object([
                "id": .string("a1"), "type": .string("agentMessage"), "text": .string("Fixed; one more task flagged."),
                "phase": .string("final_answer")
            ]), fallbackID: "a1", lifecycle: .completed)
        ]
        thread.turns = [turn]
        return CodexTaskState(thread: thread)
    }

    private func actions(store: TaskSuggestionStore, task: UUID) -> TaskSuggestionActions {
        TaskSuggestionActions(
            resolution: { store.resolution(of: $0, in: task) },
            progress: { store.progress(of: $0, in: task) },
            start: { _ in },
            dismiss: { store.dismiss($0, in: task) },
            openTask: { _ in },
            canOpenTask: { $0 == Self.started }
        )
    }

    private func draw<Content: View>(_ name: String, height: CGFloat,
                                     _ content: () -> Content) throws -> [ConversationDrawing.Drawing] {
        let directory = try WindowlessRender.directory("task-suggestion-qa")
        return try WindowlessRender.Appearance.allCases.map { appearance in
            let drawing = try ConversationDrawing.draw(content(), size: NSSize(width: 760, height: height),
                                                      appearance: appearance)
            try WindowlessRender.writePNG(drawing.capture.bitmap,
                                          to: directory.appending(path: "\(name)-\(appearance.suffix).png"))
            return drawing
        }
    }

    /// What the chip asked the window to do. Only the main thread touches it.
    private final class Recorder: @unchecked Sendable {
        var started: [ConversationTaskSuggestion] = []
        var here: [ConversationTaskSuggestion] = []
        var options: [ConversationTaskSuggestion] = []
        var opened: [UUID] = []
    }
}
