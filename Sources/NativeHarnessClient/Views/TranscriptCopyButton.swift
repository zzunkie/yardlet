import AppKit
import SwiftUI

@MainActor
/// The one place the app writes text for the person to paste. A test process writes to a pasteboard of
/// its own, never the person's: a test that pressed Copy once replaced what they had copied (an image
/// they meant to paste came back as a test's sample message, 2026-10-23).
enum TranscriptClipboard {
    static let pasteboard: NSPasteboard = NSClassFromString("XCTestCase") == nil
        ? .general : NSPasteboard(name: NSPasteboard.Name("Yardlet.tests.\(ProcessInfo.processInfo.processIdentifier)"))

    @discardableResult
    static func copy(_ payload: String?, to pasteboard: NSPasteboard = TranscriptClipboard.pasteboard) -> Bool {
        guard let payload else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(payload, forType: .string)
    }
}

struct TranscriptCopyButton: View {
    let title: String
    /// What the button copies, for assistive apps, where several such buttons sit side by side.
    var detail: String? = nil
    let payload: () -> String?
    @State private var feedback: Bool?
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        Button {
            feedback = TranscriptClipboard.copy(payload())
        } label: {
            Label(
                feedback == true ? L10n.string("Copied") : title,
                systemImage: feedback == true ? "checkmark" : "doc.on.doc"
            )
        }
        .buttonStyle(.borderless)
        .parityPointer()
        // The size of the message actions it often sits beside.
        .font(.yardlet(.caption, scale: interfaceScale))
        .foregroundStyle(.secondary)
        .accessibilityLabel(title)
        .accessibilityValue(feedback.map { L10n.string($0 ? "Copied" : "Copy failed") } ?? detail ?? "")
        .help(feedback == false ? L10n.string("Copy failed") : title)
        .task(id: feedback) {
            guard feedback != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            feedback = nil
        }
    }
}
