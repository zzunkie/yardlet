import Foundation
import YardletAgentTools

/// MCP Apps (extension `io.modelcontextprotocol/ui`, spec 2026-01-26) as Yardlet's connectors carry it: a tool
/// names an HTML view (`_meta.ui.resourceUri`, a `ui://` URI) that Yardlet reads with `resources/read` and draws
/// under the call in the conversation, and says who may call it (`_meta.ui.visibility`: the model, views, or both).
/// The contract is docs/CONNECTORS.md, "MCP Apps".
enum MCPAppTool {
    static let modelVisibility = "model"
    static let viewVisibility = "app"

    /// The view a tool names for its results; nil when it names none or names something other than `ui://`.
    static func viewURI(of tool: ToolJSON?) -> String? {
        let meta = tool?["_meta"]
        // `_meta["ui/resourceUri"]` is the spec's deprecated spelling, still sent by some servers.
        let uri = meta?["ui"]?["resourceUri"]?.stringValue ?? meta?["ui/resourceUri"]?.stringValue
        guard let uri, uri.lowercased().hasPrefix("ui://"), uri.count > 5 else { return nil }
        return uri
    }

    /// Who may call the tool: both the model and views unless the tool says otherwise.
    static func visibility(of tool: ToolJSON?) -> Set<String> {
        guard let listed = tool?["_meta"]?["ui"]?["visibility"]?.arrayValue else {
            return [modelVisibility, viewVisibility]
        }
        return Set(listed.compactMap(\.stringValue))
    }

    /// Whether the model may see and call the tool. A view-only tool (GitHub's `ui_get`) stays out of every
    /// harness's list.
    static func isForModel(_ tool: ToolJSON?) -> Bool {
        visibility(of: tool).contains(modelVisibility)
    }

    /// Whether a view of the same connector may call the tool.
    static func isForViews(_ tool: ToolJSON?) -> Bool {
        visibility(of: tool).contains(viewVisibility)
    }

    /// The tool's fields without what only the app reads: the Yardlet MCP server serves no resources, so a
    /// harness that drew views itself would find nothing to read, and Yardlet draws them.
    static func removingViewMeta(from fields: inout [String: ToolJSON]) {
        guard var meta = fields["_meta"]?.objectValue else { return }
        meta["ui"] = nil
        meta["ui/resourceUri"] = nil
        fields["_meta"] = meta.isEmpty ? nil : .object(meta)
    }
}

/// A call's arguments as one string, so that a conversation row finds the result its call returned: sorted keys,
/// no spaces, `{}` for none. Both sides go through `ToolJSON`, so numbers and escapes are written alike.
enum MCPAppArguments {
    static func key(_ arguments: ToolJSON?) -> String {
        guard let arguments, arguments != .null else { return "{}" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(arguments) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The arguments a row's text shows, read back: the JSON Claude Code and Codex rows show for a call's input, or
    /// nothing for a call without arguments. Nil when the text is not a JSON object.
    static func parse(_ text: String?) -> ToolJSON? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return .object([:]) }
        guard !text.isEmpty else { return .object([:]) }
        guard text.hasPrefix("{"), let value = try? JSONDecoder().decode(ToolJSON.self, from: Data(text.utf8)),
              value.objectValue != nil else { return nil }
        return value
    }
}

/// The origins a view may load from or connect to (`_meta.ui.csp`), each checked to be a plain origin, and the
/// Content-Security-Policy Yardlet serves the view with. Nothing a view does not declare is allowed, and a source
/// that is not a plain `https` or `wss` origin (a keyword, a scheme alone, a path, a quote) is dropped, so a
/// server cannot widen the policy beyond the hosts it names.
struct MCPAppCSP: Equatable, Sendable {
    var connectDomains: [String] = []
    var resourceDomains: [String] = []
    var frameDomains: [String] = []
    var baseURIDomains: [String] = []

