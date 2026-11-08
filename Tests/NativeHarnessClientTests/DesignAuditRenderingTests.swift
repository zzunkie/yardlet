import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Opt-in review artifacts, not product changes or pixel-golden assertions. Run separately for each
/// AppleLanguages setting with YARDLET_DESIGN_AUDIT=1. All windows stay unshown.
@MainActor
final class DesignAuditRenderingTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["YARDLET_DESIGN_AUDIT"] == "1")
        XCTAssertEqual(L10n.string("New task"), AuditCopy.text("New task"),
                       "The app localization and the synthetic copy must use the same language")
    }

    func testLongConversationAtReadingAndSplitWidths() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["YARDLET_DESIGN_AUDIT"] == "1")
        let directory = try WindowlessRender.directory("design-audit/conversation")
        let paragraph = AuditCopy.text("The conversation now keeps its reading position when reopened. Long file names and multiline errors should remain readable at the available width. The table and code below describe the change and its verification.")
        let title = AuditCopy.text("Changes and verification")
        let text = """
        ## \(title)

        \(paragraph)

        - **\(AuditCopy.text("Reading position"))**: `Sources/Conversation/ConversationScrollRestorationController.swift`
        - \(paragraph)

        ```swift
        func restoreConversation(_ conversation: Conversation, preserving anchor: ReadingAnchor) async throws {
            let snapshot = try await store.load(conversation.id)
            renderer.restore(snapshot, anchor: anchor)
        }
        ```

        | \(AuditCopy.text("State")) | \(AuditCopy.text("Result")) |
        | --- | --- |
        | \(AuditCopy.text("Restoration")) | \(paragraph) |
        | \(AuditCopy.text("Long file names")) | `ConversationScrollRestorationController.swift` |

        > \(paragraph)

        \(paragraph)
        """
        for width in [CGFloat(760), 420] {
            for appearance in WindowlessRender.Appearance.allCases {
                let size = NSSize(width: width, height: 1000)
                let view = ScrollView {
                    ConversationAgentMessage(itemID: "audit-answer", harness: .claudeCode,
                        text: text, isCommentary: false, isStreaming: false)
                        .padding(.horizontal, ParityTheme.conversationInset).padding(.vertical, 24)
                }.frame(width: width, height: size.height).background(ParityTheme.canvas)
                    .environment(\.colorScheme, appearance.colorScheme)
                let host = WindowlessRender.Host(view, size: size, appearance: appearance)
                defer { host.close() }
                host.settle()
                XCTAssertFalse(host.window.isVisible)
                try WindowlessRender.writePNG(host.capture().bitmap,
                    to: directory.appending(path: "long-\(Int(width))-\(appearance.suffix).png"))
            }
        }
    }

}

/// Optional synthetic copy supplied by the local reviewer. No customer conversations are loaded.
private enum AuditCopy {
    static let translations: [String: String] = {
        guard let path = ProcessInfo.processInfo.environment["YARDLET_AUDIT_COPY"],
              let data = try? Data(contentsOf: URL(filePath: path)),
              let strings = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return strings
    }()
    static func text(_ english: String) -> String { translations[english] ?? english }
}
