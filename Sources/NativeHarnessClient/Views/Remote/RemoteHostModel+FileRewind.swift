import Foundation
import YardletRemote

extension RemoteHostModel {
    func fileRewindActions(taskID: String, session: SessionRecord) -> ConversationRewindActions {
        ConversationRewindActions(beginCodexEdit: { _ in }, beginClaudeEdit: { _ in }, cancelEdit: {},
            loadFilePoints: {
                let value = try await self.readFileRewind(taskID, action: .points)
                return (value.points ?? []).map {
                    ClaudeConversationPoint(id: $0.id, text: $0.text, previousAssistantID: nil,
                                            hasAttachments: false, precedingEntries: [])
                }
            }, previewFiles: { pointID in
                let value = try await self.readFileRewind(taskID, action: .preview, pointID: pointID)
                guard let receipt = value.receipt.flatMap(UUID.init(uuidString:)) else { throw RemoteError(.unavailable) }
                return FileRewindPreview(id: receipt, session: session,
                    point: ClaudeConversationPoint(id: pointID, text: "", previousAssistantID: nil,
                        hasAttachments: false, precedingEntries: []), result: Self.fileRewindResult(value), fileFingerprints: [:])
            }, restoreFiles: { preview in
                Self.fileRewindResult(try await self.readFileRewind(taskID, action: .restore,
                    receipt: preview.id.uuidString, confirmed: true))
            }, confirmsRestore: true)
    }

    private func readFileRewind(_ taskID: String, action: RemoteFileRewindAction, pointID: String? = nil,
                               receipt: String? = nil, confirmed: Bool = false) async throws -> RemoteFileRewind {
        let response = await response(to: .fileRewind(taskID: taskID, action: action, pointID: pointID,
                                                     receipt: receipt, confirmed: confirmed))
        guard response.ok, let value = response.rewind else { throw response.error ?? RemoteError(.unavailable) }
        return value
    }

    private static func fileRewindResult(_ value: RemoteFileRewind) -> HarnessFileRewindResult {
        HarnessFileRewindResult(canRewind: value.canRewind == true, error: value.canRewind == false ? L10n.string("File restore is unavailable.") : nil, filesChanged: value.files,
            insertions: value.insertions, deletions: value.deletions, skippedLinks: value.skippedLinks, inFlight: value.inFlight)
    }
}
