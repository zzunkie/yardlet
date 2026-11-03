import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// One task composer per harness family, with each provider's own controls filled in the way a
/// running app fills them: Codex's typed catalog and run location, Claude Code's selectors, and an
/// ACP agent's selectors. The review images and the bottom-row comparison draw these.
@MainActor
enum ComposerUnificationFixtures {
    struct Scenario {
        let name: String
        let size: NSSize
        let view: () -> AnyView
    }

    static let workspace = URL(filePath: "/tmp/composer-unify-project")

    static var codexCatalog: CodexModelCatalog {
        CodexModelCatalog(models: [
            CodexModelOption(id: "gpt-6.1-sol", model: "gpt-6.1-sol", displayName: "GPT-6.1-Sol", defaultReasoningEffort: "medium",
                             supportedReasoningEfforts: ["low", "medium", "high", "xhigh"], isDefault: true,
                             serviceTiers: [CodexServiceTier(id: "priority", name: "Fast", description: "2x speed, increased usage")])
        ], selection: CodexModelSelection(model: "gpt-6.1-sol", reasoningEffort: "high", serviceTier: "default"))
    }

    static let planPreset = CodexCollaborationPreset(name: "Plan", mode: "plan", model: nil, reasoningEffort: nil)
    static let defaultPreset = CodexCollaborationPreset(name: "Default", mode: "default", model: nil, reasoningEffort: nil)

    static let skills = [
        CodexSkillSummary(name: "release notes", displayName: "Release notes", description: "Draft release notes",
                          enabled: true, scope: "repo", path: "/skills/release/SKILL.md")
    ]

    static var codexTokenUsage: CodexThreadTokenUsage {
        let last = CodexTokenUsageBreakdown(inputTokens: 60_000, cachedInputTokens: 20_000, cacheWriteInputTokens: 0,
                                            outputTokens: 4_000, reasoningOutputTokens: 1_000, totalTokens: 64_000)
        return CodexThreadTokenUsage(total: last, last: last, modelContextWindow: 256_000)
    }

    static func session(_ harness: HarnessKind, status: SessionStatus = .ready,
                        options: [String: String] = [:]) -> SessionRecord {
        SessionRecord(harness: harness, workspaceURL: workspace, runtimeExecutableURL: URL(filePath: "/tmp/\(harness.rawValue)"),
                      title: "Fixture", status: status, providerSessionID: "saved", providerOptions: options)
    }

    static let queue = [
        CodexQueuedSubmission(draft: CodexComposerDraft(inputs: [.text("Also update the README")])),
        CodexQueuedSubmission(draft: CodexComposerDraft(inputs: [.text("Run the tests again")]), state: .failed,
                              failureMessage: "The message was not taken.")
    ]

    static var claudeLiveCapabilities: ProviderCapabilityState {
        var state = ProviderCapabilityState()
        state.selectors = [
            ProviderCapabilitySelector(id: "model", name: "Model", description: nil, category: "model", currentValue: "opus",
                choices: [.init(value: "default", name: "Default (recommended)", description: nil),
                          .init(value: "opus", name: "Opus", description: nil),
                          .init(value: "sonnet", name: "Sonnet", description: nil)]),
            ProviderCapabilitySelector(id: "effort", name: "Effort", description: nil, category: "thought_level",
                currentValue: "high", choices: [.init(value: "low", name: "Low", description: nil),
                                                .init(value: "high", name: "High", description: nil)]),
            ProviderCapabilitySelector(id: "permissionMode", name: "Permission mode",
                description: "Controls how Claude Code asks before using tools.", category: "mode", currentValue: "acceptEdits",
                choices: ClaudePermissionMode.selectable.compactMap { mode in
                    ClaudePermissionMode.displayName(mode).map { ProviderCapabilityChoice(value: mode, name: $0, description: nil) }
                })
        ]
        return state
    }

    static var claudeDetachedCapabilities: ProviderCapabilityState {
        var state = ProviderCapabilityState()
        state.selectors = ClaudeComposerModelProjection.selectors(model: nil, effort: nil,
            defaults: HarnessModelDefaults(model: "fable", effort: "xhigh"), catalog: ModelVisibilityFixtures.claudeModels)
        state.offersModelsBeforeAttach = true
        return state
    }

    static var acpCapabilities: ProviderCapabilityState {
        var state = ProviderCapabilityState()
        state.selectors = [
            ProviderCapabilitySelector(id: "model", name: "Model", description: nil, category: "model",
                currentValue: "anthropic/sonnet", choices: [.init(value: "anthropic/sonnet", name: "Sonnet", description: nil),
                                                            .init(value: "openai/gpt", name: "GPT", description: nil)]),
            ProviderCapabilitySelector(id: "mode", name: "Mode", description: nil, category: "mode", currentValue: "build",
                choices: [.init(value: "build", name: "Build", description: nil),
                          .init(value: "plan", name: "Plan", description: nil)]),
            ProviderCapabilitySelector(id: "thought_level", name: "Thinking", description: nil, category: "thought_level",
                currentValue: "medium", choices: [.init(value: "low", name: "Low", description: nil),
                                                  .init(value: "medium", name: "Medium", description: nil)])
        ]
        return state
    }

