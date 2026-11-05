import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

@MainActor
final class ArchivedTaskRenderingTests: XCTestCase {
    func testArchivedListSearchMatchesTitleProjectAndHarness() {
        let codex = ArchivedSessionRecord(
            session: SessionRecord(harness: .codex, workspaceURL: URL(filePath: "/tmp/parser"),
                runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Fix the parser"),
            archivedAt: nil, isProviderArchived: false)
        let claude = ArchivedSessionRecord(
            session: SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/site"),
                runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Landing page"),
            archivedAt: nil, isProviderArchived: false)
        let name: (SessionRecord) -> String = { $0.workspaceURL.lastPathComponent == "site" ? "Website" : "Parser" }
        XCTAssertEqual(ArchivedTaskFilter.matches([codex, claude], query: "  ", projectName: name), [codex, claude])
        XCTAssertEqual(ArchivedTaskFilter.matches([codex, claude], query: "PARSER", projectName: name), [codex])
        XCTAssertEqual(ArchivedTaskFilter.matches([codex, claude], query: "web", projectName: name), [claude])
        XCTAssertEqual(ArchivedTaskFilter.matches([codex, claude], query: "claude", projectName: name), [claude])
        XCTAssertEqual(ArchivedTaskFilter.matches([codex, claude], query: "nothing", projectName: name), [])
    }

    func testSidebarEntryArchivedListAndRestoreRowRenderWithoutAWindow() throws {
        let codex = SessionRecord(harness: .codex, workspaceURL: URL(filePath: "/tmp/yardlet"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Fix the session index migration",
            providerSessionID: "codex-thread")
        let claude = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/site"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Landing page copy",
            providerSessionID: "claude-session")
        let restoring = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/yardlet"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Review the split view", providerSessionID: "claude-2")
        let archived = [codex, claude, restoring].map {
            ArchivedSessionRecord(session: $0, archivedAt: Date(), isProviderArchived: $0.harness == .codex)
        }
        let active = SessionRecord(harness: .codex, workspaceURL: URL(filePath: "/tmp/yardlet"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Keyboard shortcuts", status: .completed,
            hasUnreadUpdate: true)
        let groups = TaskNavigationProjection.workspaceGroups(from: [active])
        let layout = SidebarProjection.layout(visibleGroups: groups, allGroups: groups, splits: [], isFiltering: false)
        let projectName: (SessionRecord) -> String = { $0.workspaceURL.lastPathComponent }
        let directory = try WindowlessRender.directory("archived-tasks-qa")

        for appearance in [ColorScheme.light, .dark] {
            let view = HStack(alignment: .top, spacing: 0) {
                TaskSidebar(layout: layout, allGroups: groups, isRestoring: false, selection: .session(active.id),
                    searchText: .constant(""), onNewTask: {}, onActivate: { _ in }, onNewTaskInProject: { _ in },
                    projects: ProjectStore(), onEditProject: { _ in },
                    onArchiveProjectChats: { _ in }, onRemoveProject: { _ in }, onTogglePinned: { _ in },
                    onArchive: { _ in }, onDelete: { _ in }, onRename: { _ in }, onMarkRead: { _ in })
                    .frame(width: ParityTheme.sidebarWidth)
                Rectangle().fill(ParityTheme.separator).frame(width: 1)
                ArchivedTaskList(archived: archived, errorMessage: nil, restoringIDs: [restoring.id],
                    searchText: .constant(""), projectName: projectName, onBack: {}, onUnarchive: { _ in })
                    .frame(width: ParityTheme.sidebarWidth)
                Rectangle().fill(ParityTheme.separator).frame(width: 1)
                VStack(spacing: 0) {
                    ArchivedTaskList(archived: [], errorMessage: nil, restoringIDs: [],
                        searchText: .constant(""), projectName: projectName, onBack: {}, onUnarchive: { _ in })
                        .frame(height: 150)
                    ArchivedTaskList(archived: nil, errorMessage: nil, restoringIDs: [],
                        searchText: .constant("nothing"), projectName: projectName, onBack: {}, onUnarchive: { _ in })
                        .frame(height: 150)
                    ArchivedTaskRow(record: archived[0], projectName: "yardlet", isRestoring: false,
                        onUnarchive: {}, isHovering: true)
                        .padding(4)
                        .background(ParityTheme.sidebar)
                    Spacer(minLength: 0)
                }
                .frame(width: ParityTheme.sidebarWidth)
            }
            .frame(width: ParityTheme.sidebarWidth * 3 + 2, height: 420)
            .environment(\.colorScheme, appearance)

            let host = WindowlessRender.Host(view, size: NSSize(width: ParityTheme.sidebarWidth * 3 + 2, height: 420),
                                             appearance: WindowlessRender.Appearance(appearance))
            defer { host.close() }
            host.settle(passes: 1, interval: 0.1)
            let capture = try host.capture()
            let bitmap = capture.bitmap
            try WindowlessRender.writePNG(bitmap,
                to: directory.appending(path: appearance == .dark ? "archived-dark.png" : "archived-light.png"))
            XCTAssertEqual(bitmap.pixelsWide, Int(host.hosting.bounds.width * capture.backingScaleFactor))
            XCTAssertGreaterThan(bitmap.pixelsHigh, 400)
        }
    }

    /// An archived task opened from the list: its conversation read-only in the task's place, drawn by
    /// each harness's renderer (a long Claude Code history, a Codex thread, an ACP agent's replay and an
    /// Antigravity CLI log), and the archived note with Unarchive in the composer's place. A harness
    /// Yardlet does not read, and a history that is gone, say so instead of an empty conversation.
    func testAnArchivedTaskOpensReadOnlyBesideTheListForEachHarness() throws {
        func record(_ harness: HarnessKind, _ title: String, folder: String = "yardlet") -> ArchivedSessionRecord {
            ArchivedSessionRecord(
                session: SessionRecord(harness: harness, workspaceURL: URL(filePath: "/tmp/\(folder)"),
                    runtimeExecutableURL: URL(filePath: "/tmp/\(harness.rawValue)"), title: title,
                    status: .completed, providerSessionID: "\(harness.rawValue)-session", completionState: .completed),
                archivedAt: Date(), isProviderArchived: harness == .codex)
        }
        func turns(_ count: Int) -> [TranscriptEntry] {
            (1...count).flatMap { index in [
                TranscriptEntry(content: .user(text: "Request \(index): check the session index migration")),
                TranscriptEntry(content: .assistant(text: index == count
                    ? "The migration keeps `archived_at` and `provider_archived` together.\n\n```sql\nALTER TABLE sessions ADD COLUMN archived_at REAL;\n```\n\nEvery archived row reads back unchanged."
                    : "Answer \(index). The rows read back unchanged.", isStreaming: false))
            ] }
        }
        let claude = record(.claudeCode, "Fix the session index migration")
        let codex = record(.codex, "Fix the flaky test")
        let openCode = record(.openCode, "Tidy the parser", folder: "parser")
        let antigravity = record(.antigravityCLI, "Landing page copy", folder: "site")
        let pi = record(.pi, "Sketch the release notes")
        let gone = record(.claudeCode, "Review the split view")
        let archived = [claude, codex, openCode, antigravity, pi, gone]
        let codexState: CodexTaskState = {
            var state = CodexTaskState(thread: CodexTaskDecoder().thread(from: CodexDetachedThreadReadTests.savedThread))
            CodexTaskReducer().endRuntime(in: &state)
            return state
        }()
        let scenes: [(String, ArchivedSessionRecord, (ArchivedTaskReading) -> Void)] = [
            // A long history: the conversation draws its newest turns, and earlier ones as it scrolls up.
            ("claude-long", claude, { $0.show(turns(600)) }),
            ("codex", codex, { $0.show(codexState) }),
            ("opencode", openCode, { $0.show(turns(3)) }),
            ("antigravity", antigravity, { $0.show(turns(2)) }),
            ("pi-unsupported", pi, { _ in }),
            ("claude-unavailable", gone, { _ in })
        ]
        let directory = try WindowlessRender.directory("archived-tasks-qa")
        let size = NSSize(width: ParityTheme.sidebarWidth + 1 + 760, height: 620)

        for (name, shown, fill) in scenes {
            let reading = ArchivedTaskReading(record: shown)
            fill(reading)
            reading.finishReading()
            switch name {
            case "pi-unsupported": XCTAssertEqual(reading.outcome, .unsupported)
            case "claude-unavailable": XCTAssertEqual(reading.outcome, .unavailable)
            default: XCTAssertEqual(reading.outcome, .shown)
            }
            for appearance in [ColorScheme.light, .dark] {
                let view = ArchivedTaskWindowShowcase(archived: archived, reading: reading)
                    .frame(width: size.width, height: size.height)
                    .environment(\.colorScheme, appearance)
                let host = WindowlessRender.Host(view, size: size, appearance: WindowlessRender.Appearance(appearance))
                defer { host.close() }
                host.settle(passes: 12)
                let elements = host.accessibilityElements().map(\.description).joined(separator: "\n")
                XCTAssertTrue(elements.contains(L10n.string("This task is archived. Unarchive it to keep working in it.")),
                              "\(name): \(elements)")
                XCTAssertFalse(elements.contains(L10n.string("Start a conversation")), name)
                let capture = try host.capture()
                XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6), name)
                try WindowlessRender.writePNG(capture.bitmap,
                    to: directory.appending(path: "archived-\(name)-\(appearance == .dark ? "dark" : "light").png"))
            }
        }
    }
}

