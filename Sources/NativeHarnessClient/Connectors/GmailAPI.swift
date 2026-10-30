import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import YardletAgentTools

/// The Gmail REST API (developers.google.com/workspace/gmail/api/reference/rest) for one account,
/// JSON in and out, through the account's `OAuthAPISession`. Nothing here logs or keeps what a
/// mailbox holds; a failure carries Google's own error message, never a request or response body.
struct GmailAPI: Sendable {
    /// `https://gmail.googleapis.com/gmail/v1/`.
    let base: URL
    let session: OAuthAPISession

    enum Failure: Error, Equatable, LocalizedError {
        /// Google answered with an error: its HTTP status and its `error.message`.
        case http(status: Int, message: String)
        case unreadableAnswer
        /// An ID with characters Gmail's IDs do not have, refused before any request.
        case invalidID(String)

        var errorDescription: String? {
            switch self {
            case .http(let status, let message): message.isEmpty ? "HTTP \(status)" : "\(message) (HTTP \(status))"
            case .unreadableAnswer: "Gmail's answer could not be read."
            case .invalidID(let id): "Not a Gmail ID: \(id)"
            }
        }
    }

    func profile() async throws -> ToolJSON {
        try await get("users/me/profile")
    }

    func get(_ path: String, _ query: [URLQueryItem] = []) async throws -> ToolJSON {
        try await send(method: "GET", path: path, query: query, body: nil)
    }

    func post(_ path: String, _ body: ToolJSON) async throws -> ToolJSON {
        try await send(method: "POST", path: path, query: [], body: body)
    }

    func delete(_ path: String) async throws {
        _ = try await send(method: "DELETE", path: path, query: [], body: nil)
    }

    /// A message through the upload endpoint (`…/upload/gmail/v1/`, up to 35 MB), as a message
    /// with attachments goes: the metadata as JSON, then the message as `message/rfc822`
    /// (developers.google.com/workspace/gmail/api/guides/uploads).
    func upload(_ path: String, metadata: ToolJSON, message: Data) async throws -> ToolJSON {
        let boundary = "yardlet-\(UUID().uuidString)"
        var body = Data()
        func line(_ text: String) { body.append(Data((text + "\r\n").utf8)) }
        line("--\(boundary)")
        line("Content-Type: application/json; charset=UTF-8")
        line("")
        body.append(try JSONEncoder().encode(metadata))
        line("")
        line("--\(boundary)")
        line("Content-Type: message/rfc822")
        line("")
        body.append(message)
        line("")
        line("--\(boundary)--")
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        components.path = "/upload" + components.path
        components.queryItems = [URLQueryItem(name: "uploadType", value: "multipart")]
        return try await send(method: "POST", url: components.url!, payload: body,
                              contentType: "multipart/related; boundary=\(boundary)", timeout: 120)
    }

    /// A Gmail ID as a path segment: message, thread, draft, and label IDs are letters, digits,
    /// `_`, `-`, `:`, and `.`.
    static func segment(_ id: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-:.")
        guard !id.isEmpty, id.count <= 256, id.unicodeScalars.allSatisfy(allowed.contains) else {
            throw Failure.invalidID(id)
        }
        return id
    }

    private func send(method: String, path: String, query: [URLQueryItem], body: ToolJSON?) async throws -> ToolJSON {
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query
            // `+` is a space to Google's query parser; Gmail's `+word` operator needs it kept.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        let payload = try body.map { try JSONEncoder().encode($0) }
        return try await send(method: method, url: components.url!, payload: payload, contentType: "application/json")
    }

    private func send(method: String, url: URL, payload: Data?, contentType: String,
                      timeout: TimeInterval = 30) async throws -> ToolJSON {
        let (data, response) = try await session.send {
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let payload {
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
                request.httpBody = payload
            }
            return request
        }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(ToolJSON.self, from: data))?["error"]?["message"]?.stringValue ?? ""
            throw Failure.http(status: response.statusCode, message: message)
        }
        if data.isEmpty { return .object([:]) }
        guard let json = try? JSONDecoder().decode(ToolJSON.self, from: data) else { throw Failure.unreadableAnswer }
        return json
    }
}

