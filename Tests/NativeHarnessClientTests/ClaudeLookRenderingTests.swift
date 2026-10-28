import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The parts of the Claude Code look the user took on 2026-10-15:
/// calls and thinking as status lines folded into a summary, Claude Code's conversation spacing and
/// sent bubble, the answer's copy shown on hover or focus, and the composer's corner and controls, in
/// Yardlet's own colors. Drawn without a window on screen, provider, account or user data: one
/// window-like fixture — the title bar, the sidebar with pinned, chats and projects, a Claude Code task
/// with a sent message, a folded finished turn, a running turn with thinking, a read, an edit with
/// its diff and a running command, and the composer — light and dark, into
/// `.build/claude-look-qa/applied/`.
@MainActor
final class ClaudeLookRenderingTests: XCTestCase {
    static let size = NSSize(width: 1280, height: 860)

    func testTheAppliedLookRenders() throws {
        let folder = try WindowlessRender.directory("claude-look-qa/applied")
        for appearance in WindowlessRender.Appearance.allCases {
            let capture = try WindowlessRender.hosted(
                ClaudeLookShowcase(fixture: ClaudeLookFixture())
                    .environment(\.colorScheme, appearance.colorScheme)
                    .environment(\.opensDetailsForReview, true)
                    .frame(width: Self.size.width, height: Self.size.height),
                size: Self.size, appearance: appearance, passes: 10
            )
            try WindowlessRender.writePNG(capture.bitmap, to: folder.appending(path: "task-\(appearance.suffix).png"))
        }
    }

    /// A run of calls reads as Claude Code reads it, its parts in the order they first came. The
    /// thinking before the calls is in the run where it came, and the summary counts no call for it.
    func testARunOfCallsReadsAsOneSummary() {
        let work = ClaudeLookFixture.runningTurnWork
        let runs = ConversationWorkGrouping.runs(work)
        XCTAssertEqual(runs.count, 1)
        guard case let .group(run) = runs.last else { return XCTFail("\(runs)") }
        XCTAssertEqual(run.map(\.id), work.map(\.id))
        XCTAssertEqual(run.filter { ConversationWorkSummary.category(of: $0) != nil }.count, 3)
        // In the test's language; English continues the sentence in lower case.
        let phrases = ["Read a file", "Edited a file", "Ran a command"].map { L10n.string($0) }
        let expected = phrases.enumerated().map { index, phrase in
            index > 0 && phrase.first?.isASCII == true ? phrase.prefix(1).lowercased() + phrase.dropFirst() : phrase
        }.joined(separator: ", ")
        XCTAssertEqual(ConversationWorkSummary.title(for: run, harness: .claudeCode), expected)
        XCTAssertEqual(ConversationWorkSummary.phase(of: run), .running)
    }

    /// The running turn reads one live line for its run of calls and the thinking before them
    /// (2026-10-16, `ConversationLiveWork`): folded, the line reads the running command and the turn's
    /// steps; opened, it lists the thinking and each call's line in order. The finished turn folds its
    /// work under its work time.
    func testTheRunningTurnListsItsCallsAsLines() throws {
        let host = WindowlessRender.Host(
            TaskConversationView(harness: .claudeCode, workspaceURL: ClaudeLookFixture.workspace,
                                 entries: ClaudeLookFixture.conversation(now: Date()), sessionStatus: .running)
                .environment(\.transcriptWorkspaceURL, ClaudeLookFixture.workspace)
                .frame(width: 900, height: 1_400),
            size: NSSize(width: 900, height: 1_400), appearance: .light
        )
        defer { host.close() }
        host.settle(passes: 10)
        let running = ConversationLineWording.command(
            ConversationCommand(command: "swift test --filter ParserTests", status: ""), phase: .running,
            harness: .claudeCode
        ).map(\.text).joined(separator: ", ")
        let folded = host.accessibilityElements()
        XCTAssertTrue(folded.contains { $0.label.hasPrefix(running + ", ") && $0.value == L10n.string("Collapsed") },
                      "\(folded)")
        XCTAssertFalse(folded.contains { $0.label == L10n.string("Command") }, "the running command is the live line's")
        XCTAssertFalse(folded.contains { $0.label == L10n.string("Thought process") }, "the run's: \(folded)")

        XCTAssertTrue(host.hosting.openLiveWorkLine(step: running))
        host.settle(passes: 6)
        let elements = host.accessibilityElements()
        let labels = elements.map(\.label)
        let live = try XCTUnwrap(labels.firstIndex { $0.hasPrefix(running + ", ") }, "\(elements)")
        let command = try XCTUnwrap(labels.lastIndex(of: L10n.string("Command")), "\(elements)")
        let edit = try XCTUnwrap(labels.lastIndex(of: L10n.string("File change")), "\(elements)")
        let thought = try XCTUnwrap(labels.lastIndex(of: L10n.string("Thought process")), "\(elements)")
        XCTAssertLessThan(live, thought)
        XCTAssertLessThan(thought, edit)
        XCTAssertLessThan(edit, command)
        XCTAssertTrue(elements.contains { $0.label == L10n.string("Edited") + " Parser.swift" }, "\(elements)")
        XCTAssertTrue(elements.contains { $0.label == L10n.string("claude.read.done") + " Parser.swift" },
                      "Claude Code names the file it read: \(elements)")
        XCTAssertTrue(elements.contains { $0.value == L10n.string("Running") + ", swift test --filter ParserTests" },
                      "\(elements)")
    }

