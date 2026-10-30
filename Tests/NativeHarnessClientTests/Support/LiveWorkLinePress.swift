import AppKit
@testable import NativeHarnessClient

extension NSView {
    /// Opens a running turn's live line (`ConversationLiveWorkLine`), as a click on it would, so a
    /// test can read the calls it stands for. Its label reads the current step, then the steps and
    /// time, which go on as it runs, so the button is found by the step alone; with no step given,
    /// the first live line. SwiftUI builds its accessibility tree only while an assistive app has
    /// announced itself (`AXEnhancedUserInterface`), which this sets for the press and then puts back.
    @discardableResult
    func openLiveWorkLine(step: String? = nil) -> Bool {
        let steps = [L10n.string("1 step"), L10n.format("%lld steps", Int64(2)).replacingOccurrences(of: "2", with: "")]
        func isLiveLine(_ label: String) -> Bool {
            if let step { return label.hasPrefix(step + ", ") }
            return steps.contains { !$0.isEmpty && label.contains($0) }
        }
        return pressFirstButton { label, value in isLiveLine(label) && value == L10n.string("Collapsed") }
    }

    /// Presses the first button labelled `label`, as a click on it would.
    @discardableResult
    func pressButton(labeled label: String) -> Bool {
        pressFirstButton { found, _ in found == label }
    }

    /// Presses the first button whose label `matches`, for a label that reads on as it runs.
    @discardableResult
    func pressButton(where matches: (String) -> Bool) -> Bool {
        pressFirstButton { label, _ in matches(label) }
    }

    /// Presses the first button in the accessibility tree that `matches` its label and value.
    private func pressFirstButton(where matches: (String, String?) -> Bool) -> Bool {
        WindowlessRender.withAccessibilityTree {
            func visit(_ node: AnyObject) -> AnyObject? {
                for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                    let value: Any? = (child.accessibilityValue?() as Any??) ?? nil
                    if let label = child.accessibilityLabel?() ?? nil, matches(label, value as? String),
                       (child.accessibilityRole?() ?? nil) == NSAccessibility.Role.button { return child }
                    if let found = visit(child) { return found }
                }
                return nil
            }
            return visit(self)?.accessibilityPerformPress?() ?? false
        }
    }
}
