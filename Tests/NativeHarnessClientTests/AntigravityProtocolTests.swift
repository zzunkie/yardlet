import Foundation
import XCTest
@testable import NativeHarnessClient

/// Antigravity CLI's model list as Yardlet's menus fold it (`AntigravityModelCatalog`): `agy models`, and
/// the models an `agy acp` session lists, name each effort of a model as a model of its own.
final class AntigravityProtocolTests: XCTestCase {
    /// `agy models` 1.4.0 lists effort variants as models of their own.
    private static let listedModels: [ProviderCapabilityChoice] = [
        ("gemini-3.8-flash-high", "Gemini 3.8 Flash (High)"),
        ("gemini-3.8-flash-medium", "Gemini 3.8 Flash (Medium)"),
        ("gemini-3.8-flash-low", "Gemini 3.8 Flash (Low)"),
        ("claude-sonnet-4-6", "Claude Sonnet 4.6 (Thinking)"),
        ("claude-opus-4-6-thinking", "Claude Opus 4.6 (Thinking)"),
        ("gpt-oss-120b-medium", "GPT-OSS 120B (Medium)")
    ].map { ProviderCapabilityChoice(value: $0.0, name: $0.1, description: nil) }

    func testTheModelListFoldsEffortVariantsIntoOneModel() {
        let catalog = AntigravityModelCatalog(choices: Self.listedModels)
        XCTAssertEqual(catalog.models.map(\.id),
                       ["gemini-3.8-flash", "claude-sonnet-4-6", "claude-opus-4-6-thinking", "gpt-oss-120b-medium"])
        XCTAssertEqual(catalog.models.map(\.name),
                       ["Gemini 3.8 Flash", "Claude Sonnet 4.6 (Thinking)", "Claude Opus 4.6 (Thinking)", "GPT-OSS 120B (Medium)"])
        XCTAssertEqual(catalog.models.first?.efforts.map(\.value), ["low", "medium", "high"])
        XCTAssertEqual(catalog.models.first?.efforts.map(\.modelID),
                       ["gemini-3.8-flash-low", "gemini-3.8-flash-medium", "gemini-3.8-flash-high"])
        // A lone variant keeps its own name and takes no effort (`/effort` says "adjustable": false).
        XCTAssertEqual(catalog.model(for: "gpt-oss-120b-medium")?.efforts, [])
        XCTAssertEqual(catalog.model(for: "gemini-3.8-flash-low")?.id, "gemini-3.8-flash")
        XCTAssertEqual(catalog.effort(carriedBy: "gemini-3.8-flash-low"), "low")
        XCTAssertNil(catalog.effort(carriedBy: "gemini-3.8-flash"))
    }
}