    /// "Copy response" shows on hover or focus only, and stays reachable without either: the message
    /// offers it as its own accessibility action, and keyboard focus shows the button.
    func testTheAnswersCopyIsReachableWithoutHover() throws {
        let message = ConversationAgentMessage(itemID: "a1", harness: .claudeCode, text: "Trailing commas now parse.",
                                               isCommentary: false, isStreaming: false)
        let size = NSSize(width: 520, height: 120)
        func host(revealed: Bool) -> WindowlessRender.Host<some View> {
            WindowlessRender.Host(
                message.environment(\.revealsSentMessageActions, revealed)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .background(ParityTheme.canvas),
                size: size, appearance: .light
            )
        }
        let isCopyButton: (WindowlessRender.AccessibilityElement) -> Bool = {
            $0.role == NSAccessibility.Role.button.rawValue && $0.label == L10n.string("Copy response")
        }
        let hidden = host(revealed: false)
        defer { hidden.close() }
        hidden.settle()
        // Out of sight, the button leaves the tree; the message still offers the copy.
        XCTAssertFalse(hidden.accessibilityElements().contains(where: isCopyButton))
        XCTAssertEqual(Self.customActionNames(in: hidden.hosting, on: HarnessKind.claudeCode.displayName),
                       [L10n.string("Copy response")])

        let shown = host(revealed: true)
        defer { shown.close() }
        shown.settle()
        XCTAssertTrue(shown.accessibilityElements().contains(where: isCopyButton), "\(shown.accessibilityElements())")
        let atRest = try hidden.capture().bitmap
        XCTAssertNotEqual(try WindowlessRender.pngData(atRest), try WindowlessRender.pngData(try shown.capture().bitmap),
                          "the action draws only when shown")

        // Keyboard: with keyboard navigation on, focus moves to the action and shows it.
        try XCTSkipUnless(NSApplication.shared.isFullKeyboardAccessEnabled, "keyboard navigation is off")
        hidden.window.makeFirstResponder(hidden.hosting)
        hidden.window.selectNextKeyView(nil)
        hidden.settle()
        XCTAssertNotEqual(try WindowlessRender.pngData(atRest), try WindowlessRender.pngData(try hidden.capture().bitmap),
                          "focus shows the action")
    }

    /// The names of the custom actions of the first accessibility element labelled `label`.
    private static func customActionNames(in root: NSView, on label: String) -> [String] {
        let attribute = "AXEnhancedUserInterface" as NSString
        let app = NSApplication.shared
        let previous = (app.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: attribute)?
            .takeUnretainedValue() as? NSNumber)?.boolValue ?? false
        _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true),
                        with: attribute)
        defer {
            _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                            with: NSNumber(value: previous), with: attribute)
        }
        root.layoutSubtreeIfNeeded()
        func visit(_ node: AnyObject) -> [String]? {
            for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                if (child.accessibilityLabel?() ?? nil) == label {
                    let actions = (child.accessibilityCustomActions?() ?? nil) ?? []
                    return actions.map(\.name)
                }
                if let found = visit(child) { return found }
            }
            return nil
        }
        return visit(root) ?? []
    }
}

