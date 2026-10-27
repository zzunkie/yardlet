import AppKit
import SwiftUI

private struct YardletConversationFindKey: FocusedValueKey {
    typealias Value = ConversationFindModel
}

extension FocusedValues {
    /// The find of the task the window shows (the focused pane's task in split view).
    var yardletConversationFind: ConversationFindModel? {
        get { self[YardletConversationFindKey.self] }
        set { self[YardletConversationFindKey.self] = newValue }
    }
}

/// The Codex app's find shortcuts: `⌘F` opens the find bar (from the composer too), `⌘G` and `⇧⌘G`
/// move between its results while it is open. They sit in the Edit menu, where a Mac app keeps Find.
/// A focused browser page keeps its own `⌘F`, which it handles before the menu.
enum ConversationFindShortcut {
    static let find = KeyboardShortcut("f", modifiers: .command)
    static let next = KeyboardShortcut("g", modifiers: .command)
    static let previous = KeyboardShortcut("g", modifiers: [.command, .shift])
}

struct YardletConversationFindCommands: Commands {
    @FocusedValue(\.yardletConversationFind) private var find

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Button(L10n.string("Find")) { open() }
                .keyboardShortcut(ConversationFindShortcut.find)
                .disabled(find == nil)
            Button(L10n.string("Next result")) { find?.next() }
                .keyboardShortcut(ConversationFindShortcut.next)
                .disabled(find == nil)
            Button(L10n.string("Previous result")) { find?.previous() }
                .keyboardShortcut(ConversationFindShortcut.previous)
                .disabled(find == nil)
        }
    }

    private func open() {
        guard let find else { return }
        let window = NSApp.keyWindow
        let editor = window?.firstResponder as? NSTextView
        // With the bar already open, the field's own selection is not a new query.
        let selection = find.isPresented && editor?.isFieldEditor == true
            ? nil : ConversationFindSelection.text(in: editor)
        var returnFocus: (@MainActor () -> Bool)?
        if !find.isPresented, let bookmark = WindowFocusBookmark(window: window) {
            returnFocus = { bookmark.restore() }
        }
        find.open(selection: selection, returnFocus: returnFocus)
    }
}

enum ConversationFindSelection {
    /// A short selection in a text view, the way ⌘F in the Codex app starts from selected text.
    @MainActor
    static func text(in editor: NSTextView?) -> String? {
        guard let editor else { return nil }
        let range = editor.selectedRange()
        guard range.location != NSNotFound, range.length > 0, range.length <= 500,
              NSMaxRange(range) <= (editor.string as NSString).length else { return nil }
        return (editor.string as NSString).substring(with: range)
    }
}
