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
            Button(L10n.string("Find")) { find?.openFromKeyWindow() }
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
}

extension ConversationFindModel {
    /// Edit › Find and the task header's Find button: opens the bar, or brings the keyboard back to it,
    /// starting from the key window's selected text and returning focus where it was once it closes.
    func openFromKeyWindow() {
        let window = NSApp.keyWindow
        let editor = window?.firstResponder as? NSTextView
        // With the bar already open, the field's own selection is not a new query.
        let selection = isPresented && editor?.isFieldEditor == true
            ? nil : ConversationFindSelection.text(in: editor)
        var returnFocus: (@MainActor () -> Bool)?
        if !isPresented, let bookmark = WindowFocusBookmark(window: window) {
            returnFocus = { bookmark.restore() }
        }
        open(selection: selection, returnFocus: returnFocus)
    }

    /// The bar's close button and the header's Find button while the bar is open: the keyboard goes
    /// back where it was before the bar opened, or to the conversation.
    func close(fallingBackTo keyboardFocus: TaskKeyboardFocus?) {
        if !close() { keyboardFocus?.move(to: .chat) }
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
