import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The shared render tool itself: where it writes, the scale it draws at, both appearances, and
/// the accessibility listing the rendering checks read. Images go to `.build/windowless-render-qa`.
@MainActor
final class WindowlessRenderTests: XCTestCase {
    func testDrawsBothAppearancesAndListsTheAccessibilityTreeInReadingOrder() throws {
        let directory = try WindowlessRender.directory("windowless-render-qa")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: WindowlessRender.repositoryRoot.appending(path: "Package.swift").path(percentEncoded: false)))
        XCTAssertEqual(directory, WindowlessRender.repositoryRoot.appending(path: ".build/windowless-render-qa"))

        // ImageRenderer draws at scale 2.
        var corners: [WindowlessRender.Appearance: NSColor?] = [:]
        for appearance in WindowlessRender.Appearance.allCases {
            let bitmap = try WindowlessRender.bitmap(Text("Windowless").padding(12).frame(width: 200, height: 60)
                .background(ParityTheme.canvas).environment(\.colorScheme, appearance.colorScheme))
            XCTAssertEqual([bitmap.pixelsWide, bitmap.pixelsHigh], [400, 120])
            XCTAssertTrue(WindowlessRender.drawsContent(bitmap, step: 2))
            corners[appearance] = bitmap.colorAt(x: 1, y: 1)
            try WindowlessRender.writePNG(bitmap, to: directory.appending(path: "image-\(appearance.suffix).png"))
        }
        XCTAssertNotEqual(corners[.light], corners[.dark])

        // A real conversation in an unshown window, written as `<name>-light.png` and `<name>-dark.png`.
        let entries = try ConversationFixtures.completedTranscript(for: .claudeCode)
        let size = NSSize(width: 720, height: 1_200)
        func transcript(_ appearance: WindowlessRender.Appearance) -> some View {
            TranscriptConversationView(harness: .claudeCode, entries: entries, sessionStatus: .completed,
                                       actions: ConversationActions(chooseOption: { _, _ in }))
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height)
                .background(ParityTheme.canvas)
        }
        let captures = try WindowlessRender.hostedInBothAppearances("transcript", in: directory, size: size,
                                                                    content: transcript)
        XCTAssertEqual(captures.map(\.bitmap.pixelsWide), captures.map { Int(size.width * $0.backingScaleFactor) })
        XCTAssertNotEqual(captures[0].bitmap.colorAt(x: 4, y: 4), captures[1].bitmap.colorAt(x: 4, y: 4))
        for suffix in ["light", "dark"] {
            let png = try Data(contentsOf: directory.appending(path: "transcript-\(suffix).png"))
            XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        }

        // Role, label and value in reading order, without scroll bars, containers or repeats.
        let controls = WindowlessRender.Host(VStack(alignment: .leading) {
            Text("Title")
            Button("Send") {}
            Toggle("Fast", isOn: .constant(true))
            TextField("Message", text: .constant("Hello"))
        }.padding(20).frame(width: 300, height: 200), size: NSSize(width: 300, height: 200))
        controls.settle()
        XCTAssertEqual(controls.accessibilityElements().map(\.description), [
            "AXStaticText = “Title”", "AXButton “Send”", "AXCheckBox “Fast” = “1”", "AXTextField = “Hello”"
        ])
        controls.close()

        // The same conversation lists the same elements in either appearance, with the approval's
        // choices in their order.
        let listings = WindowlessRender.Appearance.allCases.map { appearance in
            let host = WindowlessRender.Host(transcript(appearance), size: size, appearance: appearance)
            defer { host.close() }
            host.settle()
            return host.accessibilityElements()
        }
        XCTAssertEqual(listings[0], listings[1])
        let elements = listings[0]
        XCTAssertFalse(elements.contains { $0.role == NSAccessibility.Role.scrollBar.rawValue })
        XCTAssertFalse(zip(elements, elements.dropFirst()).contains { $0 == $1 })
        XCTAssertTrue(elements.contains { $0.description.contains("Approve the next tool call.") })
        // Denials first and the prominent allow last, as both apps end the row with "Allow once".
        let choices = ["Reject", "Always reject", "Always allow", "Allow once"]
        XCTAssertEqual(elements.filter { $0.role == "AXButton" && choices.contains($0.label) }.map(\.label), choices)
    }
}
