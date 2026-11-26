import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

@MainActor
final class CommonComposerRenderingTests: XCTestCase {
    func testSharedOptionMenuRendersActualNativeChoicesInBothAppearances() throws {
        let selector = ProviderCapabilitySelector(id: "permissionMode", name: "Permission mode", description: nil,
            category: "mode", currentValue: "manual", choices: [
                .init(value: "manual", name: "Manual", description: nil),
                .init(value: "plan", name: "Plan", description: "The plan mode this harness provides"),
                .init(value: "acceptEdits", name: "Accept edits automatically", description: nil),
                .init(value: "dontAsk", name: "Don't ask", description: nil)
            ])
        let directory = try WindowlessRender.directory("common-composer-qa")
        for appearance in [ColorScheme.light, .dark] {
            let view = ComposerProviderOptionMenu(selector: selector, isEnabled: true,
                onSelect: { _, _ in }, onDismiss: {})
                .frame(width: 264).environment(\.colorScheme, appearance)
            let image = try WindowlessRender.image(view)
            XCTAssertEqual(image.width, 528)
            XCTAssertGreaterThan(image.height, 200)
            let bitmap = NSBitmapImageRep(cgImage: image)
            XCTAssertTrue(WindowlessRender.drawsContent(bitmap, step: 5, from: 10))
            try WindowlessRender.writePNG(bitmap,
                to: directory.appending(path: appearance == .dark ? "menu-dark.png" : "menu-light.png"))
        }
    }

    func testNestedProviderControlsWrapWithoutClippingAtNarrowComposerWidth() throws {
        func view(_ width: CGFloat) -> some View {
            ControlRowLayout(pinsTrailingActions: true) {
                ControlRowLayout {
                    ParityComposerControl(title: "Long provider model name", showsChevron: true)
                    ParityComposerControl(title: "Provider work mode", showsChevron: true)
                    ParityComposerControl(title: "Provider permission mode", showsChevron: true)
                }
                Image(systemName: "arrow.up.circle.fill").frame(width: 30, height: 30)
            }
            .frame(width: width).background(ParityTheme.input)
        }
        let narrowImage = try WindowlessRender.image(view(280)), wideImage = try WindowlessRender.image(view(740))
        XCTAssertEqual(narrowImage.width, 560)
        XCTAssertGreaterThan(narrowImage.height, wideImage.height,
            "Nested wrapping height must be reserved before the send control is placed")
    }

    /// The composer row's order of giving way: trailing actions that can shorten take the room left beside the
    /// leading controls, down to half their width, before the row wraps; and a wrap never leaves the first
    /// control (the composer's "+") alone on its row.
    func testTheComposerRowShortensItsActionsBeforeItWraps() throws {
        let leadingWidth: CGFloat = 28 + 7 + 80 + 7
        func row(_ width: CGFloat, actions: some View) -> some View {
            ControlRowLayout(pinsTrailingActions: true) {
                Color.red.frame(width: 28, height: 28)
                Color.blue.frame(width: 80, height: 28)
                actions
            }
            .frame(width: width)
        }
        let shortening = HStack(spacing: 7) {
            Text(verbatim: "Opus (1M context) · Extra high").lineLimit(1).truncationMode(.tail)
            Color.green.frame(width: 28, height: 28)
        }
        let full = try WindowlessRender.image(shortening.fixedSize(), scale: 1).width
        XCTAssertGreaterThan(full, 100)
        let shortened = try WindowlessRender.image(row(leadingWidth + CGFloat(full) * 0.7, actions: shortening), scale: 1)
        XCTAssertEqual(shortened.height, 28, "Shortened to the room left, the actions stay on the row")
        let wrapped = try WindowlessRender.image(row(leadingWidth + CGFloat(full) * 0.4, actions: shortening), scale: 1)
        XCTAssertEqual(wrapped.height, 28 + 4 + 28, "Under half their width, the actions wrap")

        // Actions that cannot shorten wrap alone, after both leading controls: the second row starts with them.
        let fixed = Color.green.frame(width: 150, height: 28)
        let bitmap = try WindowlessRender.bitmap(row(87 + 150 + 5, actions: fixed), scale: 1)
        XCTAssertEqual(bitmap.pixelsHigh, 28 + 4 + 28)
        let firstRowBlue = try XCTUnwrap(bitmap.colorAt(x: 35 + 40, y: 14)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(firstRowBlue.blueComponent, 0.9, "The second control stays beside the first")
        XCTAssertLessThan(firstRowBlue.redComponent, 0.1)
    }
}
