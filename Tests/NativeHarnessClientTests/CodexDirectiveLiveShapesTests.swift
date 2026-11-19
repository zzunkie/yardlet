import Foundation
import XCTest
@testable import NativeHarnessClient

/// Opt-in, read-only: reads the Codex answers in the rollout files listed in `NHC_DIRECTIVE_LIVE_FILES`
/// (one path a line) and counts what the unified renderer draws of their directives, and any directive
/// left as text. It prints counts only, never a message's words.
final class CodexDirectiveLiveShapesTests: XCTestCase {
    func testRealAnswersDrawTheirDirectives() throws {
        guard let list = ProcessInfo.processInfo.environment["NHC_DIRECTIVE_LIVE_FILES"] else {
            throw XCTSkip("Set NHC_DIRECTIVE_LIVE_FILES to a list of rollout files to read.")
        }
        let paths = try String(contentsOfFile: list, encoding: .utf8).split(separator: "\n").map(String.init)
        var counts: [String: Int] = [:]
        var seen = Set<Int>()
        for path in paths {
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            for line in data.split(separator: UInt8(ascii: "\n")) where line.count < 4_000_000 {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      object["type"] as? String == "response_item",
                      let payload = object["payload"] as? [String: Any], payload["role"] as? String == "assistant",
                      let content = payload["content"] as? [[String: Any]] else { continue }
                for part in content {
                    guard let text = part["text"] as? String, text.contains(":codex-") || text.contains("::code-comment"),
                          seen.insert(text.hashValue).inserted else { continue }
                    counts["messages", default: 0] += 1
                    let shown = CodexDirectiveMarkup.displayText(text, isStreaming: false)
                    count(TranscriptMarkdownDocument(shown, dialect: .codex).blocks, into: &counts)
                }
            }
        }
        print("codex directive live shapes:", counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            .joined(separator: " "))
        XCTAssertGreaterThan(counts["messages"] ?? 0, 0)
    }

    private func count(_ blocks: [TranscriptMarkdownBlock], into counts: inout [String: Int]) {
        func inline(_ content: TranscriptInlineContent) {
            counts["links", default: 0] += content.attributed.runs.filter { $0.link != nil }.count
            let text = content.plainText
            for marker in [":codex-file-citation", ":codex-followup", "::code-comment", "::codex-inline-vis"]
            where text.contains(marker) {
                counts["left as text \(marker)", default: 0] += 1
            }
        }
        for block in blocks {
            switch block {
            case let .paragraph(content), let .heading(_, content): inline(content)
            case let .unorderedList(items, _), let .orderedList(_, items, _):
                for item in items { count(item.blocks, into: &counts) }
            case let .blockQuote(inside): count(inside, into: &counts)
            case let .table(headers, rows, _): (headers + rows.flatMap { $0 }).forEach(inline)
            case let .details(_, _, inside):
                counts["details", default: 0] += 1
                count(inside, into: &counts)
            case let .reviewComments(comments):
                counts["comment cards", default: 0] += 1
                counts["comments", default: 0] += comments.count
            case .suggestedTask: counts["suggested tasks", default: 0] += 1
            case .visualization: counts["visualizations", default: 0] += 1
            case .pictures: counts["pictures", default: 0] += 1
            case .code, .divider: break
            }
        }
    }
}
