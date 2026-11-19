import Foundation

/// Small, bounded lexical styling. Unknown languages remain plain text; source is never rewritten.
enum TranscriptCodeSyntax {
    enum Kind: Int, CaseIterable, Sendable { case comment, string, keyword, number }
    struct Token: Equatable, Sendable {
        let range: NSRange
        let kind: Kind
    }

    static func tokens(in text: String, language: String?) -> [Token] {
        guard let language = language?.lowercased(), let lexer = lexers[language] else { return [] }
        return lexer.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            for kind in Kind.allCases {
                let range = match.range(at: kind.rawValue + 1)
                if range.location != NSNotFound { return Token(range: range, kind: kind) }
            }
            return nil
        }
    }

    private static let lexers: [String: NSRegularExpression] = {
        let quoted = #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#
        let numbers = #"\b(?:0[xX][0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#
        let configurations: [([String], String, String, String)] = [
            (["swift"], #"//[^\n]*|/\*[\s\S]*?\*/"#, quoted,
             "actor as async await break case catch class continue default defer deinit do else enum extension fallthrough false fileprivate final for func guard if import in init inout internal is let nil nonisolated open override private protocol public repeat rethrows return self some static struct subscript super switch throws throw true try typealias var weak where while"),
            (["javascript", "js", "jsx", "typescript", "ts", "tsx", "java", "c", "cpp", "c++", "cs", "csharp", "go", "rust"], #"//[^\n]*|/\*[\s\S]*?\*/"#, quoted,
             "as async await break case catch class const continue default delete do else enum export extends false finally for from function if implements import in instanceof interface let match new null package private protected public return static struct super switch this throw true try type typeof undefined var void while yield"),
            (["python", "py"], #"#[^\n]*"#, #""""[\s\S]*?"""|'''[\s\S]*?'''|"# + quoted,
             "and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return True try while with yield"),
            (["bash", "sh", "zsh", "shell", "shellscript"], #"#[^\n]*"#, quoted,
             "if then else elif fi for while do done case esac function in export local return"),
            (["json", "jsonc"], #"//[^\n]*|/\*[\s\S]*?\*/"#, quoted, "true false null")
        ]
        var result: [String: NSRegularExpression] = [:]
        for (languages, comments, strings, keywords) in configurations {
            let words = keywords.split(separator: " ").joined(separator: "|")
            let pattern = "(\(comments))|(\(strings))|(\\b(?:\(words))\\b)|(\(numbers))"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for language in languages { result[language] = regex }
        }
        return result
    }()
}

enum TranscriptCopyPayload {
    /// Resolve at click time from the complete response, never from the truncated render window.
    static func code(in source: String, blockIndex: Int) -> String? {
        code(in: source, blockPath: [blockIndex])
    }

    static func code(in source: String, blockPath: [Int], dialect: TranscriptMarkdownDialect = .standard) -> String? {
        switch TranscriptMarkdownDocument(source, dialect: dialect).block(at: blockPath) {
        case let .code(_, text)?, let .mermaid(text)?: text
        default: nil
        }
    }
}

struct TranscriptCodeWindow: Equatable {
    let text: String
    let isTruncated: Bool

    init(_ source: String, lineLimit: Int = 40, characterLimit: Int = 6_000) {
        var end = source.startIndex
        var lines = 1
        var characters = 0
        while end < source.endIndex, characters < characterLimit {
            if source[end].isNewline {
                guard lines < lineLimit else { break }
                lines += 1
            }
            characters += 1
            end = source.index(after: end)
        }
        text = String(source[..<end])
        isTruncated = end < source.endIndex
    }
}
