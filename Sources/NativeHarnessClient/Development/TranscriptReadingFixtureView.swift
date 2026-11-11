#if DEBUG
import AppKit
import SwiftUI

/// Interactive, provider-free reading checks. These controls never create or attach a runtime.
struct TranscriptReadingFixtureView: View {
    @State private var entries = Self.initialEntries
    @State private var draft = ""
    @State private var clipboardCheck = ""
    @State private var status: SessionStatus = .completed
    @State private var submissions = 0

    private static let sample = """
        ## Reading check

        This response belongs to **Grok Build**.

        ```swift
        let message = "한글 👩🏽‍💻"
        // Preserve whitespace and Unicode.
        print(message)
        ```
        """

    nonisolated static let mixedMarkdown = #"""
        ## Mixed response

        9. **Review the structure.** 한글과 👩🏽‍💻 이모지가 있는 긴 문장도 본문 시작 위치를 유지합니다.
           This continuation stays with the parent item.

           - First child keeps its own bullet.
           - Second child includes code:

             ```swift
             let message = "한글 👩🏽‍💻"
               print(message)
             // NESTED-CODE-END
             ```

           This paragraph stays inside item nine.

        1. **Continue at ten.** The next item remains at the parent level.

        > **Quoted review**
        >
        > 1. Preserve the quoted list.
        > 2. Keep this second item inside the quote.
        >
        > ```text
        > QUOTED-CODE-END
        > ```

        | Detail | Count | State |
        | :--- | ---: | :---: |
        | A long explanation that should wrap inside its own column rather than stretching the entire table. 긴 표의 설명을 끝까지 읽을 수 있습니다. | 12 | Ready |
        | Literal left\|right and `a\|b` remain in one cell. | 3 | Done |
        | Final row | 1200 | TABLE-END |

        Paragraph after the table.

        | File | Workspace | Description | Result |
        | :--- | :--- | :--- | ---: |
        | `Sources/Transcript/MarkdownDocument.swift` | `/tmp/프로젝트/한글과-긴-폴더-이름` | A second wide table keeps the final column reachable while wrapping this longer description within its column. | 120 |
        | `Views/TranscriptTableLayout.swift` | `/tmp/fixture/workspace` | Final row after horizontal scrolling. | WIDE-END |
        """#

    private static var initialEntries: [TranscriptEntry] {
        (1...24).flatMap { index in
            [TranscriptEntry(content: .user(text: "Request \(index)")),
             TranscriptEntry(content: .assistant(
                text: "Response \(index)\n\n" + String(repeating: "Read this earlier response without losing your place.\n", count: 4),
                isStreaming: false
             ))]
        } + [TranscriptEntry(content: .assistant(text: sample, isStreaming: false))]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HarnessIdentityLabel(harness: .grokBuild)
                Text("Reading fixture").foregroundStyle(.secondary)
                Spacer()
                Button("Append response") {
                    entries.append(TranscriptEntry(content: .assistant(text: "New response\n\n" + Self.sample, isStreaming: false)))
                }
                Button("Grow response") {
                    guard let last = entries.indices.last,
                          case let .assistant(text, _) = entries[last].content else { return }
                    entries[last].content = .assistant(
                        text: text + String(repeating: "\n\nStreaming update with the same entry identity.", count: 12),
                        isStreaming: true
                    )
                    status = .running
                }
                Button("Long code") {
                    entries.append(TranscriptEntry(content: .assistant(
                        text: "```swift\n" + String(repeating: "print(\"한글 👩🏽‍💻\")\n", count: 3_000) + "// END-OF-FULL-CODE\n```",
                        isStreaming: false
                    )))
                    status = .completed
                }
                Button("Fail request") {
                    entries.append(TranscriptEntry(content: .user(text: "Please review this failed request.")))
                    entries.append(TranscriptEntry(content: .error(
                        message: "ACP request timed out.\nfixture-only details: no provider was contacted.",
                        recoverable: true
                    )))
                    status = .failed
                }
            }
            .font(.caption)
            .padding(12)
            Divider()
            TranscriptConversationView(
                harness: .grokBuild, entries: entries,
                latestTurnIsComplete: status == .completed, sessionStatus: status,
                actions: ConversationActions(restoreDraft: { draft = $0.text })
            )
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Submissions: \(submissions)").font(.caption)
                TextField("Restored request", text: $draft)
                    .onSubmit { submissions += 1 }
                Button("Check clipboard") {
                    clipboardCheck = TranscriptClipboard.pasteboard.string(forType: .string) ?? ""
                }
                Text(verbatim: "Copied characters: \(clipboardCheck.count) · Full code ending: \(clipboardCheck.hasSuffix("// END-OF-FULL-CODE"))")
                    .font(.caption)
            }
            .textFieldStyle(.roundedBorder)
            .padding(12)
        }
        .background(ParityTheme.canvas)
    }
}
#endif
