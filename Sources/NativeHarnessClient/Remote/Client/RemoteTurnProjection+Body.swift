import Foundation
import YardletRemote

extension RemoteTurnProjection {
    static func bodyItem(_ item: RemoteItem) -> ConversationItem? {
        guard let body = item.body else { return nil }
        let record = ConversationItemSource.transcript(TranscriptEntry(id: uuid(item.id), createdAt: .distantPast, content: .user(text: item.text ?? "")))
        let phase: ConversationItemPhase = switch item.status {
        case "running": .running
        case "failed": .failed
        case "stopped": .stopped
        default: .completed
        }
        let kind: ConversationItemKind
        if item.shell == true {
            kind = .shellCommand(ClaudeBashMessage(command: item.text ?? "", output: body.output ?? "", hasOutput: body.hasOutput == true), entryID: uuid(item.id))
        } else if let command = body.command {
            kind = .command(ConversationCommand(
                words: item.words?.map { ConversationLineWords(leading: $0.leading ?? "", verb: $0.verb, trailing: $0.trailing ?? "") },
                command: command, workingDirectory: nil, status: item.status ?? "completed", output: body.output,
                exitCode: item.exitCode, durationMilliseconds: item.durationMs, liveOutputHeadByteCount: body.headBytes,
                isApproved: item.approved == true, isBackground: body.background == true))
        } else if let files = body.files {
            kind = .fileChange(ConversationFileChange(rows: files.enumerated().map { index, file in
                let kind: CodexFileChangeCardProjection.Kind = switch file.kind {
                case "add": .add
                case "delete": .delete
                default: .update
                }
                let state: CodexFileChangeCardProjection.State = switch file.state {
                case "inProgress": .inProgress
                case "stopped": .stopped
                case "rejected": .rejected
                default: .applied
                }
                let preview: CodexFileChangeCardProjection.PreviewAvailability = switch file.preview {
                case "available": .available
                case "tooLarge": .tooLarge
                default: .missing
                }
                return .init(id: file.path, change: .null, displayPath: file.path,
                             fileName: (file.path as NSString).lastPathComponent, kind: kind, state: state,
                             lineCounts: file.additions.flatMap { a in file.deletions.map { .init(additions: a, deletions: $0) } },
                             preview: preview, fileURL: RemoteConversationFileLink.url(file.path),
                             precomputedPreview: .init(lines: file.lines.enumerated().map { i, line in
                                 let kind: CodexFileChangeCardProjection.Preview.Line.Kind = switch line.kind {
                                 case "addition": .addition
                                 case "deletion": .deletion
                                 case "separator": .separator
                                 default: .context
                                 }
                                 return .init(id: i, kind: kind, number: line.number, text: line.text)
                             }, hiddenLineCount: file.hidden, firstChangedLine: file.firstChangedLine))
            }, handoffs: [], errorMessage: item.detail, isApproved: item.approved == true))
        } else { return nil }
        var result = ConversationItem(id: item.id, kind: kind, phase: phase, source: record)
        result.copyDetails = bodyCopyText(item)
        return result
    }

    /// Copy only the display content the host sent, never its raw provider payload or tool input.
    static func bodyCopyText(_ item: RemoteItem) -> String? {
        guard let body = item.body else { return nil }
        var texts = [body.command ?? item.text ?? item.title, item.detail, body.output, body.reasoning].compactMap { $0 }
        texts += (body.mcp ?? []).compactMap(\.text)
        texts += (body.files ?? []).map { file in
            file.path + "\n" + file.lines.map { line in
                (line.kind == "addition" ? "+" : line.kind == "deletion" ? "-" : " ") + line.text
            }.joined(separator: "\n")
        }
        let text = texts.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    static func mcpBody(_ blocks: [RemoteConversationBody.Block]?, itemID: String) -> CodexMCPResultProjection? {
        guard let blocks else { return nil }
        let content: [CodexMCPResultProjection.Block] = blocks.enumerated().compactMap { index, block in
            let id = "\(itemID)#\(index)"
            switch block.kind {
            case "text": return .text(id: id, text: block.text ?? "")
            case "image":
                guard let image = block.image else { return nil }
                return .image(id: id, data: image.data, mimeType: image.type)
            case "resource_link":
                var link = CodexMCPResultProjection.ResourceLink(name: block.name ?? "", title: block.title,
                    uri: block.uri ?? "", description: block.text, mimeType: block.mimeType)
                if let url = URL(string: link.uri), RemoteConversationFileLink.path(url) != nil { link.remoteURL = url }
                return .resourceLink(id: id, link: link)
            default: return nil
            }
        }
        return CodexMCPResultProjection(blocks: content)
    }
}