    init(connectDomains: [String] = [], resourceDomains: [String] = [], frameDomains: [String] = [],
         baseURIDomains: [String] = []) {
        self.connectDomains = connectDomains.compactMap(Self.source)
        self.resourceDomains = resourceDomains.compactMap(Self.source)
        self.frameDomains = frameDomains.compactMap(Self.source)
        self.baseURIDomains = baseURIDomains.compactMap(Self.source)
    }

    init(_ json: ToolJSON?) {
        func list(_ key: String) -> [String] { json?[key]?.arrayValue?.compactMap(\.stringValue) ?? [] }
        self.init(connectDomains: list("connectDomains"), resourceDomains: list("resourceDomains"),
                  frameDomains: list("frameDomains"), baseURIDomains: list("baseUriDomains"))
    }

    /// `https://host`, `https://*.host` or `wss://host`, with a port at most, as the spec's examples write them;
    /// nil for anything else.
    static func source(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespaces)
        while value.hasSuffix("/") { value.removeLast() }
        let pattern = #"^(https|wss)://(\*\.)?[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*(:[0-9]{1,5})?$"#
        guard value.count <= 253, value.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return value.lowercased()
    }

    /// The policy: the spec's restrictive default, with each declared origin added where the spec puts it.
    var header: String {
        func sources(_ base: [String], _ declared: [String], none: Bool = false) -> String {
            let all = base + declared
            return all.isEmpty && none ? "'none'" : all.joined(separator: " ")
        }
        return [
            "default-src 'none'",
            "script-src " + sources(["'self'", "'unsafe-inline'"], resourceDomains),
            "style-src " + sources(["'self'", "'unsafe-inline'"], resourceDomains),
            "img-src " + sources(["'self'", "data:", "blob:"], resourceDomains),
            "font-src " + sources(["'self'", "data:"], resourceDomains),
            "media-src " + sources(["'self'", "data:", "blob:"], resourceDomains),
            "connect-src " + sources([], connectDomains, none: true),
            "frame-src " + sources([], frameDomains, none: true),
            "object-src 'none'",
            "base-uri " + (baseURIDomains.isEmpty ? "'self'" : baseURIDomains.joined(separator: " ")),
            "form-action 'none'"
        ].joined(separator: "; ")
    }
}

/// A view as its server answered `resources/read`, checked: the HTML, the origins it declared, and whether it
/// wants the host's border.
struct MCPAppView: Equatable, Sendable {
    static let mimeType = "text/html;profile=mcp-app"
    /// More than any view seen so far (GitHub's largest is under 1 MB) and little enough to hold a few in memory.
    static let maximumLength = 5 * 1024 * 1024

    let uri: String
    let html: String
    let csp: MCPAppCSP
    /// `true` asks for the host's border and background, `false` for none; nil leaves it to the host.
    let prefersBorder: Bool?

    enum Problem: Error, Equatable {
        /// The server answered no content for this URI.
        case missing
        /// The content is not HTML.
        case notHTML(String)
        case tooLarge
    }

    /// The content item for `uri` in a `ReadResourceResult`: HTML in `text` or base64 `blob`, of `text/html` with or
    /// without the MCP App profile, at most `maximumLength`.
    static func read(_ result: ToolJSON, uri: String) throws -> MCPAppView {
        let contents = result["contents"]?.arrayValue ?? []
        guard let item = contents.first(where: { $0["uri"]?.stringValue == uri }) ?? contents.first else {
            throw Problem.missing
        }
        let type = item["mimeType"]?.stringValue ?? ""
        guard type.lowercased().replacingOccurrences(of: " ", with: "").hasPrefix("text/html") else {
            throw Problem.notHTML(type)
        }
        let html: String
        if let text = item["text"]?.stringValue {
            html = text
        } else if let blob = item["blob"]?.stringValue, let data = Data(base64Encoded: blob) {
            guard data.count <= maximumLength else { throw Problem.tooLarge }
            html = String(decoding: data, as: UTF8.self)
        } else {
            throw Problem.missing
        }
        guard html.utf8.count <= maximumLength else { throw Problem.tooLarge }
        guard !html.isEmpty else { throw Problem.missing }
        let ui = item["_meta"]?["ui"]
        let border: Bool? = if case .bool(let value)? = ui?["prefersBorder"] { value } else { nil }
        return MCPAppView(uri: uri, html: html, csp: MCPAppCSP(ui?["csp"]), prefersBorder: border)
    }
}

