import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The task composer, whose empty field shows the suggestion as its faint text (the Claude app's
/// composer), mounted in an unshown window with the real field editor: Tab and → put the suggestion
/// into the composer without sending it, Tab while
/// a Korean syllable is being composed stays the input method's, typing lets the suggestion go, and
/// nothing shows while a turn runs or with the setting off. Images go to `.build/next-prompt-qa/`.
/// No provider, CLI, app window or screen capture.
@MainActor final class NextMessageSuggestionComposerTests: XCTestCase {
    private static let suggestion = "run the tests"

    /// A Claude task's composer, counting sends.
    @MainActor private final class Probe {
        let draft = TaskComposerDraft()
        let focus = TaskKeyboardFocus()
        var sent: [HarnessUserInput] = []
    }

    private func surface(_ probe: Probe, isRunning: Bool = false, harness: HarnessKind = .claudeCode,
                         defaults: UserDefaults? = nil) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            PromptComposer(harness: harness, composerDraft: probe.draft, isRunning: isRunning,
                           actions: ComposerActions(send: { probe.sent.append($0) }))
        }
        .environment(\.taskKeyboardFocus, probe.focus)
        .defaultAppStorage(defaults ?? .yardlet)
    }

    @MainActor private struct Mounted {
        let host: WindowlessRender.Host<AnyView>
        var window: NSWindow { host.window }
        var elements: [WindowlessRender.AccessibilityElement] { host.accessibilityElements() }
        func shows(_ label: String) -> Bool { elements.contains { $0.label == label } }
        /// The empty composer's faint text, where the suggestion shows.
        var placeholder: String? {
            func fields(_ view: NSView) -> [ComposerMarkdownTextView] {
                (view as? ComposerMarkdownTextView).map { [$0] } ?? view.subviews.flatMap(fields)
            }
            return fields(host.hosting).first?.placeholder
        }
        func showsSuggestion(_ text: String) -> Bool { placeholder == text }
    }

    private func mount(_ view: some View, size: NSSize = NSSize(width: 760, height: 260),
                       appearance: WindowlessRender.Appearance? = nil, focus: Bool = true) throws -> Mounted {
        let host = WindowlessRender.Host(AnyView(view.frame(width: size.width, height: size.height, alignment: .bottom)
            .background(ParityTheme.canvas)), size: size, appearance: appearance)
        addTeardownBlock { @MainActor in host.close() }
        host.settle()
        if focus {
            let field = try XCTUnwrap(views(ComposerMarkdownTextView.self, in: host.hosting).first)
            XCTAssertTrue(host.window.makeFirstResponder(field))
            host.settle(passes: 4)
        }
        return Mounted(host: host)
    }

    private func editor(_ mounted: Mounted) throws -> NSTextView {
        try XCTUnwrap(mounted.window.firstResponder as? NSTextView)
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

    private func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        ([root] + root.subviews.flatMap { views(NSView.self, in: $0) }).compactMap { $0 as? T }
    }

    // MARK: - Tab, click, typing

    func testTabPutsTheSuggestionInTheComposerWithoutSendingIt() throws {
        let probe = Probe()
        probe.draft.nextMessageSuggestion = Self.suggestion
        let mounted = try mount(surface(probe))
        XCTAssertTrue(mounted.showsSuggestion(Self.suggestion), "The empty composer shows the suggestion as its faint text")

        try press("\t", keyCode: 48, in: mounted)
        XCTAssertEqual(probe.draft.text, Self.suggestion)
        XCTAssertNil(probe.draft.nextMessageSuggestion)
        XCTAssertTrue(probe.sent.isEmpty, "Tab never sends")
        XCTAssertFalse(mounted.showsSuggestion(Self.suggestion), "Taken, the faint text is gone")
        let editor = try editor(mounted)
        XCTAssertEqual(editor.string, Self.suggestion)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: (Self.suggestion as NSString).length, length: 0),
                       "The caret waits after the words")

        // The person edits it and sends that: the words go as any typed message does.
        editor.insertText(" again", replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
        mounted.host.settle()
        try press("\r", keyCode: 36, in: mounted)
        XCTAssertEqual(probe.sent.map(\.text), ["run the tests again"])
    }

    /// A Codex task's composer takes the Codex app's prediction the same way.
    func testTabPutsACodexPredictionInTheComposerWithoutSendingIt() throws {
        let probe = Probe()
        let prediction = "Rerun only the failing tests"
        probe.draft.nextMessageSuggestion = prediction
        let mounted = try mount(surface(probe, harness: .codex))
        XCTAssertTrue(mounted.showsSuggestion(prediction))
        try press("\t", keyCode: 48, in: mounted)
        XCTAssertEqual(probe.draft.text, prediction)
        XCTAssertNil(probe.draft.nextMessageSuggestion)
        XCTAssertTrue(probe.sent.isEmpty, "Tab never sends")
        XCTAssertEqual(try editor(mounted).selectedRange(), NSRange(location: (prediction as NSString).length, length: 0))
    }

    func testRightArrowPutsTheSuggestionInTheComposerWithoutSendingIt() throws {
        let probe = Probe()
        probe.draft.nextMessageSuggestion = Self.suggestion
        let mounted = try mount(surface(probe))
        try press("\u{F703}", keyCode: 124, modifiers: [.function, .numericPad], in: mounted)
        XCTAssertEqual(probe.draft.text, Self.suggestion)
        XCTAssertTrue(probe.sent.isEmpty, "→ never sends")
        XCTAssertEqual(try editor(mounted).selectedRange(),
                       NSRange(location: (Self.suggestion as NSString).length, length: 0))
    }

    /// While an input method composes, SwiftUI keeps the marked letter out of the composer's text, so
    /// the draft still reads empty and the suggestion still shows. Tab then belongs to the input method
    /// (`takesSuggestion` sees the marked text): the suggestion is not put in, and the syllable the
    /// field commits is typing, which lets the suggestion go.
    func testTabWhileAKoreanSyllableIsComposedStaysWithTheInputMethod() throws {
        let probe = Probe()
        probe.draft.nextMessageSuggestion = Self.suggestion
        let mounted = try mount(surface(probe))
        let editor = try editor(mounted)
        editor.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        mounted.host.settle(passes: 2)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(probe.draft.text, "", "The composition has not reached the draft")
        XCTAssertTrue(mounted.showsSuggestion(Self.suggestion), "so the suggestion still shows")

        try press("\t", keyCode: 48, in: mounted)
        XCTAssertFalse(probe.draft.text.contains(Self.suggestion), "Nothing is taken while the syllable is composed")
        XCTAssertFalse(editor.string.contains(Self.suggestion))
        XCTAssertTrue(probe.sent.isEmpty)
        if !probe.draft.text.isEmpty {
            XCTAssertNil(probe.draft.nextMessageSuggestion, "The committed syllable is typing")
        }
    }

    func testCommittingAKoreanSyllableLetsTheSuggestionGo() throws {
        let probe = Probe()
        probe.draft.nextMessageSuggestion = Self.suggestion
        let mounted = try mount(surface(probe))
        let editor = try editor(mounted)
        editor.setMarkedText("하", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        mounted.host.settle(passes: 2)
        editor.insertText("한", replacementRange: editor.markedRange())
        mounted.host.settle()
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(probe.draft.text, "한")
        XCTAssertNil(probe.draft.nextMessageSuggestion)
        XCTAssertFalse(mounted.showsSuggestion(Self.suggestion))
        XCTAssertTrue(probe.sent.isEmpty)
    }

    func testTypingLetsTheSuggestionGo() throws {
        let probe = Probe()
        probe.draft.nextMessageSuggestion = Self.suggestion
        let mounted = try mount(surface(probe))
        let editor = try editor(mounted)
        editor.insertText("c", replacementRange: NSRange(location: 0, length: 0))
        mounted.host.settle()
        XCTAssertNil(probe.draft.nextMessageSuggestion)
        XCTAssertFalse(mounted.showsSuggestion(Self.suggestion))
        editor.selectAll(nil)
        editor.deleteBackward(nil)
        mounted.host.settle()
        XCTAssertEqual(probe.draft.text, "")
        XCTAssertFalse(mounted.showsSuggestion(Self.suggestion), "Emptying the composer again does not bring it back")
        try press("\t", keyCode: 48, in: mounted)
        XCTAssertEqual(probe.draft.text, "")
    }

    func testNothingShowsWhileATurnRunsOrWithTheSettingOff() throws {
        let running = Probe()
        running.draft.nextMessageSuggestion = Self.suggestion
        let busy = try mount(surface(running, isRunning: true))
        XCTAssertFalse(busy.showsSuggestion(Self.suggestion))
        try press("\t", keyCode: 48, in: busy)
        XCTAssertEqual(running.draft.text, "", "Tab takes nothing while the turn runs")

        let suite = testDefaultsSuite("NextMessageSuggestionComposer")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: NextMessageSuggestionPreference.key)
        let off = Probe()
        off.draft.nextMessageSuggestion = Self.suggestion
        let quiet = try mount(surface(off, defaults: defaults))
        XCTAssertFalse(quiet.showsSuggestion(Self.suggestion))
        try press("\t", keyCode: 48, in: quiet)
        XCTAssertEqual(off.draft.text, "", "Tab takes nothing with the setting off")
        defaults.set(true, forKey: NextMessageSuggestionPreference.key)
        quiet.host.settle()
        XCTAssertTrue(quiet.showsSuggestion(Self.suggestion), "Turning it back on shows the one that waited")
    }

    func testTheTypedListsKeepTheirTab() throws {
        let probe = Probe()
        let mounted = try mount(VStack(spacing: 0) {
            Spacer(minLength: 0)
            PromptComposer(harness: .claudeCode, composerDraft: probe.draft,
                           providerCapabilities: { var state = ProviderCapabilityState()
                               state.composerCommands = [ProviderComposerCommand(name: "review", description: "Review", argumentHint: "")]
                               return state }(),
                           isRunning: false, actions: ComposerActions(send: { probe.sent.append($0) }))
        }.environment(\.taskKeyboardFocus, probe.focus), size: NSSize(width: 760, height: 360))
        let editor = try editor(mounted)
        for character in "/re" {
            editor.insertText(String(character), replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
            mounted.host.settle(passes: 2)
        }
        try press("\t", keyCode: 48, in: mounted)
        XCTAssertEqual(probe.draft.text, "/review ", "Tab still chooses the typed list's row")
    }

    // MARK: - Renders

    func testTheSuggestionDrawsInBothAppearances() throws {
        let directory = try WindowlessRender.directory("next-prompt-qa")
        let long = "Run the full test suite again with the verbose flag and report which of the snapshot tests still fail on CI"
        let scenarios: [(name: String, suggestion: String?, harness: HarnessKind, size: NSSize)] = [
            ("claude-suggestion", Self.suggestion, .claudeCode, NSSize(width: 860, height: 200)),
            ("claude-suggestion-long", long, .claudeCode, NSSize(width: 860, height: 200)),
            ("claude-suggestion-narrow", "commit this and push it", .claudeCode, NSSize(width: 520, height: 200)),
            ("codex-prediction", "Rerun only the failing tests and check that they pass", .codex, NSSize(width: 860, height: 200))
        ]
        for scenario in scenarios {
            for appearance in WindowlessRender.Appearance.allCases {
                let probe = Probe()
                probe.draft.nextMessageSuggestion = scenario.suggestion
                let mounted = try mount(surface(probe, harness: scenario.harness)
                    .environment(\.colorScheme, appearance.colorScheme),
                    size: scenario.size, appearance: appearance, focus: false)
                if let suggestion = scenario.suggestion {
                    XCTAssertEqual(mounted.placeholder, suggestion, scenario.name)
                }
                try WindowlessRender.writePNG(try mounted.host.capture().bitmap,
                    to: directory.appending(path: "\(scenario.name)-\(appearance.suffix).png"))
                mounted.host.close()
            }
        }

        // The General settings with the new row, as Settings opens it.
        for appearance in WindowlessRender.Appearance.allCases {
            let host = WindowlessRender.Host(AnyView(SettingsCenterView(initialSection: SettingsSection.general.rawValue,
                notificationCenter: LocalSystemNotificationCenter())
                .environment(\.colorScheme, appearance.colorScheme)), size: NSSize(width: 820, height: 620),
                appearance: appearance)
            host.settle()
            if appearance == .light {
                XCTAssertTrue(host.accessibilityElements().contains { $0.label == L10n.string("Next message suggestions") })
            }
            try WindowlessRender.writePNG(try host.capture().bitmap,
                to: directory.appending(path: "settings-general-\(appearance.suffix).png"))
            host.close()
        }
    }
}
