import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Links to other tasks in a conversation (`TaskLink`), in the forms agents write them: a Yardlet task
/// ID as an anchor, as the session tools give it (`SessionToolText.link`), the Claude app's `#local_…`
/// session anchor, and the Codex app's `codex://threads/<id>`. Each names a task Yardlet opens; the
/// prose text of a Claude Code or Codex reply shows the pointing hand over it and hands the click to the
/// window as written. No harness runs; the Claude app's folder is a temporary copy of its layout.
@MainActor
final class TaskLinkTests: XCTestCase {
    private static let taskID = UUID(uuidString: "13242C33-725C-4AC5-A49B-BA5FA470EE9E")!
    private static let desktopID = "local_0ec681f3-5b06-444b-a704-cb7d1556b843"
    /// A title with the characters that would end a link, format its text or split a table cell.
    private static let title = "Release [v2] *notes* `cut` a|b_c\\d (draft)"
    private static let message = "Started \(SessionToolText.link(title: title, taskID: taskID)), and see "
        + "[PRO-972 session](#local_0ec681f3-5b06-444b-a704-cb7d1556b843) and [the parser](Sources/Parser.swift)."

    func testTheLinkFormsAgentsWrite() throws {
        XCTAssertEqual(TaskLink(try XCTUnwrap(URL(string: "#13242C33-725C-4AC5-A49B-BA5FA470EE9E"))), .task(Self.taskID))
        XCTAssertEqual(TaskLink(try XCTUnwrap(URL(string: "#13242c33-725c-4ac5-a49b-ba5fa470ee9e"))), .task(Self.taskID))
        XCTAssertEqual(TaskLink(try XCTUnwrap(URL(string: "#" + Self.desktopID))), .claudeDesktopSession(Self.desktopID))
        XCTAssertEqual(TaskLink(try XCTUnwrap(URL(string: "codex://threads/019a2b3c-4d5e-7f80-9a1b-2c3d4e5f6a7b"))),
                       .codexThread("019a2b3c-4d5e-7f80-9a1b-2c3d4e5f6a7b"))
        XCTAssertEqual(TaskLink(try XCTUnwrap(URL(string: "codex://threads/019a2b3c?view=review")))?.opensElsewhere, true)
        let cloudURL = try XCTUnwrap(URL(string: "https://claude.ai/code/session_01abcdef"))
        XCTAssertEqual(TaskLink(cloudURL), .cloudSession(cloudURL))
        XCTAssertEqual(TaskLink(cloudURL)?.opensElsewhere, true)
        for other in ["#what-changed", "#local_../../etc",
                      "file:///tmp/a.swift#L3", "Sources/Parser.swift", "codex://threads/a/b", "codex://skills/x",
                      "mailto:someone@example.com"] {
            XCTAssertNil(TaskLink(try XCTUnwrap(URL(string: other))), other)
        }
    }

    func testAnAnchorStaysAnAnchorWhileARelativeLinkIsAFileInTheTasksFolder() throws {
        let content = TranscriptInlineContent(stringLiteral: Self.message)
        let links = content.resolved(relativeTo: URL(filePath: "/work/uploader", directoryHint: .isDirectory))
            .runs.compactMap(\.link)
        XCTAssertEqual(links.map(\.absoluteString), [
            "#13242C33-725C-4AC5-A49B-BA5FA470EE9E", "#" + Self.desktopID, "file:///work/uploader/Sources/Parser.swift"
        ])

        // A session tool's link reads as its title alone, in a sentence or a table cell, in either harness's reply.
        let link = SessionToolText.link(title: Self.title, taskID: Self.taskID)
        for dialect in [TranscriptMarkdownDialect.standard, .codex] {
            let blocks = TranscriptMarkdownDocument("| Task | State |\n|---|---|\n| \(link) | idle |\n\nSee \(link).",
                                                    dialect: dialect).blocks
            guard case let .table(_, rows, _)? = blocks.first, case let .paragraph(sentence)? = blocks.last else {
                return XCTFail("\(dialect): \(blocks)")
            }
            XCTAssertEqual(rows.map(\.count), [2], "\(dialect): the title's | stays in its cell")
            for content in [rows[0][0], sentence] {
                let run = try XCTUnwrap(content.attributed.runs.first { $0.link != nil }, "\(dialect)")
                XCTAssertEqual(String(content.attributed[run.range].characters), Self.title, "\(dialect)")
                XCTAssertEqual(run.link.flatMap(TaskLink.init), .task(Self.taskID), "\(dialect)")
            }
        }
    }