/// The window the look is drawn in: the shell's own parts (`IntegratedTitleBar`, `TaskSidebar`,
/// `TaskConversationView`, `PromptComposer`) put together as `MainWindow` and `TaskSurface` put
/// them, without an app model.
private struct ClaudeLookShowcase: View {
    let fixture: ClaudeLookFixture
    @State private var panels = TaskSurfaceNavigationProjection.PanelState()
    @FocusState private var focusedSurface: TaskSurface?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                TitleBarSidebarPart(isSidebarVisible: true, width: ParityTheme.sidebarWidth, onToggleSidebar: {},
                                    onNewTask: {})
                Rectangle().fill(ParityTheme.separator).frame(width: 1)
                IntegratedTitleBar(
                    session: fixture.selected, isSidebarVisible: true, isAttached: true, showsSessionRail: false,
                    onToggleSessionRail: {}, panelState: $panels, focusedSurface: $focusedSurface,
                    onToggleSidebar: {}, onNewTask: {}, onResume: { _ in }, onRename: { _ in },
                    onTogglePinned: { _ in }, onArchive: { _ in }, onBackToConversation: { _ in },
                    projectName: { $0.workspaceURL.lastPathComponent }
                )
            }
            HStack(spacing: 0) {
                TaskSidebar(
                    layout: fixture.layout, allGroups: fixture.groups, isRestoring: false,
                    selection: .session(fixture.selected.id), searchText: .constant(""), onNewTask: {},
                    onActivate: { _ in }, onNewTaskInProject: { _ in }, projects: fixture.projects, onEditProject: { _ in }, onArchiveProjectChats: { _ in },
                    onRemoveProject: { _ in }, onTogglePinned: { _ in }, onArchive: { _ in }, onDelete: { _ in },
                    onRename: { _ in }, onMarkRead: { _ in }
                )
                .frame(width: ParityTheme.sidebarWidth)
                Rectangle().fill(ParityTheme.separator).frame(width: 1)
                VStack(spacing: 0) {
                    TaskConversationView(
                        harness: .claudeCode, workspaceURL: ClaudeLookFixture.workspace,
                        entries: fixture.entries, sessionStatus: .running
                    )
                    .environment(\.transcriptWorkspaceURL, ClaudeLookFixture.workspace)
                    PromptComposer(harness: .claudeCode, composerDraft: fixture.draft, isRunning: false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ParityTheme.canvas)
            }
        }
        .background(ParityTheme.canvas)
        .tint(Color.primary)
    }
}

/// The fixture's tasks and conversation. Paths name folders that are never read.
@MainActor
private struct ClaudeLookFixture {
    static let workspace = URL(filePath: "/tmp/claude-look-qa/yardlet", directoryHint: .isDirectory)
    static let otherProject = URL(filePath: "/tmp/claude-look-qa/example-web", directoryHint: .isDirectory)
    static let home = URL(filePath: "/tmp/claude-look-qa/home", directoryHint: .isDirectory)

    let projects: ProjectStore
    let groups: [WorkspaceGroup]
    let layout: SidebarProjection.Layout
    let selected: SessionRecord
    let entries: [TranscriptEntry]
    let draft: TaskComposerDraft

    init() {
        let projects = ProjectStore(chatWorkspaceHome: Self.home)
        _ = projects.ensureProject(forRoot: Self.workspace)
        _ = projects.ensureProject(forRoot: Self.otherProject)
        let now = Date()
        func task(_ title: String, _ harness: HarnessKind, in folder: URL, minutesAgo: Double,
                  status: SessionStatus = .ready, unread: Bool = false, pinned: Bool = false) -> SessionRecord {
            SessionRecord(harness: harness, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/\(harness.rawValue)"),
                          title: title, titleOrigin: .provider, status: status,
                          updatedAt: now.addingTimeInterval(-minutesAgo * 60), hasUnreadUpdate: unread,
                          completionState: unread ? .completed : .none, isPinned: pinned)
        }
        func chat(_ path: String) -> URL { Self.home.appending(path: path, directoryHint: .isDirectory) }
        let selected = task("Accept trailing commas in the parser", .claudeCode, in: Self.workspace, minutesAgo: 0,
                            status: .running)
        let sessions = [
            selected,
            task("Release checklist", .codex, in: Self.workspace, minutesAgo: 30, pinned: true),
            task("Fix the sidebar search", .codex, in: Self.workspace, minutesAgo: 12, unread: true),
            task("Title Codex threads by request", .claudeCode, in: Self.workspace, minutesAgo: 95),
            task("Blog list pagination", .claudeCode, in: Self.otherProject, minutesAgo: 40),
            task("Profile page review", .codex, in: Self.otherProject, minutesAgo: 300),
            task("Summarize the meeting notes", .claudeCode, in: chat("Documents/Yardlet/2026-10-15/new-chat"),
                 minutesAgo: 8),
            task("Plan today's schedule", .codex, in: chat("Documents/Yardlet/2026-10-15/new-chat-2"), minutesAgo: 50)
        ]
        let groups = projects.visibleGroups(sessions: sessions)
        let chats = projects.chats(sessions: sessions)
        self.projects = projects
        self.groups = groups
        layout = SidebarProjection.layout(visibleGroups: groups, allGroups: groups, chats: chats, splits: [],
                                          isFiltering: false, selection: .session(selected.id))
        self.selected = selected
        entries = Self.conversation(now: now)
        let draft = TaskComposerDraft()
        draft.text = "Also cover nested arrays"
        self.draft = draft
    }

