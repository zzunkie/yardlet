import Foundation

/// A tool approval that runs exactly one database change on a provider-hosted site: delete, insert
/// or update one row. It is executed as the one operation its confirmation summary describes, so it
/// is allowed once, never remembered, and only when that summary is exactly the provider's canonical
/// form of a valid change bound to its row. A summary that cannot be checked leaves Allow off.
///
/// The connector identity is the provider's constant for its sites connector, not an account's.
enum DotsSitesDatabaseApproval {
    static let connectorID = "connector_20205bf7d4e99a89d7154bb849718324"
    static let deleteTool = "sites.execute_database_delete"
    static let insertTool = "sites.execute_database_insert"
    static let updateTool = "sites.execute_database_update"
    static let summaryLimit = 500

    struct Recognition: Equatable, Sendable {
        let toolName: String
        /// The checked change, or nil when it cannot be bound and allowing stays off.
        let summary: [String: JSONValue]?

        /// The change as rows to read before allowing it.
        var details: [DotsApproval.Detail] {
            guard let summary else { return [] }
            let operation = switch toolName {
            case DotsSitesDatabaseApproval.deleteTool: L10n.string("Delete a row")
            case DotsSitesDatabaseApproval.insertTool: L10n.string("Insert a row")
            default: L10n.string("Update a value")
            }
            var rows: [DotsApproval.Detail] = [.init(name: L10n.string("Operation"), value: operation)]
            func add(_ title: String, _ key: String) {
                if let value = summary[key] { rows.append(.init(name: title, value: DotsJSONText.plain(value))) }
            }
            add(L10n.string("Database table"), "table_name")
            if let column = summary["primary_key_column"]?.stringValue, let value = summary["primary_key_value"]?.stringValue {
                rows.append(.init(name: L10n.string("Row"), value: column + " = " + value))
            }
            if toolName == DotsSitesDatabaseApproval.updateTool {
                add(L10n.string("Column"), "column")
                add(L10n.string("Current value"), "old_value")
                add(L10n.string("New value"), "new_value")
            } else if let values = summary["values"]?.objectValue {
                for key in values.keys.sorted() { rows.append(.init(name: key, value: DotsJSONText.plain(values[key]!))) }
            }
            return rows
        }
    }

    /// The database change `params` asks to approve, or nil when it is not one.
    static func recognize(_ params: JSONValue) -> Recognition? {
        let meta = params["_meta"]
        guard params["mode"]?.stringValue ?? "form" == "form", params["serverName"]?.stringValue == "codex_apps",
              meta?["codex_approval_kind"]?.stringValue == "mcp_tool_call",
              meta?["connector_id"]?.stringValue == connectorID else { return nil }
        let toolParams = meta?["tool_params"]?.objectValue
        let name = meta?["tool_name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tool: String
        if let name, [deleteTool, insertTool, updateTool].contains(name) {
            tool = name
        } else {
            if let name, !name.isEmpty { return nil }
            // A request that names no tool but carries a plan is the provider's update.
            guard let toolParams, toolParams["confirmation_summary"] != nil || toolParams["plan_token"] != nil else { return nil }
            tool = updateTool
        }
        guard let toolParams, Set(toolParams.keys) == ["confirmation_summary", "plan_token"],
              let token = toolParams["plan_token"]?.stringValue, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let summary = toolParams["confirmation_summary"]?.stringValue else {
            return .init(toolName: tool, summary: nil)
        }
        return .init(toolName: tool, summary: validate(summary, tool: tool))
    }

    /// The summary's change, when it is short enough, valid for the tool and already canonical.
    static func validate(_ text: String, tool: String) -> [String: JSONValue]? {
        guard text.utf16.count <= summaryLimit,
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
              let object = value.objectValue, valid(object, tool: tool), canonical(value) == text else { return nil }
        return object
    }

    private static func valid(_ object: [String: JSONValue], tool: String) -> Bool {
        let common: Set<String> = ["approval_version", "binding_name", "deployment_id", "primary_key_column",
                                   "primary_key_value", "project_id", "table_name"]
        guard isOne(object["approval_version"]) else { return false }
        func strings(_ keys: Set<String>) -> Bool { keys.allSatisfy { object[$0]?.stringValue != nil } }
        let shared = common.subtracting(["approval_version"])
        switch tool {
        case updateTool:
            guard Set(object.keys) == common.union(["column", "new_value", "old_value"]),
                  strings(shared.union(["column", "new_value"])) else { return false }
            return object["old_value"] == .null || object["old_value"]?.stringValue != nil
        case insertTool, deleteTool:
            guard Set(object.keys) == common.union(["operation", "values"]), strings(shared),
                  object["operation"]?.stringValue == (tool == insertTool ? "insert" : "delete"),
                  let values = object["values"]?.objectValue,
                  let column = object["primary_key_column"]?.stringValue,
                  let key = object["primary_key_value"]?.stringValue else { return false }
            if tool == insertTool {
                return values.values.allSatisfy { $0.stringValue != nil } && values[column]?.stringValue == key
            }
            guard values.values.allSatisfy({ $0.stringValue != nil || $0.boolValue != nil || safeInteger($0) != nil }),
                  let bound = values[column] else { return false }
            return text(of: bound) == key
        default:
            return false
        }
    }

    private static func isOne(_ value: JSONValue?) -> Bool {
        value.flatMap(safeInteger) == 1
    }

    private static func safeInteger(_ value: JSONValue) -> Int64? {
        let limit: Int64 = (1 << 53) - 1
        switch value {
        // Compared as a range: the magnitude of the smallest Int64 does not fit in one.
        case let .integer(number) where (-limit...limit).contains(number): return number
        case let .number(number) where number.rounded() == number && (-Double(limit)...Double(limit)).contains(number):
            return Int64(number)
        default: return nil
        }
    }

    /// A row key's value as the provider writes it in text: a string as it is, a number or a flag spelled out.
    private static func text(of value: JSONValue) -> String? {
        if let text = value.stringValue { return text }
        if let flag = value.boolValue { return flag ? "true" : "false" }
        return safeInteger(value).map(String.init)
    }

    /// The provider's canonical serialization: keys ordered by code point, no spaces, and every
    /// character from U+007F up written as a lowercase `\u` escape of its UTF-16 units. Values a
    /// valid summary cannot hold, such as fractions, have none.
    static func canonical(_ value: JSONValue) -> String? {
        switch value {
        case .null: return "null"
        case let .bool(flag): return flag ? "true" : "false"
        case let .string(text): return quoted(text)
        case .integer, .number: return safeInteger(value).map(String.init)
        case let .array(items):
            var parts: [String] = []
            for item in items {
                guard let part = canonical(item) else { return nil }
                parts.append(part)
            }
            return "[" + parts.joined(separator: ",") + "]"
        case let .object(object):
            var parts: [String] = []
            let keys = object.keys.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) { $0.value < $1.value } }
            for key in keys {
                guard let part = canonical(object[key]!) else { return nil }
                parts.append(quoted(key) + ":" + part)
            }
            return "{" + parts.joined(separator: ",") + "}"
        }
    }

    private static func quoted(_ text: String) -> String {
        var result = "\""
        for unit in text.utf16 {
            switch unit {
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0x08: result += "\\b"
            case 0x0C: result += "\\f"
            case 0x0A: result += "\\n"
            case 0x0D: result += "\\r"
            case 0x09: result += "\\t"
            case 0..<0x20, 0x7F...:
                let hex = String(unit, radix: 16)
                result += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default:
                result.unicodeScalars.append(Unicode.Scalar(unit)!)
            }
        }
        return result + "\""
    }
}