    func testEachLinkFindsItsTask() async throws {
        let model = makeModel()
        let folder = URL(filePath: "/tmp/yardlet-task-links", directoryHint: .isDirectory)
        let task = try await model.store.createSession(
            harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
            title: "Release notes", providerSessionID: "6f0d8a52-3c3e-4f0e-9d55-0a5c9b1e2f30")
        let thread = try await model.store.createSession(
            harness: .codex, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Queue", providerSessionID: "019a2b3c-4d5e-7f80-9a1b-2c3d4e5f6a7b")

        let byID = await model.task(linkedBy: .task(task.id))
        XCTAssertEqual(byID?.id, task.id)
        let bySession = await model.task(linkedBy: .task(UUID(uuidString: "6F0D8A52-3C3E-4F0E-9D55-0A5C9B1E2F30")!))
        XCTAssertEqual(bySession?.id, task.id, "A Claude Code session ID names its task")
        let byThread = await model.task(linkedBy: .codexThread("019a2b3c-4d5e-7f80-9a1b-2c3d4e5f6a7b"))
        XCTAssertEqual(byThread?.id, thread.id)
        let missing = await model.task(linkedBy: .task(UUID()))
        XCTAssertNil(missing)

        // The Claude app's `local_…` names the Claude Code session in its own file.
        let root = FileManager.default.temporaryDirectory.appending(path: "claude-sessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let account = root.appending(path: "org/account", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
        try Data(#"{"sessionId":"\#(Self.desktopID)","cliSessionId":"6f0d8a52-3c3e-4f0e-9d55-0a5c9b1e2f30","cwd":"/tmp/yardlet-task-links"}"#.utf8)
            .write(to: account.appending(path: Self.desktopID + ".json"))
        model.claudeDesktopSessionsRoot = root
        let byDesktop = await model.task(linkedBy: .claudeDesktopSession(Self.desktopID))
        XCTAssertEqual(byDesktop?.id, task.id)
        let unknown = await model.task(linkedBy: .claudeDesktopSession("local_00000000-0000-0000-0000-000000000000"))
        XCTAssertNil(unknown)
        await model.shutdown()
    }

    /// The prose text of a Claude Code or a Codex reply shows the pointing hand over each link and
    /// hands the window the link as the agent wrote it, not a file in the task's folder.
    func testTheProseShowsTheHandAndHandsTheWindowTheTaskLink() throws {
        for harness in [HarnessKind.claudeCode, .codex] {
            try assertTheProseHandsTheWindowTheTaskLink(harness: harness)
        }
    }

    private func assertTheProseHandsTheWindowTheTaskLink(harness: HarnessKind) throws {
        var opened: [URL] = []
        let view = ConversationAgentMessage(itemID: "answer", harness: harness, text: Self.message,
                                            isCommentary: false, isStreaming: false)
            .environment(\.transcriptWorkspaceURL, URL(filePath: "/tmp/yardlet-prose"))
            .environment(\.openURL, OpenURLAction { url in
                opened.append(url)
                return .handled
            })
            .padding(24)
            .frame(width: 720, alignment: .topLeading)
        let host = WindowlessRender.Host(view, size: NSSize(width: 720, height: 300), appearance: .light)
        defer { host.close() }
        host.settle()
        let text = try XCTUnwrap(TranscriptProseRenderingTests.proseTextViews(in: host.hosting).first, "\(harness)")
        let string = text.string as NSString
        for words in [Self.title, "PRO-972 session"] {
            let index = string.range(of: words).location
            XCTAssertNotEqual(index, NSNotFound, "\(harness) shows \(words) as written: \(string)")
            text.clicked(onLink: try XCTUnwrap(text.textStorage?.attribute(.link, at: index, effectiveRange: nil)), at: index)
        }
        XCTAssertEqual(opened.compactMap(TaskLink.init), [.task(Self.taskID), .claudeDesktopSession(Self.desktopID)],
                       "\(harness)")

        let rects = text.linkRects()
        XCTAssertEqual(rects.count, 3, "\(harness): a rect for each link on its line: \(rects)")
        for rect in rects { XCTAssertTrue(text.bounds.contains(rect), "\(harness): \(rect) in \(text.bounds)") }
        NSCursor.arrow.set()
        let point = text.convert(CGPoint(x: rects[0].midX, y: rects[0].midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                                     windowNumber: text.window?.windowNumber ?? 0, context: nil,
                                                     eventNumber: 0, clickCount: 0, pressure: 0))
        text.cursorUpdate(with: event)
        XCTAssertEqual(NSCursor.current, NSCursor.pointingHand)
    }

    private func makeModel() -> AppModel {
        AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: SuggestionVolatileDefaults(), discoversRuntimes: false,
                                                     loadsPersistedSelections: false),
            registry: HarnessRegistry { _, _ in SuggestionRecordingAdapter() },
            preferences: SuggestionVolatileDefaults(),
            codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: SuggestionVolatileDefaults()),
            taskSuggestionRepository: InMemoryTaskSuggestionRepository(),
            sessionTitleResolver: { _ in nil },
            sessionTitleRetryCount: 0,
            systemNotificationCenter: QuietLinkNotificationCenter(),
            restoresIndexOnLaunch: false
        )
    }
}

private final class QuietLinkNotificationCenter: SystemNotificationCenter {
    func authorization() async -> SystemNotificationAuthorization { .authorized }
    func requestAuthorization() async -> Bool { true }
    func post(title: String, body: String, identifier: String) async {}
}
