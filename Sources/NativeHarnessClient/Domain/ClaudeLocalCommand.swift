import Foundation

/// Claude Code's local slash commands. The transcript keeps the command name and arguments in a
/// tagged user record. Output can be a second user record or a system record with a command outcome.
enum ClaudeLocalCommand: Equatable {
    /// The command as it was typed: its name, then its arguments.
    case request(String)
    /// What it printed, without terminal colour codes; empty when it printed nothing.
    case output(String)

    /// `/compact`, whose compaction Claude Code saves before the command that ran it.
    static let compactName = "/compact"

    /// Claude saves a rejected local command as a system record and streams its output as a
    /// synthetic assistant message. Both carry the command and its outcome outside the text.
    static func isFailedCompaction(run: JSONValue?, outcome: JSONValue?) -> Bool {
        run?["command"]?.stringValue == "compact" && outcome?["kind"]?.stringValue == "failed"
    }

    static func isSavedCompactionFailure(_ record: JSONValue) -> Bool {
        record["subtype"]?.stringValue == "local_command" && record["type"]?.stringValue == "system"
            && record["isMeta"]?.boolValue != true
            && isFailedCompaction(run: record["commandRun"], outcome: record["commandOutcome"])
    }

    static func savedCompactionFailure(in record: JSONValue) -> HarnessContextCompaction? {
        guard isSavedCompactionFailure(record) else { return nil }
        let text = record["content"]?.stringValue ?? ""
        let reason = if case let .output(output) = parse(text) { unescapedOutput(output) } else { text }
        return failedCompaction(reason: reason, id: record["uuid"]?.stringValue)
    }

    static func unescapedOutput(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func failedCompaction(reason: String, id: String?) -> HarnessContextCompaction {
        let prefix = "Error during compaction:"
        let trimmed = strippingEscapeSequences(reason).trimmingCharacters(in: .whitespacesAndNewlines)
        let message = trimmed.hasPrefix(prefix)
            ? String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
        return HarnessContextCompaction(phase: .failed, message: message.isEmpty ? nil : message, providerID: id)
    }

    static func parse(_ text: String) -> Self? {
        guard text.contains("<command-name>") || text.contains("<local-command-std") else { return nil }
        let source = text as NSString
        var parts: [String: [String]] = [:]
        var rest = ""
        var cursor = 0
        for match in tagPattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            parts[source.substring(with: match.range(at: 1)), default: []].append(source.substring(with: match.range(at: 2)))
            rest += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
        }
        rest += source.substring(from: cursor)
        guard rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let name = parts["command-name"]?.first?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            guard parts["local-command-stdout"] == nil, parts["local-command-stderr"] == nil else { return nil }
            let command = name.hasPrefix("/") ? name : "/" + name
            let arguments = (parts["command-args"]?.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return .request(arguments.isEmpty ? command : "\(command) \(arguments)")
        }
        let printed = (parts["local-command-stdout"] ?? []) + (parts["local-command-stderr"] ?? [])
        guard !printed.isEmpty, parts["command-message"] == nil, parts["command-args"] == nil else { return nil }
        let output = printed.map { strippingEscapeSequences($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        return .output(output)
    }

    private static let tagPattern = try! NSRegularExpression(
        pattern: #"<(command-name|command-message|command-args|local-command-stdout|local-command-stderr)>([\s\S]*?)</\1>"#
    )

    private static let escapeSequencePattern = try! NSRegularExpression(
        pattern: #"\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[@-Z\\-_])"#
    )

    private static func strippingEscapeSequences(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        return escapeSequencePattern.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
    }
}
