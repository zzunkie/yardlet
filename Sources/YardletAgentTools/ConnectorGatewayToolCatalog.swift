import Foundation

/// Compact discovery and dispatch tools for connected Yardlet connectors on harnesses whose MCP tool
/// declaration budget drops large schemas when hundreds of connector tools are listed flat (Antigravity CLI).
///
/// Listing these two tools instead of every connector's tools keeps Yardlet's own session, browser,
/// schedule and simulator tools inside the harness's eager budget while every connected service's
/// tools stay reachable through `AgentToolBroker` and `ConnectorCenter` with the same toggles,
/// argument validation, authentication and credential scrubbing.
package enum ConnectorGatewayToolCatalog {
    package static let listTools = "list_connector_tools"
    package static let callTool = "call_connector_tool"

    /// Maximum matching tools returned with full JSON schemas before switching to compact summaries.
    package static let detailedSchemaLimit = 20

    package static let staticTools: [AgentToolDefinition] = tools(services: [])

    package static func definition(named name: String) -> AgentToolDefinition? {
        staticTools.first { $0.name == name }
    }

    package static func tools(services: [String]) -> [AgentToolDefinition] {
        let trimmed = services
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let serviceNote = trimmed.isEmpty
            ? "connected Yardlet services"
            : "connected Yardlet services (\(trimmed.joined(separator: ", ")))"
        return [
            AgentToolDefinition(
                name: listTools,
                title: "List connector tools",
                description: "List tools of \(serviceNote) with their parameter schemas. Pass service, query, or tool to inspect schemas before calling \(callTool).",
                inputSchema: .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "properties": .object([
                        "service": .object([
                            "type": .string("string"),
                            "description": .string("Service prefix or name, such as gmail, calendar, drive, slack, linear, notion, github, stripe, or mail.")
                        ]),
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("Substring filter on tool name or description.")
                        ]),
                        "tool": .object([
                            "type": .string("string"),
                            "description": .string("Exact tool name to inspect its full description and inputSchema.")
                        ])
                    ])
                ]),
                readOnly: true,
                openWorld: false
            ),
            AgentToolDefinition(
                name: callTool,
                title: "Call connector tool",
                description: "Call a connected Yardlet connector tool by exact name from \(listTools).",
                inputSchema: .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "required": .array([.string("tool")]),
                    "properties": .object([
                        "tool": .object([
                            "type": .string("string"),
                            "description": .string("Exact connector tool name from \(listTools).")
                        ]),
                        "arguments": .object([
                            "type": .string("object"),
                            "additionalProperties": .bool(true),
                            "description": .string("Arguments object matching the tool's inputSchema.")
                        ])
                    ])
                ]),
                readOnly: false,
                openWorld: true
            )
        ]
    }

    package static func formatList(
        tools: [ToolJSON],
        service: String?,
        query: String?,
        exactTool: String?
    ) -> AgentToolResult {
        guard !tools.isEmpty else {
            return .text("No Yardlet connector tools are enabled for this task.")
        }
        let exact = exactTool?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact, !exact.isEmpty {
            if let match = tools.first(where: { $0["name"]?.stringValue == exact }) {
                return .text(encodeDetailed([match]))
            }
            let names = tools.compactMap { $0["name"]?.stringValue }
            let similar = AgentToolNames.family(of: exact, in: names)
            let message = similar.isEmpty
                ? "No connected connector tool named \(exact). Call \(listTools) with service or query to list available tools."
                : "No connected connector tool named \(exact). Tools in that service: \(AgentToolNames.listed(similar))."
            return .failure(message, .unknownTool, retry: .withChanges, details: [
                "tool": .string(exact),
                "similar": .array(similar.map(ToolJSON.string))
            ])
        }

        let serviceFilter = service?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let queryFilter = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = tools.filter { entry in
            let name = (entry["name"]?.stringValue ?? "").lowercased()
            let description = (entry["description"]?.stringValue ?? "").lowercased()
            if let serviceFilter, !serviceFilter.isEmpty {
                let compact = serviceFilter.replacingOccurrences(of: " ", with: "")
                let matchesService = name.hasPrefix(serviceFilter + "_")
                    || name.hasPrefix(serviceFilter)
                    || name.hasPrefix(compact + "_")
                    || description.hasPrefix("[\(serviceFilter)]")
                    || description.contains("[\(serviceFilter)")
                if !matchesService { return false }
            }
            if let queryFilter, !queryFilter.isEmpty {
                if !name.contains(queryFilter) && !description.contains(queryFilter) { return false }
            }
            return true
        }

        if filtered.isEmpty {
            let prefixes = serviceSummary(of: tools)
            return .text("No connector tools matched. Available prefixes: \(prefixes).")
        }

        if filtered.count <= detailedSchemaLimit {
            return .text(encodeDetailed(filtered))
        }

        var lines: [String] = []
        if (serviceFilter?.isEmpty ?? true) && (queryFilter?.isEmpty ?? true) {
            lines.append("Connected connector tools (\(filtered.count) total): \(serviceSummary(of: filtered)).")
            lines.append("Pass service, query, or tool to inspect parameter schemas before calling \(callTool).")
        } else {
            lines.append("Matched \(filtered.count) connector tools (showing summaries; narrow with query or pass tool for full inputSchema):")
        }
        for entry in filtered {
            guard let name = entry["name"]?.stringValue else { continue }
            let firstLine = (entry["description"]?.stringValue ?? "")
                .split(whereSeparator: \.isNewline)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let short = firstLine.count > 120 ? String(firstLine.prefix(120)) + "…" : firstLine
            lines.append(short.isEmpty ? "- \(name)" : "- \(name): \(short)")
        }
        return .text(lines.joined(separator: "\n"))
    }

    private static func serviceSummary(of tools: [ToolJSON]) -> String {
        var counts: [(prefix: String, count: Int)] = []
        for entry in tools {
            guard let name = entry["name"]?.stringValue else { continue }
            let prefix = name.firstIndex(of: "_").map { String(name[..<$0]) } ?? name
            if let index = counts.firstIndex(where: { $0.prefix == prefix }) {
                counts[index].count += 1
            } else {
                counts.append((prefix, 1))
            }
        }
        return counts.map { "\($0.prefix) (\($0.count))" }.joined(separator: ", ")
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