/// A Gmail message resource read into the fields the tools return: headers by name, the date in
/// the Mac's time zone, the plain-text and HTML bodies decoded with their charset, and the
/// attachments' names.
struct GmailMessage {
    let json: ToolJSON

    var id: String? { json["id"]?.stringValue }
    var threadId: String? { json["threadId"]?.stringValue }
    var labelIds: [String] { json["labelIds"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
    var snippet: String? { json["snippet"]?.stringValue.map(GmailText.decodeEntities) }

    /// A header's value; names are case-insensitive (`Message-ID`, `Message-Id`).
    func header(_ name: String) -> String? {
        let wanted = name.lowercased()
        return json["payload"]?["headers"]?.arrayValue?.first {
            $0["name"]?.stringValue?.lowercased() == wanted
        }?["value"]?.stringValue
    }

    /// `internalDate`, milliseconds since 1970.
    var internalDate: Date? {
        let raw: Double? = switch json["internalDate"] {
        case .string(let text)?: Double(text)
        case .integer(let value)?: Double(value)
        case .number(let value)?: value
        default: nil
        }
        return raw.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    /// `internalDate` as local ISO 8601.
    var date: String? {
        guard let internalDate else { return header("Date") }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .autoupdatingCurrent
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: internalDate)
    }

    /// The fields one format returns.
    func output(_ format: GmailToolCatalog.Format, bodyLimit: Int = GmailText.bodyLimit) -> ToolJSON {
        var fields: [String: ToolJSON] = [:]
        func put(_ key: String, _ value: String?) {
            if let value, !value.isEmpty { fields[key] = .string(value) }
        }
        put("id", id)
        put("threadId", threadId)
        put("date", date)
        put("from", header("From"))
        put("to", header("To"))
        put("cc", header("Cc"))
        put("bcc", header("Bcc"))
        fields["labelIds"] = .array(labelIds.map { .string($0) })
        fields["unread"] = .bool(labelIds.contains("UNREAD"))
        guard format != .metadataOnly else { return .object(fields) }
        put("subject", header("Subject"))
        put("snippet", snippet)
        guard format == .plainText || format == .fullContent else { return .object(fields) }
        let parts = GmailMessage.parts(json["payload"])
        let plain = parts.plain ?? parts.html.map(GmailText.plainText(fromHTML:))
        put("body", plain.map { GmailText.limited($0, to: bodyLimit) })
        if format == .fullContent { put("htmlBody", parts.html.map { GmailText.limited($0, to: bodyLimit) }) }
        if !parts.attachments.isEmpty { fields["attachments"] = .array(parts.attachments) }
        return .object(fields)
    }

    /// The first plain-text and HTML parts, and the attachments, from a payload's part tree.
    static func parts(_ payload: ToolJSON?) -> (plain: String?, html: String?, attachments: [ToolJSON]) {
        var plain: String?
        var html: String?
        var attachments: [ToolJSON] = []
        func walk(_ part: ToolJSON, depth: Int) {
            guard depth < 32 else { return }
            let mimeType = part["mimeType"]?.stringValue?.lowercased() ?? ""
            let filename = part["filename"]?.stringValue ?? ""
            let body = part["body"]
            if !filename.isEmpty, !mimeType.hasPrefix("multipart/") {
                var item: [String: ToolJSON] = ["filename": .string(filename), "mimeType": .string(mimeType)]
                if let size = body?["size"] { item["size"] = size }
                attachments.append(.object(item))
            } else if let data = body?["data"]?.stringValue, let decoded = decode(data, charset: charset(of: part)) {
                if mimeType == "text/plain", plain == nil { plain = decoded }
                if mimeType == "text/html", html == nil { html = decoded }
            }
            for child in part["parts"]?.arrayValue ?? [] { walk(child, depth: depth + 1) }
        }
        if let payload { walk(payload, depth: 0) }
        return (plain, html, attachments)
    }

    private static func charset(of part: ToolJSON) -> String? {
        let contentType = part["headers"]?.arrayValue?.first {
            $0["name"]?.stringValue?.lowercased() == "content-type"
        }?["value"]?.stringValue ?? ""
        guard let range = contentType.range(of: "charset=", options: .caseInsensitive) else { return nil }
        let rest = contentType[range.upperBound...]
        let value = rest.prefix { $0 != ";" }.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        return value.isEmpty ? nil : value
    }

    /// A part's `body.data`: base64url of the decoded content, in the part's own charset.
    static func decode(_ base64URL: String, charset: String?) -> String? {
        var text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text = text.filter { !$0.isWhitespace }
        while text.count % 4 != 0 { text.append("=") }
        guard let data = Data(base64Encoded: text) else { return nil }
        if let charset {
            #if canImport(Darwin)
            let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cf != kCFStringEncodingInvalidId,
               let decoded = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) {
                return decoded
            }
            #else
            if let encoding = String.Encoding(ianaName: charset), let decoded = String(data: data, encoding: encoding) {
                return decoded
            }
            #endif
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}

/// Text conversions for message bodies.
enum GmailText {
    /// The longest body one message returns, in characters; the rest is cut with a note.
    static let bodyLimit = 40_000

    static func limited(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n[… \(text.count - limit) more characters]"
    }

    /// Readable text from an HTML body: no scripts or styles, line breaks where blocks end.
    static func plainText(fromHTML html: String) -> String {
        var text = html
        func replace(_ pattern: String, _ template: String) {
            text = text.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
        }
        replace("<(script|style|head)[^>]*>[\\s\\S]*?</\\1>", "")
        replace("<br\\s*/?>", "\n")
        replace("</(p|div|li|tr|h[1-6]|blockquote|table)>", "\n")
        replace("<li[^>]*>", "• ")
        replace("<[^>]+>", "")
        text = decodeEntities(text)
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var result: [String] = []
        for line in lines where !(line.isEmpty && (result.last?.isEmpty ?? true)) { result.append(line) }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The HTML entities snippets and bodies carry: named basics and numeric references.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&#39;": "'"]
        var result = text
        for (entity, value) in named { result = result.replacingOccurrences(of: entity, with: value) }
        let pattern = try! NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);")
        let source = result as NSString
        var output = ""
        var last = 0
        for match in pattern.matches(in: result, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: last, length: match.range.location - last))
            let digits = source.substring(with: match.range(at: 1))
            let value = digits.hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            if let value, let scalar = Unicode.Scalar(value) { output.append(Character(scalar)) }
            else { output += source.substring(with: match.range) }
            last = match.range.location + match.range.length
        }
        output += source.substring(from: last)
        return output.replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// An RFC 5322 message for a draft or a send, as `raw` (base64url): UTF-8 bodies in base64, a
/// non-ASCII subject, display name, or file name as RFC 2047 encoded words, a reply's
/// `In-Reply-To` and `References`, and attachments in `multipart/mixed` after the body. Gmail
/// fills `From` with the signed-in account.
struct GmailOutgoingMessage: Equatable {
    var to: [String] = []
    var cc: [String] = []
    var bcc: [String] = []
    var subject = ""
    var body: String?
    var htmlBody: String?
    var inReplyTo: String?
    var references: String?
    var attachments: [Attachment] = []
    var boundary = "yardlet-" + UUID().uuidString.lowercased()

    /// A local file attached under its own name (`GmailAttachmentFiles`).
    struct Attachment: Equatable {
        var filename: String
        var mimeType: String
        var data: Data
    }

    enum Problem: Error, Equatable, LocalizedError {
        case invalidAddress(String)
        case noRecipients
        case unattachable(path: String, reason: String)
        case attachmentsTooLarge(bytes: Int)

        var errorDescription: String? {
            switch self {
            case .invalidAddress(let address): "Not an email address: \(address)"
            case .noRecipients: "Give at least one recipient in to, cc, or bcc."
            case .unattachable(let path, let reason): "Cannot attach \(path): \(reason)"
            case .attachmentsTooLarge(let bytes):
                "The attachments come to \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)), "
                    + "over Gmail's 25 MB. Share large files as a Drive link instead."
            }
        }
    }

    /// Plain addresses or `Name <address>`, one line each.
    static func validated(_ addresses: [String]) throws -> [String] {
        try addresses.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { address in
            // By scalar: "\r\n" is one Character, neither "\r" nor "\n".
            guard address.contains("@"),
                  !address.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) || $0 == "," }) else {
                throw Problem.invalidAddress(address)
            }
            return address
        }
    }

    var hasRecipients: Bool { !(to.isEmpty && cc.isEmpty && bcc.isEmpty) }

    var mime: String {
        var lines: [String] = []
        if !to.isEmpty { lines.append("To: " + to.map(Self.encodedAddress).joined(separator: ", ")) }
        if !cc.isEmpty { lines.append("Cc: " + cc.map(Self.encodedAddress).joined(separator: ", ")) }
        if !bcc.isEmpty { lines.append("Bcc: " + bcc.map(Self.encodedAddress).joined(separator: ", ")) }
        lines.append("Subject: " + Self.encodedWords(Self.oneLine(subject)))
        if let inReplyTo { lines.append("In-Reply-To: " + Self.oneLine(inReplyTo)) }
        if let references { lines.append("References: " + Self.oneLine(references)) }
        lines.append("MIME-Version: 1.0")
        if attachments.isEmpty {
            lines += bodyEntity(boundary: boundary)
        } else {
            lines.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
            lines.append("")
            lines += ["--\(boundary)"] + bodyEntity(boundary: boundary + "-alt")
            for attachment in attachments { lines += ["--\(boundary)"] + Self.part(attachment) }
            lines.append("--\(boundary)--")
        }
        return lines.joined(separator: "\r\n")
    }

    /// The message as Gmail's `raw` field takes it.
    var raw: String { ConnectorOAuth.base64URL(Data(mime.utf8)) }

    /// The text, or the text and HTML side by side under `boundary`.
    private func bodyEntity(boundary: String) -> [String] {
        let plain = body ?? htmlBody.map(GmailText.plainText(fromHTML:)) ?? ""
        guard let htmlBody else { return Self.part("text/plain", plain) }
        return ["Content-Type: multipart/alternative; boundary=\"\(boundary)\"", ""]
            + ["--\(boundary)"] + Self.part("text/plain", plain)
            + ["--\(boundary)"] + Self.part("text/html", htmlBody)
            + ["--\(boundary)--", ""]
    }

    private static func part(_ type: String, _ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        return ["Content-Type: \(type); charset=\"UTF-8\"", "Content-Transfer-Encoding: base64", "",
                base64Lines(Data(normalized.utf8)), ""]
    }

    /// An attachment named as Gmail names one: the name quoted, as encoded words when it is not ASCII.
    private static func part(_ attachment: Attachment) -> [String] {
        let name = attachment.filename
        let quoted = name.unicodeScalars.allSatisfy(\.isASCII)
            ? name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            : encodedWords(name)
        return ["Content-Type: \(attachment.mimeType); name=\"\(quoted)\"",
                "Content-Disposition: attachment; filename=\"\(quoted)\"",
                "Content-Transfer-Encoding: base64", "", base64Lines(attachment.data), ""]
    }

    private static func base64Lines(_ data: Data) -> String {
        data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }

    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
    }

    /// `Name <address>` with a non-ASCII name as encoded words; the address as it is.
    static func encodedAddress(_ address: String) -> String {
        guard address.unicodeScalars.contains(where: { !$0.isASCII }),
              let open = address.lastIndex(of: "<"), address.hasSuffix(">") else { return address }
        let name = address[..<open].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
        return encodedWords(name) + " " + address[open...]
    }

    /// RFC 2047 `=?UTF-8?B?…?=` words of at most 45 bytes each (75 characters encoded), folded
    /// onto continuation lines; ASCII text as it is.
    static func encodedWords(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { !$0.isASCII }) else { return text }
        var words: [String] = []
        var chunk = ""
        for character in text {
            if chunk.utf8.count + String(character).utf8.count > 45 {
                words.append(chunk)
                chunk = ""
            }
            chunk.append(character)
        }
        if !chunk.isEmpty { words.append(chunk) }
        return words.map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
    }
}

