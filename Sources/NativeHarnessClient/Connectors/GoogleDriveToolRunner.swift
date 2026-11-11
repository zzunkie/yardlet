import Foundation
import YardletAgentTools

/// Runs one Google Drive tool call against the Drive API v3
/// (developers.google.com/workspace/drive/api/reference/rest/v3) and answers with compact JSON
/// text. Arguments are checked before any request; a mistake the model can fix is an error result.
/// Google's errors and a sign-in that ended are thrown to the connector center, which words them.
struct GoogleDriveToolRunner {
    let api: GoogleREST
    /// `…/upload/drive/v3/`, where content goes.
    let uploadBase: URL

    /// The most text `read_file_content` returns, and the most bytes `download_file_content` does.
    var maximumCharacters = 100_000
    var maximumDownload = 5 * 1_048_576

    typealias Problem = ConnectorToolArguments.Problem
    private typealias Arguments = ConnectorToolArguments
    private typealias Catalog = GoogleDriveToolCatalog

    /// What a file's answer carries, by the Drive API's field names.
    static let fileFields = "id,name,mimeType,size,createdTime,modifiedTime,viewedByMeTime,owners(emailAddress,displayName),"
        + "parents,webViewLink,description,starred,shared,trashed"

    func call(_ name: String, _ arguments: ToolJSON) async throws -> AgentToolResult {
        let arguments = arguments.objectValue ?? [:]
        do {
            let result: ToolJSON
            switch name {
            case Catalog.searchFiles: result = try await searchFiles(arguments)
            case Catalog.listRecentFiles: result = try await listRecentFiles(arguments)
            case Catalog.getFileMetadata: result = Self.file(try await metadata(try fileID(arguments)))
            case Catalog.getFilePermissions: result = try await permissions(arguments)
            case Catalog.readFileContent: result = try await readFileContent(arguments)
            case Catalog.downloadFileContent: result = try await downloadFileContent(arguments)
            case Catalog.createFile: result = try await createFile(arguments)
            case Catalog.copyFile: result = try await copyFile(arguments)
            case Catalog.updateFile: result = try await updateFile(arguments)
            default: return .error("Unknown tool: \(name)")
            }
            return .text(Arguments.text(result))
        } catch let problem as Problem {
            return .error(problem.localizedDescription)
        } catch GoogleREST.Failure.invalidID(let id) {
            return .error("Not an ID Google Drive takes: \(id)")
        } catch GoogleREST.Failure.tooLarge(let bytes, let limit) {
            return .error("The file is \(bytes) bytes, more than the \(limit) download_file_content returns.")
        }
    }

    // MARK: Finding files

    private func searchFiles(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let query = DriveQuery.translate(Arguments.string(arguments, "query") ?? "")
        return try await list(query: query, order: nil, arguments)
    }

    private func listRecentFiles(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let order = switch Arguments.string(arguments, "orderBy") {
        case "lastModified"?: "modifiedTime desc"
        case "lastModifiedByMe"?: "modifiedByMeTime desc"
        default: "recency desc"
        }
        return try await list(query: "trashed = false", order: order, arguments)
    }

