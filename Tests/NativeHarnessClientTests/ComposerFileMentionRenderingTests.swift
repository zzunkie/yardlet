import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The real composers in an unshown window, driven through their native field editor with
/// synthesized key events sent to that window. No app window, screen capture, provider or user
/// keyboard is involved; the rendered images are written under `.build/composer-mention-qa`.
@MainActor
final class ComposerFileMentionRenderingTests: XCTestCase {
    private static let output = WindowlessRender.repositoryRoot.appending(path: ".build/composer-mention-qa")

    private func makeWorkspace(extra: [String] = []) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "nhc-mention-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
        for path in [
            "Sources/App/Views/SessionTranscriptView.swift", "Sources/App/Views/SessionList.swift",
            "Sources/App/Store/SessionStore.swift", "Tests/SessionStoreTests.swift",
            "docs/세션 저장소.md", "README.md"
        ] + extra {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private struct Harness {
        let window: NSWindow
        let hosting: NSView
        let editor: NSTextView
    }

    private func mount<Content: View>(_ content: Content, appearance: NSAppearance.Name = .aqua) throws -> Harness {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: content.frame(width: 640, height: 420, alignment: .bottom)
            .background(ParityTheme.canvas))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        settle()
        let field = try XCTUnwrap(views(NSTextField.self, in: hosting).first)
        XCTAssertTrue(window.makeFirstResponder(field))
        settle()
        addTeardownBlock { @MainActor in window.contentView = nil }
        return Harness(window: window, hosting: hosting, editor: try XCTUnwrap(window.firstResponder as? NSTextView))
    }

    private func type(_ text: String, into harness: Harness) {
        let end = NSRange(location: (harness.editor.string as NSString).length, length: 0)
        harness.editor.insertText(text, replacementRange: end)
        // The search waits out a short burst of keystrokes, then lists off the main thread.
        settle(0.5)
    }

    /// Waits until the `@` list shows `name`. The search answers off the main thread in its own time,
    /// which on a busy Mac or CI can be later than `type`'s wait.
    private func waitUntilListed(_ name: String, in harness: Harness, file: StaticString = #filePath, line: UInt = #line) {
        let listed = { WindowlessRender.accessibilityElements(in: harness.hosting).contains { $0.label == name } }
        let deadline = Date().addingTimeInterval(testWaitLimitSeconds)
        while !listed(), Date() < deadline { settle(0.05) }
        XCTAssertTrue(listed(), "The @ list shows \(name)", file: file, line: line)
    }

