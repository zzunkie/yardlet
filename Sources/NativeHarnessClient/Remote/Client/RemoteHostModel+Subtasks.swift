import Foundation
import YardletRemote

extension RemoteHostModel {
    func readSubtask(taskID: String, activityID: String) async throws -> (ConversationPresentation, Bool) {
        let response = await response(to: .subtask(taskID: taskID, activityID: activityID, stop: false))
        guard response.ok, let value = response.subtask else { throw response.error ?? RemoteError(.unavailable) }
        let conversation = RemoteConversationModel(taskID: taskID, harness: .claudeCode, hostName: name)
        conversation.load(value.items, cursor: nil, hasOlder: false)
        return (conversation.presentation, value.truncated)
    }
}
