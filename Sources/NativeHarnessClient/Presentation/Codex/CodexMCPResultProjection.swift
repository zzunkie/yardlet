import Foundation

/// The body of an MCP tool call result as the Codex timeline reads it.
///
/// Codex carries `McpToolCallResult.content` through verbatim, so a plugin's own MCP content
/// blocks arrive unchanged: a computer-use screenshot is an `image` block and a tool's report is
/// a `text` block, a file or page it points to a `resource_link`. Yardlet only reads what the block
/// already contains; it never re-runs a tool, fetches a linked resource, or invents a body for one.
/// Blocks this client cannot render stay out of the card, and the item's copy action keeps carrying
/// the whole payload.
struct CodexMCPResultProjection: Equatable, Sendable {
    enum Block: Equatable, Sendable, Identifiable {
        case text(id: String, text: String)
        case image(id: String, data: Data, mimeType: String)
        case resourceLink(id: String, link: ResourceLink)

        var id: String {
            switch self {
            case let .text(id, _), let .image(id, _, _), let .resourceLink(id, _): id
            }
        }
    }

    /// A `resource_link` block: a resource the tool names without sending its contents.
    struct ResourceLink: Equatable, Sendable {
        let name: String
        let title: String?
        /// As the tool wrote it, shown even when Yardlet will not open it.
        let uri: String
        let description: String?
        let mimeType: String?

        /// The title the tool gave, else its name, else the URI itself.
        var label: String {
            [title, name, uri].lazy.compactMap { $0 }.first { !$0.isEmpty } ?? uri
        }

        /// Where a click opens the link: a web page in the task's browser, a file in the task's
        /// files, both through the conversation's `openURL`. Any other scheme (`javascript:`,
        /// `data:`, another app's) is left as text, so a tool's result never launches something.
        var openableURL: URL? {
            guard let url = URL(string: uri), let scheme = url.scheme?.lowercased() else { return nil }
            switch scheme {
            case "http", "https":
                guard let host = url.host(), !host.isEmpty else { return nil }
                return url
            case "file":
                // A file on another host is not this Mac's file of the same path.
                guard ["", "localhost"].contains(url.host()?.lowercased() ?? "") else { return nil }
                let path = url.path(percentEncoded: false)
                guard path.hasPrefix("/") else { return nil }
                // The same file URL without `localhost`, keeping a `#L12` or `#L12C3` the files
                // panel opens the file at.
                guard var local = URLComponents(url: URL(filePath: path), resolvingAgainstBaseURL: false)
                else { return nil }
                local.percentEncodedFragment = url.fragment(percentEncoded: true)
                return local.url
            default:
                return nil
            }
        }
    }

    let blocks: [Block]

    var isEmpty: Bool { blocks.isEmpty }

    var textBlockCount: Int {
        blocks.filter { if case .text = $0 { return true } else { return false } }.count
    }

    var imageBlockCount: Int {
        blocks.filter { if case .image = $0 { return true } else { return false } }.count
    }

    init(result: JSONValue?, itemID: String = "mcp") {
        let content: [JSONValue]
        switch result {
        case let .some(.array(values)):
            // Older history wrote the content array where the object now sits.
            content = values
        case let .some(value):
            content = value["content"]?.arrayValue ?? []
        case .none:
            content = []
        }
        var blocks: [Block] = []
        for (offset, entry) in content.enumerated() {
            let id = "\(itemID)#\(offset)"
            switch entry["type"]?.stringValue {
            case "text":
                if let text = entry["text"]?.stringValue, !text.isEmpty {
                    blocks.append(.text(id: id, text: text))
                }
            case "image":
                if let image = Self.image(
                    id: id,
                    payload: entry["data"]?.stringValue,
                    declaredMIMEType: entry["mimeType"]?.stringValue
                ) {
                    blocks.append(image)
                }
            case "resource":
                let resource = entry["resource"]
                if let text = resource?["text"]?.stringValue, !text.isEmpty {
                    blocks.append(.text(id: id, text: text))
                } else if let image = Self.image(
                    id: id,
                    payload: resource?["blob"]?.stringValue,
                    declaredMIMEType: resource?["mimeType"]?.stringValue,
                    requiresImageMIMEType: true
                ) {
                    blocks.append(image)
                }
            case "resource_link":
                if let link = Self.resourceLink(entry) {
                    blocks.append(.resourceLink(id: id, link: link))
                }
            default:
                continue
            }
        }
        self.blocks = blocks
    }

    private static func resourceLink(_ entry: JSONValue) -> ResourceLink? {
        func field(_ key: String) -> String? {
            guard let value = entry[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else { return nil }
            return value
        }
        let name = field("name")
        let uri = field("uri")
        guard name != nil || uri != nil else { return nil }
        return ResourceLink(
            name: name ?? "",
            title: field("title"),
            uri: uri ?? "",
            description: field("description"),
            mimeType: field("mimeType")
        )
    }

    /// Decodes one image payload. MCP sends bare base64, but a plugin that built its block from a
    /// browser or canvas can send a `data:` URL instead, and both reach the timeline unchanged.
    private static func image(
        id: String,
        payload: String?,
        declaredMIMEType: String?,
        requiresImageMIMEType: Bool = false
    ) -> Block? {
        guard let payload, !payload.isEmpty else { return nil }
        var mimeType = declaredMIMEType
        var encoded = payload
        if payload.hasPrefix("data:"), let comma = payload.firstIndex(of: ",") {
            let header = payload[payload.index(payload.startIndex, offsetBy: 5)..<comma]
            guard header.hasSuffix(";base64") else { return nil }
            let declared = header.dropLast(";base64".count)
            if !declared.isEmpty { mimeType = String(declared) }
            encoded = String(payload[payload.index(after: comma)...])
        }
        let mediaType = mimeType ?? "image/png"
        if requiresImageMIMEType, !mediaType.hasPrefix("image/") { return nil }
        guard let data = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]),
              !data.isEmpty
        else { return nil }
        return .image(id: id, data: data, mimeType: mediaType)
    }
}

extension CodexMCPToolItem {
    /// The failure message Codex attached to the call. `McpToolCallError` is an object with a
    /// `message`; a plain string only appears in older history.
    var errorMessage: String? {
        guard let error else { return nil }
        let message = error["message"]?.stringValue ?? error.stringValue
        guard let message, !message.isEmpty else { return nil }
        return message
    }

    /// Codex refused the call because it needs an approval the thread's policy never asks for, which
    /// the Codex app keeps in view of folded work.
    var wasRefusedForApproval: Bool {
        errorMessage == "MCP tool call requires approval, but approval policy is never"
    }
}