/// Local files a draft or a send attaches, by absolute path (`~/` for the home folder). A file
/// comes only from the task's folders, the temporary folders where agents keep what they make, or
/// the person's Desktop, Documents, and Downloads; never from a hidden file or folder below one of
/// them (`.env`, `.ssh`), and only after `..` and symbolic links are resolved. Together they stay
/// within Gmail's 25 MB for attachments.
enum GmailAttachmentFiles {
    static let limit = 25 * 1024 * 1024

    /// What a request card shows of one: its name and size, nil when it is not there to read.
    struct File: Equatable, Sendable {
        var name: String
        var size: Int?
    }

    static func roots(taskFolders: [URL], home: URL = FileManager.default.homeDirectoryForCurrentUser,
                      temporary: URL = FileManager.default.temporaryDirectory) -> [URL] {
        taskFolders + [URL(filePath: "/tmp"), temporary] + ["Desktop", "Documents", "Downloads"].map { home.appending(path: $0) }
    }

    static func load(_ paths: [String], roots: [URL]) throws -> [GmailOutgoingMessage.Attachment] {
        var files: [(path: String, url: URL)] = []
        var total = 0
        for path in paths {
            let url = try resolve(path, roots: roots)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else {
                throw GmailOutgoingMessage.Problem.unattachable(path: path, reason: "it is not a file.")
            }
            total += size
            files.append((path, url))
        }
        guard total <= limit else { throw GmailOutgoingMessage.Problem.attachmentsTooLarge(bytes: total) }
        return try files.map { file in
            guard let data = try? Data(contentsOf: file.url) else {
                throw GmailOutgoingMessage.Problem.unattachable(path: file.path, reason: "it could not be read.")
            }
            let name = displayName(file.path)
            var type = FileTypes.mimeType(forExtension: (name as NSString).pathExtension)
                ?? "application/octet-stream"
            if type.hasPrefix("text/"), String(data: data, encoding: .utf8) != nil { type += "; charset=\"UTF-8\"" }
            return GmailOutgoingMessage.Attachment(filename: name, mimeType: type, data: data)
        }
    }

