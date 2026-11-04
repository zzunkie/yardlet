import Foundation
import YardletRemote

extension RemoteConversationProjection {
    /// The normalized body the host's card reads. Only changed turns call this projection.
    static func body(_ item: ConversationItem, full: Full, workspaceURL: URL?) -> RemoteConversationBody? {
        var body = RemoteConversationBody()
        switch item.kind {
        case let .shellCommand(command, _):
            body.output = RemoteText.capped(command.output, RemoteItemDetail.outputLimit).text
            body.hasOutput = command.hasOutput
        case let .reasoning(_, detail, _):
            body.reasoning = RemoteText.short(detail, RemoteText.fullTextLimit)
        case let .command(command):
            body.command = RemoteText.capped(command.command, RemoteText.fullTextLimit).text
            // The live buffer already keeps the provider's head and latest tail (64 KiB plus its marker).
            // Cutting it again at the detail endpoint's 64,000-character bound would lose the newest output.
            body.output = command.liveOutputHeadByteCount == nil
                ? command.output.map { String($0.suffix(RemoteItemDetail.outputLimit)) } : command.output
            body.headBytes = command.liveOutputHeadByteCount.map { min($0, body.output?.utf8.count ?? 0) }
            body.background = command.isBackground
        case let .fileChange(change):
            let rows = change.placesRowsInWorkspace ? change.rows.map { $0.placed(in: workspaceURL) } : change.rows
            var budget = RemoteItemDetail.diffLimit
            body.files = rows.prefix(RemoteItemDetail.diffCount).compactMap { row in
                // Never send an absolute path outside the task, even as a display label.
                guard !row.displayPath.hasPrefix("/"), !row.displayPath.split(separator: "/").contains("..") else { return nil }
                let preview = row.preview == .available ? row.previewLines : .empty
                var lines: [RemoteConversationBody.Line] = []
                for line in preview.lines {
                    guard line.text.count <= budget else { break }
                    budget -= line.text.count
                    lines.append(.init(kind: String(describing: line.kind), number: line.number, text: line.text))
                }
                return .init(path: row.displayPath, kind: String(describing: row.kind), state: String(describing: row.state),
                             preview: String(describing: row.preview), additions: row.lineCounts?.additions,
                             deletions: row.lineCounts?.deletions, lines: lines,
                             hidden: preview.hiddenLineCount + preview.lines.count - lines.count,
                             firstChangedLine: preview.firstChangedLine)
            }
        case let .tool(tool):
            body.output = tool.output.map { RemoteText.capped($0, RemoteItemDetail.outputLimit).text }
            body.detail = RemoteText.short(tool.detail, RemoteItemDetail.outputLimit)
            body.error = RemoteText.short(tool.errorMessage, RemoteText.errorLimit)
            if case .mcp = tool.kind { body.toolName = RemoteText.short(tool.name, RemoteText.titleLimit) }
            var budget = RemoteItemDetail.outputLimit
            var imageBudget = 4
            body.mcp = tool.mcpResult?.blocks.prefix(50).compactMap { block in
                switch block {
                case let .text(_, text):
                    let text = RemoteText.capped(text, budget).text
                    budget -= text.count
                    return .init(kind: "text", text: text)
                case let .image(_, data, mimeType):
                    guard imageBudget > 0, let url = inlineImage(data, mimeType), let preview = full.previews[url] else { return nil }
                    imageBudget -= 1
                    return .init(kind: "image", image: RemoteImagePreview(data: preview))
                case let .resourceLink(_, link):
                    // Task files use the remote window's existing host-file handler. Other host paths stay private.
                    guard let url = link.openableURL, url.user == nil, url.password == nil else { return nil }
                    var uri = link.uri
                    if url.isFileURL {
                        guard let workspaceURL,
                              url.resolvingSymlinksInPath().path.hasPrefix(workspaceURL.resolvingSymlinksInPath().path + "/") else { return nil }
                        let root = workspaceURL.resolvingSymlinksInPath().path + "/"
                        let relative = String(url.resolvingSymlinksInPath().path.dropFirst(root.count))
                        guard let remoteURL = RemoteConversationFileLink.url(relative) else { return nil }
                        uri = remoteURL.absoluteString
                    }
                    return .init(kind: "resource_link", text: RemoteText.short(link.description, RemoteText.detailLimit),
                                 name: RemoteText.short(link.name, RemoteText.titleLimit), title: RemoteText.short(link.title, RemoteText.titleLimit),
                                 uri: RemoteText.short(uri, RemoteText.commandLimit), mimeType: link.mimeType)
                }
            }
        default: return nil
        }
        return body
    }

    static func inlineImage(_ data: Data, _ mimeType: String) -> URL? {
        URL(string: "data:\(mimeType);base64,\(data.base64EncodedString())")
    }

    /// Images already in the task's content; file previews are restricted to its workspace.
    static func bodyImages(_ item: ConversationItem, workspaceURL: URL?) -> [URL] {
        guard case let .tool(tool) = item.kind else { return [] }
        var urls = tool.images.prefix(4).compactMap(\.url)
        var count = 0
        for block in (tool.mcpResult?.blocks ?? []).prefix(50) {
            if case let .image(_, data, type) = block {
                guard count < 4 else { break }
                count += 1
                if let url = inlineImage(data, type) { urls.append(url) }
            }
        }
        return urls.filter { url in
            if url.scheme == "data" { return true }
            guard url.isFileURL, let workspaceURL else { return false }
            return url.resolvingSymlinksInPath().path.hasPrefix(workspaceURL.resolvingSymlinksInPath().path + "/")
        }
    }
}
