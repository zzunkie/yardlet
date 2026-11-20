import Foundation

/// Turns CDP `Accessibility.getFullAXTree` answers into the text an agent reads, and gives each
/// element it can act on a reference such as `@e3` that maps to the element's backend DOM node.
/// A page's frames each have their own tree (a frame from another site lives in another renderer and
/// answers on its own DevTools session); each frame's tree is placed under the iframe that holds it.
enum BrowserAgentSnapshot {
    /// One frame's accessibility tree.
    struct Frame {
        var nodes: [JSONValue]
        /// The DevTools session that answers for the frame's nodes; nil for the tab's own.
        var session: String?
        /// The frames placed in this one, by the backend node of the iframe that holds each (in this
        /// frame's session): indexes into the frames given to `render`.
        var children: [Int: Int] = [:]

        init(nodes: [JSONValue], session: String? = nil, children: [Int: Int] = [:]) {
            self.nodes = nodes
            self.session = session
            self.children = children
        }

        /// Whether the element with this backend node is in the frame's tree.
        func holds(_ backend: Int) -> Bool {
            nodes.contains { $0["backendDOMNodeId"]?.integerValue == Int64(backend) }
        }
    }

    /// Where a reference's element is: its backend DOM node, in the session that answers for its frame.
    struct Ref: Equatable, Hashable {
        var node: Int
        var session: String?
    }

    struct Result: Equatable {
        var text: String
        var refs: [String: Ref]
        var isTruncated: Bool
        /// The number the next element without a reference gets.
        var nextNumber = 1
    }

    /// Containers that only group other content; without a name they add a level and no meaning.
    private static let transparentRoles: Set<String> = [
        "generic", "none", "presentation", "GenericContainer", "LayoutTable", "LayoutTableRow",
        "LayoutTableCell", "Pre", "Ruby", "LineBreak", "strong", "emphasis", "subscript", "superscript",
        "mark", "time", "abbr", "code"
    ]
    private static let valueRoles: Set<String> = [
        "textbox", "searchbox", "combobox", "spinbutton", "slider", "TextField", "ComboBoxMenuButton"
    ]
    /// Roles an agent acts on, which get a reference even when the page did not make them focusable.
    private static let actionableRoles: Set<String> = [
        "button", "link", "textbox", "searchbox", "combobox", "checkbox", "radio", "switch", "slider", "spinbutton",
        "menuitem", "menuitemcheckbox", "menuitemradio", "option", "tab", "treeitem", "listbox", "scrollbar",
        "gridcell", "PopUpButton", "ToggleButton", "TextField", "ComboBoxMenuButton", "ComboBoxSelect",
        "DisclosureTriangle", "Iframe", "heading"
    ]
    private static let booleanProperties = ["checked", "pressed", "expanded", "selected", "disabled", "required",
                                            "focused", "readonly", "invalid"]

    /// One tree, the tab's own frame alone.
    static func render(nodes: [JSONValue], maximumLength: Int = 60_000) -> Result {
        render(frames: [Frame(nodes: nodes)], maximumLength: maximumLength)
    }

    /// The first frame is the page's main frame; the others hang under the iframes that hold them. The elements in
    /// `hidden` (a field the password manager filled, an element showing such a value) read as `<redacted>`, with
    /// nothing of what is in them; `scrub` takes values out of each name and value before a long one is cut. An element
    /// in `named` keeps the reference an earlier snapshot gave it, as Playwright's references stay with their elements;
    /// the others are numbered on from `nextNumber`, so no number names two elements.
    static func render(frames: [Frame], maximumLength: Int = 60_000, hidden: Set<Ref> = [],
                       scrub: @escaping (String) -> String = { $0 }, named: [Ref: String] = [:], nextNumber: Int = 1) -> Result {
        guard let main = frames.first else {
            return Result(text: "(The page has no readable content.)", refs: [:], isTruncated: false, nextNumber: nextNumber)
        }
        var renderer = Renderer(frames: frames, maximumLength: maximumLength,
                                pageOrigin: rootURL(of: main.nodes).flatMap(origin(of:)), hidden: hidden, scrub: scrub)
        renderer.named = named
        renderer.nextNumber = nextNumber
        renderer.lines = renderer.visitFrame(0, depth: 0)
        var text = renderer.lines.joined(separator: "\n")
        if renderer.isTruncated {
            text += "\n… The page is larger than one snapshot; the rest was left out. Scroll, or read a part "
                + "with browser_evaluate."
        }
        return Result(text: text.isEmpty ? "(The page has no readable content.)" : text,
                      refs: renderer.refs, isTruncated: renderer.isTruncated, nextNumber: renderer.nextNumber)
    }

