import Foundation
import XCTest

/// Keeps `AppModel` from gathering more state (docs/ARCHITECTURE.md, "Checks that only tighten").
/// `AppModel` holds what the whole app shares. A stored property added there is state a feature keeps
/// app-wide instead of with an owner of its own, and a dictionary keyed by an ID (nearly always a
/// task's) is per-task state that every path ending a task has to clear. Both counts may only fall: a
/// change that removes some lowers its limit here, and a change that must add some raises it and says
/// why in its pull request.
final class AppModelStateLintTests: XCTestCase {
    /// Stored instance properties of `AppModel`.
    private static let storedPropertyLimit = 232
    /// Of those, dictionaries keyed by a `UUID`.
    private static let idKeyedDictionaryLimit = 61

    func testAppModelTakesOnNoNewState() throws {
        let properties = try Self.storedProperties(in: Self.appModelSource())
        let keyed = properties.filter(\.isIDKeyedDictionary)
        XCTAssertLessThanOrEqual(
            keyed.count, Self.idKeyedDictionaryLimit,
            "AppModel has \(keyed.count) dictionaries keyed by an ID, more than its \(Self.idKeyedDictionaryLimit). "
                + "Keep a task's new state with an owner of its own, as TaskComposerDraftStore and TaskWorkspaceStore "
                + "do, or on a value an existing per-task dictionary already holds.")
        XCTAssertLessThanOrEqual(
            properties.count, Self.storedPropertyLimit,
            "AppModel has \(properties.count) stored properties, more than its \(Self.storedPropertyLimit). "
                + "Give the feature's state a type of its own and keep one reference to it here at most.")
    }

    func testTheLimitsFollowWhatWasRemoved() throws {
        let properties = try Self.storedProperties(in: Self.appModelSource())
        let keyed = properties.filter(\.isIDKeyedDictionary).count
        XCTAssertGreaterThanOrEqual(
            keyed, Self.idKeyedDictionaryLimit,
            "AppModel has fewer dictionaries keyed by an ID now; lower idKeyedDictionaryLimit to \(keyed)")
        XCTAssertGreaterThanOrEqual(
            properties.count, Self.storedPropertyLimit,
            "AppModel has fewer stored properties now; lower storedPropertyLimit to \(properties.count)")
    }

