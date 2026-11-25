import Foundation

/// Compact discovery and sandboxed JavaScript execution tools for Yardlet's native MCP Code Mode.
///
/// When enabled in Settings, agents can discover available Yardlet and connector tools on demand
/// (`search_yardlet_tools`) and chain/filter multiple tool calls inside a single sandboxed script
/// (`run_yardlet_script`), keeping large intermediate payloads and unused tool schemas out of the
/// model's context window while every underlying call still runs through `AgentToolBroker`'s
/// authentication, argument validation, approvals, and credential scrubbing. Both load with the prompt
/// (`alwaysLoad`), so Claude Code does not first look them up with its own tool search.
package enum CodeModeToolCatalog {
    package static let searchTools = "search_yardlet_tools"
    package static let runScript = "run_yardlet_script"

    /// Maximum matching tools returned with full JSON schemas before switching to compact summaries.
    package static let detailedSchemaLimit = 10

    package static let tools: [AgentToolDefinition] = [
        AgentToolDefinition(
            name: searchTools,
            title: "Search Yardlet tools",
            description: "Search available Yardlet and connected connector tools. Returns JSON {count, groups, tools: [{name, category, description, inputSchema?}]}, with inputSchema when \(detailedSchemaLimit) or fewer match; pass tool for one tool's [{name, description, inputSchema}]. Use before calling \(runScript).",
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
            openWorld: false,
            alwaysLoad: true
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
            // It changes nothing itself: Yardlet checks and, where the task asks, asks the person about each
            // call it makes as about a direct one (`AgentToolBroker`), so a harness need not ask about it first.
            readOnly: true,
            openWorld: true,
            alwaysLoad: true
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

        // JSON either way, so a script's `callTool` gets an object to filter. Groups always count the
        // matches, or every tool when nothing matched, so the model can narrow or widen its next search.
        let detailed = !filtered.isEmpty && filtered.count <= detailedSchemaLimit
        var fields: [String: ToolJSON] = [
            "count": .integer(Int64(filtered.count)),
            "groups": groups(of: filtered.isEmpty ? tools : filtered),
            "tools": .array(filtered.compactMap { listed($0, detailed: detailed) })
        ]
        if !filtered.isEmpty, !detailed {
            fields["hint"] = .string("Narrow with query or category, or pass tool for one tool's inputSchema.")
        }
        return .text(encode(.object(fields)))
    }

    /// The part of a tool name before its first underscore: a connector's service, or a Yardlet family.
    private static func category(of name: String) -> String {
        name.firstIndex(of: "_").map { String(name[..<$0]) } ?? name
    }

    private static func groups(of tools: [ToolJSON]) -> ToolJSON {
        var counts: [(category: String, count: Int)] = []
        for entry in tools {
            guard let name = entry["name"]?.stringValue else { continue }
            let category = category(of: name)
            if let index = counts.firstIndex(where: { $0.category == category }) {
                counts[index].count += 1
            } else {
                counts.append((category, 1))
            }
        }
        return .array(counts.map { .object(["category": .string($0.category), "count": .integer(Int64($0.count))]) })
    }

    /// A matched tool: its whole description and inputSchema when few matched, else its first line.
    private static func listed(_ entry: ToolJSON, detailed: Bool) -> ToolJSON? {
        guard let name = entry["name"]?.stringValue else { return nil }
        let description = entry["description"]?.stringValue ?? ""
        var fields: [String: ToolJSON] = ["name": .string(name), "category": .string(category(of: name))]
        if detailed {
            fields["description"] = .string(description)
            if let schema = entry["inputSchema"] { fields["inputSchema"] = schema }
        } else {
            let firstLine = description.split(whereSeparator: \.isNewline).first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            fields["description"] = .string(firstLine.count > 100 ? String(firstLine.prefix(100)) + "…" : firstLine)
        }
        return .object(fields)
    }

    private static func encodeDetailed(_ tools: [ToolJSON]) -> String {
        let trimmed: [ToolJSON] = tools.map { entry in
            var fields: [String: ToolJSON] = [:]
            if let name = entry["name"] { fields["name"] = name }
            if let description = entry["description"] { fields["description"] = description }
            if let schema = entry["inputSchema"] { fields["inputSchema"] = schema }
            return .object(fields)
        }
        return encode(.array(trimmed))
    }

    private static func encode(_ value: ToolJSON) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