    private static let parserPath = workspace.appending(path: "Sources/Parser.swift").path(percentEncoded: false)

    /// The running turn's work, as the conversation projects it.
    static var runningTurnWork: [ConversationItem] {
        let presentation = TranscriptConversationProjection.presentation(
            from: conversation(now: Date()), harness: .claudeCode, status: .running, latestTurnIsComplete: false
        )
        return presentation.turns.last?.work ?? []
    }

    /// The running turn's calls.
    static var calls: [ConversationItem] {
        runningTurnWork.filter { ConversationWorkSummary.category(of: $0) != nil }
    }

    static func conversation(now: Date) -> [TranscriptEntry] {
        func at(_ secondsAgo: Double, _ content: TranscriptEntryContent) -> TranscriptEntry {
            TranscriptEntry(createdAt: now.addingTimeInterval(-secondsAgo), content: content)
        }
        func activity(_ id: String, _ kind: String, _ title: String, detail: String? = nil, input: String? = nil,
                      output: String? = nil, diff: HarnessActivityDiff? = nil) -> HarnessActivity {
            HarnessActivity(id: id, kind: kind, title: title, detail: detail, input: input, output: output, diff: diff)
        }
        let testOutput = """
        Test Suite 'ParserTests' started.
        Test Suite 'ParserTests' passed.
        \t Executed 14 tests, with 0 failures (0 unexpected) in 0.212 seconds
        """
        let oldArray = """
            while true {
                values.append(try parseValue())
                guard consume(",") else { break }
            }
            try expect("]")
        """
        let newArray = """
            while !peek("]") {
                values.append(try parseValue())
                guard consume(",") else { break }
            }
            try expect("]")
        """
        return [
            at(240, .user(text: "Make the JSON parser accept trailing commas in arrays and objects.")),
            at(236, .reasoning(text: "parseArray expects a value after every comma.", isStreaming: false)),
            at(230, .activity(activity("t1", "Bash", "Bash", detail: "swift test --filter ParserTests",
                                       input: "swift test --filter ParserTests", output: testOutput), state: .completed)),
            at(190, .assistant(text: """
            Trailing commas now parse in arrays and objects.

            - `parseArray` and `parseObject` stop at a closing bracket after a comma.
            - Added `testTrailingCommas` to **ParserTests**; all 14 tests pass.
            """, isStreaming: false)),
            at(60, .user(text: "Also reject a lone comma like `[,]` with a clear error.")),
            at(55, .reasoning(text: """
            A lone comma has no value before it. The loop should check for "]" before the first value \
            and throw "Expected a value" when a comma comes first.
            """, isStreaming: false)),
            at(50, .activity(activity("t2", "Read", parserPath, input: parserPath,
                                       output: "func parseArray() throws -> [Value] {"), state: .completed)),
            at(40, .activity(activity("t3", "Edit", parserPath,
                                       diff: HarnessActivityDiff(path: parserPath, oldText: oldArray, newText: newArray)),
                             state: .completed)),
            at(10, .activity(activity("t4", "Bash", "Bash", detail: "swift test --filter ParserTests",
                                       input: "swift test --filter ParserTests"), state: .running))
        ]
    }
}