    private func list(query: String, order: String?, _ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        var items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "pageSize", value: String(Arguments.pageSize(arguments, range: 1...100, fallback: 10))),
            URLQueryItem(name: "fields", value: "nextPageToken,files(\(Self.fileFields))"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true")
        ]
        if let order { items.append(URLQueryItem(name: "orderBy", value: order)) }
        if let token = Arguments.string(arguments, "pageToken") { items.append(URLQueryItem(name: "pageToken", value: token)) }
        let answer = try await api.get(["files"], items)
        var result: [String: ToolJSON] = ["files": .array((answer["files"]?.arrayValue ?? []).map(Self.file))]
        if let next = answer["nextPageToken"] { result["nextPageToken"] = next }
        return .object(result)
    }

    private func permissions(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let id = try fileID(arguments)
        let answer = try await api.get(["files", id, "permissions"], [
            URLQueryItem(name: "fields", value: "permissions(id,type,role,emailAddress,domain,displayName,deleted)"),
            URLQueryItem(name: "supportsAllDrives", value: "true")
        ])
        return .object(["fileId": .string(id.removingPercentEncoding ?? id),
                        "permissions": .array((answer["permissions"]?.arrayValue ?? []).map {
                            .object(Arguments.pick($0, ["id", "type", "role", "emailAddress", "domain", "displayName", "deleted"]))
                        })])
    }

    // MARK: Reading content

    /// A Google Doc as Markdown (plain text where Drive cannot), a Sheet's first sheet as CSV,
    /// Slides as plain text, a text file as its text; other types are not text to read.
    private func readFileContent(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let id = try fileID(arguments)
        let file = try await metadata(id)
        let type = file["mimeType"]?.stringValue ?? ""
        var result = Self.file(file).objectValue ?? [:]
        let data: Data
        switch type {
        case Catalog.document:
            do {
                data = try await export(id, as: "text/markdown")
                result["contentFormat"] = .string("markdown")
            } catch GoogleREST.Failure.http(status: 400, _) {
                data = try await export(id, as: "text/plain")
                result["contentFormat"] = .string("text")
            }
        case Catalog.spreadsheet:
            data = try await export(id, as: "text/csv")
            result["contentFormat"] = .string("csv, first sheet")
        case Catalog.presentation:
            data = try await export(id, as: "text/plain")
            result["contentFormat"] = .string("text")
        default:
            guard Self.isText(type) else {
                throw Problem.invalid("\(file["name"]?.stringValue ?? "This file") is \(type), not text to read; "
                    + "download_file_content returns its bytes.")
            }
            data = try await api.download(["files", id], [URLQueryItem(name: "alt", value: "media"),
                                                         URLQueryItem(name: "supportsAllDrives", value: "true")],
                                          limit: maximumDownload).data
            result["contentFormat"] = .string("text")
        }
        let text = String(decoding: data, as: UTF8.self)
        if text.count > maximumCharacters {
            result["content"] = .string(String(text.prefix(maximumCharacters)))
            result["contentTruncated"] = .bool(true)
        } else {
            result["content"] = .string(text)
        }
        if Arguments.bool(arguments["includeComments"]) == true {
            result["commentThreads"] = try await comments(id)
        }
        return .object(result)
    }

    private func downloadFileContent(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let id = try fileID(arguments)
        let file = try await metadata(id)
        let type = file["mimeType"]?.stringValue ?? ""
        let data: Data
        let mimeType: String
        if let defaultExport = Self.defaultExport[type] {
            mimeType = Arguments.string(arguments, "exportMimeType") ?? defaultExport
            data = try await export(id, as: mimeType)
        } else if type.hasPrefix("application/vnd.google-apps.") {
            throw Problem.invalid("\(type) has no content to download.")
        } else {
            if let size = file["size"]?.stringValue.flatMap(Int.init), size > maximumDownload {
                throw GoogleREST.Failure.tooLarge(bytes: size, limit: maximumDownload)
            }
            let path = try Arguments.string(arguments, "revisionId").map { ["files", id, "revisions", try GoogleREST.segment($0)] }
                ?? ["files", id]
            let answer = try await api.download(path, [URLQueryItem(name: "alt", value: "media"),
                                                      URLQueryItem(name: "supportsAllDrives", value: "true")],
                                                limit: maximumDownload)
            data = answer.data
            mimeType = type.isEmpty ? (answer.mimeType ?? "application/octet-stream") : type
        }
        return .object([
            "fileId": .string(id.removingPercentEncoding ?? id),
            "title": file["name"] ?? .null,
            "mimeType": .string(mimeType),
            "size": .integer(Int64(data.count)),
            "base64Content": .string(data.base64EncodedString())
        ])
    }

    private func export(_ id: String, as type: String) async throws -> Data {
        try await api.download(["files", id, "export"], [URLQueryItem(name: "mimeType", value: type)],
                               limit: maximumDownload).data
    }

    /// A file's comment threads, for any file Drive keeps (a Doc, Sheet, or Slides file too).
    func comments(_ id: String) async throws -> ToolJSON {
        let answer = try await api.get(["files", id, "comments"], [
            URLQueryItem(name: "fields", value: "comments(id,content,quotedFileContent(value),resolved,modifiedTime,"
                + "author(displayName),replies(content,modifiedTime,author(displayName)))"),
            URLQueryItem(name: "pageSize", value: "100")
        ])
        return .array((answer["comments"]?.arrayValue ?? []).map { comment in
            var thread: [String: ToolJSON] = ["commentId": comment["id"] ?? .null,
                                              "status": .string(comment["resolved"] == .bool(true) ? "RESOLVED" : "OPEN")]
            thread["headPost"] = Self.post(comment)
            if let quoted = comment["quotedFileContent"]?["value"] { thread["quotedText"] = quoted }
            thread["replies"] = .array((comment["replies"]?.arrayValue ?? []).map(Self.post))
            return .object(thread)
        })
    }

    private static func post(_ value: ToolJSON) -> ToolJSON {
        var post = Arguments.pick(value, ["content", "modifiedTime"])
        if let author = value["author"]?["displayName"] { post["authorName"] = author }
        return .object(post)
    }

    // MARK: Writing

    private func createFile(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        var metadata: [String: ToolJSON] = ["name": .string(try Arguments.required(arguments, "title"))]
        if let parent = Arguments.string(arguments, "parentId") { metadata["parents"] = .array([.string(parent)]) }
        let query = [URLQueryItem(name: "fields", value: Self.fileFields), URLQueryItem(name: "supportsAllDrives", value: "true")]
        guard let (upload, contentType) = try content(arguments) else {
            let type = Arguments.string(arguments, "mimeType") ?? Catalog.document
            guard type.hasPrefix("application/vnd.google-apps.") else {
                throw Problem.invalid("Without content, mimeType is a Google Doc, Sheet, Slides, or folder type.")
            }
            metadata["mimeType"] = .string(type)
            return Self.file(try await api.post(["files"], .object(metadata), query))
        }
        if Arguments.bool(arguments["disableConversionToGoogleType"]) != true, let google = Self.conversion[contentType] {
            metadata["mimeType"] = .string(google)
        } else {
            metadata["mimeType"] = .string(contentType)
        }
        return Self.file(try await api.upload(method: "POST", to: uploadBase, ["files"], query,
                                              metadata: .object(metadata), content: upload, contentType: contentType))
    }

    private func copyFile(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let id = try fileID(arguments)
        var body: [String: ToolJSON] = [:]
        if let title = Arguments.string(arguments, "title") { body["name"] = .string(title) }
        if let parent = Arguments.string(arguments, "parentId") { body["parents"] = .array([.string(parent)]) }
        return Self.file(try await api.post(["files", id, "copy"], .object(body), [
            URLQueryItem(name: "fields", value: Self.fileFields), URLQueryItem(name: "supportsAllDrives", value: "true")
        ]))
    }

    /// Renames, moves, or replaces the content of a file Yardlet created (`drive.file` reaches no
    /// other file for writing): the metadata and new content in one request when both change.
    private func updateFile(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let id = try fileID(arguments)
        var changes: [String: ToolJSON] = [:]
        if let title = Arguments.string(arguments, "title") { changes["name"] = .string(title) }
        if let description = arguments["description"]?.stringValue { changes["description"] = .string(description) }
        var query = [URLQueryItem(name: "fields", value: Self.fileFields), URLQueryItem(name: "supportsAllDrives", value: "true")]
        if let parent = Arguments.string(arguments, "parentId") {
            let current = try await metadata(id)
            let old = (current["parents"]?.arrayValue ?? []).compactMap(\.stringValue)
            query.append(URLQueryItem(name: "addParents", value: parent))
            if !old.isEmpty { query.append(URLQueryItem(name: "removeParents", value: old.joined(separator: ","))) }
        }
        let replacement = try content(arguments)
        guard !changes.isEmpty || replacement != nil || Arguments.string(arguments, "parentId") != nil else {
            throw Problem.invalid("Give a new title, description, folder, or content.")
        }
        if let (data, type) = replacement {
            return Self.file(try await api.upload(method: "PATCH", to: uploadBase, ["files", id], query,
                                                  metadata: .object(changes), content: data, contentType: type))
        }
        return Self.file(try await api.patch(["files", id], .object(changes), query))
    }

    /// The content a call gives: text or base64, with its type.
    private func content(_ arguments: [String: ToolJSON]) throws -> (Data, String)? {
        let text = arguments["textContent"]?.stringValue
        let base64 = Arguments.string(arguments, "base64Content") ?? Arguments.string(arguments, "content")
        switch (text, base64) {
        case (nil, nil):
            return nil
        case (let text?, nil):
            return (Data(text.utf8), Arguments.string(arguments, "contentMimeType") ?? "text/plain")
        case (nil, let base64?):
            guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
                throw Problem.invalid("base64Content is not base64.")
            }
            guard let type = Arguments.string(arguments, "contentMimeType") else { throw Problem.missing("contentMimeType") }
            return (data, type)
        default:
            throw Problem.invalid("Give textContent or base64Content, not both.")
        }
    }

    // MARK: Pieces

    private func fileID(_ arguments: [String: ToolJSON]) throws -> String {
        try GoogleREST.segment(try Arguments.required(arguments, "fileId"))
    }

    private func metadata(_ id: String) async throws -> ToolJSON {
        try await api.get(["files", id], [URLQueryItem(name: "fields", value: Self.fileFields),
                                          URLQueryItem(name: "supportsAllDrives", value: "true")])
    }

    /// Types Drive turns into a Google type on upload.
    static let conversion: [String: String] = [
        "text/plain": Catalog.document, "text/markdown": Catalog.document, "text/html": Catalog.document,
        "application/rtf": Catalog.document, "application/vnd.oasis.opendocument.text": Catalog.document,
        "application/msword": Catalog.document,
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document": Catalog.document,
        "text/csv": Catalog.spreadsheet, "text/tab-separated-values": Catalog.spreadsheet,
        "application/vnd.ms-excel": Catalog.spreadsheet,
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": Catalog.spreadsheet,
        "application/vnd.oasis.opendocument.spreadsheet": Catalog.spreadsheet,
        "application/vnd.ms-powerpoint": Catalog.presentation,
        "application/vnd.openxmlformats-officedocument.presentationml.presentation": Catalog.presentation,
        "application/vnd.oasis.opendocument.presentation": Catalog.presentation
    ]

    /// What a Google type downloads as when the call names no export type.
    static let defaultExport: [String: String] = [
        Catalog.document: "text/plain", Catalog.spreadsheet: "text/csv", Catalog.presentation: "text/plain",
        "application/vnd.google-apps.drawing": "image/png"
    ]

    static func isText(_ type: String) -> Bool {
        type.hasPrefix("text/") || ["application/json", "application/xml", "application/javascript", "application/x-sh",
                                    "application/x-yaml", "application/yaml", "application/sql", "application/csv"].contains(type)
            || type.hasSuffix("+json") || type.hasSuffix("+xml")
    }

    /// A file as the tools return it, by Google's Drive MCP names: title, fileSize, owner, parentId, viewUrl.
    static func file(_ file: ToolJSON) -> ToolJSON {
        var fields = Arguments.pick(file, ["id", "mimeType", "createdTime", "modifiedTime", "viewedByMeTime",
                                           "description", "starred", "shared", "trashed"])
        if let name = file["name"] { fields["title"] = name }
        if let size = file["size"] { fields["fileSize"] = size }
        if let owner = file["owners"]?.arrayValue?.first?["emailAddress"] { fields["owner"] = owner }
        if let parent = file["parents"]?.arrayValue?.first { fields["parentId"] = parent }
        if let link = file["webViewLink"] { fields["viewUrl"] = link }
        return .object(fields)
    }
}

