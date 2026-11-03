import Foundation

/// Words the app shows that another Mac's Yardlet can show in its own language: the catalog key they were
/// made from, with the arguments filled into it, each again a key or words as they are (a file name). The
/// words in this Mac's language are `resolved`; a remote client resolves the same text in its own
/// (docs/REMOTE_PROTOCOL.md §15.19).
struct LocalizedText: Codable, Equatable, Sendable {
    let key: String
    var args: [LocalizedText] = []
    /// Words as they are, not a key: an argument such as a path or a host name.
    var isVerbatim = false

    init(_ key: String, _ args: LocalizedText...) {
        self.key = key
        self.args = args
    }

    static func verbatim(_ text: String) -> LocalizedText {
        var text = LocalizedText(text)
        text.isVerbatim = true
        return text
    }

    /// The words in this Mac's language.
    var resolved: String {
        resolved { L10n.string($0) } ?? key
    }

    /// The words in the language `lookup` reads, or nil when a key is not in its catalog or a key's format
    /// does not take exactly its arguments as words (`%@`, `%1$@`): a caller then shows the words it was sent.
    func resolved(_ lookup: (String) -> String?) -> String? {
        if isVerbatim { return key }
        guard let format = lookup(key) else { return nil }
        let values = args.map { $0.resolved(lookup) }
        guard !values.contains(where: { $0 == nil }) else { return nil }
        guard Self.placeholderCount(format) == values.count else { return nil }
        if values.isEmpty { return format.replacingOccurrences(of: "%%", with: "%") }
        return String(format: format, arguments: values.compactMap { $0 as NSString? })
    }

    /// The `%@` and `%n$@` a format takes, or -1 when it takes anything else.
    static func placeholderCount(_ format: String) -> Int {
        var count = 0
        var index = format.startIndex
        while let percent = format[index...].firstIndex(of: "%") {
            let next = format.index(after: percent)
            guard next < format.endIndex else { return -1 }
            if format[next] == "%" {
                index = format.index(after: next)
                continue
            }
            var cursor = next
            while cursor < format.endIndex, format[cursor].isNumber { cursor = format.index(after: cursor) }
            if cursor < format.endIndex, format[cursor] == "$" { cursor = format.index(after: cursor) }
            guard cursor < format.endIndex, format[cursor] == "@" else { return -1 }
            count += 1
            index = format.index(after: cursor)
        }
        return count
    }
}

extension L10n {
    /// A key's words in this Mac's language, or nil when the catalog does not have the key.
    static func lookup(_ key: String) -> String? {
        let missing = "\u{1}"
        let value = string(key, fallback: missing)
        return value == missing ? nil : value
    }
}