    /// The file a path names, inside one of the roots and under no hidden name there.
    static func resolve(_ path: String, roots: [URL]) throws -> URL {
        let expanded = expandingHome(path)
        guard expanded.hasPrefix("/") else {
            throw GmailOutgoingMessage.Problem.unattachable(path: path, reason: "give an absolute path.")
        }
        guard let url = canonical(expanded) else {
            throw GmailOutgoingMessage.Problem.unattachable(path: path, reason: "there is no such file.")
        }
        let holding = roots.compactMap { canonical($0.path(percentEncoded: false)) }
            .filter { BrowserAgentWorkspaceFile.contains($0, url) }
        guard !holding.isEmpty else {
            throw GmailOutgoingMessage.Problem.unattachable(path: path, reason: "files come from the task's folders, "
                + "the temporary folder, Desktop, Documents, or Downloads.")
        }
        guard holding.contains(where: { root in
            !url.pathComponents.dropFirst(root.pathComponents.count).contains { $0.hasPrefix(".") }
        }) else {
            throw GmailOutgoingMessage.Problem.unattachable(path: path, reason: "it is hidden or in a hidden folder.")
        }
        return url
    }

    /// The names and sizes a request card lists, read from the disk as they are now.
    static func describe(_ paths: [String]) -> [File] {
        paths.map { path in
            let size = canonical(expandingHome(path)).flatMap {
                try? $0.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            }.flatMap { $0.isRegularFile == true ? $0.fileSize : nil }
            return File(name: displayName(path), size: size)
        }
    }

    /// The name the recipient sees: the path's last part in composed form (macOS keeps Korean
    /// names decomposed, which other systems show as separate letters), without control characters.
    static func displayName(_ path: String) -> String {
        let name = (expandingHome(path) as NSString).lastPathComponent.precomposedStringWithCanonicalMapping
        return String(String.UnicodeScalarView(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
    }

    private static func expandingHome(_ path: String) -> String {
        (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
    }

    /// The path with `..` and every symbolic link resolved, as `realpath(3)` gives it (`/tmp` is
    /// `/private/tmp`); nil when nothing is there.
    private static func canonical(_ path: String) -> URL? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return URL(filePath: String(cString: resolved))
    }
}
