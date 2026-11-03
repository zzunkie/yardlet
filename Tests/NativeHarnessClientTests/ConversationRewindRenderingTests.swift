import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Claude's edit and file restore: the banner and the provider's file preview, and the actions the
/// conversation draws under the latest request (images in `.build/rewind-qa`).
@MainActor
final class ConversationRewindRenderingTests: XCTestCase {
    func testActualEditBannerAndProviderFilePreviewRenderInBothAppearances() throws {
        let session = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Test", providerSessionID: UUID().uuidString)
        let edit = ConversationEditState(session: session, targetID: UUID().uuidString, previousID: nil,
            originalText: "Original", draft: .init(text: "Draft"), entries: [])
        let result = HarnessFileRewindResult(canRewind: true, error: nil,
            filesChanged: ["Sources/App.swift", "Tests/ExampleTests.swift"], insertions: 4, deletions: 7,
            skippedLinks: 1, inFlight: false)
        let directory = try WindowlessRender.directory("rewind-qa")
        for appearance in [ColorScheme.light, .dark] {
            let view = VStack(alignment: .leading, spacing: 16) {
                ConversationEditBanner(canCancel: edit.preparedProviderSessionID == nil, onCancel: {})
                Divider()
                FileRewindPreviewContent(result: result)
            }.padding(12).frame(width: 480).background(ParityTheme.input).environment(\.colorScheme, appearance)
            let image = try WindowlessRender.image(view)
            XCTAssertEqual(image.width, 960)
            XCTAssertGreaterThan(image.height, 180)
            try WindowlessRender.writePNG(image, to:
                directory.appending(path: appearance == .dark ? "preview-dark.png" : "preview-light.png"))
        }
    }

    /// The restore of a message's files sits under the latest message, beside its copy and before the
    /// answer, after any bash command, and only where the task can rewind (shown here as on hover).
    /// Its edit does not: the bash command opened the latest turn, and only that turn's request edits.
    func testTheMessageActionsSitUnderTheLatestMessageOnly() throws {
        let directory = try WindowlessRender.directory("rewind-qa")
        let rewind = ConversationRewindActions(
            beginCodexEdit: { _ in }, beginClaudeEdit: { _ in }, cancelEdit: {}, loadFilePoints: { [] },
            previewFiles: { _ in throw CancellationError() }, restoreFiles: { _ in throw CancellationError() }
        )
        let entries = [
            TranscriptEntry(content: .user(text: "Fix the build")),
            TranscriptEntry(content: .assistant(text: "Fixed the import.", isStreaming: false)),
            TranscriptEntry(content: .user(text: "Now run the tests")),
            TranscriptEntry(content: .assistant(text: "All tests pass.", isStreaming: false)),
            TranscriptEntry(content: .user(text: ClaudeBashMessage.text(command: "git status --short", stdout: " M a.swift")))
        ]
        let actionLabels = [L10n.string("Restore files…")].map { "AXButton “\($0)”" }
        func actions(_ actions: ConversationActions, _ appearance: WindowlessRender.Appearance) throws -> Int {
            let drawing = try ConversationDrawing.draw(
                TaskConversationView(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/yardlet"),
                                     entries: entries, sessionStatus: .ready, latestTurnIsComplete: true,
                                     actions: actions)
                    .environment(\.revealsSentMessageActions, true),
                size: NSSize(width: 720, height: 560), appearance: appearance
            )
            let list = drawing.elements.map(\.description)
            if actions.rewind != nil {
                try WindowlessRender.writePNG(drawing.capture.bitmap,
                                              to: directory.appending(path: "message-actions-\(appearance.suffix).png"))
                let latestMessage = try XCTUnwrap(list.firstIndex { $0.contains("Now run the tests") })
                let answer = try XCTUnwrap(list.firstIndex { $0.contains("All tests pass.") })
                for label in actionLabels {
                    let action = try XCTUnwrap(list.firstIndex { $0.hasPrefix(label) }, list.joined(separator: "\n"))
                    XCTAssertTrue(latestMessage < action && action < answer, "\(label) sits under the latest message")
                }
            }
            XCTAssertFalse(list.contains { $0.hasPrefix("AXButton “\(L10n.string("Edit message"))”") })
            return list.filter { item in actionLabels.contains { item.hasPrefix($0) } }.count
        }
        for appearance in WindowlessRender.Appearance.allCases {
            XCTAssertEqual(try actions(ConversationActions(rewind: rewind), appearance), 1)
            XCTAssertEqual(try actions(ConversationActions(), appearance), 0)
        }
    }
}
