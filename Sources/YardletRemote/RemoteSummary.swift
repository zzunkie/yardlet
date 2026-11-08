import Foundation

/// The one line an attention event says about the request a task waits on (§5.2), which a phone may
/// show on its lock screen: the call or the question's first line, no longer than `limit`, with what
/// looks like a secret masked. Never file contents: callers pass the request's title, its
/// description or command, or a question.
public enum RemoteSummary {
    public static let limit = 120
    static let mask = "•••"

    /// The parts joined with ": " (empty parts left out), as one line, masked and capped.
    public static func line(_ parts: [String?], limit: Int = RemoteSummary.limit) -> String? {
        let firstLines = parts.compactMap { part -> String? in
            guard let line = part?.split(whereSeparator: \.isNewline).first else { return nil }
            let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return collapsed.isEmpty ? nil : masked(collapsed)
        }
        var seen = Set<String>()
        let unique = firstLines.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return nil }
        let text = unique.joined(separator: ": ")
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    /// The text with credentials masked: `Bearer …`, `name=value` and `--flag value` for secret-like
    /// names, `user:password@` in URLs, and long runs of letters and digits that look like keys.
    public static func masked(_ text: String) -> String {
        var result = text
        for (expression, template) in rules {
            result = expression.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        return result
    }

    private static let secretName = #"[A-Za-z0-9_.-]*(?:token|secret|passw(?:or)?d|pwd|api[_-]?key|access[_-]?key|private[_-]?key|credential|auth)[A-Za-z0-9_.-]*"#

    /// Compiled once: a phone's schedule list masks every schedule's name and prompt. A match starts only where the
    /// leftmost one could, at the start of a scheme or a name, so long text is not rescanned from inside every word.
    private static let rules: [(NSRegularExpression, String)] = [
        (#"\b(bearer|basic|token)\s+[A-Za-z0-9._~+/=-]{6,}"#, "$1 " + mask),
        (#"(?<![a-z])([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^/\s@]+@"#, "$1" + mask + "@"),
        ("(?<![A-Za-z0-9_.-])(\(secretName))(\\s*[=:]\\s*)(\"[^\"]*\"|'[^']*'|\\S+)", "$1$2" + mask),
        ("(--?\(secretName)[ =])(\"[^\"]*\"|'[^']*'|\\S+)", "$1" + mask),
        (#"(?<![A-Za-z0-9_+=-])(?=[A-Za-z0-9_+=-]*[0-9])(?=[A-Za-z0-9_+=-]*[A-Za-z])[A-Za-z0-9_+=-]{32,}"#, mask)
    ].map { pattern, template in (try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]), template) }
}
