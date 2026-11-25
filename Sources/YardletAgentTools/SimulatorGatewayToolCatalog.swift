import Foundation

/// Compact discovery and dispatch tools for Yardlet's simulator tools (`SimulatorToolCatalog`) on
/// harnesses with a tight eager MCP schema budget (Antigravity CLI).
///
/// Listing these two tools instead of all ten `simulator_*` schemas keeps Yardlet's core tools
/// inside the harness's eager budget while every simulator action stays reachable through
/// `AgentToolBroker` and `SimulatorAgentTools` with the same setting checks, argument validation,
/// device approvals and credential scrubbing.
package enum SimulatorGatewayToolCatalog {
    package static let listTools = "list_simulator_tools"
    package static let callTool = "call_simulator_tool"

    package static let tools: [AgentToolDefinition] = [
        AgentToolDefinition(
            name: listTools,
            title: "List simulator tools",
            description: "List Yardlet's iOS simulator and Android emulator/device tools with their parameter schemas before calling \(callTool).",
            inputSchema: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "tool": .object([
                        "type": .string("string"),
                        "description": .string("Exact simulator tool name to inspect (omit for all).")
                    ])
                ])
            ]),
            readOnly: true,
            openWorld: false
        ),
        AgentToolDefinition(
            name: callTool,
            title: "Call simulator tool",
            description: "Call a Yardlet simulator tool by exact name from \(listTools) (e.g. simulator_list, simulator_attach, simulator_screenshot, simulator_snapshot, simulator_tap).",
            inputSchema: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "required": .array([.string("tool")]),
                "properties": .object([
                    "tool": .object([
                        "type": .string("string"),
                        "description": .string("Exact simulator tool name from \(listTools).")
                    ]),
                    "arguments": .object([
                        "type": .string("object"),
                        "additionalProperties": .bool(true),
                        "description": .string("Arguments object matching the tool's inputSchema.")
                    ])
                ])
            ]),
            // It changes nothing itself: Yardlet checks and, where the task asks, asks the person about each
            // call it makes as about a direct one (`AgentToolBroker`), so a harness need not ask about it first.
            readOnly: true,
            openWorld: true
        )
    ]

    package static func definition(named name: String) -> AgentToolDefinition? {
        tools.first { $0.name == name }
    }

    package static func formatList(tool exactTool: String?) -> AgentToolResult {
        let all = SimulatorToolCatalog.tools.map(\.json)
        let exact = exactTool?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact, !exact.isEmpty {
            if let match = all.first(where: { $0["name"]?.stringValue == exact }) {
                return .text(encodeDetailed([match]))
            }
            let names = SimulatorToolCatalog.tools.map(\.name)
            return .failure(
                "No simulator tool named \(exact). Available simulator tools: \(AgentToolNames.listed(names)).",
                .unknownTool,
                retry: .withChanges,
                details: [
                    "tool": .string(exact),
                    "similar": .array(names.map(ToolJSON.string))
                ]
            )
        }
        return .text(encodeDetailed(all))
    }

    private static func encodeDetailed(_ tools: [ToolJSON]) -> String {
        let compact: [ToolJSON] = tools.map { entry in
            var fields: [String: ToolJSON] = [:]
            if let name = entry["name"] { fields["name"] = name }
            if let description = entry["description"] { fields["description"] = description }
            if let inputSchema = entry["inputSchema"] { fields["inputSchema"] = inputSchema }
            return .object(fields)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(ToolJSON.array(compact)),
              let text = String(data: data, encoding: .utf8) else {
            return compact.compactMap { $0["name"]?.stringValue }.joined(separator: "\n")
        }
        return text
    }
}
