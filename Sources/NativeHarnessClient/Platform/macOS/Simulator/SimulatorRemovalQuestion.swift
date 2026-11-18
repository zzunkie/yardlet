import AppKit
import Foundation

/// The question Settings › General › Simulator asks as it turns off, when Yardlet installed something for the
/// simulators that is still as it left it: Remove first, Keep second. What Xcode, Android Studio or the person
/// installed is never listed.
struct SimulatorRemovalQuestion: Equatable {
    let title: String
    let message: String

    init(items: [SimulatorInstalledItem]) {
        title = L10n.string("Remove what Yardlet installed for simulators?")
        message = items.map(Self.line).joined(separator: "\n") + "\n\n"
            + L10n.string("What Xcode, Android Studio or you installed stays.")
    }

    @MainActor
    func alert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L10n.string("Remove"))
        alert.addButton(withTitle: L10n.string("Keep"))
        return alert
    }

    /// What could not be removed, and why.
    @MainActor
    static func failureAlert(_ failures: [(SimulatorInstalledItem, String)]) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("Some of what Yardlet installed couldn't be removed.")
        alert.informativeText = failures.map { "\(line($0.0)): \($0.1)" }.joined(separator: "\n")
        alert.addButton(withTitle: L10n.string("OK"))
        return alert
    }

    private static func line(_ item: SimulatorInstalledItem) -> String {
        "• " + item.displayName + (item.bytes.map { " (\(SimulatorMissingPart.size($0)))" } ?? "")
    }
}
