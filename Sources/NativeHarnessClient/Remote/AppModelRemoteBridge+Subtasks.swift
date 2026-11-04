import Foundation
import YardletRemote

extension AppModelRemoteBridge {
    func subtask(taskID: String, activityID: String, stop: Bool) async -> Result<RemoteSubtaskTranscript, RemoteError> {
        guard let model, let session = session(taskID), session.harness == .claudeCode else {
            return .failure(RemoteError(.notFound))
        }
        do {
            if stop {
                try await model.stopClaudeSubtask(activityID: activityID, from: session)
                return .success(RemoteSubtaskTranscript())
            }
            let snapshot = try await model.readClaudeSubtask(activityID: activityID, from: session)
            let presentation = TranscriptConversationProjection.presentation(from: snapshot.entries, harness: .claudeCode,
                status: .ready, latestTurnIsComplete: false)
            // Read on opening or Refresh, never on each parent event. Keep whole recent turns and bound the reply.
            var turns: [RemoteTurn] = []
            let hasEarlier = snapshot.isTruncated || presentation.turns.count > 10
            for turn in presentation.turns.suffix(10).reversed() {
                var full = RemoteConversationProjection.Full()
                if let make = subtaskPreviewMaker {
                    let root = session.workspaceURL.resolvingSymlinksInPath().path + "/"
                    let urls = (turn.prompt + turn.notices + turn.work + turn.answers).flatMap { item -> [URL] in
                        switch item.kind {
                        case let .userMessage(_, images): return images.compactMap(\.url)
                        case .tool: return RemoteConversationProjection.bodyImages(item, workspaceURL: session.workspaceURL)
                        default: return []
                        }
                    }.filter { $0.scheme == "data" || ($0.isFileURL && $0.resolvingSymlinksInPath().path.hasPrefix(root)) }
                    for url in Set(urls).prefix(8) {
                        if let data = await make(url, RemoteImagePreviews.maximumSide) { full.previews[url] = data }
                    }
                }
                let remote = RemoteConversationProjection.turn(turn, harness: .claudeCode,
                    workspaceURL: session.workspaceURL, full: full)
                turns.append(remote)
            }
            guard model.matchingSession(session) != nil, self.session(taskID) != nil else {
                return .failure(RemoteError(.notFound))
            }
            return .success(RemoteSubtaskTranscript.window(
                RemoteConversation(turns: turns.reversed(), hasEarlier: hasEarlier),
                omittedItemText: L10n.string("This part of the task is too large to show here.")))
        } catch { return .failure(RemoteError(.unavailable)) }
    }
}
