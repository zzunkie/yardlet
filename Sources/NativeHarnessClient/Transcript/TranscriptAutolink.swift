import Foundation

/// GitHub-flavored Markdown's extended autolinks (GFM spec 6.9): a bare `https://…`, `http://…`,
/// `ftp://…` or `www.…` address and a bare email address read as links, as the Codex app's renderer
/// reads them (`gfmAutolinkLiteral`). swift-markdown attaches only GFM's table, strikethrough and task
/// list extensions to cmark, so its text keeps them as plain text; this marks them afterwards, on the
/// rendered text, so an address cmark split into several text nodes (at `_` or `*`) is still one link.
/// Text already in a link or in code stays as it is.
///
/// GFM runs an address on to the next space, which Korean, Japanese and Chinese text do not put after
/// it: GitHub and the Codex app link `(https://…/pull/403)을` through `)을`. Here an address ends where
/// the address ends, and otherwise follows GFM:
/// - a `)` that closes a `(` written before the address belongs to the sentence (GFM drops such a `)`
///   only at the very end), so `(https://…/pull/403)을` and `(see https://…_(language))를` link the
///   address alone, while `www.google.com/search?q=(business))+ok`, with no `(` before it, stays whole;
/// - after the domain an address goes on only with a port, path, query or fragment, so in
///   `https://example.com(설명)` the parenthesis is the sentence's;
/// - CJK punctuation such as `（`, `）`, `：` and `。` separates words as a space does.
/// Korean, Japanese and Chinese letters in a path stay in it (`https://example.com/법령/도로교통법/제96조`).
enum TranscriptAutolink {
    static func apply(to text: AttributedString) -> AttributedString {
        let characters = Array(text.characters)
        guard characters.count >= 4, mayHoldAddress(characters) else { return text }
        let indices = Array(text.characters.indices) + [text.endIndex]
        var result = text
        var position = 0
        // `(` outside addresses so far that no `)` has closed.
        var openParentheses = 0
        while position < characters.count {
            guard let found = address(in: characters, at: position, insideParentheses: openParentheses > 0) else {
                if characters[position] == "(" {
                    openParentheses += 1
                } else if characters[position] == ")", openParentheses > 0 {
                    openParentheses -= 1
                }
                position += 1
                continue
            }
            let range = indices[found.range.lowerBound]..<indices[found.range.upperBound]
            if text[range].runs.allSatisfy({ $0.link == nil && !($0.inlinePresentationIntent?.contains(.code) ?? false) }),
               let url = URL(string: found.destination) {
                result[range].link = url
            }
            position = found.range.upperBound
        }
        return result
    }

    private struct Found {
        var range: Range<Int>
        var destination: String
    }

    private static func mayHoldAddress(_ characters: [Character]) -> Bool {
        let text = String(characters)
        return text.contains("://") || text.contains("www.") || text.contains("@")
    }

    private static func address(in characters: [Character], at start: Int, insideParentheses: Bool) -> Found? {
        if let found = urlAddress(in: characters, at: start, insideParentheses: insideParentheses) { return found }
        return emailAddress(in: characters, at: start)
    }

    /// GFM: an autolink starts at the beginning of a line, after whitespace, or after `*`, `_`, `~` or `(`;
    /// and here after CJK punctuation, as GitHub and the Codex app also link `（https://…`.
    private static func startsAfterBoundary(_ characters: [Character], _ start: Int) -> Bool {
        guard start > 0 else { return true }
        let previous = characters[start - 1]
        return previous.isWhitespace || "*_~(".contains(previous) || isCJKPunctuation(previous)
    }

    private static func urlAddress(in characters: [Character], at start: Int, insideParentheses: Bool) -> Found? {
        guard startsAfterBoundary(characters, start) else { return nil }
        let rest = characters[start...]
        let prefix: String
        let isWWW: Bool
        if let scheme = ["https://", "http://", "ftp://"].first(where: { hasPrefix(rest, $0) }) {
            prefix = scheme
            isWWW = false
        } else if hasPrefix(rest, "www.") {
            prefix = "www."
            isWWW = true
        } else {
            return nil
        }
        let domainStart = start + prefix.count
        var domainEnd = domainStart
        while domainEnd < characters.count, isDomainCharacter(characters[domainEnd]) { domainEnd += 1 }
        let domain = String(characters[domainStart..<domainEnd])
        guard validDomain(domain, needsPeriod: isWWW) else { return nil }
        let end = trimmedEnd(characters, start: start,
                              end: pathEnd(characters, domainEnd: domainEnd, insideParentheses: insideParentheses))
        guard end > domainStart else { return nil }
        let matched = String(characters[start..<end])
        let destination = isWWW ? "http://" + matched : matched
        return Found(range: start..<end, destination: encoded(destination))
    }

