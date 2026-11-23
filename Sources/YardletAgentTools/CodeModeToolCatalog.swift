import Foundation

/// Compact discovery and sandboxed JavaScript execution tools for Yardlet's native MCP Code Mode.
///
/// When enabled in Settings, agents can discover available Yardlet and connector tools on demand
/// (`search_yardlet_tools`) and chain/filter multiple tool calls inside a single sandboxed script
/// (`run_yardlet_script`), keeping large intermediate payloads and unused tool schemas out of the
/// model's context window while every underlying call still runs through `AgentToolBroker`'s
/// authentication, argument validation, approvals, and credential scrubbing.
package enum CodeModeToolCatalog {
    package static let searchTools = "search_yardlet_tools"
    package static let runScript = "run_yardlet_script"

    /// Maximum matching tools returned with full JSON schemas before switching to compact summaries.
    package static let detailedSchemaLimit = 10

    package static let tools: [AgentToolDefinition] = [
        AgentToolDefinition(
            name: searchTools,
            title: "Search Yardlet tools",
            description: "Search available Yardlet and connected connector tools with their parameter schemas. Pass query, category, or exact tool name before calling \(runScript).",
            inputSchema: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Substring filter on tool name or description.")
                    ]),
                    "category": .object([
                        "type": .string("string"),
                        "description": .string("Optional prefix or service filter, such as browser, gmail, calendar, linear, slack, github, or session.")
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
            name: runScript,
            title: "Run Yardlet script",
            description: "Run a short JavaScript snippet inside Yardlet's sandbox to chain and filter multiple Yardlet or connector tool calls in one step, returning only the distilled JSON result. Inside the script, call `callTool(name, args)` (synchronous, returns parsed JSON or `{text, isError}`) and `return` the final value. No filesystem, network, or shell access; capped at 20 tool calls.",
            inputSchema: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "required": .array([.string("code")]),
                "properties": .object([
                    "code": .object([
                        "type": .string("string"),
                        "description": .string("JavaScript function body using `callTool(name, args)` and ending with `return ...`.")
                    ]),
                    "timeoutSeconds": .object([
                        "type": .string("number"),
                        "description": .string("Optional timeout in seconds (1 to 60, default 30).")
                    ])
                ])
            ]),
            readOnly: false,
            openWorld: true
        )
    ]

    package static func definition(named name: String) -> AgentToolDefinition? {
        tools.first { $0.name == name }
    }

    package static func formatSearch(
        tools: [ToolJSON],
        query: String?,
        category: String?,
        exactTool: String?
    ) -> AgentToolResult {
        guard !tools.isEmpty else {
            return .text("No Yardlet tools are available for this task.")
        }
        let exact = exactTool?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact, !exact.isEmpty {
            if let match = tools.first(where: { $0["name"]?.stringValue == exact }) {
                return .text(encodeDetailed([match]))
            }
            let names = tools.compactMap { $0["name"]?.stringValue }
            let similar = AgentToolNames.family(of: exact, in: names)
            let message = similar.isEmpty
                ? "No Yardlet tool named \(exact). Call \(searchTools) with query or category to discover available tools."
                : "No Yardlet tool named \(exact). Similar tools: \(AgentToolNames.listed(similar))."
            return .failure(message, .unknownTool, retry: .withChanges, details: [
                "tool": .string(exact),
                "similar": .array(similar.map(ToolJSON.string))
            ])
        }

        let categoryFilter = category?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let queryFilter = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = tools.filter { entry in
            let name = (entry["name"]?.stringValue ?? "").lowercased()
            let description = (entry["description"]?.stringValue ?? "").lowercased()
            if let categoryFilter, !categoryFilter.isEmpty {
                let compact = categoryFilter.replacingOccurrences(of: " ", with: "")
                let matchesCategory = name.hasPrefix(categoryFilter + "_")
                    || name.hasPrefix(categoryFilter)
                    || name.hasPrefix(compact + "_")
                    || description.contains("[\(categoryFilter)")
                if !matchesCategory { return false }
            }
            if let queryFilter, !queryFilter.isEmpty {
                if !name.contains(queryFilter) && !description.contains(queryFilter) { return false }
            }
            return true
        }

        if filtered.isEmpty {
            return .text("No Yardlet tools matched. Available groups: \(groupSummary(of: tools)).")
        }

        if filtered.count <= detailedSchemaLimit {
            return .text(encodeDetailed(filtered))
        }

        var lines: [String] = [
            "Matched \(filtered.count) tools (\(groupSummary(of: filtered))). Narrow with query/category or pass exact tool for full inputSchema:"
        ]
        for entry in filtered {
            guard let name = entry["name"]?.stringValue else { continue }
            let firstLine = (entry["description"]?.stringValue ?? "")
                .split(whereSeparator: \.isNewline)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let short = firstLine.count > 100 ? String(firstLine.prefix(100)) + "…" : firstLine
            lines.append(short.isEmpty ? "- \(name)" : "- \(name): \(short)")
        }
        return .text(lines.joined(separator: "\n"))
    }

    private static func groupSummary(of tools: [ToolJSON]) -> String {
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
        let trimmed: [ToolJSON] = tools.map { entry in
            var fields: [String: ToolJSON] = [:]
            if let name = entry["name"] { fields["name"] = name }
            if let description = entry["description"] { fields["description"] = description }
            if let schema = entry["inputSchema"] { fields["inputSchema"] = schema }
            return .object(fields)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(ToolJSON.array(trimmed)),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }
}
