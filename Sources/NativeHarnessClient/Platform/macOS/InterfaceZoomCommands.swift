import AppKit
import SwiftUI

/// View › Actual Size, Zoom In and Zoom Out, in the Claude and Codex apps' order and keys. They change the zoom every
/// window draws at (`InterfaceZoom`, read by `YardletWindowPreferences`), so the menu reads nothing: a command holding
/// a preference would be built again with the menu bar whenever it changed. A view that zooms its own content, the
/// browser's page or an image, takes the same keys first while it has the keyboard, as views take key equivalents
/// before the menu bar.
struct InterfaceZoomCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            Button(L10n.string("Actual Size")) { InterfaceZoom.actualSize() }
                .keyboardShortcut(MacShortcut.actualSize.menuBinding)
            Button(L10n.string("Zoom In")) { InterfaceZoom.zoomIn() }
                .keyboardShortcut(MacShortcut.zoomIn.menuBinding)
            Button(L10n.string("Zoom Out")) { InterfaceZoom.zoomOut() }
                .keyboardShortcut(MacShortcut.zoomOut.menuBinding)
        }
    }

    /// ⌘= beside the menu's ⌘+, as browsers and the Claude and Codex apps take both: a menu item has one key, and ⌘+
    /// is ⌘⇧= on most layouts. The window's views get the key first, as they would before the menu.
    @MainActor static func watchAlternateZoomInKey() {
        _ = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            takeAlternateZoomInKey(event) ? nil : event
        }
    }

    /// Whether `event` was Zoom In's other key, which the window's views or the zoom then took.
    @MainActor static func takeAlternateZoomInKey(_ event: NSEvent) -> Bool {
        // Every key typed passes here: anything without ⌘ goes on at once.
        guard event.modifierFlags.contains(.command), let window = event.window else { return false }
        let key = MacShortcutEvent(event)
        guard MacShortcutPreferences.shared.additionalKeys(for: .zoomIn, send: .return).contains(where: { $0.matches(key) })
        else { return false }
        if !window.performKeyEquivalent(with: event) { InterfaceZoom.zoomIn() }
        return true
    }
}
