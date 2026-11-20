import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

final class MacShortcutTests: XCTestCase {
    func testMenuAndFocusedResponderDefaults() {
        XCTAssertEqual(Set(MacShortcut.all.map(\.id)).count, MacShortcut.all.count)
        let commands: [MacShortcut] = [.settings, .palette, .help, .newTask, .toggleSidebar, .previousTask, .nextTask,
            .nextTaskNeedingAttention, .toggleActivityView, .togglePinned, .markUnread, .archive, .toggleSessionRail,
            .toggleSidePanel, .toggleTerminal, .terminalAlternate, .openModelMenu, .back, .forward,
            .newTab, .closeTab, .closeWindow, .reopenClosedTab, .nextTab, .previousTab, .splitRight, .splitDown,
            .closePane, .focusLeft, .focusRight, .focusUp, .focusDown, .conversationFind, .nextResult, .previousResult,
            .surfaceChat, .surfaceReview, .surfaceTerminal, .surfaceBrowser, .actualSize, .zoomIn, .zoomOut,
            .attachSelection]
        XCTAssertEqual(commands.map { $0.defaultBinding().displayText }, [
            "⌘,", "⌘K", "⌘?", "⌘N", "⇧⌘S", "⇧⌘[", "⇧⌘]", "⌥⌘A", "⌥⌘U", "⌥⌘P", "⇧⌘U", "⇧⌘A", "⌃⌘I",
            "⌥⌘B", "⌘J", "⌃\u{60}", "⌃⇧M", "⌘[", "⌘]", "⌘T", "⌘W", "⇧⌘W", "⇧⌘T", "⌃⇥", "⌃⇧⇥", "⇧⌘D",
            "⌥⇧⌘D", "⌃⌘W", "⌥⌘←", "⌥⌘→", "⌥⌘↑", "⌥⌘↓", "⌘F", "⌘G", "⇧⌘G", "⌘1", "⌘2", "⌘3", "⌘4", "⌘0", "⌘+", "⌘-",
            "⇧⌘L"
        ])
        for number in 1...9 {
            XCTAssertEqual(MacShortcut.pinnedRow(number).defaultBinding().displayText, "⌃\(number)")
            XCTAssertEqual(MacShortcut.browserTab(number).defaultBinding().displayText, "⌘\(number)")
        }
    }

    func testScopedControlsKeepTheirFactoryKeys() {
        let controls: [(String, String)] = [
            ("Composer", "↩ ⌘↩ ⇧↩ ⎋ ⌘↩ → ⇥ ⌘V ⌫ ↑ ↓"),
            ("Terminal", "⇧⌘L"), ("Simulator", "⇧⌘H ⌘L ⌘W"),
            ("Images", "⌘C ← → ⎋ ⌘= ⌘- ⌘0 ⌘Z"), ("Mail", "⌘↩"),
            ("Command palette", "↑ ↓ ↩ ⎋"), ("Focused list", "↑ ↓ ↩ Space"), ("Focused control", "← →"),
            ("Home", "⇥ ⇧⇥"), ("Address field", "↓ ↑ ⇥ ⇧⇥ ⇧⌦"), ("Find bar", "⇧↩"),
            ("Dialog", "↩"), ("Dialog or menu", "⎋"), ("Select model", "1 2 3 4 5 6 7 8 9"),
            ("Question", "1 2 3 4 5 6 7 8 9")
        ]
        for (scope, expected) in controls {
            XCTAssertEqual(MacShortcut.all.filter { $0.definition.scope == scope }
                .map { $0.defaultBinding().displayText }.joined(separator: " "), expected, scope)
        }
    }

