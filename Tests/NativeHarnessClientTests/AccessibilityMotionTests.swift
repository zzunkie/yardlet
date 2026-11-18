import XCTest
import AppKit
@testable import NativeHarnessClient

final class AccessibilityMotionTests: XCTestCase {
    func testReducedMotionDisablesTimelineAndShellAnimations() {
        XCTAssertNil(ParityMotion.easeInOut(reduceMotion: true))
        XCTAssertNil(ParityMotion.easeOut(reduceMotion: true))
    }

    func testNormalMotionKeepsShortNativeTransitions() {
        XCTAssertNotNil(ParityMotion.easeInOut(reduceMotion: false))
        XCTAssertNotNil(ParityMotion.easeOut(reduceMotion: false))
    }

    func testSharedShellAccessibilityBandsKeepPrimaryJourneyOrder() {
        XCTAssertGreaterThan(ParityAccessibility.titleBar, ParityAccessibility.sidebarPrimary)
        XCTAssertGreaterThan(ParityAccessibility.sidebarPrimary, ParityAccessibility.surfacePicker)
        XCTAssertGreaterThan(ParityAccessibility.surfacePicker, ParityAccessibility.mainContent)
        XCTAssertGreaterThan(ParityAccessibility.mainContent, ParityAccessibility.composer)
        XCTAssertGreaterThan(ParityAccessibility.composer, ParityAccessibility.secondary)
    }

    func testProviderControlsExposeSelectedChoiceAndActionMeaning() {
        let selector = ProviderCapabilitySelector(
            id: "mode",
            name: "Mode",
            description: "Choose provider mode",
            category: "mode",
            currentValue: "code",
            choices: [
                ProviderCapabilityChoice(value: "ask", name: "Ask", description: nil),
                ProviderCapabilityChoice(value: "code", name: "Code", description: nil)
            ]
        )
        let action = ProviderCapabilityAction(
            id: "compact",
            title: "Compact conversation",
            description: "Summarize older context.",
            systemImage: "arrow.clockwise"
        )

        XCTAssertEqual(
            ProviderCapabilityAccessibility.selectedChoiceName(for: selector),
            "Code"
        )
        XCTAssertEqual(
            ProviderCapabilityAccessibility.actionHint(for: action),
            "Summarize older context."
        )
    }

    func testProviderChoiceAccessibilityFallsBackToUnknownRuntimeValue() {
        let selector = ProviderCapabilitySelector(
            id: "mode",
            name: "Mode",
            description: nil,
            category: nil,
            currentValue: "future-mode",
            choices: []
        )

        XCTAssertEqual(
            ProviderCapabilityAccessibility.selectedChoiceName(for: selector),
            "future-mode"
        )
    }

    func testSemanticAccentTokensMeetTextContrastFloorInBothAppearances() {
        XCTAssertTrue(
            ParityContrast.passesTextContrast(
                foreground: ParityContrast.lightAccent,
                background: ParityContrast.lightCanvas
            )
        )
        XCTAssertTrue(
            ParityContrast.passesTextContrast(
                foreground: ParityContrast.darkAccent,
                background: ParityContrast.darkCanvas
            )
        )
        XCTAssertGreaterThanOrEqual(
            ParityContrast.ratio(
                foreground: ParityContrast.lightAccent,
                background: ParityContrast.lightCanvas
            ),
            ParityContrast.textContrastFloor
        )
        XCTAssertGreaterThanOrEqual(
            ParityContrast.ratio(
                foreground: ParityContrast.darkAccent,
                background: ParityContrast.darkCanvas
            ),
            ParityContrast.textContrastFloor
        )
    }
}
