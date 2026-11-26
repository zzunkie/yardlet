import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Approval cards as a Claude task shows them, rendered from the task's conversation in a test
/// window that is never shown. The diff box's scrolling line list is
/// native scroll content, which ImageRenderer does not materialize.
@MainActor
final class PermissionCardRenderingTests: XCTestCase {
    private let workspace = URL(filePath: "/Users/someone/Desktop/workspace/yardlet-sandbox")
    private var calcPath: String { workspace.appending(path: "calc.py").path(percentEncoded: false) }

    func testAPendingEditShowsItsDiffAndAnAllowedCallReadsOnItsToolCard() throws {
        let bashInput: JSONValue = .object([
            "command": .string("ls -la /Users/someone/Desktop/workspace/yardlet-sandbox && python3 test_calc.py 2>&1"),
            "description": .string("List project files and run the calc tests")
        ])
        let editInput: JSONValue = .object([
            "replace_all": .bool(false),
            "file_path": .string(calcPath),
            "old_string": .string("def add(a, b):\n    return a - b"),
            "new_string": .string("def add(a, b):\n    return a + b")
        ])
        let entries = [
            TranscriptEntry(content: .user(text: "Fix the calc.py tests")),
            TranscriptEntry(content: .activity(HarnessActivity(
                id: "toolu_bash", kind: "Bash", title: "Bash", input: bashInput["command"]?.stringValue,
                output: "Ran 3 tests\nFAILED (failures=1, errors=1)"
            ), state: .completed)),
            TranscriptEntry(content: .permission(request(
                "bash-1", tool: "toolu_bash", name: "Bash", detail: "List project files and run the calc tests",
                input: bashInput
            ), state: .allowed)),
            TranscriptEntry(content: .activity(HarnessActivity(id: "toolu_edit", kind: "Edit", title: "Edit"), state: .running)),
            TranscriptEntry(content: .permission(request(
                "edit-1", tool: "toolu_edit", name: "Edit", detail: "calc.py", input: editInput,
                actions: ClaudePermissionSuggestions.actions(for: ClaudePermissionSuggestionOffer(
                    action: PermissionRequestAction(
                        id: "allow_session",
                        label: L10n.format("Allow and switch to %@ mode for this session", L10n.string("Accept edits")),
                        decision: .allow, kind: "allow_session"
                    ),
                    updates: []
                ))
            ), state: .pending))
        ]
        try render(entries, height: 720, name: "pending-edit")
    }

    func testOtherChangesAndADeniedRequestKeepTheirCards() throws {
        let multi: JSONValue = .object([
            "file_path": .string(calcPath),
            "edits": .array([
                .object(["old_string": .string("return a - b"), "new_string": .string("return a + b")]),
                .object(["old_string": .string("values"), "new_string": .string("numbers"), "replace_all": .bool(true)])
            ])
        ])
        let write: JSONValue = .object([
            "file_path": .string(workspace.appending(path: "notes/plan.md").path(percentEncoded: false)),
            "content": .string((1...260).map { "Step \($0): check the calculator" }.joined(separator: "\n"))
        ])
        let bash: JSONValue = .object([
            "command": .string("python3 test_calc.py -v 2>&1"),
            "description": .string("Rerun the calc tests after the fix")
        ])
        let denied: JSONValue = .object([
            "file_path": .string(calcPath),
            "old_string": .string("def mean(values):\n    return sum(values) / len(values)"),
            "new_string": .string("def mean(values):\n    if not values:\n        return 0\n    return sum(values) / len(values)")
        ])
        let entries = [
            TranscriptEntry(content: .user(text: "Fix the remaining tests")),
            TranscriptEntry(content: .activity(HarnessActivity(id: "toolu_denied", kind: "Edit", title: "Edit"), state: .failed)),
            TranscriptEntry(content: .permission(request("p-denied", tool: "toolu_denied", name: "Edit", detail: "calc.py", input: denied), state: .denied)),
            TranscriptEntry(content: .permission(request("p-multi", tool: "toolu_multi", name: "MultiEdit", detail: "calc.py", input: multi), state: .pending)),
            TranscriptEntry(content: .permission(request("p-write", tool: "toolu_write", name: "Write", detail: "plan.md", input: write), state: .pending)),
            TranscriptEntry(content: .permission(request("p-bash", tool: "toolu_bash2", name: "Bash", detail: "Rerun the calc tests after the fix", input: bash), state: .pending))
        ]
        try render(entries, height: 1_500, name: "other-changes")
    }

    /// The answer a row leads to keeps its title on one line at its own width, as a native button does, so a
    /// row too narrow for its answers stacks them rather than wrapping the title inside the fill; and the
    /// front card of the dock counts the requests behind it.
    func testTheLeadingAnswerKeepsItsTitleOnOneLineAndTheBandCountsTheRequestsBehind() throws {
        let button = NSHostingController(rootView: Button("Allow for this conversation") {}.parityPrimaryActionButton())
        let own = button.sizeThatFits(in: CGSize(width: 1_000, height: 1_000))
        let narrow = button.sizeThatFits(in: CGSize(width: 40, height: 1_000))
        XCTAssertEqual(narrow, own, "Offered less room, the button keeps its one line and its size")
        XCTAssertGreaterThanOrEqual(own.height, 24)

        let entry = TranscriptEntry(content: .plan(""))
        let approval = ConversationRequest(id: "bash", title: "Bash", command: "swift test", state: .pending,
                                           responses: ConversationRequestResponses.plain(providerActions: []),
                                           source: .transcript(entry))
        for width: CGFloat in [640, 180] {
            let host = WindowlessRender.Host(
                ConversationRequestCard(request: approval, actions: ConversationActions(chooseOption: { _, _ in }),
                                        waitingBehind: 1)
                    .frame(width: width).fixedSize(horizontal: false, vertical: true),
                size: NSSize(width: width, height: 400))
            defer { host.close() }
            host.settle(passes: 4)
            let elements = host.accessibilityElements()
            XCTAssertTrue(elements.contains { $0.value == L10n.format("%lld more waiting", Int64(1)) }, "\(elements)")
            XCTAssertEqual(elements.filter { $0.role == "AXButton" }.map(\.label),
                           [L10n.string("Deny"), L10n.string("Allow")], "\(width)")
        }
    }

    private func request(
        _ id: String, tool: String, name: String, detail: String, input: JSONValue,
        actions: [PermissionRequestAction] = []
    ) -> PermissionRequest {
        PermissionRequest(
            id: id, title: name, detail: detail, command: input["command"]?.stringValue, actions: actions,
            toolCallID: tool, preview: ClaudeProtocol.preview(toolName: name, input: input)
        )
    }

    private func render(_ entries: [TranscriptEntry], height: CGFloat, name: String) throws {
        let captures = try WindowlessRender.hostedInBothAppearances(
            name, in: WindowlessRender.directory("approval-card-qa"), size: NSSize(width: 720, height: height),
            passes: 6
        ) { appearance in
            TaskConversationView(
                harness: .claudeCode, workspaceURL: workspace, entries: entries, sessionStatus: .waitingForApproval,
                actions: ConversationActions(chooseOption: { _, _ in })
            )
                .environment(\.transcriptWorkspaceURL, workspace)
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: 720, height: height)
                .background(ParityTheme.canvas)
        }
        for capture in captures {
            XCTAssertEqual(capture.bitmap.pixelsWide, Int(720 * capture.backingScaleFactor))
        }
    }
}