    func testBrowserKeepsResponderPrecedenceAndExistingModifierAndLayoutRules() {
        func match(_ key: String, _ flags: NSEvent.ModifierFlags, _ code: UInt16 = 0) -> MacShortcut? {
            let input = MacShortcutEvent(flags: flags, keyCode: code, character: key, unmodified: key)
            return MacShortcut.browserPageCommands.first { $0.matches(input) }
        }
        let commands: [(String, MacShortcut)] = [
            ("t", .browserNew), ("w", .browserClose), ("c", .browserCopy), ("x", .browserCut),
            ("v", .browserPaste), ("a", .browserSelectAll), ("z", .browserUndo), ("=", .browserZoomIn),
            ("+", .browserZoomIn), ("-", .browserZoomOut), ("0", .browserReset), ("f", .browserFind),
            ("l", .browserAddress), ("r", .browserReload), ("[", .browserBack), ("]", .browserForward)
        ]
        for (key, command) in commands {
            XCTAssertEqual(match(key, .command), command)
            XCTAssertEqual(match(key, [.command, .option]), command)
            XCTAssertNil(match(key, []))
        }
        XCTAssertEqual(match("t", [.command, .shift]), .browserReopen)
        XCTAssertEqual(match("z", [.command, .shift]), .browserRedo)
        XCTAssertNil(match("w", [.command, .shift]))
        XCTAssertEqual(match("9", [.command, .numericPad]), .browserTab(9))
        XCTAssertNil(match("9", [.command, .capsLock]))
        XCTAssertEqual(match("\t", .control, 48), .browserNext)
        XCTAssertEqual(match("\u{19}", [.control, .shift], 48), .browserPrevious)
        XCTAssertNil(match("\t", [.control, .capsLock], 48))
        XCTAssertTrue(MacShortcut.terminalAlternate.matches(.init(flags: [.control, .capsLock], keyCode: 50,
                                                                  character: "§", unmodified: "§")))
        XCTAssertFalse(MacShortcut.attachSelection.matches(.init(flags: [.command, .shift, .capsLock], keyCode: 37,
                                                                 character: "l", unmodified: "ㅣ")))
    }
}

