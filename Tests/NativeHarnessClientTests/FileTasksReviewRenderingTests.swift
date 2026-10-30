import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// A Markdown change rendered in the review, and a file's related tasks, drawn with no window on screen,
/// light and dark, into `.build/file-tasks-qa/`:
///
/// - `review-markdown-wide-*`: the review at 900 points, a Last turn's Markdown change rendered, the
///   tasks that edited the file under its name.
/// - `review-markdown-narrow-*`: the same at 380 points, where the file menu takes the file list's place.
/// - `review-markdown-lines-wide-*`: the same file as the line diff, the rendered view switched off.
/// - `files-tasks-*`: the files panel with the file open and its related tasks under the header.
///
/// The clicks go through the accessibility tree of a window that is never ordered on screen.
@MainActor
final class FileTasksReviewRenderingTests: XCTestCase {
    private static let before = """
    # Release plan

    The release goes out on Monday.

    - Build the bundle
    - Sign it
    - Upload the update

    | Step | Owner |
    | --- | --- |
    | Build | Yardlet |
    | Review | Reviewer |

    ## Notes

    Nothing else changes.

    Old closing paragraph.

    """

    private static let after = """
    # Release plan

    The release goes out on **Tuesday**, after the review.

    - Build the bundle
    - Sign it with the Developer ID
    - Upload the update

    | Step | Owner |
    | --- | --- |
    | Build | Yardlet |
    | Review | Reviewer |

    ## Notes

    Nothing else changes.

    ## Rollback

    1. Keep the previous build.
    2. Point the feed back to it.

    """