/// What the conversation needs to draw a connector call's view: the tool by Yardlet's name, the view it names,
/// the call's arguments, and what the harness kept of the result, for a call whose whole result Yardlet no longer
/// holds (`ConnectorAppCalls`).
struct ConversationConnectorView: Equatable, Sendable {
    /// Yardlet's name for the tool (`github_get_me`).
    var tool: String
    /// The `ui://` resource the tool names.
    var uri: String
    /// The call's arguments; nil when the row's text could not be read back as them.
    var arguments: ToolJSON?
    /// The result as the harness kept it: Codex's result, or the row's text as one text item.
    var harnessResult: ToolJSON
    /// The tool changes nothing (`readOnlyHint`). Only such a tool's view is drawn from `harnessResult`: a view of a
    /// tool that changes something may offer to make the change again when it cannot read the result as a finished
    /// one (GitHub's form views).
    var readOnly: Bool

    /// The view for a completed call of a connector tool that names one; nil for any other.
    static func of(tool name: String, label: ConnectorToolLabels.Label, arguments: ToolJSON?,
                   harnessResult: ToolJSON) -> ConversationConnectorView? {
        guard let uri = label.view else { return nil }
        return ConversationConnectorView(tool: name, uri: uri, arguments: arguments, harnessResult: harnessResult,
                                         readOnly: label.readOnly)
    }

    /// A text result, as a harness that keeps only text (Claude Code, Antigravity) kept the call's.
    static func textResult(_ text: String?) -> ToolJSON {
        .object(["content": .array([.object(["type": .string("text"), "text": .string(text ?? "")])])])
    }
}

/// The whole results of this app run's connector calls whose tool has a view, so a view gets the
/// `structuredContent` and every content item its call returned, which the harnesses do not all keep. Kept in
/// memory only, newest last: 20 per task and 200 in all.
@MainActor
final class ConnectorAppCalls {
    struct Entry: Equatable {
        let task: UUID
        let tool: String
        let arguments: String
        let result: ToolJSON
    }

    static let perTask = 20
    static let total = 200

    private(set) var entries: [Entry] = []

    func record(_ result: ToolJSON, task: UUID, tool: String, arguments: ToolJSON?) {
        entries.append(Entry(task: task, tool: tool, arguments: MCPAppArguments.key(arguments), result: result))
        if entries.filter({ $0.task == task }).count > Self.perTask,
           let oldest = entries.firstIndex(where: { $0.task == task }) {
            entries.remove(at: oldest)
        }
        if entries.count > Self.total { entries.removeFirst(entries.count - Self.total) }
    }

    /// The latest result of the task's call to `tool` with these arguments; with arguments unknown, its latest call
    /// to `tool`.
    func result(task: UUID, tool: String, arguments: ToolJSON?) -> ToolJSON? {
        let key = arguments.map(MCPAppArguments.key)
        return entries.last { $0.task == task && $0.tool == tool && (key == nil || $0.arguments == key) }?.result
    }
}

extension AgentToolResult {
    /// The result as an MCP `CallToolResult`, which a view reads (`ui/notifications/tool-result`).
    var callToolResult: ToolJSON {
        var fields: [String: ToolJSON] = [
            "content": .array(content.map { item in
                switch item {
                case .text(let text): .object(["type": .string("text"), "text": .string(text)])
                case .json(let json): json
                case .image(let data, let mimeType):
                    .object(["type": .string("image"), "data": .string(data), "mimeType": .string(mimeType)])
                }
            })
        ]
        if isError { fields["isError"] = .bool(true) }
        if let structuredContent { fields["structuredContent"] = structuredContent }
        return .object(fields)
    }
}