    /// One element and what it holds, its frames included, read as `render(frames:)` reads them and starting at no
    /// indent; `refs` has only the references in that part. The text is empty when the element shows nothing, and the
    /// result is nil when the element is not in the frames' trees.
    static func render(_ scope: Ref, in frames: [Frame], maximumLength: Int = 60_000, hidden: Set<Ref> = [],
                       scrub: @escaping (String) -> String = { $0 }, named: [Ref: String] = [:], nextNumber: Int = 1) -> Result? {
        guard let main = frames.first,
              let frame = frames.indices.first(where: { frames[$0].session == scope.session && frames[$0].holds(scope.node) }),
              let id = frames[frame].nodes.first(where: { $0["backendDOMNodeId"]?.integerValue == Int64(scope.node) })?["nodeId"]?
                .stringValue
        else { return nil }
        var renderer = Renderer(frames: frames, maximumLength: maximumLength,
                                pageOrigin: rootURL(of: main.nodes).flatMap(origin(of:)), hidden: hidden, scrub: scrub)
        renderer.named = named
        renderer.nextNumber = nextNumber
        renderer.lines = renderer.visit(id, in: frame, depth: 0, parentName: "")
        var text = renderer.lines.joined(separator: "\n")
        if renderer.isTruncated {
            text += "\n… This part is larger than one snapshot; the rest was left out. Read a smaller part by the reference "
                + "of an element in it, or with browser_evaluate."
        }
        return Result(text: text, refs: renderer.refs, isTruncated: renderer.isTruncated, nextNumber: renderer.nextNumber)
    }

    private struct Renderer {
        let frames: [Frame]
        let byID: [[String: JSONValue]]
        let maximumLength: Int
        /// The main frame's origin: a link there reads as its path.
        let pageOrigin: String?
        let hidden: Set<Ref>
        let scrub: (String) -> String
        var lines: [String] = []
        var refs: [String: Ref] = [:]
        var named: [Ref: String] = [:]
        var nextNumber = 1
        var length = 0
        var isTruncated = false
        /// Frames already placed, so a frame the page holds twice is read once.
        var placed: Set<Int> = [0]
        /// How many nodes deep the walk is, the ones it reads through included. A page nested deeper than
        /// `maximumNesting` is cut there, as the panel's tree is, so it cannot run the walk out of stack.
        var nesting = 0
        static let maximumNesting = 256

        init(frames: [Frame], maximumLength: Int, pageOrigin: String?, hidden: Set<Ref>, scrub: @escaping (String) -> String) {
            self.frames = frames
            self.hidden = hidden
            self.scrub = scrub
            byID = frames.map { frame in
                var map: [String: JSONValue] = [:]
                for node in frame.nodes {
                    if let id = node["nodeId"]?.stringValue { map[id] = node }
                }
                return map
            }
            self.maximumLength = maximumLength
            self.pageOrigin = pageOrigin
        }

        /// The element's reference: the one it had, else the next number.
        mutating func reference(for element: Ref) -> String {
            let ref: String
            if let known = named[element] {
                ref = known
            } else {
                ref = "@e\(nextNumber)"
                nextNumber += 1
                named[element] = ref
            }
            refs[ref] = element
            return ref
        }

        mutating func visitFrame(_ index: Int, depth: Int) -> [String] {
            let nodes = frames[index].nodes
            guard let root = nodes.first(where: { $0["parentId"] == nil }) ?? nodes.first,
                  let rootID = root["nodeId"]?.stringValue else { return [] }
            return visit(rootID, in: index, depth: depth, parentName: "")
        }