    private static func emailAddress(in characters: [Character], at start: Int) -> Found? {
        // The local part is the whole run of allowed characters before `@`, so start only at its first.
        guard isEmailLocalCharacter(characters[start]),
              start == 0 || !isEmailLocalCharacter(characters[start - 1]) else { return nil }
        var at = start
        while at < characters.count, isEmailLocalCharacter(characters[at]) { at += 1 }
        guard at < characters.count, characters[at] == "@", at > start else { return nil }
        var end = at + 1
        while end < characters.count, characters[end].isASCII,
              characters[end].isLetter || characters[end].isNumber || "-_.".contains(characters[end]) { end += 1 }
        while end > at + 1, characters[end - 1] == "." { end -= 1 }
        let domain = String(characters[(at + 1)..<end])
        guard domain.contains("."), let last = domain.last, last != "-", last != "_",
              !domain.split(separator: ".", omittingEmptySubsequences: false).contains(where: \.isEmpty) else { return nil }
        let matched = String(characters[start..<end])
        return Found(range: start..<end, destination: encoded("mailto:" + matched))
    }

    private static func hasPrefix(_ characters: ArraySlice<Character>, _ prefix: String) -> Bool {
        guard characters.count >= prefix.count else { return false }
        return zip(characters, prefix).allSatisfy { $0.lowercased() == String($1) }
    }

    private static func isDomainCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
    }

    private static func isEmailLocalCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || ".-_+".contains(character))
    }

    /// Segments of letters, digits, `_` and `-` between periods, no `_` in the last two; a `www.` address
    /// needs a period after `www.` (cmark-gfm lets an `http://` address be a single name, `localhost`).
    private static func validDomain(_ domain: String, needsPeriod: Bool) -> Bool {
        let trimmed = domain.hasSuffix(".") ? String(domain.dropLast()) : domain
        let segments = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard !trimmed.isEmpty, !segments.contains(where: \.isEmpty) else { return false }
        if needsPeriod, segments.count < 2 { return false }
        return !segments.suffix(2).contains { $0.contains("_") }
    }

    /// Where the port, path, query and fragment after the domain stop, before GFM's trailing rules: at
    /// whitespace, `<` or CJK punctuation, or at a `)` that closes a `(` before the address.
    private static func pathEnd(_ characters: [Character], domainEnd: Int, insideParentheses: Bool) -> Int {
        guard domainEnd < characters.count, ":/?#".contains(characters[domainEnd]) else { return domainEnd }
        var end = domainEnd
        var depth = 0
        while end < characters.count {
            let character = characters[end]
            if character.isWhitespace || character == "<" || isCJKPunctuation(character) { break }
            if character == "(" {
                depth += 1
            } else if character == ")" {
                if depth > 0 {
                    depth -= 1
                } else if insideParentheses {
                    break
                }
            }
            end += 1
        }
        return end
    }

    /// Punctuation in CJK Symbols and Punctuation and in the full-width and half-width forms (`（`, `）`,
    /// `：`, `、`, `。`, `「`), which Korean, Japanese and Chinese text puts where English puts ASCII
    /// punctuation and spaces.
    private static func isCJKPunctuation(_ character: Character) -> Bool {
        guard !character.isLetter, !character.isNumber, let scalar = character.unicodeScalars.first else { return false }
        return (0x3000...0x303F).contains(scalar.value) || (0xFF00...0xFFEF).contains(scalar.value)
    }

    /// GFM's trailing rules: `?`, `!`, `.`, `,`, `:`, `*`, `_`, `~` and quotes are not part of the link,
    /// nor an unmatched closing parenthesis, nor an entity-like `&name;` at the end.
    private static func trimmedEnd(_ characters: [Character], start: Int, end: Int) -> Int {
        var end = end
        while end > start {
            let last = characters[end - 1]
            if "?!.,:*_~'\"".contains(last) {
                end -= 1
            } else if last == ")" {
                let link = characters[start..<end]
                let opening = link.filter { $0 == "(" }.count
                let closing = link.filter { $0 == ")" }.count
                guard closing > opening else { break }
                end -= 1
            } else if last == ";" {
                var cursor = end - 2
                while cursor > start, characters[cursor].isASCII, characters[cursor].isLetter || characters[cursor].isNumber {
                    cursor -= 1
                }
                end = cursor >= start && characters[cursor] == "&" && cursor < end - 2 ? cursor : end - 1
            } else {
                break
            }
        }
        return end
    }

    /// Foundation's URL takes non-ASCII and spaces only escaped; escape what is missing, keeping `%xx`.
    private static func encoded(_ destination: String) -> String {
        let escaped = destination.replacingOccurrences(of: "%(?![0-9A-Fa-f]{2})", with: "%25", options: .regularExpression)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")
        return escaped.addingPercentEncoding(withAllowedCharacters: allowed) ?? destination
    }
}
