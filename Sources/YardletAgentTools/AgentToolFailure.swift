import Foundation

/// What a call that did not do what it asked tells the agent beside its words: what went wrong and what
/// calling again can do, so that a refused call is not made again unchanged and a call that may have taken
/// effect is checked before it is repeated. A result carries it as `structuredContent`, under `error`, with
/// the message: Claude Code (2.1.291) and Codex show the model a result's `structuredContent` in place of its
/// text when it has one.
package struct AgentToolFailure: Equatable, Sendable {
    package enum Kind: String, Codable, Sendable {
        /// The arguments do not fit the tool's input schema.
        case invalidArguments = "invalid_arguments"
        /// The task has no tool of that name.
        case unknownTool = "unknown_tool"
        /// What the call names is not there: a task, a cursor.
        case notFound = "not_found"
        /// It names an archived task.
        case archived
        /// The person, a setting or one of Yardlet's boundaries refused it.
        case refused
        /// It ran out of time and changed nothing.
        case timedOut = "timed_out"
        /// It went out, and Yardlet or the service stopped answering: it may or may not have taken effect.
        case outcomeUnknown = "outcome_unknown"
        /// Yardlet or the service could not be reached, so the call did not go out.
        case unreachable
    }

    /// What calling again can do.
    package enum Retry: String, Codable, Sendable {
        /// Nothing: the same call is refused again until the person or a setting changes something.
        case no
        /// Only with other arguments, as the message says.
        case withChanges = "with_changes"
        /// The same call, in a moment.
        case later
        /// Only once it is checked whether the call took effect, since calling again may do it twice.
        case afterChecking = "after_checking"
    }

    package var kind: Kind
    package var retry: Retry
    /// What the kind needs said, such as the arguments a call lacks or the full id of a task.
    package var details: [String: ToolJSON]

    package init(_ kind: Kind, retry: Retry, details: [String: ToolJSON] = [:]) {
        self.kind = kind
        self.retry = retry
        self.details = details
    }
}

extension AgentToolResult {
    /// A failed call: the message as its text, and the failure with the message as its structured content.
    package static func failure(_ message: String, _ failure: AgentToolFailure) -> AgentToolResult {
        var error = failure.details
        error["kind"] = .string(failure.kind.rawValue)
        error["retry"] = .string(failure.retry.rawValue)
        error["message"] = .string(message)
        return AgentToolResult(content: [.text(message)], isError: true, structuredContent: .object(["error": .object(error)]))
    }

    package static func failure(_ message: String, _ kind: AgentToolFailure.Kind, retry: AgentToolFailure.Retry,
                                details: [String: ToolJSON] = [:]) -> AgentToolResult {
        failure(message, AgentToolFailure(kind, retry: retry, details: details))
    }

    /// The failure this result carries (`failure(_:_:)`); nil for any other result.
    package var failure: AgentToolFailure? {
        guard isError, let error = structuredContent?["error"]?.objectValue,
              let kind = error["kind"]?.stringValue.flatMap(AgentToolFailure.Kind.init(rawValue:)),
              let retry = error["retry"]?.stringValue.flatMap(AgentToolFailure.Retry.init(rawValue:))
        else { return nil }
        return AgentToolFailure(kind, retry: retry,
                                details: error.filter { !["kind", "retry", "message"].contains($0.key) })
    }
}

/// Checks a call's arguments against the input schema of a tool whose schema is Yardlet's own, before it runs:
/// every property the schema requires must be there. As the MCP SDKs' own checks do, a property the schema does
/// not name does not stop a call that has what the tool needs. When something is missing, the failure also names
/// what the call gave that the tool does not take, most often the missing one misspelt (`task_id` for `task_ids`,
/// `script` for `function`), and every argument the tool takes. Values are left to the tool, which reads some more
/// leniently than JSON Schema would (an integer written as a string, one string for a list). A connector's own
/// server checks the calls to its tools itself.
package enum AgentToolArgumentCheck {
    package static func failure(tool: String, arguments: ToolJSON, schema: ToolJSON) -> AgentToolResult? {
        guard let given = arguments.objectValue else { return nil }
        let properties = schema["properties"]?.objectValue ?? [:]
        let required = (schema["required"]?.arrayValue ?? []).compactMap(\.stringValue)
        let missing = required.filter { given[$0] == nil || given[$0] == .null }
        guard !missing.isEmpty else { return nil }
        let unexpected = given.keys.filter { properties[$0] == nil }.sorted()
        let optional = properties.keys.filter { !required.contains($0) }.sorted()
        var message = "\(tool) was not run: it needs \(AgentToolNames.phrase(missing, "and"))."
        if !unexpected.isEmpty { message += " It takes no \(AgentToolNames.phrase(unexpected, "or"))." }
        message += " Its arguments: " + (required.map { "\($0) (required)" } + optional).joined(separator: ", ") + "."
        return .failure(message, .invalidArguments, retry: .withChanges, details: [
            "tool": .string(tool),
            "missing": .array(missing.map(ToolJSON.string)),
            "unexpected": .array(unexpected.map(ToolJSON.string)),
            "required": .array(required.map(ToolJSON.string)),
            "optional": .array(optional.map(ToolJSON.string))
        ])
    }
}

/// Words for tool names in a message.
package enum AgentToolNames {
    /// At most this many names of a family go into a message.
    package static let listedFamilyLimit = 40

    /// The names that share the first word of `name` with it, its underscore included (`browser_` for
    /// `browser_find`, `slack_` for a Slack tool): the tools an unknown name was most likely meant as.
    package static func family(of name: String, in names: [String]) -> [String] {
        guard let end = name.firstIndex(of: "_"), end != name.startIndex else { return [] }
        let prefix = name[...end]
        return names.filter { $0.hasPrefix(prefix) && $0 != name }
    }

    /// The names, at most `listedFamilyLimit`, then how many more there are.
    package static func listed(_ names: [String]) -> String {
        let shown = names.prefix(listedFamilyLimit).joined(separator: ", ")
        return names.count > listedFamilyLimit ? shown + " and \(names.count - listedFamilyLimit) more" : shown
    }

    /// "a", "a and b", "a, b and c".
    static func phrase(_ words: [String], _ conjunction: String) -> String {
        guard words.count > 1 else { return words.first ?? "" }
        return words.dropLast().joined(separator: ", ") + " \(conjunction) " + words[words.count - 1]
    }
}
