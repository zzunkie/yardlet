import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The editing both composers share (`ComposerEditor` over `ComposerDraftEditing`): the same
/// edits through the task draft and the new-task draft, the rules for when a typed list shows,
/// and the real composers driven through their field editor in an unshown window. No provider,
/// CLI, app window, screen capture or user keyboard is involved; nothing is sent.
@MainActor
final class ComposerEditorTests: XCTestCase {
    /// One fresh draft of each kind, named for failure messages.
    private func drafts() -> [(String, any ComposerDraftEditing)] {
        [("task", TaskComposerDraft()), ("new task", NewTaskDraft())]
    }

    private func makeFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "nhc-editor-\(UUID().uuidString)", directoryHint: .isDirectory)
        for path in ["README.md", "Sources/App/Reader.swift", "Sources/App/Session.swift", "docs/release.md", "shot.png"] {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private static let review = ProviderComposerCommand(name: "review", description: "Review the working tree",
                                                        argumentHint: "")
    private static let releaseNotes = ProviderComposerCommand(name: "release-notes", description: "Draft release notes",
                                                              argumentHint: "")

    // MARK: - The same edits through both drafts

    func testBothDraftsTakeACommandAndRemoveAChipTheSameWay() {
        for (name, draft) in drafts() {
            draft.text = "/re"
            draft.attachments = [.localImage(URL(filePath: "/tmp/a.png"), detail: .auto),
                                 .mention(name: "b.swift", path: URL(filePath: "/tmp/b.swift"))]
            draft.insertCommand(Self.review)
            XCTAssertEqual(draft.text, "/review ", name)
            XCTAssertEqual(draft.selection?.lowerBound, draft.text.endIndex, "The caret follows the command (\(name))")

            draft.removeAttachment(at: 5)
            XCTAssertEqual(draft.attachments.count, 2, "An index already gone does nothing (\(name))")
            draft.removeAttachment(at: 0)
            XCTAssertEqual(draft.attachments, [.mention(name: "b.swift", path: URL(filePath: "/tmp/b.swift"))], name)

            // A selection measured in other text is not kept.
            draft.rememberSelection(NSRange(location: 1, length: 0), in: "something else")
            XCTAssertEqual(draft.selection?.lowerBound, draft.text.endIndex, name)
            draft.rememberSelection(NSRange(location: 1, length: 0), in: draft.text)
            XCTAssertEqual(draft.selection.map { NSRange($0, in: draft.text) }, NSRange(location: 1, length: 0), name)
        }
    }

    func testBothDraftsTurnAChosenFileIntoOneMentionAndDropTheTypedWord() throws {
        let root = try makeFolder()
        let match = WorkspaceFileMatch(root: root, relativePath: "Sources/App/Reader.swift", isDirectory: false)
        for (name, draft) in drafts() {
            draft.text = "Fix @read now"
            let token = try XCTUnwrap(ComposerMentions.token(in: draft.text, caret: 9))
            XCTAssertEqual(draft.insertMention(match, replacing: token), ComposerMentionEdit(caret: 4), name)
            XCTAssertEqual(draft.text, "Fix now", name)
            XCTAssertEqual(draft.attachments, [.mention(name: "Reader.swift", path: match.url)], name)

            // The text changed under the list: the file still joins, once, and the text stays.
            XCTAssertEqual(draft.insertMention(match, replacing: token), ComposerMentionEdit(caret: nil), name)
            XCTAssertEqual(draft.text, "Fix now", name)
            XCTAssertEqual(draft.attachments.count, 1, "A file is mentioned once (\(name))")
        }
    }

    func testBothDraftsTakePastedAndDroppedFilesAsThePickersWould() throws {
        let root = try makeFolder()
        let image = root.appending(path: "shot.png"), source = root.appending(path: "README.md")
        for (name, draft) in drafts() {
            draft.receive(.files([image, source, image]), policy: HarnessComposerInputPolicy(harness: .claudeCode))
            XCTAssertEqual(draft.attachments, [
                .localImage(image.standardizedFileURL, detail: .auto),
                .mention(name: "README.md", path: source.standardizedFileURL)
            ], name)
            XCTAssertNil(draft.notice, name)
            draft.attachFiles([source], policy: HarnessComposerInputPolicy(harness: .claudeCode))
            XCTAssertEqual(draft.attachments.count, 2, "A file already attached is not added again (\(name))")

            // A harness without an attachment surface says so instead of dropping the file.
            draft.receive(.files([image]), policy: HarnessComposerInputPolicy(harness: .cursorAgent))
            XCTAssertEqual(draft.notice, L10n.string("Unsupported attachment type"), name)
            XCTAssertEqual(draft.attachments.count, 2, name)

            // Image data where images cannot travel is refused before anything is written.
            draft.notice = nil
            draft.receive(.image(Data([1, 2, 3]), type: .png),
                          policy: HarnessComposerInputPolicy(harness: .kimiCode, negotiatedImageInput: false))
            XCTAssertEqual(draft.notice, L10n.string("Unsupported attachment type"), name)
        }
    }

    func testBothDraftsAttachAPastedImageOrSayWhyNot() async throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        for (name, draft) in drafts() {
            await draft.attachPastedImage(png, type: .png)
            guard case let .localImage(url, _) = draft.attachments.first else { return XCTFail("No image (\(name))") }
            addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            XCTAssertEqual(try Data(contentsOf: url), png, name)

            // TIFF bytes that do not decode cannot be re-encoded, and the user is told.
            await draft.attachPastedImage(Data([0, 1, 2]), type: .tiff)
            XCTAssertEqual(draft.attachments.count, 1, name)
            XCTAssertEqual(draft.notice, L10n.string("The pasted image could not be attached."), name)
        }
    }

    /// The marked-up copy keeps the image's size with the marks where the editor drew them (from the
    /// top left), takes the attachment's place in both drafts, and leaves the original file as it was.
    func testBothDraftsSwapAnAttachedImageForItsMarkedUpCopy() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 30, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let white = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1)
        for x in 0..<40 { for y in 0..<30 { rep.setColor(white, atX: x, y: y) } }
        let original = try ComposerAttachmentIntake.storePastedImage(try XCTUnwrap(rep.representation(using: .png, properties: [:])))
        addTeardownBlock { try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }
        let before = try Data(contentsOf: original)
        let model = ImageMarkupModel(image: try XCTUnwrap(ImageMarkupRenderer.image(at: original)))
        model.tool = .rectangle
        model.drag(from: CGPoint(x: 4, y: 4), to: CGPoint(x: 20, y: 12))
        model.endDrag()
        model.drag(from: CGPoint(x: 30, y: 28), to: CGPoint(x: 30, y: 28))
        model.endDrag()
        XCTAssertEqual(model.marks.count, 1, "a click leaves no mark")
        let copy = try XCTUnwrap(ImageMarkupRenderer.saveCopy(model.image, marks: model.marks))
        addTeardownBlock { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        let marked = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: copy)))
        XCTAssertEqual([marked.pixelsWide, marked.pixelsHigh], [40, 30])
        let edge = try XCTUnwrap(marked.colorAt(x: 4, y: 8)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(edge.redComponent, 0.8)
        XCTAssertLessThan(edge.greenComponent, 0.4, "the rectangle's left edge, 8 px from the top")
        let below = try XCTUnwrap(marked.colorAt(x: 12, y: 24)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(below.greenComponent, 0.9, "nothing drawn under the rectangle")
        XCTAssertEqual(try Data(contentsOf: original), before)

        for (name, draft) in drafts() {
            draft.attachments = [.localImage(original, detail: .auto), .mention(name: "a.swift", path: URL(filePath: "/tmp/a.swift"))]
            draft.replaceAttachment(at: 0, withMarkedUp: copy)
            draft.replaceAttachment(at: 1, withMarkedUp: copy)
            XCTAssertEqual(draft.attachments, [.localImage(copy.standardizedFileURL, detail: .auto),
                                               .mention(name: "a.swift", path: URL(filePath: "/tmp/a.swift"))], name)
        }
    }

    func testOnlyTheTaskDraftHasBashMode() {
        let task = TaskComposerDraft(), home = NewTaskDraft()
        task.text = "!"
        home.text = "!"
        XCTAssertTrue(task.enterBashModeIfTyped(after: ""))
        XCTAssertEqual(task.text, "")
        XCTAssertTrue(task.isBashMode)
        XCTAssertTrue(task.leaveBashMode())

        let editing: any ComposerDraftEditing = home
        XCTAssertFalse(editing.enterBashModeIfTyped(after: ""))
        XCTAssertFalse(editing.isBashMode)
        XCTAssertFalse(editing.leaveBashMode())
        XCTAssertEqual(home.text, "!", "The new-task draft keeps a typed `!`")
    }

    // MARK: - When a typed list shows

    func testTheTypedListsShowOnlyInTheFocusedEditorWithNoMenuOrBashMode() {
        func query(_ text: String = "/re", offers: Bool = true, focused: Bool = true, commandMenu: Bool = false,
                   bash: Bool = false, dismissed: String? = nil) -> String? {
            ComposerTypedLists.commandQuery(in: text, offersCommands: offers, isFocused: focused,
                                            isCommandMenuOpen: commandMenu, isBashMode: bash, dismissedText: dismissed)
        }
        XCTAssertEqual(query(), "re")
        XCTAssertNil(query(offers: false))
        XCTAssertNil(query(focused: false), "A restored `/` draft opens nothing until the editor has focus")
        XCTAssertNil(query(commandMenu: true), "The + menu's search takes its place")
        XCTAssertNil(query(bash: true), "A shell command is plain text")
        XCTAssertNil(query(dismissed: "/re"), "Escape closes it for this text")
        XCTAssertEqual(query("/rev", dismissed: "/re"), "rev", "Typing again reopens it")
        XCTAssertNil(query("Fix /re"))

        func mention(_ text: String = "See @rea", offers: Bool = true, roots: Bool = true, menu: Bool = false,
                     bash: Bool = false, commands: Bool = false, dismissed: String? = nil) -> String? {
            ComposerTypedLists.mention(in: text, caret: nil, offersMentions: offers, hasRoots: roots, isFocused: true,
                                       isMenuOpen: menu, isBashMode: bash, showsCommands: commands,
                                       dismissedText: dismissed)?.query
        }
        XCTAssertEqual(mention(), "rea")
        XCTAssertNil(mention(offers: false), "No `@` list where the `@` button is not offered")
        XCTAssertNil(mention(roots: false))
        XCTAssertNil(mention(menu: true))
        XCTAssertNil(mention(bash: true))
        XCTAssertNil(mention(commands: true), "The `/` list wins")
        XCTAssertNil(mention(dismissed: "See @rea"))
    }

    func testArrowKeysMoveTheCommandHighlightButLeaveAnInputMethodItsKeys() {
        XCTAssertEqual(ComposerTypedLists.movedCommandHighlight(0, by: 1, count: 3, hasMarkedText: false), 1)
        XCTAssertEqual(ComposerTypedLists.movedCommandHighlight(2, by: 1, count: 3, hasMarkedText: false), 2)
        XCTAssertEqual(ComposerTypedLists.movedCommandHighlight(0, by: -1, count: 3, hasMarkedText: false), 0)
        XCTAssertNil(ComposerTypedLists.movedCommandHighlight(0, by: 1, count: 0, hasMarkedText: false))
        XCTAssertNil(ComposerTypedLists.movedCommandHighlight(0, by: 1, count: 3, hasMarkedText: true),
                     "Composing Hangul keeps the arrow key")
    }

    // MARK: - The real composers

    @MainActor private struct Mounted {
        let host: WindowlessRender.Host<AnyView>
        var window: NSWindow { host.window }

        var elements: [WindowlessRender.AccessibilityElement] { host.accessibilityElements() }

        func shows(_ label: String) -> Bool { elements.contains { $0.label == label } }
    }

    private func mount(_ view: some View, focus: Bool = true) throws -> Mounted {
        let host = WindowlessRender.Host(AnyView(view.frame(width: 760, height: 460, alignment: .bottom)
            .background(ParityTheme.canvas)), size: NSSize(width: 760, height: 460))
        addTeardownBlock { @MainActor in host.close() }
        host.settle()
        if focus {
            let field = try XCTUnwrap(views(NSTextField.self, in: host.hosting).first { $0.isEditable })
            XCTAssertTrue(host.window.makeFirstResponder(field))
            host.settle(passes: 4)
        }
        return Mounted(host: host)
    }

    private func editor(_ mounted: Mounted) throws -> NSTextView {
        try XCTUnwrap(mounted.window.firstResponder as? NSTextView)
    }

    private func type(_ text: String, into mounted: Mounted) throws {
        let editor = try editor(mounted)
        for character in text {
            editor.insertText(String(character), replacementRange: NSRange(location: (editor.string as NSString).length,
                                                                           length: 0))
            mounted.host.settle(passes: 2)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        mounted.host.settle()
    }

    private func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [],
                       in mounted: Mounted) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: mounted.window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        mounted.window.sendEvent(event)
        mounted.host.settle()
    }

    private let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)

    private func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        ([root] + root.subviews.flatMap { views(NSView.self, in: $0) }).compactMap { $0 as? T }
    }

    /// A Claude task composer with the session's commands, counting catalog reads and sends.
    @MainActor private final class TaskProbe {
        let draft = TaskComposerDraft()
        var reads = 0
        var sent: [HarnessUserInput] = []
    }

    private func taskComposer(_ probe: TaskProbe, roots: [URL] = []) -> some View {
        var capabilities = ProviderCapabilityState()
        capabilities.composerCommands = [Self.review, Self.releaseNotes]
        let shell = ClaudeShellCommandActions(isRunning: false, run: { _ in }, stop: {}, runForEntry: { _ in nil })
        return PromptComposer(harness: .claudeCode, composerDraft: probe.draft, providerCapabilities: capabilities,
                              isRunning: false, mentionRoots: roots,
                              actions: ComposerActions(send: { probe.sent.append($0) },
                                                       prepareProviderSettings: { probe.reads += 1 }))
            .environment(\.claudeShellCommands, shell)
    }

    /// A Claude new-task composer whose commands come from a session that sends nothing.
    @MainActor private final class HomeProbe {
        let draft = NewTaskDraft()
        var reads = 0
        var created: [String] = []
    }

    private func homeComposer(_ probe: HomeProbe, workspace: URL) throws -> some View {
        let project = Project(name: "App", primaryRoot: workspace)
        probe.draft.harness = .claudeCode
        probe.draft.workspaceURL = workspace
        probe.draft.projectID = project.id
        let suite = testDefaultsSuite("ComposerEditorTests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let runtimes = RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false, loadsPersistedSelections: false)
        runtimes.select(URL(filePath: "/usr/bin/true"), for: .claudeCode)
        return NewTaskHome(recentSessions: [], projects: [project], draft: probe.draft, runtimeSelections: runtimes,
            onSelectSession: { _ in }, onChooseWorkspace: { _ in }, onShowHarnesses: {},
            onCreate: { probe.created.append($0.originalText); return nil },
            onReadCommands: { _, _, _ in probe.reads += 1; return [Self.review, Self.releaseNotes] })
    }

    func testBothComposersChooseATypedCommandWithArrowsReturnAndTab() throws {
        let workspace = try makeFolder()
        let task = TaskProbe(), home = HomeProbe()
        let composers: [(String, any ComposerDraftEditing, () throws -> Mounted)] = [
            ("task", task.draft, { try self.mount(self.taskComposer(task)) }),
            ("new task", home.draft, { try self.mount(self.homeComposer(home, workspace: workspace)) })
        ]
        for (name, draft, make) in composers {
            let mounted = try make()
            try type("/re", into: mounted)
            XCTAssertTrue(mounted.shows("/review"), "The typed list shows (\(name))")
            XCTAssertTrue(mounted.shows("/release-notes"), name)
            try press(down, keyCode: 125, in: mounted)
            XCTAssertEqual(draft.text, "/re", "↓ moves the highlight, not the text (\(name))")
            try press("\r", keyCode: 36, in: mounted)
            XCTAssertEqual(draft.text, "/release-notes ", "Return chooses the highlighted row (\(name))")
            XCTAssertFalse(mounted.shows("/review"), name)

            draft.text = ""
            mounted.host.settle()
            try type("/re", into: mounted)
            try press("\t", keyCode: 48, in: mounted)
            XCTAssertEqual(draft.text, "/review ", "Tab chooses the first row (\(name))")
        }
        XCTAssertTrue(task.sent.isEmpty, "Choosing a command sends nothing")
        XCTAssertTrue(home.created.isEmpty, "Choosing a command starts nothing")
        XCTAssertEqual(home.reads, 1, "The new-task list is read once for its project, runtime and account")
    }

    func testEscapeClosesTheTypedListsAndReturnThenSubmitsInBothComposers() throws {
        let workspace = try makeFolder()
        let task = TaskProbe(), home = HomeProbe()
        let composers: [(String, () throws -> Mounted)] = [
            ("task", { try self.mount(self.taskComposer(task, roots: [workspace])) }),
            ("new task", { try self.mount(self.homeComposer(home, workspace: workspace)) })
        ]
        for (name, make) in composers {
            let mounted = try make()
            try type("Explain @read", into: mounted)
            XCTAssertTrue(mounted.shows("README.md"), "The `@` list shows (\(name))")
            try press("\u{1b}", keyCode: 53, in: mounted)
            XCTAssertFalse(mounted.shows("README.md"), "Escape closes it (\(name))")
            try press("\r", keyCode: 36, in: mounted)
        }
        XCTAssertEqual(task.sent.map(\.text), ["Explain @read"], "Return sends the text as typed")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(home.created, ["Explain @read"], "Return starts the task with the text as typed")
    }

    func testBothComposersChooseAFileFromTheTypedMentionList() throws {
        let workspace = try makeFolder()
        let task = TaskProbe(), home = HomeProbe()
        let composers: [(String, any ComposerDraftEditing, () throws -> Mounted)] = [
            ("task", task.draft, { try self.mount(self.taskComposer(task, roots: [workspace])) }),
            ("new task", home.draft, { try self.mount(self.homeComposer(home, workspace: workspace)) })
        ]
        for (name, draft, make) in composers {
            let mounted = try make()
            try type("Explain @sess", into: mounted)
            try press("\r", keyCode: 36, in: mounted)
            XCTAssertEqual(draft.text, "Explain", name)
            XCTAssertEqual(draft.attachments, [.mention(name: "Session.swift",
                path: workspace.appending(path: "Sources/App/Session.swift").standardizedFileURL)], name)
        }
        XCTAssertTrue(task.sent.isEmpty)
        XCTAssertTrue(home.created.isEmpty)
    }

    func testBothComposersTakeDroppedAndPastedFilesThroughTheirEditor() throws {
        let workspace = try makeFolder()
        let image = workspace.appending(path: "shot.png"), source = workspace.appending(path: "README.md")
        let task = TaskProbe(), home = HomeProbe()
        let composers: [(String, any ComposerDraftEditing, () throws -> Mounted)] = [
            ("task", task.draft, { try self.mount(self.taskComposer(task, roots: [workspace])) }),
            ("new task", home.draft, { try self.mount(self.homeComposer(home, workspace: workspace)) })
        ]
        let expected: [CodexUserInput] = [.localImage(image.standardizedFileURL, detail: .auto),
                                          .mention(name: "README.md", path: source.standardizedFileURL)]
        for (name, draft, make) in composers {
            let mounted = try make()
            let target = try XCTUnwrap(views(ComposerExternalInputView.self, in: mounted.host.hosting).first, name)
            target.onInput(.files([image]))
            XCTAssertEqual(draft.attachments, [expected[0]], "A drop attaches (\(name))")

            let pasteboard = NSPasteboard(name: .init("nhc-editor-\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            pasteboard.writeObjects([source as NSURL, image as NSURL])
            let paste = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: mounted.window.windowNumber, context: nil, characters: "v",
                charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
            XCTAssertTrue(target.handlePaste(paste, pasteboard: pasteboard), name)
            XCTAssertEqual(draft.attachments, expected, "A paste attaches what is not attached yet (\(name))")
            mounted.host.settle()
            XCTAssertEqual(mounted.elements.filter { $0.label == L10n.string("Attached input") }.count, 2,
                           "Both chips show (\(name))")
        }
    }

    func testBashModeIsTheTaskComposersAlone() throws {
        let workspace = try makeFolder()
        let task = TaskProbe(), home = HomeProbe()
        let taskMounted = try mount(taskComposer(task, roots: [workspace]))
        try type("!", into: taskMounted)
        XCTAssertTrue(task.draft.isBashMode)
        XCTAssertEqual(task.draft.text, "")
        XCTAssertTrue(taskMounted.shows(L10n.string("Enter a shell command")))

        let homeMounted = try mount(homeComposer(home, workspace: workspace))
        try type("!", into: homeMounted)
        XCTAssertEqual(home.draft.text, "!", "The new-task composer keeps `!` as text")
    }

    func testAClaudeCatalogIsReadForATypedSlashNotForARestoredOne() throws {
        let workspace = try makeFolder()
        let task = TaskProbe(), home = HomeProbe()
        task.draft.text = "/re"
        home.draft.text = "/re"
        let taskMounted = try mount(taskComposer(task))
        XCTAssertEqual(task.reads, 0, "Focusing a restored `/` draft reads nothing")
        XCTAssertTrue(taskMounted.shows("/review"), "The list shows what the session already listed")
        try type("v", into: taskMounted)
        XCTAssertEqual(task.reads, 1, "A typed slash reads the detached task's catalog")
        taskMounted.host.close()

        let homeMounted = try mount(homeComposer(home, workspace: workspace))
        XCTAssertEqual(home.reads, 0, "Focusing a restored `/` draft reads nothing")
        try type("i", into: homeMounted)
        XCTAssertEqual(home.reads, 1, "A typed slash reads the new task's catalog")
        try type("e", into: homeMounted)
        XCTAssertEqual(home.reads, 1, "Once per project, runtime and account")
    }

    func testCodexReadsItsCommandsWhenItsListOpens() throws {
        var reads = 0
        let draft = TaskComposerDraft()
        draft.text = "/mo"
        let mounted = try mount(PromptComposer(
            harness: .codex, composerDraft: draft, modelCatalog: ComposerUnificationFixtures.codexCatalog,
            isRunning: false, actions: ComposerActions(runCodexCommand: { _ in }, prepareCodexCommands: { reads += 1 })))
        XCTAssertEqual(reads, 1, "Focusing a `/` draft opens Codex's list, which reads Plan mode, Fast and skills")
        let listRow = WindowlessRender.AccessibilityElement(role: "AXButton", label: L10n.string("Model"), value: "")
        XCTAssertTrue(mounted.elements.contains(listRow), "\(mounted.elements)")
        try type("d", into: mounted)
        XCTAssertEqual(reads, 1, "Typing within the open list reads nothing more")
        XCTAssertTrue(mounted.elements.contains(listRow))
    }

    // MARK: - Return while a turn runs

    func testCommandReturnSendsTheOtherWayOfTheFollowUpSettingAndShiftReturnAddsALine() {
        XCTAssertEqual(ComposerFollowUpOptions.alternateAction(preferred: .steer, canSteer: true), .queue,
                       "By default Return sends at once and ⌘Return after the turn")
        XCTAssertEqual(ComposerFollowUpOptions.alternateAction(preferred: .steer, canSteer: false), .queue)
        XCTAssertEqual(ComposerFollowUpOptions.alternateAction(preferred: .queue, canSteer: true), .steer)
        XCTAssertNil(ComposerFollowUpOptions.alternateAction(preferred: .queue, canSteer: false),
                     "No turn to steer yet: ⌘Return is Return")
        XCTAssertEqual(FollowUpMode.steer.other, .queue)
        XCTAssertEqual(FollowUpMode.queue.other.action, .steer)

        // The Codex and Claude apps' keys: Return sends, ⌘Return the other way, Shift-Return a line.
        XCTAssertEqual(ComposerReturnKey([] as EventModifiers), .send)
        XCTAssertEqual(ComposerReturnKey(EventModifiers.capsLock), .send, "Caps Lock does not count")
        XCTAssertEqual(ComposerReturnKey(EventModifiers.command), .alternate)
        XCTAssertEqual(ComposerReturnKey(EventModifiers.shift), .newline)
        XCTAssertEqual(ComposerReturnKey([.shift, .capsLock] as EventModifiers), .newline)
        XCTAssertNil(ComposerReturnKey(EventModifiers.option), "Option-Return adds a line in the field editor")
        XCTAssertNil(ComposerReturnKey([.shift, .command] as EventModifiers))
        XCTAssertNil(ComposerReturnKey(EventModifiers.control))
        XCTAssertEqual(ComposerReturnKey(NSEvent.ModifierFlags.command), .alternate)
        XCTAssertEqual(ComposerReturnKey(NSEvent.ModifierFlags.shift), .newline)

        // The Return an input method passes on after committing its composition reaches `onSubmit`;
        // the app's current event says which Return it was.
        let shiftReturn = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
                                           windowNumber: 0, context: nil, characters: "\r",
                                           charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
        let keypadEnter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                           windowNumber: 0, context: nil, characters: "\u{3}",
                                           charactersIgnoringModifiers: "\u{3}", isARepeat: false, keyCode: 76)
        let letter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
                                      windowNumber: 0, context: nil, characters: "A",
                                      charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)
        XCTAssertEqual(ComposerReturnKey(event: shiftReturn), .newline)
        XCTAssertEqual(ComposerReturnKey(event: keypadEnter), .alternate)
        XCTAssertNil(ComposerReturnKey(event: letter))
        XCTAssertNil(ComposerReturnKey(event: nil))
    }

    /// While an input method composes, Return is its own: the composer only notes which Return it
    /// was, so the `onSubmit` the input method passes on after committing adds the line Shift-Return
    /// asked for instead of sending, and nothing is sent or added while the composition stands.
    func testAReturnDuringCompositionIsNotedForTheSubmitThatFollowsIt() {
        let context = ComposerFieldContext()
        XCTAssertNil(context.takeComposedReturn())
        context.composedReturn = .newline
        XCTAssertEqual(context.takeComposedReturn(), .newline)
        XCTAssertNil(context.takeComposedReturn(), "Read once")

        let draft = TaskComposerDraft()
        draft.text = "안녕"
        context.insertLine(into: draft)
        XCTAssertEqual(draft.text, "안녕\n", "With no field editor the line goes at the end")
    }

    /// A task composer recording what its sends were asked: Return's automatic send, or the queue
    /// and steering's explicit one.
    @MainActor private final class FollowUpProbe {
        let draft = TaskComposerDraft()
        var sent: [String] = []
        var followUps: [String] = []
    }

    private func followUpComposer(_ harness: HarnessKind, _ probe: FollowUpProbe, preferred: FollowUpMode,
                                  isRunning: Bool = true, canSteer: Bool = true) throws -> some View {
        let suite = testDefaultsSuite("ComposerEditorTests.followUp")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(preferred.rawValue, forKey: FollowUpMode.preferenceKey)
        var actions = ComposerActions(send: { probe.sent.append($0.text) })
        if harness == .codex {
            actions.submitCodex = { draft, action in probe.followUps.append("\(action.rawValue): \(draft.text)") }
        } else {
            actions.submitFollowUp = { input, action in probe.followUps.append("\(action.rawValue): \(input.text)") }
        }
        var capabilities = ProviderCapabilityState()
        capabilities.composerCommands = [Self.review, Self.releaseNotes]
        return PromptComposer(harness: harness, composerDraft: probe.draft,
                              modelCatalog: ComposerUnificationFixtures.codexCatalog,
                              providerCapabilities: harness == .codex ? nil : capabilities,
                              isRunning: isRunning, canSteer: canSteer, actions: actions)
            .defaultAppStorage(defaults)
    }

    func testWhileATurnRunsReturnSendsNowAndCommandReturnQueuesInBothHarnesses() throws {
        for harness in [HarnessKind.claudeCode, .codex] {
            let probe = FollowUpProbe()
            let mounted = try mount(followUpComposer(harness, probe, preferred: .steer))
            try type("Use Python", into: mounted)
            try press("\r", keyCode: 36, in: mounted)
            try type("Then update the README", into: mounted)
            try press("\r", keyCode: 36, modifiers: .command, in: mounted)
            XCTAssertEqual(probe.draft.text, "", "\(harness)")

            try type("Two", into: mounted)
            try press("\r", keyCode: 36, modifiers: .shift, in: mounted)
            XCTAssertEqual(probe.draft.text, "Two\n", "Shift-Return adds a line while a turn runs (\(harness))")
            try type("lines", into: mounted)
            try press("\r", keyCode: 36, modifiers: .option, in: mounted)
            XCTAssertEqual(probe.draft.text, "Two\nlines\n", "Option-Return adds a line (\(harness))")
            if harness == .codex {
                // Codex's typed draft takes Return's automatic send, which steers by the setting.
                XCTAssertEqual(probe.followUps, ["automatic: Use Python", "queue: Then update the README"])
                XCTAssertEqual(probe.sent, [])
            } else {
                // Return is the ordinary send, which the app model sends now while Claude runs.
                XCTAssertEqual(probe.sent, ["Use Python"])
                XCTAssertEqual(probe.followUps, ["queue: Then update the README"])
            }
        }
    }

    func testWithQueueingSetCommandReturnSendsNowAndWithoutATurnItIsReturn() throws {
        let queued = FollowUpProbe()
        let mounted = try mount(followUpComposer(.claudeCode, queued, preferred: .queue))
        try type("Stop and use Python", into: mounted)
        try press("\r", keyCode: 36, modifiers: .command, in: mounted)
        XCTAssertEqual(queued.followUps, ["steer: Stop and use Python"])
        mounted.host.close()

        let idle = FollowUpProbe()
        let idleMounted = try mount(followUpComposer(.claudeCode, idle, preferred: .steer, isRunning: false))
        try type("Next", into: idleMounted)
        try press("\r", keyCode: 36, modifiers: .shift, in: idleMounted)
        XCTAssertEqual(idle.draft.text, "Next\n", "With no turn running Shift-Return still adds a line")
        try type("request", into: idleMounted)
        try press("\r", keyCode: 36, modifiers: .command, in: idleMounted)
        XCTAssertEqual(idle.sent, ["Next\nrequest"], "With no turn running ⌘Return sends as Return does")
        XCTAssertEqual(idle.followUps, [])
        idleMounted.host.close()

        let unsteerable = FollowUpProbe()
        let waiting = try mount(followUpComposer(.codex, unsteerable, preferred: .queue, canSteer: false))
        try type("Later", into: waiting)
        try press("\r", keyCode: 36, modifiers: .command, in: waiting)
        XCTAssertEqual(unsteerable.followUps, ["automatic: Later"], "No turn to steer yet: it goes as Return sends")
    }

    /// Shift-Return adds a line in both composers, and past its line limit the field scrolls inside,
    /// as the Codex and Claude apps' composers do: the caret's line stays in view as lines are added
    /// or the caret moves, and the wheel moves it (`scrollsPastLines`).
    func testShiftReturnAddsALineInTheNewTaskComposerTooAndALongDraftScrolls() throws {
        let workspace = try makeFolder()
        let home = HomeProbe()
        let mounted = try mount(homeComposer(home, workspace: workspace))
        try type("Plan", into: mounted)
        try press("\r", keyCode: 36, modifiers: .shift, in: mounted)
        XCTAssertEqual(home.draft.text, "Plan\n")
        try type("then build", into: mounted)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(home.created, [], "Shift-Return starts nothing")
        try press("\r", keyCode: 36, in: mounted)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(home.created, ["Plan\nthen build"])

        let task = TaskProbe()
        task.draft.text = (1...12).map { "Line \($0)" }.joined(separator: "\n")
        let composer = try mount(taskComposer(task))
        let editor = try editor(composer)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        try press("\r", keyCode: 36, modifiers: .shift, in: composer)
        try type("Line 13", into: composer)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.frame.height, scroll.contentView.bounds.height + 50,
                             "The field grows past what the composer shows")
        XCTAssertEqual(scroll.contentView.bounds.maxY, document.frame.height, accuracy: 1,
                       "Typing on at the end keeps the caret's line in view")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        composer.host.settle()
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1, "The caret moved to the start brings it into view")
        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3,
                                          wheel2: 0, wheel3: 0).flatMap(NSEvent.init(cgEvent:)))
        editor.scrollWheel(with: wheel)
        // AppKit moves the scroll view on a later turn of the run loop, later still on a busy Mac.
        let deadline = Date().addingTimeInterval(testWaitLimitSeconds)
        while scroll.contentView.bounds.minY <= 1, Date() < deadline { composer.host.settle(passes: 1) }
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 1, "The wheel scrolls the field")
        task.draft.text = "Short"
        composer.host.settle()
        XCTAssertEqual(scroll.frame.height, document.frame.height, accuracy: 1, "A short draft shows whole again")
    }

    func testTheTypedListsTakeShiftAndCommandReturnAsTheyTakeReturnWhileATurnRuns() throws {
        for modifiers in [NSEvent.ModifierFlags.shift, .command] {
            let probe = FollowUpProbe()
            let mounted = try mount(followUpComposer(.claudeCode, probe, preferred: .steer))
            try type("/re", into: mounted)
            XCTAssertTrue(mounted.shows("/review"))
            try press("\r", keyCode: 36, modifiers: modifiers, in: mounted)
            XCTAssertEqual(probe.draft.text, "/review ", "The modified Return chooses the highlighted row")
            XCTAssertEqual(probe.sent, [])
            XCTAssertEqual(probe.followUps, [])
            mounted.host.close()
        }
    }
}
