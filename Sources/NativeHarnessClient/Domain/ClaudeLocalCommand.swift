import Foundation

/// A local slash command Claude Code saved in a conversation's transcript, which it writes as two `user`
/// records of its own (2.1.322): the command the person ran,
/// `<command-name>/compact</command-name> <command-message>compact</command-message> <command-args></command-args>`,
/// and what it printed, `<local-command-stdout>Compacted </local-command-stdout>` (or `-stderr`). Live,
/// Yardlet shows the command as the request it sent and the output as the stream's
/// `local_command_output` card; read back, they read the same way rather than as their tags.
enum ClaudeLocalCommand: Equatable {
    /// The command as it was typed: its name, then its arguments.
    case request(String)
    /// What it printed, without terminal colour codes; empty when it printed nothing.
    case output(String)

    /// `/compact`, whose compaction Claude Code saves before the command that ran it.
    static let compactName = "/compact"

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