extension MacShortcutTests {
    /// View › Zoom In takes ⌘= beside its menu key ⌘+ (shown together in Settings), after the window's views: a
    /// browser page or an image that zooms itself keeps the key while it has it.
    @MainActor
    func testZoomInTakesCommandEqualsAfterTheWindowsOwnZoom() throws {
        XCTAssertEqual(MacShortcutPreferences.shared.displayedKeys(for: .zoomIn, send: .return), "⌘+ / ⌘=")
        final class PageView: NSView {
            override func performKeyEquivalent(with event: NSEvent) -> Bool { true }
        }
        func window(_ content: NSView) -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 80, height: 40), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = content
            return window
        }
        func key(_ characters: String, _ flags: NSEvent.ModifierFlags, in window: NSWindow) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 24))
        }
        let plain = window(NSView()), page = window(PageView())
        defer { plain.close(); page.close(); InterfaceZoom.actualSize() }
        InterfaceZoom.actualSize()
        XCTAssertTrue(InterfaceZoomCommands.takeAlternateZoomInKey(try key("=", .command, in: plain)))
        XCTAssertEqual(InterfaceZoom.current(), 1.1)
        XCTAssertTrue(InterfaceZoomCommands.takeAlternateZoomInKey(try key("=", .command, in: page)))
        XCTAssertEqual(InterfaceZoom.current(), 1.1, "The page zoomed itself")
        XCTAssertFalse(InterfaceZoomCommands.takeAlternateZoomInKey(try key("+", [.command, .shift], in: plain)),
                       "⌘+ is the menu's")
        XCTAssertFalse(InterfaceZoomCommands.takeAlternateZoomInKey(try key("=", [], in: plain)))
    }

    @MainActor
    func testReassignmentIsAtomicAndRestoringRemovesThePreference() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("ShortcutReassignment")))
        let prefs = MacShortcutPreferences(defaults: defaults)
        let terminal = MacKeyChord(MacShortcut.toggleTerminal.defaultBinding())
        XCTAssertNil(defaults.object(forKey: MacShortcutPreferences.key))
        XCTAssertEqual(prefs.assign(terminal, to: .newTask, send: .return), .conflicts([.toggleTerminal]))
        XCTAssertNil(defaults.object(forKey: MacShortcutPreferences.key))
        XCTAssertEqual(prefs.assign(terminal, to: .newTask, send: .return, replacing: [.toggleTerminal]), .ready)
        XCTAssertEqual(defaults.dictionary(forKey: MacShortcutPreferences.key) as? [String: String],
                       ["newTask": "@j", "toggleTerminal": ""])
        let reloaded = MacShortcutPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.binding(for: .newTask)?.displayText, "⌘J")
        XCTAssertNil(reloaded.binding(for: .toggleTerminal))
        XCTAssertEqual(prefs.assign(MacKeyChord(MacShortcut.newTask.defaultBinding()), to: .newTask, send: .return), .ready)
        XCTAssertEqual(prefs.snapshot.overrides, ["toggleTerminal": ""])
        prefs.restoreAll()
        XCTAssertNil(defaults.object(forKey: MacShortcutPreferences.key))
        XCTAssertEqual(prefs.binding(for: .toggleTerminal)?.displayText, "⌘J")
    }

    @MainActor
    func testSystemCommandsTakePrecedenceAndLeaveNoDormantOverride() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("ShortcutSystem")))
        let prefs = MacShortcutPreferences(defaults: defaults)
        let chord = MacKeyChord("y", [.shift, .command])
        XCTAssertEqual(prefs.assign(chord, to: .newTask, send: .return), .ready)
        let name = L10n.string("New task")
        let raw = [name: "@$y"]
        defaults.set(raw, forKey: "NSUserKeyEquivalents")
        prefs.readSystemAssignments()
        XCTAssertEqual(prefs.binding(for: .newTask)?.displayText, "⇧⌘Y")
        XCTAssertNil(defaults.object(forKey: MacShortcutPreferences.key))
        for action in [prefs.assign(nil, to: .newTask, send: .return), prefs.assign(chord, to: .palette, send: .return)] {
            guard case let .refused(message) = action else { return XCTFail("System assignment was writable") }
            XCTAssertTrue(message.contains(name))
        }
        for reserved in [MacKeyChord(" ", .command), MacKeyChord(" ", .control), MacKeyChord("\t", .command)] {
            guard case .refused = prefs.assign(reserved, to: .palette, send: .return) else { return XCTFail("Accepted a system key") }
        }
        prefs.restoreAll()
        XCTAssertEqual(defaults.dictionary(forKey: "NSUserKeyEquivalents") as? [String: String], raw)
        prefs.setSystemAssignments([])
        XCTAssertEqual(prefs.binding(for: .newTask)?.displayText, "⌘N")
    }

    @MainActor
    func testFocusedResponderAndComposerUseTheRecordedChordAndForgetTheOldOne() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("ShortcutDispatch")))
        let prefs = MacShortcutPreferences(defaults: defaults)
        let chord = MacKeyChord("y", [.control, .option])
        let old = MacKeyChord(MacShortcut.attachSelection.defaultBinding())
        XCTAssertEqual(prefs.assign(chord, to: .attachSelection, send: .return), .ready)
        XCTAssertTrue(MacShortcut.attachSelection.matches(chord.event, in: prefs))
        XCTAssertFalse(MacShortcut.attachSelection.matches(old.event, in: prefs))
        XCTAssertEqual(prefs.assign(nil, to: .attachSelection, send: .return), .ready)
        XCTAssertFalse(MacShortcut.attachSelection.matches(chord.event, in: prefs))
        XCTAssertEqual(prefs.assign(chord, to: .composerSend, send: .commandReturnForMultiline), .ready)
        XCTAssertEqual(ComposerReturnKey.resolve(chord, send: .commandReturnForMultiline, draft: "", preferences: prefs), .send)
        XCTAssertNil(ComposerReturnKey.resolve(.init("\r", .command), send: .commandReturnForMultiline, draft: "", preferences: prefs))
        XCTAssertNil(ComposerReturnKey.resolve(.init("\r", []), send: .commandReturnForMultiline, draft: "", preferences: prefs))
        XCTAssertEqual(ComposerReturnKey.resolve(.init("\r", []), send: .commandReturnForMultiline, draft: "a\nb", preferences: prefs), .newline)
    }

    @MainActor
    func testShortcutSettingsRenderAtBothSizesAndAppearances() throws {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd"
        let directory = try WindowlessRender.directory("design-audit/shortcuts-" + stamp.string(from: .now))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("ShortcutRenders")))
        let prefs = MacShortcutPreferences(defaults: defaults)
        let editor = ShortcutEditor(preferences: prefs, isSystemHotKey: { _ in false })
        let custom = MacKeyChord("y", [.option, .control])
        for scene in ["list", "search", "record", "custom", "cleared", "conflict", "reserved", "system-command", "system-conflict", "restore", "restored"] {
            for appearance in WindowlessRender.Appearance.allCases {
                for (width, height, sizeName) in [(820, 620, "default"), (560, 440, "narrow")] {
                    editor.cancel()
                    prefs.setSystemAssignments([])
                    prefs.restoreAll()
                    editor.query = scene == "list" ? "" : L10n.string("Command palette")
                    switch scene {
                    case "record": editor.start(.palette)
                    case "custom", "cleared":
                        XCTAssertEqual(prefs.assign(scene == "custom" ? custom : nil, to: .palette, send: .return), .ready)
                        editor.start(.palette)
                    case "conflict": editor.set(.init("j", .command), for: .palette, send: .return)
                    case "reserved": editor.set(.init(" ", .control), for: .palette, send: .return)
                    case "system-command", "system-conflict":
                        prefs.setSystemAssignments([.init(name: L10n.string("New task"), chord: custom, commands: [.newTask])])
                        if scene == "system-command" { editor.query = L10n.string("New task") }
                        else { editor.set(custom, for: .palette, send: .return) }
                    case "restore", "restored":
                        XCTAssertEqual(prefs.assign(custom, to: .palette, send: .return), .ready)
                        if scene == "restore" { editor.confirmsRestore = true }
                        else { prefs.restoreAll() }
                    default: break
                    }
                    let size = CGSize(width: width, height: height)
                    let view = SettingsCenterView(size: size, initialSection: SettingsSection.keyboardShortcuts.rawValue,
                                                  shortcutEditor: editor)
                        .environment(\.colorScheme, appearance.colorScheme)
                    let host = WindowlessRender.Host(view, size: size, appearance: appearance, alpha: 0)
                    defer { host.close() }
                    host.settle(passes: 3, interval: 0.01)
                    let capture = try host.capture()
                    XCTAssertEqual(capture.bitmap.pixelsWide, width * Int(capture.backingScaleFactor))
                    try WindowlessRender.writePNG(capture.bitmap, to: directory.appending(path: "\(scene)-\(sizeName)-\(appearance.suffix).png"))
                }
            }
        }
    }
}