/// `search_files` takes the query terms Google's Drive MCP server documents (`title`, `parentId`,
/// `owner`, plus the Drive API's own); the Drive API names them `name`, `'…' in parents`, and
/// `'…' in owners`. Plain words with no operator search the full text. Trashed files stay out.
enum DriveQuery {
    static func translate(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "trashed = false" }
        var tokens = tokenize(trimmed)
        // A query compares something to a quoted value or a literal; "plan in progress" is words.
        let operators: Set<String> = ["=", "!=", "<", "<=", ">", ">=", "contains", "has"]
        let structured = tokens.contains { operators.contains($0.lowercased()) }
            || zip(tokens, tokens.dropFirst()).contains { $0.hasPrefix("'") && $1.lowercased() == "in" }
        guard structured else {
            return "fullText contains \(quoted(trimmed)) and trashed = false"
        }
        var output: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let field = token.lowercased()
            if (field == "parentid" || field == "owner"), index + 2 < tokens.count,
               tokens[index + 1] == "=" || tokens[index + 1] == "!=", tokens[index + 2].hasPrefix("'") {
                let membership = "\(tokens[index + 2]) in \(field == "owner" ? "owners" : "parents")"
                output.append(tokens[index + 1] == "!=" ? "not \(membership)" : membership)
                index += 3
                continue
            }
            output.append(field == "title" ? "name" : token)
            index += 1
        }
        tokens = output
        let text = tokens.joined(separator: " ").replacingOccurrences(of: "( ", with: "(").replacingOccurrences(of: " )", with: ")")
        return text.lowercased().contains("trashed") ? text : "(\(text)) and trashed = false"
    }

    /// Words, operators, parentheses, and single-quoted strings (with `\'` inside) as they are.
    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var characters = Array(text)[...]
        func flush() {
            if !current.isEmpty { tokens.append(current); current = "" }
        }
        while let character = characters.popFirst() {
            switch character {
            case "'":
                flush()
                var literal = "'"
                while let next = characters.popFirst() {
                    literal.append(next)
                    if next == "\\", let escaped = characters.popFirst() { literal.append(escaped); continue }
                    if next == "'" { break }
                }
                tokens.append(literal)
            case "(", ")":
                flush()
                tokens.append(String(character))
            case "=", "<", ">", "!":
                flush()
                var op = String(character)
                if characters.first == "=" { op.append(characters.removeFirst()) }
                tokens.append(op)
            case _ where character.isWhitespace:
                flush()
            default:
                current.append(character)
            }
        }
        flush()
        return tokens
    }

    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }
}
