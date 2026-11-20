import Foundation

/// A Claude Code bash-mode (`!`) exchange as Claude itself keeps it. The Claude app's Code tab
/// sends one user message after a command runs:
/// `<bash-input>command</bash-input><bash-stdout>output</bash-stdout><bash-stderr>error</bash-stderr>`,
/// and Claude answers it as any other message. The CLI's own `!` writes the same tags as two
/// user records, the command and then its output. Either way the transcript reads it back as one
/// command with its output, never as a chat bubble of tags.
struct ClaudeBashMessage: Equatable, Sendable {
    let command: String
    /// stdout, then stderr on its own line, as the conversation shows it.
    let output: String
    /// False for a command whose output has not been written (yet): the CLI's first record, or a
    /// command still running.
    let hasOutput: Bool

    /// The Claude app keeps the end of longer output (`capOutput`, 102400 characters).
    static let outputCharacterLimit = 102_400
    static let truncationMarker = "[output truncated]\n"

    /// The message the Claude app sends once a command has run: stdout and stderr escaped so
    /// output cannot close a tag, and an `@` that starts a word made full-width so Claude Code
    /// does not read output such as `@scope/package` as a file to attach.
    static func text(command: String, stdout: String, stderr: String = "") -> String {
        "<bash-input>\(neutralizingMentions(command))</bash-input>"
            + "<bash-stdout>\(escaped(neutralizingMentions(stdout)))</bash-stdout>"
            + "<bash-stderr>\(escaped(neutralizingMentions(stderr)))</bash-stderr>"
    }

    /// A command that has not produced its message yet, as the CLI's first record has it.
    static func inputText(command: String) -> String {
        "<bash-input>\(neutralizingMentions(command))</bash-input>"
    }

    /// The end of output longer than the limit, marked as the Claude app marks it.
    static func capped(_ output: String) -> String {
        guard output.count > outputCharacterLimit else { return output }
        return truncationMarker + String(output.suffix(outputCharacterLimit))
    }

    /// A message made only of bash tags, as the Claude app's renderer reads one: nothing but
    /// `bash-input`, `bash-stdout` and `bash-stderr`, the command present. Output is unescaped
    /// when the command and its stdout came in one message, which is the form that escapes it.
    static func parse(_ text: String) -> ClaudeBashMessage? {
        guard text.contains("<bash-input>"), let parts = tags(in: text), let input = parts["bash-input"] else { return nil }
        let unescapes = parts["bash-stdout"] != nil
        let decode: (String) -> String = { unescapes ? ClaudeLocalCommand.unescapedOutput($0) : $0 }
        let stdout = parts["bash-stdout"].map { decode(strippingEscapeSequences($0)).trimmingCharacters(in: .whitespacesAndNewlines) }
        let stderr = parts["bash-stderr"].map { decode(strippingEscapeSequences($0)).trimmingCharacters(in: .whitespacesAndNewlines) }
        let output = [stdout, stderr].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        return ClaudeBashMessage(
            command: decode(input.trimmingCharacters(in: .whitespacesAndNewlines)),
            output: output,
            hasOutput: stdout != nil || stderr != nil
        )
    }

    /// The CLI saves a `!` command and its output as two user records. Read back, the output
    /// joins its command. Returns the one message for both, or nil when they are not that pair.
    static func joining(input: String, output: String) -> String? {
        guard let command = parse(input), !command.hasOutput,
              !output.contains("<bash-input>"), let parts = tags(in: output),
              parts["bash-stdout"] != nil || parts["bash-stderr"] != nil else { return nil }
        // The CLI writes its output unescaped; written back in the one-message form it is
        // escaped, so reading it unescapes to what the command printed.
        return "<bash-input>\(escaped(command.command))</bash-input>"
            + "<bash-stdout>\(escaped(parts["bash-stdout"] ?? ""))</bash-stdout>"
            + "<bash-stderr>\(escaped(parts["bash-stderr"] ?? ""))</bash-stderr>"
    }

    /// The CLI's second record: a command's output on its own.
    static func isOutputOnly(_ text: String) -> Bool {
        guard !text.contains("<bash-input>"), text.contains("<bash-std"), let parts = tags(in: text) else { return false }
        return parts["bash-stdout"] != nil || parts["bash-stderr"] != nil
    }

    /// How the request reads where only a line fits, such as a title: `! command`.
    static func summary(of text: String) -> String? {
        parse(text).map { "! \($0.command)" }
    }

    /// The command and its output, for search and for context handed to another chat.
    static func readableText(of text: String) -> String? {
        parse(text).map { message in
            (["! \(message.command)"] + (message.output.isEmpty ? [] : [message.output])).joined(separator: "\n")
        }
    }

    // MARK: - Tags

    private static let tagPattern = try! NSRegularExpression(
        pattern: #"<(bash-input|bash-stdout|bash-stderr)>([\s\S]*?)</\1>"#
    )
    private static let foreignTagPattern = try! NSRegularExpression(
        pattern: #"<(command-name|command-message|command-args|local-command-stdout|local-command-stderr)>"#
    )

    /// The first of each bash tag, or nil when anything but those tags is in the text.
    private static func tags(in text: String) -> [String: String]? {
        let source = text as NSString
        let whole = NSRange(location: 0, length: source.length)
        guard foreignTagPattern.firstMatch(in: text, range: whole) == nil else { return nil }
        var parts: [String: String] = [:]
        var rest = ""
        var cursor = 0
        for match in tagPattern.matches(in: text, range: whole) {
            let name = source.substring(with: match.range(at: 1))
            guard parts[name] == nil else { continue }
            parts[name] = source.substring(with: match.range(at: 2))
            rest += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
        }
        rest += source.substring(from: cursor)
        guard !parts.isEmpty, rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return parts
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static let escapeSequencePattern = try! NSRegularExpression(
        pattern: #"\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[@-Z\\-_])"#
    )

    /// Saved CLI output can still carry terminal colour codes; the conversation shows plain text.
    private static func strippingEscapeSequences(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        return escapeSequencePattern.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: ""
        )
    }

    /// The Claude app replaces an `@` with a full-width one where Claude Code would take it for a
    /// file mention: at the start or after a space or CJK sentence mark, with a character after it.
    static func neutralizingMentions(_ text: String) -> String {
        guard text.contains("@") else { return text }
        let scalars = Array(text.unicodeScalars)
        var result = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            guard scalar == "@" else { result.append(scalar); continue }
            var next = index + 1
            while next < scalars.count, ["\u{FEFF}", "\u{0B}", "\u{0C}"].contains(scalars[next]) { next += 1 }
            guard next < scalars.count, !scalars[next].properties.isWhitespace else { result.append(scalar); continue }
            var previous = index - 1
            while previous >= 0, scalars[previous].properties.generalCategory == .format { previous -= 1 }
            let startsWord = previous < 0 || scalars[previous].properties.isWhitespace
                || ["\u{85}", "\u{3002}", "\u{3001}", "\u{FF1F}", "\u{FF01}"].contains(scalars[previous])
            result.append(startsWord ? "\u{FF20}" : scalar)
        }
        return String(result)
    }
}