    func testTheScannerReadsEachForm() throws {
        let sample = #"""
        @MainActor
        @Observable
        final class AppModel {
            var sessions: [UUID: Session] = [:]
            @ObservationIgnored private var runs: [ UUID : Task<Void, Never> ] = [:]
            private(set) var names: [String: String] = [:]
            let store: SessionStore
            @ObservationIgnored
            nonisolated(unsafe) var flag = false
            lazy var cache = Cache()
            var inferred = [UUID: Int]()
            var observed: Int = 0 { didSet { } }
            var watched: Int {
                didSet { }
            }
            static let shared = 1
            private static var counter = 0
            var computed: Int { sessions.count }
            var title: String {
                "{ not a brace \(names.count) }"
            }
            func work() { var local = 0; local += 1 }
            struct Nested { var inner = 0 }
            // var commented = 0
            /* var blocked = 0 */
            let note = """
                var quoted = 0 {
                """
        }
        var outside = 0
        """#
        let properties = try Self.storedProperties(in: sample)
        XCTAssertEqual(properties.map(\.name),
                       ["sessions", "runs", "names", "store", "flag", "cache", "inferred", "observed", "watched", "note"])
        XCTAssertEqual(properties.filter(\.isIDKeyedDictionary).map(\.name), ["sessions", "runs", "inferred"])
    }

    private struct StoredProperty {
        let name: String
        let type: String
        /// What follows `=` when the declaration gives no type.
        let initializer: String

        var isIDKeyedDictionary: Bool {
            (type.isEmpty ? initializer : type).range(of: #"^\[\s*UUID\s*:"#, options: .regularExpression) != nil
        }
    }

    /// A property declaration at the start of a line: its attributes and modifiers (`static` and
    /// `class` are left out, so type properties never match), `var` or `let`, the name, the type and
    /// what follows it.
    private static let declaration = try? NSRegularExpression(pattern:
        #"^(?:@\w+(?:\([^)]*\))?\s+)*"#
            + #"(?:(?:private|fileprivate|internal|public|package)(?:\(set\))?\s+"#
            + #"|nonisolated(?:\(unsafe\))?\s+|lazy\s+|weak\s+|unowned\s+|override\s+)*"#
            + #"(var|let)\s+(\w+)\s*(?::\s*([^={]+?))?\s*(=.*|\{.*)?$"#)

    /// The stored instance properties declared directly in `AppModel`'s body. Swift keeps stored
    /// properties out of extensions, so the class's own declaration holds all of them.
    private static func storedProperties(in source: String) throws -> [StoredProperty] {
        let declaration = try XCTUnwrap(declaration)
        let lines = code(of: source).components(separatedBy: "\n")
        var properties: [StoredProperty] = []
        var depth = 0
        var body: Int?
        var entered = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if body == nil, trimmed.range(of: #"\bclass\s+AppModel\b"#, options: .regularExpression) != nil {
                body = depth + 1
            } else if let body, depth == body,
                      let match = declaration.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) {
                func group(_ number: Int) -> String {
                    Range(match.range(at: number), in: trimmed).map { String(trimmed[$0]) } ?? ""
                }
                let tail = group(4)
                let following = ([String(tail.dropFirst())] + lines.dropFirst(index + 1).prefix(2)).joined(separator: "\n")
                let isComputed = group(1) == "var" && tail.hasPrefix("{") && !startsWithObserver(following)
                if !isComputed {
                    let initializer = tail.hasPrefix("=") ? tail.dropFirst().trimmingCharacters(in: .whitespaces) : ""
                    properties.append(StoredProperty(name: group(2), type: group(3), initializer: initializer))
                }
            }
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            guard let body else { continue }
            if depth >= body { entered = true } else if entered { break }
        }
        return properties
    }

    private static func startsWithObserver(_ text: String) -> Bool {
        text.range(of: #"^\s*(willSet|didSet)\b"#, options: .regularExpression) != nil
    }

    /// `source` with its comments removed and the contents of its string literals left out, so the
    /// braces and declarations that remain are the code's own. Lines keep their places.
    private static func code(of source: String) -> String {
        let scalars = Array(source.unicodeScalars)
        var out = String.UnicodeScalarView()
        var index = 0
        var blockComments = 0
        var lineComment = false
        var string: (multiline: Bool, hashes: Int)?
        var interpolations: [(multiline: Bool, hashes: Int, parentheses: Int)] = []
        func at(_ position: Int) -> Unicode.Scalar? { position < scalars.count ? scalars[position] : nil }
        while index < scalars.count {
            let scalar = scalars[index]
            if lineComment {
                if scalar == "\n" { lineComment = false; out.append(scalar) }
                index += 1
                continue
            }
            if blockComments > 0 {
                if scalar == "/", at(index + 1) == "*" { blockComments += 1; index += 2; continue }
                if scalar == "*", at(index + 1) == "/" { blockComments -= 1; index += 2; continue }
                if scalar == "\n" { out.append(scalar) }
                index += 1
                continue
            }
            if let open = string {
                if scalar == "\n" { out.append(scalar); index += 1; continue }
                if scalar == "\\" {
                    var next = index + 1
                    var hashes = 0
                    while hashes < open.hashes, at(next) == "#" { hashes += 1; next += 1 }
                    if hashes == open.hashes, at(next) == "(" {
                        interpolations.append((open.multiline, open.hashes, 1))
                        string = nil
                        index = next + 1
                        continue
                    }
                    index = hashes == open.hashes ? next + 1 : index + 1
                    continue
                }
                if scalar == "\"" {
                    var next = index
                    var quotes = 0
                    while quotes < (open.multiline ? 3 : 1), at(next) == "\"" { quotes += 1; next += 1 }
                    var hashes = 0
                    while hashes < open.hashes, at(next) == "#" { hashes += 1; next += 1 }
                    if quotes == (open.multiline ? 3 : 1), hashes == open.hashes {
                        string = nil
                        out.append(contentsOf: "\"\"".unicodeScalars)
                        index = next
                        continue
                    }
                }
                index += 1
                continue
            }
            if scalar == "/", at(index + 1) == "/" { lineComment = true; index += 2; continue }
            if scalar == "/", at(index + 1) == "*" { blockComments = 1; index += 2; continue }
            if scalar == "#" || scalar == "\"" {
                var next = index
                var hashes = 0
                while at(next) == "#" { hashes += 1; next += 1 }
                if at(next) == "\"" {
                    let multiline = at(next + 1) == "\"" && at(next + 2) == "\""
                    string = (multiline, hashes)
                    index = next + (multiline ? 3 : 1)
                    continue
                }
            }
            if !interpolations.isEmpty {
                if scalar == "(" { interpolations[interpolations.count - 1].parentheses += 1 }
                if scalar == ")" {
                    interpolations[interpolations.count - 1].parentheses -= 1
                    if interpolations[interpolations.count - 1].parentheses == 0 {
                        let back = interpolations.removeLast()
                        string = (back.multiline, back.hashes)
                        index += 1
                        continue
                    }
                }
            }
            out.append(scalar)
            index += 1
        }
        return String(out)
    }

    private static func appModelSource() throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/NativeHarnessClient/AppModel.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