        mutating func visit(_ id: String, in frame: Int, depth: Int, parentName: String) -> [String] {
            guard !isTruncated, let node = byID[frame][id] else { return [] }
            guard nesting < Self.maximumNesting else {
                isTruncated = true
                return []
            }
            nesting += 1
            defer { nesting -= 1 }
            let role = node["role"]?["value"]?.stringValue ?? ""
            var name = BrowserAgentSnapshot.clean(scrub(node["name"]?["value"]?.stringValue ?? ""))
            let children = node["childIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let properties = BrowserAgentSnapshot.properties(of: node)
            if let backend = node["backendDOMNodeId"]?.integerValue.map(Int.init),
               hidden.contains(Ref(node: backend, session: frames[frame].session)) {
                let actionable = actionableRoles.contains(role) || properties["focusable"] == "true"
                    || properties["editable"] != nil
                guard actionable else { return emit(["\(indent(depth))- text: <redacted>"]) }
                let ref = reference(for: Ref(node: backend, session: frames[frame].session))
                // A field's label is no secret; a name made of its contents could be.
                let label = name.isEmpty || BrowserAgentSnapshot.isNamedByContents(node) ? "" : " " + BrowserAgentSnapshot.quoted(name)
                return emit(["\(indent(depth))- \(role)\(label) [ref=\(ref)]: \"<redacted>\""])
            }

            if role == "InlineTextBox" || role == "ListMarker" { return [] }
            if role == "StaticText" {
                // Separators ("|", "·", "(") carry nothing an agent reads.
                guard !name.isEmpty, name != parentName, name.contains(where: { $0.isLetter || $0.isNumber }) else { return [] }
                return emit(["\(indent(depth))- text: \(BrowserAgentSnapshot.quoted(name))"])
            }
            let actionable = actionableRoles.contains(role) || properties["focusable"] == "true"
                || properties["editable"] != nil
            // A container named by its own text repeats what its children say.
            let namedByContents = BrowserAgentSnapshot.isNamedByContents(node)
            if namedByContents, !actionable, !children.isEmpty, role != "RootWebArea" { name = "" }
            let isIgnored = node["ignored"]?.boolValue == true
            let isTransparent = transparentRoles.contains(role) && name.isEmpty && properties["focusable"] != "true"
            if isIgnored || isTransparent || role == "RootWebArea" || role.isEmpty {
                return children.flatMap {
                    visit($0, in: frame, depth: depth, parentName: role == "RootWebArea" ? name : parentName)
                }
            }

            let backend = node["backendDOMNodeId"]?.integerValue.map(Int.init)

            var line = "\(indent(depth))- \(role)"
            if !name.isEmpty { line += " \(BrowserAgentSnapshot.quoted(name))" }
            if let level = properties["level"], role == "heading" { line += " [level=\(level)]" }
            for property in booleanProperties {
                guard let value = properties[property], value != "false" else { continue }
                line += value == "true" ? " [\(property)]" : " [\(property)=\(value)]"
            }
            if role == "link", let url = properties["url"], !url.isEmpty {
                line += " [url=\(String(shortened(url).prefix(200)))]"
            }
            let held = backend.flatMap { frames[frame].children[$0] }
            if let held, let url = rootURL(of: frames[held].nodes), let origin = BrowserAgentSnapshot.origin(of: url),
               origin != pageOrigin {
                line += " [origin=\(origin)]"
            }
            if actionable, let backend {
                line += " [ref=\(reference(for: Ref(node: backend, session: frames[frame].session)))]"
            }
            let value = BrowserAgentSnapshot.redactingMasked(BrowserAgentSnapshot.clean(scrub(node["value"]?["value"]?.stringValue
                ?? node["value"]?["value"]?.integerValue.map(String.init) ?? "")))
            if valueRoles.contains(role), !value.isEmpty {
                return emit([line + ": " + BrowserAgentSnapshot.quoted(value)])
                    + children.flatMap { visit($0, in: frame, depth: depth + 1, parentName: value) }
                        .filter { !$0.hasPrefix(indent(depth + 1) + "- text:") }
            }
            guard let head = emit([line]).first else { return [] }
            var childLines = children.flatMap { visit($0, in: frame, depth: depth + 1, parentName: name) }
            if let held, !placed.contains(held) {
                placed.insert(held)
                childLines += visitFrame(held, depth: depth + 1)
            }
            // An element named by its text (a link, a button) says it once: what is left below it is what
            // the agent can act on.
            if namedByContents, actionable, !name.isEmpty {
                childLines = childLines.filter { $0.contains("[ref=") }
            }
            let textPrefix = indent(depth + 1) + "- text: "
            childLines = BrowserAgentSnapshot.joiningText(childLines, prefix: textPrefix)
            if childLines.isEmpty {
                // A container left with nothing to say is not worth a line.
                if name.isEmpty, value.isEmpty, !line.contains("["), !actionable { unemit(head) ; return [] }
                return [head]
            }
            // A nameless element holding only text reads as one line.
            if name.isEmpty, childLines.allSatisfy({ $0.hasPrefix(textPrefix) }) {
                let joined = childLines.map { String($0.dropFirst(textPrefix.count)) }.joined(separator: " ")
                return [head + ": " + joined]
            }
            return [head] + childLines
        }

        /// A link on the page's own site reads as its path.
        private func shortened(_ url: String) -> String {
            guard let pageOrigin, let origin = BrowserAgentSnapshot.origin(of: url), origin == pageOrigin else { return url }
            let rest = String(url.dropFirst(origin.count))
            return rest.isEmpty ? "/" : rest
        }

        private mutating func emit(_ new: [String]) -> [String] {
            let added = new.reduce(0) { $0 + $1.count + 1 }
            guard length + added <= maximumLength else {
                isTruncated = true
                return []
            }
            length += added
            return new
        }

        private mutating func unemit(_ line: String) {
            length -= line.count + 1
        }

        private func indent(_ depth: Int) -> String { String(repeating: "  ", count: depth) }
    }

