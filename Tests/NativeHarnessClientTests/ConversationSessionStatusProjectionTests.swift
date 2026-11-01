import XCTest
@testable import NativeHarnessClient

final class ConversationSessionStatusProjectionTests: XCTestCase {
    func testPrioritizesModelReasoningAndPermissionSelectors() {
        let state = ProviderCapabilityState(selectors: [
            selector(id: "autoCompaction", category: "context"),
            selector(id: "approvalMode", category: "mode"),
            selector(id: "reasoningEffort", category: "thought_level"),
            selector(id: "model", category: "model")
        ])

        XCTAssertEqual(
            ConversationSessionStatusProjection.inlineSelectors(from: state).map(\.id),
            ["model", "reasoningEffort", "approvalMode"]
        )
    }

    func testProjectsUsageContextAndPendingPermissions() {
        let usage = HarnessProtocolUsage(
            inputTokens: 20_618,
            cachedInputTokens: 6_400,
            outputTokens: 64,
            reasoningTokens: 50,
            totalCostUSD: 0.0054434,
            contextWindowTokens: 500_000,
            contextUsedTokens: 10_445,
            extensionValues: [:]
        )
        let entries = [TranscriptEntry(content: .permission(
            PermissionRequest(id: "permission", title: "Run", detail: nil, command: "pwd"),
            state: .pending
        ))]

        XCTAssertEqual(ConversationSessionStatusProjection.totalUsageTokens(usage), 20_682)
        XCTAssertEqual(
            ConversationSessionStatusProjection.contextFraction(usage) ?? -1,
            0.02089,
            accuracy: 0.00001
        )
        XCTAssertEqual(
            ConversationSessionStatusProjection.pendingPermissionCount(in: entries),
            1
        )
        XCTAssertEqual(ConversationSessionStatusProjection.compactTokenCount(20_682), "21K")
        XCTAssertNil(ConversationSessionStatusProjection.contextFraction(nil))
        XCTAssertTrue(ConversationSessionStatusProjection.supportsPermissionRequests(.grokBuild))
        XCTAssertFalse(ConversationSessionStatusProjection.supportsPermissionRequests(.cursorAgent))
    }

    func testClassifiesPermissionRequestSupportForEveryBuiltInHarness() {
        let requestDriven: Set<HarnessKind> = [
            .codex,
            .claudeCode,
            .museCode,
            .openCode,
            .antigravityCLI,
            .kimiCode,
            .grokBuild,
            .hermes,
            .pi
        ]
        let unavailable: Set<HarnessKind> = [
            .cursorAgent
        ]

        XCTAssertEqual(
            requestDriven.union(unavailable),
            Set(HarnessCatalog.builtIns.map(\.id))
        )
        for harness in requestDriven {
            XCTAssertTrue(
                ConversationSessionStatusProjection.supportsPermissionRequests(harness),
                "Expected permission requests for \(harness.displayName)"
            )
        }
        for harness in unavailable {
            XCTAssertFalse(
                ConversationSessionStatusProjection.supportsPermissionRequests(harness),
                "Expected unavailable permission requests for \(harness.displayName)"
            )
        }
    }

    func testBuildsCompactModelReasoningSummaryAndDetectsElevatedAccess() {
        let selectors = [
            ProviderCapabilitySelector(
                id: "model",
                name: "Model",
                description: nil,
                category: "model",
                currentValue: "grok-4.6",
                choices: [ProviderCapabilityChoice(
                    value: "grok-4.6",
                    name: "grok-4.6",
                    description: nil
                )]
            ),
            ProviderCapabilitySelector(
                id: "reasoning",
                name: "Reasoning",
                description: nil,
                category: "thought_level",
                currentValue: "high",
                choices: [ProviderCapabilityChoice(
                    value: "high",
                    name: "High",
                    description: nil
                )]
            )
        ]

        XCTAssertEqual(
            ComposerModelMenu.provider(selectors, speed: nil, canChoose: true).title,
            "grok-4.6 · High"
        )
        XCTAssertTrue(ConversationSessionStatusProjection.isElevatedPermission("Full access"))
        XCTAssertTrue(ConversationSessionStatusProjection.isElevatedPermission("전체 액세스"))
        XCTAssertFalse(ConversationSessionStatusProjection.isElevatedPermission("On request"))
    }

    func testOrdersKnownReasoningChoicesFromLowToHigh() {
        let reversed = [
            ProviderCapabilityChoice(value: "xhigh", name: "Extra High Effort", description: nil),
            ProviderCapabilityChoice(value: "high", name: "High Effort", description: nil),
            ProviderCapabilityChoice(value: "low", name: "Low Effort", description: nil)
        ]

        XCTAssertEqual(
            ConversationSessionStatusProjection.orderedReasoningChoices(reversed).map(\.value),
            ["low", "high", "xhigh"]
        )
    }

    func testPreservesProviderOrderWhenReasoningScaleIsUnknown() {
        let providerSpecific = [
            ProviderCapabilityChoice(value: "fast", name: "Fast", description: nil),
            ProviderCapabilityChoice(value: "deep", name: "Deep", description: nil)
        ]

        XCTAssertEqual(
            ConversationSessionStatusProjection.orderedReasoningChoices(providerSpecific).map(\.value),
            ["fast", "deep"]
        )
    }

    private func selector(id: String, category: String) -> ProviderCapabilitySelector {
        ProviderCapabilitySelector(
            id: id,
            name: id,
            description: nil,
            category: category,
            currentValue: "default",
            choices: [ProviderCapabilityChoice(value: "default", name: "Default", description: nil)]
        )
    }
}
