import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import YardletAgentTools

/// Adapt the remote schema, arguments and result at the edge. Callers prepare arguments once,
/// before the first request, and retain those values through permission prompts.
enum GoogleWorkspaceMCPBridge {
    private static let attachmentTools: Set<String> = ["create_draft", "update_draft", "send_message", "reply", "forward"]
    static let rawLimit = 18 * 1024 * 1024
    private static let imageLimit = 10 * 1024 * 1024
    private static let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]

    static func exposedTool(_ tool: ToolJSON) -> ToolJSON {
        guard var definition = tool.objectValue, let name = definition["name"]?.stringValue, attachmentTools.contains(name),
              var schema = definition["inputSchema"]?.objectValue, var properties = schema["properties"]?.objectValue,
              var attachments = properties["attachments"]?.objectValue, var item = attachments["items"]?.objectValue,
              var fields = item["properties"]?.objectValue, fields["content"] != nil else { return tool }
        fields["path"] = .object(["type": .string("string"), "description": .string(
            "Absolute local file path instead of content. Yardlet supplies the filename and MIME type. "
            + "Use a visible file in the task folders, temporary folder, Desktop, Documents, or Downloads (18 MB total).")])
        item["properties"] = .object(fields)
        let required = item["required"]?.arrayValue ?? []
        let derived: Set<String> = ["content", "filename", "mimeType"]
        let conditional = required.filter { derived.contains($0.stringValue ?? "") }
        item["required"] = .array(required.filter { !conditional.contains($0) })
        item["oneOf"] = .array([
            .object(["required": .array(conditional.contains(.string("content")) ? conditional : conditional + [.string("content")])]),
            .object(["required": .array([.string("path")])])
        ])
        attachments["items"] = .object(item)
        properties["attachments"] = .object(attachments)
        schema["properties"] = .object(properties)
        definition["inputSchema"] = .object(schema)
        return .object(definition)
    }

    static func prepareArguments(name: String, arguments: ToolJSON, taskFolders: [URL]) throws -> ToolJSON {
        guard var args = arguments.objectValue else { throw MCPHTTPError.invalidResponse("expected tool arguments") }
        args.removeValue(forKey: "account")
        for key in ["fileId", "documentId", "spreadsheetId", "presentationId"] {
            if let value = args[key]?.stringValue, let id = fileID(in: value) { args[key] = .string(id) }
        }
        if attachmentTools.contains(name), let items = args["attachments"]?.arrayValue {
            let roots = GmailAttachmentFiles.roots(taskFolders: taskFolders)
            var remaining = rawLimit
            var encodedRemaining = GmailAttachmentFiles.limit
            args["attachments"] = .array(try items.map { attachment in
                guard var item = attachment.objectValue else { throw Failure.invalidAttachment }
                if let pathValue = item.removeValue(forKey: "path") {
                    guard let path = pathValue.stringValue, item["content"] == nil else { throw Failure.invalidAttachment }
                    let url = try GmailAttachmentFiles.resolve(path, roots: roots)
                    guard !hasHiddenComponent(path), !hasHiddenComponent(url.path(percentEncoded: false)) else {
                        throw GmailOutgoingMessage.Problem.unattachable(path: path, reason: "it is hidden or in a hidden folder.")
                    }
                    let data = try readFile(at: url, roots: roots, remaining: remaining)
                    remaining -= data.count
                    item["content"] = .string(data.base64EncodedString())
                    item["filename"] = .string(GmailAttachmentFiles.displayName(path))
                    item["mimeType"] = .string(FileTypes.mimeType(forExtension: url.pathExtension) ?? "application/octet-stream")
                } else if let content = item["content"]?.stringValue {
                    guard content.utf8.count <= encodedRemaining else { throw Failure.tooLarge }
                    guard let data = Data(base64Encoded: content) else { throw Failure.invalidAttachment }
                    remaining -= data.count
                } else { throw Failure.invalidAttachment }
                encodedRemaining -= item["content"]?.stringValue?.utf8.count ?? 0
                guard remaining >= 0, encodedRemaining >= 0 else { throw Failure.tooLarge }
                return .object(item)
            })
        }
        return .object(args)
    }

    private static func hasHiddenComponent(_ path: String) -> Bool {
        let normalized = PathRules.current.isWindows ? path.replacingOccurrences(of: "\\", with: "/") : path
        return normalized.split(separator: "/").contains { $0.hasPrefix(".") && $0 != "." && $0 != ".." }
    }

    private enum Failure: LocalizedError {
        case tooLarge, invalidAttachment
        var errorDescription: String? {
            switch self {
            case .tooLarge: "Attachments exceed the 18 MB raw or 25 MB base64 limit. Share large files as links."
            case .invalidAttachment: "Each attachment needs either base64 content or a readable local file path."
            }
        }
    }

    private static func readFile(at url: URL, roots: [URL], remaining: Int) throws -> Data {
        // resolve() checked the canonical destination. Open its components without following
        // links again, and read at most one byte beyond the budget if the file grows.
        #if os(Windows)
        let candidates = roots.map { $0.resolvingSymlinksInPath() }
        #else
        let candidates = [URL(filePath: "/")]
        #endif
        for root in candidates {
            guard let relative = PathRules.current.relativePath(of: url, in: root),
                  let file = ScopedFiles(root: root).openRegularFile(relative.split(separator: "/").map(String.init))
            else { continue }
            guard file.size <= Int64(remaining) else { throw Failure.tooLarge }
            let bytes = try file.read(remaining + 1, at: 0)
            guard bytes.count <= remaining else { throw Failure.tooLarge }
            return bytes
        }
        throw Failure.invalidAttachment
    }

    private static func fileID(in value: String) -> String? {
        guard let url = URLComponents(string: value), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), ["drive.google.com", "docs.google.com"].contains(host)
        else { return nil }
        let parts = url.path.split(separator: "/")
        if let marker = parts.firstIndex(where: { $0 == "d" || $0 == "folders" }),
           parts.indices.contains(marker + 1) { return String(parts[marker + 1]) }
        if host == "drive.google.com", url.path == "/open" { return url.queryItems?.first { $0.name == "id" }?.value }
        return nil
    }

    static func augmentResult(name: String, result: ToolJSON,
                              configuration: URLSessionConfiguration = .ephemeral) async throws -> ToolJSON {
        guard name == "read_slide_page_thumbnail", result["isError"] != .bool(true),
              var object = result.objectValue, let content = object["content"]?.arrayValue else { return result }
        for entry in content where entry["type"] == .string("text") {
            guard let text = entry["text"]?.stringValue,
                  let json = try? JSONDecoder().decode(ToolJSON.self, from: Data(text.utf8)),
                  let address = json["contentUrl"]?.stringValue, let url = URL(string: address),
                  ThumbnailDownload.allows(url) else { continue }
            do {
                let image = try await thumbnail(url: url, configuration: configuration)
                guard image.starts(with: pngSignature) else { return result }
                object["content"] = .array(content + [.object([
                    "type": .string("image"), "mimeType": .string("image/png"),
                    "data": .string(image.base64EncodedString())
                ])])
                return .object(object)
            } catch {
                try Task.checkCancellation()
                return result
            }
        }
        return result
    }

    private static func thumbnail(url: URL, configuration: URLSessionConfiguration) async throws -> Data {
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let (results, completion) = AsyncThrowingStream<Data, Error>.makeStream()
        let download = ThumbnailDownload(completion: completion)
        let session = URLSession(configuration: configuration, delegate: download, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: URLRequest(url: url, timeoutInterval: 60)).resume()
        var iterator = results.makeAsyncIterator()
        let data = try await iterator.next()
        try Task.checkCancellation()
        guard let data else { throw URLError(.badServerResponse) }
        return data
    }

    /// The session calls the delegate on its serial delegate queue. Reject oversized responses
    /// both at the headers and while streaming a body without an accurate Content-Length.
    final class ThumbnailDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let completion: AsyncThrowingStream<Data, Error>.Continuation
        private var data = Data()

        init(completion: AsyncThrowingStream<Data, Error>.Continuation) {
            self.completion = completion
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  http.expectedContentLength <= Int64(imageLimit) else {
                completion.finish(throwing: URLError(.badServerResponse))
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            guard chunk.count <= imageLimit - data.count else {
                completion.finish(throwing: URLError(.dataLengthExceedsMaximum))
                dataTask.cancel()
                return
            }
            data.append(chunk)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                completion.finish(throwing: error)
            } else {
                completion.yield(data)
                completion.finish()
            }
        }

        static func allows(_ url: URL) -> Bool {
            guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
                  let host = url.host?.lowercased() else { return false }
            return host.hasSuffix(".googleusercontent.com") || host.hasSuffix(".ggpht.com")
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(request.url.map(Self.allows) == true ? request : nil)
        }
    }
}