    private static let now = Date()
    private static let edited = [
        FileTasks.Item(id: UUID(), title: "Redesign the home screen", harness: .claudeCode, at: now, callID: "toolu_home"),
        FileTasks.Item(id: UUID(), title: "Clean up Google cookies", harness: .codex, at: now.addingTimeInterval(-86_400),
                       callID: "call_cookies"),
        FileTasks.Item(id: UUID(), title: "Prepare the public repository", harness: .claudeCode, at: now.addingTimeInterval(-4 * 86_400),
                       callID: "toolu_release")
    ]
    private static let readOnly = [
        FileTasks.Item(id: UUID(), title: "Yardlet merge duty", harness: .claudeCode, at: now, callID: "toolu_read")
    ]

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "file-tasks-render-\(UUID())")
        try FileManager.default.createDirectory(at: url.appending(path: "docs"), withIntermediateDirectories: true)
        try Self.after.write(to: url.appending(path: "docs/RELEASE.md"), atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The turn's change to the file, as a Last turn reads one.
    fileprivate static var lastTurn: ReviewLastTurn {
        func lines(_ text: String) -> [String] { Array(text.components(separatedBy: "\n").dropLast()) }
        let hunks = ConversationFileChangeProjection.hunks(old: lines(before), new: lines(after))
        let text = (["diff --git a/docs/RELEASE.md b/docs/RELEASE.md", "--- a/docs/RELEASE.md", "+++ b/docs/RELEASE.md"]
                    + hunks).joined(separator: "\n") + "\n"
        return .offered(CodexLastTurnDiff(turnID: "turn", text: text, isRunning: false))
    }

    private final class Opened {
        var items: [FileTasks.Item] = []
        var preferences: DiffReviewPreferences?
    }

    /// The review as a task's panel holds it: its preferences are the panel's state.
    private struct Review: View {
        let root: URL
        @State var preferences: DiffReviewPreferences
        let opened: Opened

        var body: some View {
            DiffPane(workspaceURL: root, review: $preferences, lastTurn: FileTasksReviewRenderingTests.lastTurn, onClose: {})
                .onChange(of: preferences) { _, new in opened.preferences = new }
        }
    }

    private func services(_ opened: Opened) -> FileTaskServices {
        FileTaskServices(currentTaskID: Self.edited[0].id,
                         lookup: { _ in FileTasks(edited: Self.edited, readOnly: Self.readOnly) },
                         open: { opened.items.append($0) })
    }

    private func review(_ root: URL, rendered: Bool, opened: Opened) -> some View {
        Review(root: root, preferences: Self.preferences(rendered: rendered), opened: opened)
            .environment(\.fileTaskServices, services(opened))
    }

    private static func preferences(rendered: Bool) -> DiffReviewPreferences {
        var preferences = DiffReviewPreferences()
        preferences.scope = .lastTurn
        preferences.rendersMarkdown = rendered ? true : nil
        return preferences
    }

    private func texts<Content: View>(_ host: WindowlessRender.Host<Content>) -> String {
        host.accessibilityElements().map(\.description).joined(separator: "\n")
    }

    func testTheReviewDrawsAMarkdownChangeRenderedAtEachWidth() async throws {
        let root = try folder()
        let directory = try WindowlessRender.directory("file-tasks-qa")
        for (name, width, rendered) in [("review-markdown-wide", 900.0, true), ("review-markdown-narrow", 380.0, true),
                                        ("review-markdown-lines-wide", 900.0, false)] {
            for appearance in WindowlessRender.Appearance.allCases {
                let size = NSSize(width: width, height: 720)
                let host = WindowlessRender.Host(
                    review(root, rendered: rendered, opened: Opened())
                        .environment(\.colorScheme, appearance.colorScheme)
                        .frame(width: size.width, height: size.height)
                        .background(ParityTheme.canvas),
                    size: size, appearance: appearance)
                defer { host.close() }
                let ready = rendered ? "Tuesday" : "+The release goes out on **Tuesday**, after the review."
                await host.settle(until: { self.texts(host).contains(ready) && self.texts(host).contains(Self.edited[1].title) })
                host.settle(passes: 4)
                let drawn = texts(host)
                try drawn.write(to: directory.appending(path: "\(name)-\(appearance.suffix).txt"), atomically: true, encoding: .utf8)
                XCTAssertTrue(drawn.contains(L10n.string("Edited in")), drawn)
                if rendered {
                    // The change's blocks, both sides, and the table between them folded away.
                    for text in ["The release goes out on Monday.", "Sign it with the Developer ID", "Rollback",
                                 "Point the feed back to it.", "Old closing paragraph."] {
                        XCTAssertTrue(drawn.contains(text), "\(text) is not drawn:\n\(drawn)")
                    }
                    XCTAssertTrue(drawn.contains(L10n.format("%d unchanged blocks", 2)), drawn)
                    XCTAssertFalse(drawn.contains("Reviewer"), "the unchanged table is folded")
                }
                let bitmap = try host.capture().bitmap
                XCTAssertTrue(WindowlessRender.drawsContent(bitmap, step: 6))
                try WindowlessRender.writePNG(bitmap, to: directory.appending(path: "\(name)-\(appearance.suffix).png"))
            }
        }
    }

    /// The task in the line opens its conversation; the control beside the file's name switches between
    /// the rendered view and the line diff; the folded blocks open.
    func testTheTasksLineOpensATaskAndTheControlSwitchesTheView() async throws {
        let root = try folder()
        let opened = Opened()
        let size = NSSize(width: 900, height: 720)
        let host = WindowlessRender.Host(review(root, rendered: true, opened: opened)
            .frame(width: size.width, height: size.height), size: size)
        defer { host.close() }
        await host.settle(until: { self.texts(host).contains("Tuesday") && self.texts(host).contains(Self.edited[1].title) })

        // The first task is the review's own: "This task".
        let own = "\(L10n.string("This task")), \(FileTasksLine.day(Self.edited[0].at))"
        let second = "\(Self.edited[1].title), \(FileTasksLine.day(Self.edited[1].at))"
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: second), texts(host))
        XCTAssertEqual(opened.items.map(\.callID), ["call_cookies"])
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: own), texts(host))
        XCTAssertEqual(opened.items.map(\.callID), ["call_cookies", "toolu_home"])
        // The rest of the tasks are behind the menu, which is never opened here.
        XCTAssertTrue(texts(host).contains(L10n.format("%d more", 2)), texts(host))

        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.format("%d unchanged blocks", 2)), texts(host))
        await host.settle(until: { self.texts(host).contains("Reviewer") })

        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Rendered preview")), texts(host))
        await host.settle(until: { self.texts(host).contains("+The release goes out on **Tuesday**, after the review.") })
        XCTAssertNotNil(opened.preferences)
        XCTAssertNil(opened.preferences?.rendersMarkdown, "the line diff is the review's default again")
    }

    func testTheFilesPanelShowsTheOpenFilesTasks() throws {
        let root = try folder()
        let directory = try WindowlessRender.directory("file-tasks-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            let state = WorkspaceFilesState()
            let host = WindowlessRender.Host(
                FilesPane(workspaceURL: root, state: state, onClose: {})
                    .environment(\.fileTaskServices, services(Opened()))
                    .environment(\.colorScheme, appearance.colorScheme)
                    .background(ParityTheme.canvas),
                size: NSSize(width: 520, height: 420), appearance: appearance)
            defer { host.close() }
            state.open(.init(relativePath: "docs/RELEASE.md"), in: root)
            let deadline = Date().addingTimeInterval(20)
            while state.isLoading || !texts(host).contains(Self.edited[1].title), Date() < deadline {
                host.settle(passes: 1)
            }
            XCTAssertTrue(texts(host).contains(L10n.string("Edited in")), texts(host))
            try WindowlessRender.writePNG(try host.capture().bitmap,
                                          to: directory.appending(path: "files-tasks-\(appearance.suffix).png"))
        }
    }

    /// A call another view asked for: the conversation widens its window to the turn holding it, far
    /// above the latest turns it draws, and goes there.
    func testTheConversationGoesToTheTurnHoldingTheCall() async throws {
        let namespace = UUID(uuidString: "4C4B7F10-55A4-4E8B-9F3C-2B1E0D6A9C21")!
        let entries: [TranscriptEntry] = (1...40).flatMap { index -> [TranscriptEntry] in
            var turn = [TranscriptEntry(id: NameBasedUUID.make(namespace: namespace, name: "u\(index)"),
                                        createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60),
                                        content: .user(text: "Request \(index)"))]
            if index == 3 {
                turn.append(TranscriptEntry(
                    id: NameBasedUUID.make(namespace: namespace, name: "e\(index)"),
                    createdAt: Date(timeIntervalSince1970: 1_700_000_010 + Double(index) * 60),
                    content: .activity(HarnessActivity(id: "toolu_edit", kind: "Edit", title: "Edit",
                                                       input: "/work/docs/RELEASE.md",
                                                       diff: HarnessActivityDiff(path: "/work/docs/RELEASE.md",
                                                                                 oldText: "Monday", newText: "Tuesday")),
                                       state: .completed)))
            }
            turn.append(TranscriptEntry(id: NameBasedUUID.make(namespace: namespace, name: "a\(index)"),
                                        createdAt: Date(timeIntervalSince1970: 1_700_000_030 + Double(index) * 60),
                                        content: .assistant(text: "Answer \(index). " + String(repeating: "Words. ", count: 60),
                                                            isStreaming: false)))
            return turn
        }
        var shown = false
        let place = ConversationPlace(request: ConversationPlaceRequest(callID: "toolu_edit"), done: { shown = true })
        let size = NSSize(width: 620, height: 600)
        let host = WindowlessRender.Host(
            ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .ready,
                                                     latestTurnIsComplete: true))
                .environment(\.conversationPlace, place)
                .frame(width: size.width, height: size.height).background(ParityTheme.canvas),
            size: size)
        defer { host.close() }
        await host.settle(until: { shown })
        host.settle(passes: 6)
        let visible = host.accessibilityElements(visibleOnly: true).map(\.description).joined(separator: "\n")
        try visible.write(to: WindowlessRender.directory("file-tasks-qa").appending(path: "conversation-place.txt"),
                          atomically: true, encoding: .utf8)
        XCTAssertTrue(visible.contains("Request 3"), visible)
        XCTAssertFalse(visible.contains("Request 40"), visible)
    }
}
