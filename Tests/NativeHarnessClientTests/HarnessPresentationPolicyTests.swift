import XCTest
@testable import NativeHarnessClient

final class HarnessPresentationPolicyTests: XCTestCase {
    func testAllBuiltInsResolveToOneTruthfulCapabilitySurface() {
        let policies = Dictionary(uniqueKeysWithValues: HarnessCatalog.builtIns.map {
            ($0.id, HarnessPresentationPolicy(harness: $0.id))
        })

        XCTAssertEqual(policies.count, 11)
        XCTAssertEqual(policies[.codex]?.capabilitySurface, .codex)
        XCTAssertEqual(
            policies.filter { $0.value.capabilitySurface == .liveProvider }.keys.sorted {
                $0.rawValue < $1.rawValue
            },
            [
                .claudeCode, .museCode, .grokBuild, .hermes,
                .kimiCode, .cursorAgent, .antigravityCLI,
                .openCode, .kiroCLI, .pi
            ].sorted { $0.rawValue < $1.rawValue }
        )
        XCTAssertEqual(
            policies.filter { $0.value.capabilitySurface == .informational }.keys.sorted {
                $0.rawValue < $1.rawValue
            },
            []
        )
    }

    func testUnknownHarnessFailsClosedToInformationalPresentation() {
        let policy = HarnessPresentationPolicy(
            harness: HarnessKind(rawValue: "future-harness")
        )

        XCTAssertEqual(policy.capabilitySurface, .informational)
        XCTAssertFalse(policy.usesCodexTimeline)
        XCTAssertFalse(policy.showsCodexComposerControls)
        XCTAssertFalse(policy.loadsLiveProviderControls)
    }
}