extension MacShortcutTests {
    @MainActor
    func testRecordingFromTheSettingsRowConsumesOnlyItsOwnWindowsKey() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("ShortcutRecorder")))
        let prefs = MacShortcutPreferences(defaults: defaults)
        let editor = ShortcutEditor(preferences: prefs, isSystemHotKey: { _ in false })
        editor.query = L10n.string("Command palette")
        let host = WindowlessRender.Host(KeyboardShortcutsSettings(editor: editor), size: CGSize(width: 430, height: 450), alpha: 0)
        defer { host.close() }
        host.settle()
        editor.start(.palette)
        await host.settle(until: { host.window.firstResponder is ShortcutRecorder.KeyView })
        // Returning to the same row after the search field took focus starts recording again.
        host.window.makeFirstResponder(nil)
        editor.start(.palette)
        await host.settle(until: { host.window.firstResponder is ShortcutRecorder.KeyView })
        let recorder = try XCTUnwrap(host.window.firstResponder as? ShortcutRecorder.KeyView)
        func key(in window: Int) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
                windowNumber: window, context: nil, characters: "y", charactersIgnoringModifiers: "y",
                isARepeat: false, keyCode: 16))
        }
        XCTAssertFalse(recorder.handle(try key(in: 0)))
        XCTAssertTrue(recorder.handle(try key(in: host.window.windowNumber)))
        XCTAssertEqual(prefs.binding(for: .palette)?.displayText, "⌃Y")
        XCTAssertNil(editor.selection)
    }

    @MainActor
    func testShiftedPunctuationConflictUsesTheCurrentLayoutsCharacter() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("ShortcutPunctuation")))
        let prefs = MacShortcutPreferences(defaults: defaults)
        let editor = ShortcutEditor(preferences: prefs, isSystemHotKey: { _ in false })
        let key = MacShortcutEvent(flags: [.command, .shift], keyCode: 44, character: "/", unmodified: "?")
        editor.start(.palette)
        editor.record(key, for: .palette, send: .return)
        let captured = try XCTUnwrap(MacKeyChord(event: key))
        XCTAssertEqual(editor.edit, .conflict(captured, [.help]))
        XCTAssertNil(defaults.object(forKey: MacShortcutPreferences.key))
        editor.set(captured, for: .palette, send: .return, replacing: [.help])
        XCTAssertEqual(prefs.binding(for: .palette)?.displayText, "⇧⌘/")
        XCTAssertNil(prefs.binding(for: .help))
    }

    @MainActor
    func testBrowserTabResponderUsesTheChangedKeyOnlyWhileFocused() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("ShortcutPage")))
        let prefs = MacShortcutPreferences(defaults: defaults)
        let view = BrowserHostView(frame: NSRect(x: 0, y: 0, width: 220, height: 120))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        view.shortcutPreferences = prefs
        var actions: [BrowserPanelShortcut] = []
        view.onShortcut = { actions.append($0) }
        func tab(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
                isARepeat: false, keyCode: 48))
        }

        XCTAssertTrue(window.makeFirstResponder(view))
        XCTAssertTrue(view.performKeyEquivalent(with: try tab(.control)))
        let changed = MacKeyChord("\t", [.control, .option])
        XCTAssertEqual(prefs.assign(changed, to: .browserNext, send: .return), .ready)
        XCTAssertFalse(view.performKeyEquivalent(with: try tab(.control)))
        XCTAssertTrue(view.performKeyEquivalent(with: try tab([.control, .option])))
        window.makeFirstResponder(nil)
        XCTAssertFalse(view.performKeyEquivalent(with: try tab([.control, .option])))
        XCTAssertEqual(actions, [.nextTab, .nextTab])
    }
}
