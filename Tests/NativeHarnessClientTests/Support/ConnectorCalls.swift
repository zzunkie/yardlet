import Foundation
import YardletAgentTools
@testable import NativeHarnessClient

extension ConnectorCenter {
    /// A call as a model makes it from the task's list: a tool its service's accounts share, whose list
    /// offers one account, names that account when the call names none.
    func callNamingTheOnlyAccount(_ name: String, _ arguments: [String: ToolJSON],
                                  for context: ConnectorToolContext) async -> AgentToolResult? {
        var arguments = arguments
        let key = ConnectorToolNaming.accountArgument
        if arguments[key] == nil {
            let tool = await connectorTools(for: context).first { $0["name"]?.stringValue == name }
            if let accounts = tool?["inputSchema"]?["properties"]?[key]?["enum"]?.arrayValue, accounts.count == 1 {
                arguments[key] = accounts[0]
            }
        }
        return await callConnectorTool(named: name, arguments: .object(arguments), for: context)
    }
}
