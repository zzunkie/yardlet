import Foundation

/// The screen's elements as Android's UI Automator dumps them (`uiautomator dump`): each `node`'s class, text, content
/// description, resource id, state and bounds in pixels, turned into the tools' elements in dp.
enum AndroidUITree {
    /// The shell command that writes the dump to its output instead of a file on the device, which it then names.
    static let dumpArguments = ["exec-out", "uiautomator", "dump", "/dev/tty"]
    static let maximumElements = 1_500

    /// The dump's elements, their bounds divided by `pixelsPerDp`; nil when the text holds no hierarchy.
    static func parse(_ output: String, pixelsPerDp: Double) -> SimulatorUITree? {
        guard pixelsPerDp > 0, let start = output.range(of: "<?xml") ?? output.range(of: "<hierarchy"),
              let end = output.range(of: "</hierarchy>", options: .backwards) else { return nil }
        let reader = Reader(pixelsPerDp: pixelsPerDp)
        // Foundation's XML parser would tie the engine to libxml2 on Linux (`SimpleXML`).
        SimpleXML.read(String(output[start.lowerBound..<end.upperBound]), start: reader.start, text: { _ in },
                       end: reader.end)
        guard !reader.roots.isEmpty else { return nil }
        return SimulatorUITree(elements: reader.roots, truncated: reader.truncated)
    }

    /// The element's role from its class and whether it takes a tap: a widget's own kind, and a layout that takes a
    /// tap (a list row) as a button.
    static func role(className: String, clickable: Bool) -> String {
        let name = className.split(separator: ".").last.map(String.init) ?? className
        switch name {
        case "EditText", "AutoCompleteTextView", "MultiAutoCompleteTextView", "TextInputEditText": return "text field"
        case "Button", "ImageButton", "MaterialButton", "FloatingActionButton", "ExtendedFloatingActionButton":
            return "button"
        case "CheckBox", "MaterialCheckBox", "CheckedTextView": return "checkbox"
        case "Switch", "SwitchCompat", "SwitchMaterial", "MaterialSwitch", "ToggleButton": return "switch"
        case "RadioButton", "MaterialRadioButton": return "radio button"
        case "SeekBar", "RatingBar", "Slider": return "slider"
        case "ProgressBar": return "progress"
        case "ImageView": return clickable ? "button" : "image"
        case "TextView": return clickable ? "button" : "text"
        case "WebView": return "web view"
        case "RecyclerView", "ListView", "GridView", "ScrollView", "HorizontalScrollView", "NestedScrollView",
             "ViewPager", "ViewPager2":
            return "list"
        default: return clickable ? "button" : "group"
        }
    }

    /// `[x1,y1][x2,y2]` in pixels.
    static func bounds(_ text: String) -> (x1: Double, y1: Double, x2: Double, y2: Double)? {
        let numbers = text.split(whereSeparator: { !$0.isNumber && $0 != "-" }).compactMap { Double($0) }
        guard numbers.count == 4 else { return nil }
        return (numbers[0], numbers[1], numbers[2], numbers[3])
    }

    private final class Reader {
        let pixelsPerDp: Double
        var roots: [SimulatorUIElement] = []
        var truncated = false
        private var stack: [SimulatorUIElement] = []
        private var count = 0
        /// Nodes inside one left out past the limit, whose ends close nothing of ours.
        private var skipped = 0

        init(pixelsPerDp: Double) {
            self.pixelsPerDp = pixelsPerDp
        }

        func start(_ name: String, _ attributes: [String: String]) {
            guard name == "node" else { return }
            guard skipped == 0, count < AndroidUITree.maximumElements else {
                truncated = true
                skipped += 1
                return
            }
            count += 1
            stack.append(element(attributes))
        }

        func end(_ name: String) {
            guard name == "node" else { return }
            if skipped > 0 {
                skipped -= 1
                return
            }
            guard let done = stack.popLast() else { return }
            if stack.isEmpty {
                roots.append(done)
            } else {
                stack[stack.count - 1].children.append(done)
            }
        }

        private func element(_ attributes: [String: String]) -> SimulatorUIElement {
            func text(_ key: String) -> String? {
                attributes[key].flatMap { $0.isEmpty ? nil : $0 }
            }
            let clickable = attributes["clickable"] == "true"
            let description = text("content-desc")
            let shown = attributes["password"] == "true" ? nil : text("text")
            var value = description == nil ? nil : shown
            if attributes["checkable"] == "true" {
                value = attributes["checked"] == "true" ? "checked" : "not checked"
            }
            // `com.example:id/search` reads `search`.
            let identifier = text("resource-id").map { id in
                id.range(of: ":id/").map { String(id[$0.upperBound...]) } ?? id
            }
            let box = attributes["bounds"].flatMap(AndroidUITree.bounds) ?? (0, 0, 0, 0)
            let frame = SimulatorUIRect(x: box.x1 / pixelsPerDp, y: box.y1 / pixelsPerDp,
                                        width: max(0, box.x2 - box.x1) / pixelsPerDp,
                                        height: max(0, box.y2 - box.y1) / pixelsPerDp)
            return SimulatorUIElement(role: AndroidUITree.role(className: attributes["class"] ?? "", clickable: clickable),
                                      label: description ?? shown, value: value, identifier: identifier, frame: frame)
        }
    }
}
