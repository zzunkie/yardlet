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
            .surfaceChat, .surfaceReview, .surfaceTerminal, .surfaceBrowser, .attachSelection]
        XCTAssertEqual(commands.map { $0.defaultBinding().displayText }, [
            "⌘,", "⌘K", "⌘?", "⌘N", "⇧⌘S", "⇧⌘[", "⇧⌘]", "⌥⌘A", "⌥⌘U", "⌥⌘P", "⇧⌘U", "⇧⌘A", "⌃⌘I",
            "⌥⌘B", "⌘J", "⌃\u{60}", "⌃⇧M", "⌘[", "⌘]", "⌘T", "⌘W", "⇧⌘W", "⇧⌘T", "⌃⇥", "⌃⇧⇥", "⇧⌘D",
            "⌥⇧⌘D", "⌃⌘W", "⌥⌘←", "⌥⌘→", "⌥⌘↑", "⌥⌘↓", "⌘F", "⌘G", "⇧⌘G", "⌘1", "⌘2", "⌘3", "⌘4", "⇧⌘L"
        ])
        for number in 1...9 {
            XCTAssertEqual(MacShortcut.pinnedRow(number).defaultBinding().displayText, "⌃\(number)")
            XCTAssertEqual(MacShortcut.browserTab(number).defaultBinding().displayText, "⌘\(number)")
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
