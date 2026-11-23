import Foundation
import XCTest
import YardletAgentTools
@testable import NativeHarnessClient

final class ConversationWidgetProjectionTests: XCTestCase {
    func testRecognizesYardletNamespacedShowWidgetWhenOutputIsOmitted() throws {
        let html = "<div>Architecture diagram</div>"
        let input = String(
            decoding: try JSONSerialization.data(withJSONObject: [
                "title": "Diagram",
                "widget_code": html
            ]),
            as: UTF8.self
        )
        let expected = ConversationWidget(title: "Diagram", code: html)

        let validNames = [
            "mcp__yardlet__show_widget",
            "mcp_yardlet_9f2cf821_show_widget",
            "Run mcp_yardlet_9f2cf821_show_widget",
            "yardlet/show_widget",
            "yardlet:show_widget",
            "yardlet__show_widget",
            "yardlet.show_widget",
            "yardlet_show_widget",
            "mcp/yardlet/show_widget",
            "mcp:yardlet:show_widget",
            "Run `yardlet/show_widget`",
            "yardlet_deadbeef/show_widget"
        ]
        for name in validNames {
            let activity = HarnessActivity(
                id: "call-\(name)",
                kind: "other",
                title: name,
                input: input,
                output: nil
            )
            XCTAssertEqual(ConversationWidget.of(activity), expected, "Expected match for \(name)")
        }

        let invalidNames = [
            "show_widget",
            "claude__show_widget",
            "mcp__claude__show_widget",
            "other/show_widget",
            "not_yardlet/show_widget",
            "myyardlet/show_widget",
            "yardlet_other/show_widget",
            "mcp_yardlet_nothex_show_widget",
            "yardlet/show_widget_v2",
            "yardletshow_widget"
        ]
        for name in invalidNames {
            let activity = HarnessActivity(
                id: "call-\(name)",
                kind: name,
                title: name,
                input: input,
                output: nil
            )
            XCTAssertNil(ConversationWidget.of(activity), "Must not match non-Yardlet tool \(name)")
        }

        // Failed calls and non-Yardlet outputs never project a widget.
        let failed = HarnessActivity(
            id: "call-failed",
            kind: "other",
            title: "yardlet/show_widget",
            outcome: .failed,
            input: input,
            output: nil
        )
        XCTAssertNil(ConversationWidget.of(failed))

        let claudeOutput = HarnessActivity(
            id: "call-claude-out",
            kind: "yardlet/show_widget",
            title: "yardlet/show_widget",
            input: input,
            output: "Widget rendered."
        )
        XCTAssertNil(ConversationWidget.of(claudeOutput))

        let yardletOutput = HarnessActivity(
            id: "call-yardlet-out",
            kind: "show_widget",
            title: "show_widget",
            input: input,
            output: WidgetToolCatalog.result
        )
        XCTAssertEqual(ConversationWidget.of(yardletOutput), expected)
    }
}