    private func press(_ characters: String, keyCode: UInt16, in harness: Harness) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: harness.window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ))
        harness.window.sendEvent(event)
        settle()
    }

    private let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)

    private func settle(_ seconds: TimeInterval = 0.15) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        ([root] + root.subviews.flatMap { views(NSView.self, in: $0) }).compactMap { $0 as? T }
    }

    private func snapshot(_ harness: Harness, _ name: String) throws {
        let bitmap = try WindowlessRender.capture(harness.hosting)
        try FileManager.default.createDirectory(at: Self.output, withIntermediateDirectories: true)
        try WindowlessRender.writePNG(bitmap, to: Self.output.appending(path: name))
    }

    private func mentionedNames(_ inputs: [CodexUserInput]) -> [String] {
        inputs.compactMap { if case let .mention(name, _) = $0 { name } else { nil } }
    }

    func testTheTaskComposerListsFilesAndTheKeyboardChoosesOne() throws {
        let workspace = try makeWorkspace()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .darkAqua ? "dark" : "light"
            let draft = TaskComposerDraft()
            var sent: [HarnessUserInput] = []
            let harness = try mount(PromptComposer(
                harness: .claudeCode, composerDraft: draft, isRunning: false,
                mentionRoots: [workspace], actions: ComposerActions(send: { sent.append($0) })
            ), appearance: appearance)

            type("Fix the bug in @sess", into: harness)
            waitUntilListed("SessionList.swift", in: harness)
            XCTAssertEqual(draft.text, "Fix the bug in @sess")
            try snapshot(harness, "task-list-\(suffix).png")

            // ↓ moves the highlight without touching the text; Return chooses it.
            try press(down, keyCode: 125, in: harness)
            XCTAssertEqual(draft.text, "Fix the bug in @sess")
            try snapshot(harness, "task-highlight-\(suffix).png")
            try press("\r", keyCode: 36, in: harness)
            XCTAssertEqual(draft.text, "Fix the bug in")
            XCTAssertEqual(mentionedNames(draft.attachments), ["SessionList.swift"], "The second match was highlighted")
            XCTAssertTrue(sent.isEmpty, "Choosing a file does not send")
            guard case let .mention(_, path) = draft.attachments.first else { return XCTFail("Expected a mention") }
            XCTAssertEqual(path, workspace.appending(path: "Sources/App/Views/SessionList.swift").standardizedFileURL)
            try snapshot(harness, "task-chosen-\(suffix).png")

            // Tab chooses as well, and a Hangul query finds a Hangul file name.
            type(" @저장", into: harness)
            waitUntilListed("세션 저장소.md", in: harness)
            try snapshot(harness, "task-hangul-\(suffix).png")
            try press("\t", keyCode: 48, in: harness)
            XCTAssertEqual(mentionedNames(draft.attachments), ["SessionList.swift", "세션 저장소.md"])
            XCTAssertEqual(draft.text, "Fix the bug in")

            // Esc closes the list; Return then sends what was typed, the word included.
            type(" @read", into: harness)
            try press("\u{1b}", keyCode: 53, in: harness)
            XCTAssertEqual(draft.text, "Fix the bug in @read")
            try press("\r", keyCode: 36, in: harness)
            XCTAssertEqual(sent.count, 1)
            XCTAssertEqual(sent.first?.text, "Fix the bug in @read")
            XCTAssertEqual(sent.first?.mentions.map(\.lastPathComponent), ["SessionList.swift", "세션 저장소.md"])
        }
    }

    func testALongListScrollsWithinItsBoundAndAnEmptyWordAsksForText() throws {
        let workspace = try makeWorkspace(extra: (1...30).map { "Sources/Generated/Session\($0).swift" })
        let draft = TaskComposerDraft()
        let harness = try mount(PromptComposer(
            harness: .codex, composerDraft: draft, isRunning: false,
            mentionRoots: [workspace, workspace.appending(path: "docs", directoryHint: .isDirectory)]
        ))
        type("@", into: harness)
        try snapshot(harness, "task-empty-query.png")
        type("session", into: harness)
        try snapshot(harness, "task-long-list.png")
        for _ in 0..<12 { try press(down, keyCode: 125, in: harness) }
        try snapshot(harness, "task-long-list-scrolled.png")
        type("zzzz", into: harness)
        try snapshot(harness, "task-no-match.png")
        XCTAssertEqual(draft.text, "@sessionzzzz")
    }

    func testTheDropHighlightCoversTheComposerInBothAppearances() throws {
        for scheme in [ColorScheme.light, .dark] {
            let composer = RoundedRectangle(cornerRadius: ParityTheme.composerCornerRadius)
                .fill(ParityTheme.input)
                .overlay(alignment: .topLeading) { Text("Fix the bug in").padding(15) }
                .overlay { ComposerDropHighlight() }
                .frame(width: 560, height: 120).padding(20)
                .background(ParityTheme.canvas)
                .environment(\.colorScheme, scheme)
            let image = try WindowlessRender.image(composer)
            XCTAssertEqual(image.width, 1_200)
            try FileManager.default.createDirectory(at: Self.output, withIntermediateDirectories: true)
            try WindowlessRender.writePNG(image,
                to: Self.output.appending(path: "drop-highlight-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    func testTheNewTaskComposerMentionsFromTheChosenProject() throws {
        let workspace = try makeWorkspace()
        let draft = NewTaskDraft()
        draft.harness = .claudeCode
        draft.workspaceURL = workspace
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests")))
        let harness = try mount(NewTaskHome(
            recentSessions: [], projects: [Project(name: "App", primaryRoot: workspace)], draft: draft,
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            onSelectSession: { _ in }, onChooseWorkspace: { _ in }, onShowHarnesses: {},
            onCreate: { _ in nil }
        ))
        type("Explain @readme", into: harness)
        waitUntilListed("README.md", in: harness)
        try snapshot(harness, "home-list.png")
        try press("\r", keyCode: 36, in: harness)
        XCTAssertEqual(draft.text, "Explain")
        XCTAssertEqual(mentionedNames(draft.attachments), ["README.md"])
        try snapshot(harness, "home-chosen.png")
    }
}
