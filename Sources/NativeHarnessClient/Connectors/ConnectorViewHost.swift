import Foundation
import YardletAgentTools

/// One task's way to the views its connector calls name (docs/CONNECTORS.md, "MCP Apps"): reads a view from its
/// connector, finds the result it shows, and runs what the view asks of the connector under the task, with the
/// checks a model's call gets. The app makes one per task, so the conversation keeps the same one while it redraws.
@MainActor
final class ConnectorViewHost {
    let taskID: UUID
    private weak var center: ConnectorCenter?
    private let context: @MainActor () -> ConnectorToolContext
    /// Whether the person allows a view's call that may change something.
    private let ask: @MainActor (_ connector: String, _ tool: String, _ arguments: ToolJSON) async -> Bool

    init(taskID: UUID, center: ConnectorCenter, context: @escaping @MainActor () -> ConnectorToolContext,
         ask: @escaping @MainActor (_ connector: String, _ tool: String, _ arguments: ToolJSON) async -> Bool) {
        self.taskID = taskID
        self.center = center
        self.context = context
        self.ask = ask
    }

    /// The result a row's view shows: the whole one Yardlet kept from the call, else what the harness kept, for a tool
    /// that changes nothing. Nil leaves the row as text.
    func result(for view: ConversationConnectorView) -> ToolJSON? {
        if let kept = center?.appCalls.result(task: taskID, tool: view.tool, arguments: view.arguments) { return kept }
        return view.readOnly ? view.harnessResult : nil
    }

    /// The view and what its bridge needs, read from the connector; throws when the view cannot be drawn.
    func load(_ view: ConversationConnectorView, openLink: @escaping @MainActor (URL) -> Void) async throws
        -> (view: MCPAppView, host: MCPAppBridge.Host) {
        guard let center, let result = result(for: view) else { throw MCPAppViewFailure.noView }
        let (read, tool) = try await center.appView(forTool: view.tool)
        let viewTool = view.tool
        let host = MCPAppBridge.Host(
            tool: tool, arguments: view.arguments ?? .object([:]), result: result, version: center.clientVersion,
            callTool: { [weak self] name, arguments in
                guard let self, let center = self.center else { throw MCPAppViewFailure.noView }
                return try await center.callFromView(viewTool: viewTool, tool: name, arguments: arguments,
                                                     context: self.context(), ask: self.ask)
            },
            readResource: { [weak self] uri in
                guard let center = self?.center else { throw MCPAppViewFailure.noView }
                return try await center.readFromView(viewTool: viewTool, uri: uri)
            },
            openLink: openLink
        )
        return (read, host)
    }
}
