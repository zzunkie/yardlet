import Foundation
import UWP
import WinSDK
import WinUI

/// A composer's field as the Mac's composer and the harnesses' own apps have it: it holds several lines, Enter sends
/// what it holds and Shift+Enter starts a new line. A field that accepts Return takes Enter as a new line before a
/// KeyDown handler sees it, so Enter is read on its way down (PreviewKeyDown). With the Microsoft Korean IME the
/// field's text already holds the syllable being composed when Enter comes in, and no composition end follows
/// (`Windows/scripts/check-window.ps1` types through the IME to check this).
@MainActor
enum ComposerKeys {
    /// The tallest a composer grows before it scrolls, about eight lines.
    static let maximumHeight: Double = 200

    /// While a task's turn runs, Ctrl+Enter sends the other way (`alternate`, where it returns true), as the Mac's
    /// ⌘Return does, and Escape stops what runs (`escape`), as the Mac composer's Escape does.
    static func prepare(_ field: TextBox, send: @escaping @MainActor () -> Void,
                        alternate: (@MainActor () -> Bool)? = nil, escape: (@MainActor () -> Bool)? = nil) {
        field.textWrapping = .wrap
        field.acceptsReturn = true
        field.maxHeight = maximumHeight
        field.previewKeyDown.addHandler { _, args in
            guard let args else { return }
            switch args.key {
            case .enter where isDown(VK_SHIFT):
                return
            case .enter where isDown(VK_CONTROL):
                guard let alternate, alternate() else { return }
                args.handled = true
            case .enter:
                args.handled = true
                send()
            case .escape:
                if let escape, escape() { args.handled = true }
            default:
                return
            }
        }
    }

    /// The button beside a composer that sends what it holds, named for UI Automation as it reads.
    static func sendButton(_ title: String, action: @escaping @MainActor () -> Void) -> Button {
        let button = Button()
        button.content = title
        button.verticalAlignment = .bottom
        button.isEnabled = false
        try? AutomationProperties.setName(button, title)
        button.click.addHandler { _, _ in action() }
        return button
    }

    /// Whether `text` holds something to send.
    static func canSend(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Ctrl is held, as a click that does more than choose reads it (⌘ on the Mac).
    static var isControlDown: Bool { isDown(VK_CONTROL) }

    private static func isDown(_ key: Int32) -> Bool {
        GetKeyState(key) < 0
    }
}