    static let providerUsage = HarnessProtocolUsage(inputTokens: 42_000, cachedInputTokens: 30_000, outputTokens: 3_000,
        reasoningTokens: nil, totalCostUSD: nil, contextWindowTokens: 200_000, contextUsedTokens: 120_000,
        extensionValues: [:])

    static var codexActions: ComposerActions {
        ComposerActions(submitCodex: { _, _ in }, removeQueued: { _ in }, retryQueued: { _ in }, moveQueued: { _, _ in },
                        sendQueuedNow: { _ in }, editQueued: { _ in nil }, resumeQueue: {}, runCodexCommand: { _ in })
    }

    static var claudeActions: ComposerActions {
        ComposerActions(submitFollowUp: { _, _ in }, removeQueued: { _ in }, retryQueued: { _ in }, moveQueued: { _, _ in },
                        sendQueuedNow: { _ in }, editQueued: { _ in nil }, resumeQueue: {})
    }

    static func draft(_ text: String) -> TaskComposerDraft {
        let draft = TaskComposerDraft()
        draft.text = text
        return draft
    }

    /// The task composers, one per harness family and state.
    static var taskScenarios: [Scenario] {
        [
            Scenario(name: "codex-idle", size: NSSize(width: 760, height: 150)) {
                AnyView(PromptComposer(harness: .codex, composerDraft: draft("Refactor the parser"), skills: skills,
                    modes: [planPreset, defaultPreset], selectedModeID: planPreset.id, modelCatalog: codexCatalog,
                    runLocation: .approveForMe, providerSession: session(.codex), isProviderAttached: true, isRunning: false,
                    codexHasThread: true, codexTokenUsage: codexTokenUsage, workspaceURL: workspace, actions: codexActions))
            },
            Scenario(name: "codex-running", size: NSSize(width: 760, height: 190)) {
                AnyView(PromptComposer(harness: .codex, composerDraft: draft(""), modelCatalog: codexCatalog,
                    runLocation: .dangerFullAccess, providerSession: session(.codex, status: .running),
                    isProviderAttached: true, isRunning: true, canSteer: true, codexQueue: queue,
                    codexHasThread: true, codexTokenUsage: codexTokenUsage, workspaceURL: workspace, actions: codexActions))
            },
            Scenario(name: "claude-detached", size: NSSize(width: 760, height: 150)) {
                AnyView(PromptComposer(harness: .claudeCode, composerDraft: draft("Explain the build"),
                    providerSession: session(.claudeCode, options: ["permissionMode": "acceptEdits"]),
                    providerCapabilities: claudeDetachedCapabilities, providerUsage: providerUsage,
                    isProviderAttached: false, isRunning: false, workspaceURL: workspace, actions: claudeActions))
            },
            Scenario(name: "claude-running", size: NSSize(width: 760, height: 190)) {
                AnyView(PromptComposer(harness: .claudeCode, composerDraft: draft(""),
                    providerSession: session(.claudeCode, status: .running),
                    providerCapabilities: claudeLiveCapabilities, providerUsage: providerUsage,
                    isProviderAttached: true, isRunning: true, canSteer: true, codexQueue: queue,
                    workspaceURL: workspace, actions: claudeActions))
            },
            Scenario(name: "opencode-attached", size: NSSize(width: 760, height: 150)) {
                AnyView(PromptComposer(harness: .openCode, composerDraft: draft("Add a flag"),
                    providerSession: session(.openCode), providerCapabilities: acpCapabilities, providerUsage: providerUsage,
                    isProviderAttached: true, isRunning: false, workspaceURL: workspace))
            },
            Scenario(name: "opencode-detached", size: NSSize(width: 760, height: 150)) {
                AnyView(PromptComposer(harness: .openCode, composerDraft: draft(""),
                    providerSession: session(.openCode), isProviderAttached: false, isRunning: false, workspaceURL: workspace))
            }
        ]
    }

    /// Draws `scenario` in both appearances into `directory`, and returns the light window's
    /// accessibility elements.
    @discardableResult
    static func render(_ scenario: Scenario, into directory: URL) throws -> [WindowlessRender.AccessibilityElement] {
        var elements: [WindowlessRender.AccessibilityElement] = []
        for appearance in WindowlessRender.Appearance.allCases {
            let host = WindowlessRender.Host(
                scenario.view()
                    .environment(\.colorScheme, appearance.colorScheme)
                    .frame(width: scenario.size.width, height: scenario.size.height, alignment: .bottom)
                    .background(ParityTheme.canvas),
                size: scenario.size, appearance: appearance)
            host.settle()
            try WindowlessRender.writePNG(try host.capture().bitmap,
                to: directory.appending(path: "\(scenario.name)-\(appearance.suffix).png"))
            if appearance == .light { elements = host.accessibilityElements() }
            host.close()
        }
        try elements.map(\.description).joined(separator: "\n")
            .write(to: directory.appending(path: "\(scenario.name)-ax.txt"), atomically: true, encoding: .utf8)
        return elements
    }
}