/// The title bar, the archived list with one task open, and that task's conversation, as `MainWindow`
/// puts them.
private struct ArchivedTaskWindowShowcase: View {
    let archived: [ArchivedSessionRecord]
    let reading: ArchivedTaskReading
    @State private var panels = TaskSurfaceNavigationProjection.PanelState()
    @FocusState private var focusedSurface: TaskSurface?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                TitleBarSidebarPart(isSidebarVisible: true, width: ParityTheme.sidebarWidth, onToggleSidebar: {},
                                    onNewTask: {})
                Rectangle().fill(ParityTheme.separator).frame(width: 1)
                IntegratedTitleBar(
                    session: nil, isSidebarVisible: true, isAttached: false, showsSessionRail: false,
                    onToggleSessionRail: {}, panelState: $panels, focusedSurface: $focusedSurface,
                    onToggleSidebar: {}, onNewTask: {}, onResume: { _ in }, onRename: { _ in },
                    onTogglePinned: { _ in }, onArchive: { _ in }, onBackToConversation: { _ in },
                    title: reading.session.title
                )
            }
            .frame(height: ParityTheme.titleBarHeight)
            HStack(spacing: 0) {
                ArchivedTaskList(archived: archived, errorMessage: nil, restoringIDs: [], searchText: .constant(""),
                                 projectName: { $0.workspaceURL.lastPathComponent }, onBack: {}, onUnarchive: { _ in },
                                 shownID: reading.record.id, onOpen: { _ in })
                    .frame(width: ParityTheme.sidebarWidth)
                Rectangle().fill(ParityTheme.separator).frame(width: 1)
                ArchivedTaskConversation(reading: reading, isUnarchiving: false, onUnarchive: {}, onReadEarlier: {})
                    .background(ParityTheme.canvas)
            }
        }
        .background(ParityTheme.canvas)
    }
}
