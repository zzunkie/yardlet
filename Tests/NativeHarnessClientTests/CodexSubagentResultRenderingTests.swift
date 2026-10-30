import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// A Codex `wait` call's subagent card, opened, with the results its children reported: one done,
/// one failed, one still running. The images go to `.build/codex-subagent-result-qa`.
@MainActor
final class CodexSubagentResultRenderingTests: XCTestCase {
    func testOpenedCardShowsEveryChildResultInBothAppearances() throws {
        let decoded = CodexTaskDecoder().item(from: .object([
            "id": .string("wait-1"), "type": .string("collabAgentToolCall"), "tool": .string("wait"),
            "status": .string("completed"), "senderThreadId": .string("parent"),
            "receiverThreadIds": .array([.string("child-a"), .string("child-b"), .string("child-c")]),
            "prompt": .string("Wait for the reviewers"),
            "agentsStates": .object([
                "child-a": .object(["status": .string("completed"), "message": .string("Parser: no issues.")]),
                "child-b": .object(["status": .string("errored"), "message": .string("Lexer: 2 tests failed.")]),
                "child-c": .object(["status": .string("running")])
            ])
        ]), fallbackID: "wait-1", lifecycle: .completed)
        let item = CodexConversationProjection.item(decoded, turnID: "turn", isTurnFinished: true,
            workspaceURL: URL(filePath: "/tmp"), changes: [], isHistoryMatch: false)
        guard case let .subagent(subagent) = item.kind else { return XCTFail("Not a subagent") }
        let output = try XCTUnwrap(subagent.output)

        let size = NSSize(width: 620, height: 360)
        let directory = try WindowlessRender.directory("codex-subagent-result-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            let host = WindowlessRender.Host(
                ConversationSubagentCard(subagent: subagent, phase: item.phase, actions: ConversationActions(),
                                         copyDetails: item.copyDetails)
                    .padding(16)
                    .environment(\.colorScheme, appearance.colorScheme)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .background(ParityTheme.canvas),
                size: size, appearance: appearance
            )
            defer { host.close() }
            host.settle()
            XCTAssertTrue(openDisclosure(in: host.hosting), "The card folds its details")
            host.settle()

            let text = host.accessibilityElements().flatMap { [$0.label, $0.value] }.joined(separator: "\n")
            for line in ["child-a: completed", "Parser: no issues.", "child-b: errored", "Lexer: 2 tests failed.",
                         "child-c: running"] {
                XCTAssertTrue(text.contains(line), "\(line) must show in the opened card: \(text)")
            }
            XCTAssertTrue(item.copyDetails?.contains(output) == true, "Copy carries what the card shows")

            let capture = try host.capture()
            XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6))
            try WindowlessRender.writePNG(capture.bitmap,
                                          to: directory.appending(path: "child-results-\(appearance.suffix).png"))
        }
    }

    /// Presses the card's disclosure triangle, as VoiceOver's press does. Reading the tree first
    /// turns on the tree SwiftUI builds only for an assistive app.
    private func openDisclosure(in root: NSView) -> Bool {
        func find(_ node: AnyObject) -> AnyObject? {
            for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                if (child.accessibilityRole?() ?? nil) == .disclosureTriangle { return child }
                if let found = find(child) { return found }
            }
            return nil
        }
        return WindowlessRender.withAccessibilityTree {
            root.layoutSubtreeIfNeeded()
            return find(root)?.accessibilityPerformPress?() == true
        }
    }
}
