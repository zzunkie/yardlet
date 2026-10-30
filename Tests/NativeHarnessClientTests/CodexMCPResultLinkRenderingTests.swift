import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// An MCP result's `resource_link` blocks as the tool card's result body draws them, in a test
/// window that is never shown. A web page or file is a link that goes to the conversation's
/// `openURL`; another scheme is text only. The images go to `.build/codex-mcp-link-qa`.
@MainActor
final class CodexMCPResultLinkRenderingTests: XCTestCase {
    func testLinksDrawInBothAppearancesAndOnlySafeOnesOpen() throws {
        let projection = CodexMCPResultProjection(result: .object(["content": .array([
            .object(["type": .string("text"), "text": .string("Found the report and one file.")]),
            link(name: "audit-report", title: "Audit report", uri: "https://example.com/report",
                 description: "The full findings, grouped by severity.", mimeType: "text/html"),
            link(name: "App.swift", uri: "file:///tmp/work/Sources/App.swift", mimeType: "text/x-swift"),
            link(name: "Run script", uri: "javascript:alert(document.cookie)",
                 description: "A link Yardlet leaves as text."),
            link(name: "orders", uri: "postgres://db.internal/orders")
        ])]), itemID: "mcp")
        XCTAssertEqual(projection.blocks.count, 5)

        let size = NSSize(width: 560, height: 300)
        let content = { (appearance: WindowlessRender.Appearance) in
            CodexMCPResultContent(projection: projection)
                .padding(16)
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(ParityTheme.canvas)
        }
        let captures = try WindowlessRender.hostedInBothAppearances(
            "resource-links", in: WindowlessRender.directory("codex-mcp-link-qa"), size: size, content: content
        )
        for capture in captures {
            XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 4))
        }

        var opened: [URL] = []
        let host = WindowlessRender.Host(
            content(.light).environment(\.openURL, OpenURLAction { opened.append($0); return .handled }),
            size: size, appearance: .light
        )
        defer { host.close() }
        host.settle()
        let elements = host.accessibilityElements()
        let buttons = elements.filter { $0.role == NSAccessibility.Role.button.rawValue }.map(\.label)
        let openLabels = ["Audit report", "App.swift"].map { L10n.format("Open %@", $0) }
        XCTAssertEqual(buttons, openLabels, elements.description)
        let text = elements.map(\.label) + elements.map(\.value)
        for written in ["Run script", "javascript:alert(document.cookie)", "postgres://db.internal/orders",
                        "text/html", "The full findings, grouped by severity."] {
            XCTAssertTrue(text.contains(written), "\(written) must stay readable: \(elements)")
        }

        for label in openLabels {
            XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: label), "\(label) is pressable")
        }
        host.settle(passes: 2)
        XCTAssertEqual(opened, [URL(string: "https://example.com/report")!,
                                URL(filePath: "/tmp/work/Sources/App.swift")])
    }

    private func link(
        name: String, title: String? = nil, uri: String, description: String? = nil, mimeType: String? = nil
    ) -> JSONValue {
        var value: [String: JSONValue] = [
            "type": .string("resource_link"), "name": .string(name), "uri": .string(uri)
        ]
        if let title { value["title"] = .string(title) }
        if let description { value["description"] = .string(description) }
        if let mimeType { value["mimeType"] = .string(mimeType) }
        return .object(value)
    }
}