    /// The address of a frame's document, which its root node carries.
    fileprivate static func rootURL(of nodes: [JSONValue]) -> String? {
        let root = nodes.first { $0["parentId"] == nil } ?? nodes.first
        return root.flatMap { properties(of: $0)["url"] }
    }

    /// scheme://host[:port], for http and https addresses.
    fileprivate static func origin(of address: String) -> String? {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host(), !host.isEmpty else { return nil }
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }

    /// The element's name comes from its own text, not a label the page gave it.
    fileprivate static func isNamedByContents(_ node: JSONValue) -> Bool {
        let sources = node["name"]?["sources"]?.arrayValue ?? []
        let used = sources.first { $0["value"] != nil && $0["superseded"]?.boolValue != true }
        return used?["type"]?.stringValue == "contents"
    }

    fileprivate static func properties(of node: JSONValue) -> [String: String] {
        var result: [String: String] = [:]
        for property in node["properties"]?.arrayValue ?? [] {
            guard let name = property["name"]?.stringValue, let value = property["value"]?["value"] else { continue }
            switch value {
            case .bool(let flag): result[name] = flag ? "true" : "false"
            case .string(let text): result[name] = text
            case .integer(let number): result[name] = String(number)
            case .number(let number): result[name] = String(number)
            default: break
            }
        }
        return result
    }

    fileprivate static func clean(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > 300 ? String(collapsed.prefix(300)) + "…" : collapsed
    }

    /// Chromium shows a password field's value to accessibility as one bullet per character; even its
    /// length stays out of the result.
    fileprivate static func redactingMasked(_ value: String) -> String {
        !value.isEmpty && value.allSatisfy({ $0 == "•" || $0 == "●" }) ? "<redacted>" : value
    }

    /// Text lines side by side read as one: "51 points" and "by" as "51 points by".
    fileprivate static func joiningText(_ lines: [String], prefix: String) -> [String] {
        var joined: [String] = []
        for line in lines {
            if line.hasPrefix(prefix), let last = joined.last, last.hasPrefix(prefix), last.hasSuffix("\""),
               line.hasSuffix("\""), last.count + line.count < 400 {
                joined[joined.count - 1] = String(last.dropLast()) + " " + String(line.dropFirst(prefix.count + 1))
            } else {
                joined.append(line)
            }
        }
        return joined
    }

    fileprivate static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
