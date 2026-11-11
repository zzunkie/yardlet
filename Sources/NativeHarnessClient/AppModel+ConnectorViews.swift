import Foundation
import YardletAgentTools

extension AppModel {
    /// The task's way to the views its connector calls name (docs/CONNECTORS.md, "MCP Apps"); nil without connectors
    /// (tests, fixtures). One per task, so its conversation keeps the same one while it redraws.
    func connectorViewHost(for taskID: UUID) -> ConnectorViewHost? {
        guard let center = connectorCenter else { return nil }
        if let host = connectorViewHosts[taskID] { return host }
        let host = ConnectorViewHost(
            taskID: taskID, center: center,
            context: { [weak self] in
                let session = self?.store.sessions.first { $0.id == taskID }
                return ConnectorToolContext(
                    taskID: taskID,
                    scope: self?.connectorScopeBySessionID[taskID],
                    workspaceRoots: session.map { [$0.workspaceURL] + $0.additionalRootURLs } ?? [])
            },
            ask: { [weak self] connector, tool, arguments in
                await self?.askAboutViewCall(in: taskID, connector: connector, tool: tool, arguments: arguments) ?? false
            })
        connectorViewHosts[taskID] = host
        return host
    }

    /// Asks the person, on the task's request card, whether a view may run a tool that may change something. A view
    /// is a server's page whose script can call without a click, so this is asked in every permission mode.
    func askAboutViewCall(in taskID: UUID, connector: String, tool: String, arguments: ToolJSON) async -> Bool {
        let request = PermissionRequest(
            id: SessionToolApproval.idPrefix + UUID().uuidString.lowercased(),
            title: L10n.format("Allow the %@ view to %@?", connector, ConnectorToolLabels.spaced(tool)),
            detail: JSONValue(arguments).readableText ?? "",
            command: nil)
        return await sessionTools.ask(request, in: taskID) { [weak self] in
            self?.sessionToolApprovalsChanged(in: taskID)
        }
    }
}
