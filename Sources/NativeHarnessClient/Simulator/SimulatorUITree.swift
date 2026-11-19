import Foundation

/// A rectangle on a device's screen in the units the agent's tools use (points on iOS, dp on Android), from the
/// screen's top left.
struct SimulatorUIRect: Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }
}

/// An element of the screen's accessibility tree, as the platform describes it: iOS's accessibility runtime, Android's
/// UI Automator.
struct SimulatorUIElement: Equatable, Sendable {
    /// What the element is, in a few words: `button`, `text field`, `static text`, `image`, `switch`.
    var role: String
    var label: String?
    var value: String?
    /// The app's own name for it: an accessibility identifier on iOS, a resource id on Android.
    var identifier: String?
    var frame: SimulatorUIRect
    var children: [SimulatorUIElement] = []
}

/// The elements of the app in front, and whether the platform's reading stopped at its limit before the end.
struct SimulatorUITree: Equatable, Sendable {
    var elements: [SimulatorUIElement]
    var truncated = false
}

/// `simulator_snapshot`'s text: one line for each element that names or shows something, indented by nesting, with a
/// reference (`@e3`) for each one whose middle is on the screen, which `simulator_tap` takes in place of a point.
/// Groups and layouts without a label or value are read through, their children at their place. Every label, value and identifier is scrubbed before it is cut.
enum SimulatorSnapshot {
    struct Target: Equatable, Sendable {
        var frame: SimulatorUIRect
        /// The element as the line names it: `button “Settings”`.
        var name: String
    }

    struct Result: Equatable, Sendable {
        var text: String
        var refs: [String: Target]
        var isTruncated: Bool
    }

    static let longestText = 200
    static let maximumNesting = 64

    /// Roles that say nothing by themselves: their elements are shown only when they carry a label or value.
    static let containerRoles: Set<String> = ["group", "unknown", "layout", "view", "scroll area", "window"]

    static func render(_ tree: SimulatorUITree, screen: SimulatorToolScreen, maximumLength: Int = 40_000,
                       scrub: @escaping (String) -> String = { $0 }) -> Result {
        var renderer = Renderer(screen: screen, maximumLength: maximumLength, scrub: scrub)
        for element in tree.elements { renderer.visit(element, depth: 0, nesting: 0) }
        var text = renderer.lines.joined(separator: "\n")
        if text.isEmpty { text = "(The screen has no readable elements; take a screenshot to see it.)" }
        let truncated = renderer.isTruncated || tree.truncated
        if truncated {
            text += "\n… The screen has more elements than one snapshot reads; the rest was left out. Scroll, or take a "
                + "screenshot."
        }
        return Result(text: text, refs: renderer.refs, isTruncated: truncated)
    }

    /// A platform's role in the tools' words: `AXStaticText` reads `static text`.
    static func roleName(_ role: String) -> String {
        guard role.hasPrefix("AX"), role.count > 2 else { return role }
        var words: [String] = []
        var word = ""
        for character in role.dropFirst(2) {
            if character.isUppercase, !word.isEmpty {
                words.append(word)
                word = ""
            }
            word.append(character)
        }
        if !word.isEmpty { words.append(word) }
        return words.joined(separator: " ").lowercased()
    }

    private struct Renderer {
        let screen: SimulatorToolScreen
        let maximumLength: Int
        let scrub: (String) -> String
        var lines: [String] = []
        var refs: [String: Target] = [:]
        var length = 0
        var isTruncated = false

        mutating func visit(_ element: SimulatorUIElement, depth: Int, nesting: Int) {
            guard !isTruncated, nesting < SimulatorSnapshot.maximumNesting else { return }
            let role = SimulatorSnapshot.roleName(element.role)
            let label = cleaned(element.label)
            let value = cleaned(element.value).flatMap { $0 == label ? nil : $0 }
            let identifier = cleaned(element.identifier).flatMap { $0 == label ? nil : $0 }
            // A layout's id alone (Android's `content`, `main_content`) says nothing to the agent.
            let isContainer = SimulatorSnapshot.containerRoles.contains(role)
            guard label != nil || value != nil || !isContainer else {
                for child in element.children { visit(child, depth: depth, nesting: nesting + 1) }
                return
            }
            var line = String(repeating: "  ", count: depth) + "- " + role
            if let label { line += " \"\(label)\"" }
            if let value { line += " [value=\(value)]" }
            if let identifier { line += " [id=\(identifier)]" }
            let frame = element.frame
            if frame.width > 0, frame.height > 0 {
                if (0...Double(screen.width)).contains(frame.midX), (0...Double(screen.height)).contains(frame.midY) {
                    let ref = "@e\(refs.count + 1)"
                    refs[ref] = Target(frame: frame, name: role + (label.map { " “\($0)”" } ?? ""))
                    line += " [ref=\(ref)]"
                } else {
                    line += " [off screen]"
                }
            }
            guard length + line.utf8.count + 1 <= maximumLength else {
                isTruncated = true
                return
            }
            length += line.utf8.count + 1
            lines.append(line)
            for child in element.children { visit(child, depth: depth + 1, nesting: nesting + 1) }
        }

        /// Scrubbed, on one line, and cut.
        private func cleaned(_ text: String?) -> String? {
            guard let text else { return nil }
            let flat = scrub(text).split(whereSeparator: \.isNewline).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !flat.isEmpty else { return nil }
            return flat.count > SimulatorSnapshot.longestText
                ? String(flat.prefix(SimulatorSnapshot.longestText)) + "…" : flat
        }
    }
}
