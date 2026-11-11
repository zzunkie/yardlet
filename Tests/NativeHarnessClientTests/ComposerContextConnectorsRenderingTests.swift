import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// The composer's context window and connector list, drawn offscreen into
/// `.build/composer-context-qa`, light and dark. No provider, process, app launch or window server.
///
/// - `context-claude-*`: a Claude Code task at 48%: numbers, bar, `/context` breakdown, auto-compact.
/// - `context-claude-near-*`: 76%, warning colour, "Auto-compacts soon" and "Compact session".
/// - `context-codex-*`: a Codex thread at 25% with its last turn and running total.
/// - `context-empty-*`: a Claude Code task before its first turn.
/// - `connectors-menu-*`: the "+" menu with "Connectors" and its reconnection hint, beside the list it
///   opens: Manage connectors, then Yardlet's connectors and, under their heading, the session's MCP
///   servers.
/// - `composer-ring-*`: the task composer with the ring beside the model menu.
/// - `context-limit-*`: a Claude Code task's context limit on its Default, which names the 600k Settings
///   gives it, in the context window and, as `context-limit-rail-*`, in the session rail's narrower card;
///   `context-limit-rail-claude-*` with Claude Code's own default, the longest name Default has.
@MainActor
final class ComposerContextConnectorsRenderingTests: XCTestCase {
    private typealias Fixtures = ComposerContextAndConnectorsTests

    private func drawDetails(_ name: String, summary: ComposerContextSummary, usage: HarnessProtocolUsage?,
                             breakdowns: [ComposerUsageBreakdown], compact: ComposerContextUsageDetails.Compact? = nil,
                             height: CGFloat, expected: [String]) throws {
        let directory = try WindowlessRender.directory("composer-context-qa")
        let size = NSSize(width: 340, height: height)
        let captures = try WindowlessRender.hostedInBothAppearances(name, in: directory, size: size) { appearance in
            ComposerContextUsageDetails(summary: summary, usage: usage, breakdowns: breakdowns, compact: compact)
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(ParityTheme.elevated)
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
        let host = WindowlessRender.Host(
            ComposerContextUsageDetails(summary: summary, usage: usage, breakdowns: breakdowns, compact: compact)
                .frame(width: size.width, height: size.height, alignment: .top), size: size)
        defer { host.close() }
        host.settle()
        let elements = host.accessibilityElements()
        for text in expected {
            XCTAssertTrue(elements.contains { $0.label.contains(text) || $0.value.contains(text) },
                          "\(name) shows no \(text): \(elements)")
        }
    }

    func testClaudeContextWindow() throws {
        var usage = try XCTUnwrap(ClaudeProtocol.contextUsage(from: Fixtures.claudeContextUsage))
        usage = HarnessProtocolUsage(inputTokens: 1_200, cachedInputTokens: 93_000, outputTokens: 2_400,
                                     reasoningTokens: nil, totalCostUSD: 0.4213, contextWindowTokens: usage.contextWindowTokens,
                                     contextUsedTokens: usage.contextUsedTokens, extensionValues: [:],
                                     contextBreakdown: usage.contextBreakdown)
        let summary = try XCTUnwrap(ComposerContextSummary.make(usage: usage, reportsContextWindow: true))
        try drawDetails("context-claude", summary: summary, usage: usage,
                        breakdowns: ComposerUsageBreakdown.provider(usage),
                        compact: .init(isAvailable: true, unavailableReason: nil, run: {}), height: 520,
                        expected: [L10n.string("Context window"), "95.1k / 200k (48%)", "Messages", "Autocompact buffer",
                                   "Free space", L10n.format("%@ until auto-compact", "71k"), L10n.string("Cost")])
    }

    func testClaudeContextWindowNearAutoCompact() throws {
        var near = Fixtures.claudeContextUsage.objectValue ?? [:]
        near["totalTokens"] = .integer(152_000)
        near["categories"] = .array([
            .object(["name": .string("System prompt"), "tokens": .integer(3_100), "kind": .string("used")]),
            .object(["name": .string("System tools"), "tokens": .integer(17_900), "kind": .string("used")]),
            .object(["name": .string("Messages"), "tokens": .integer(131_000), "kind": .string("used")]),
            .object(["name": .string("Autocompact buffer"), "tokens": .integer(33_000), "kind": .string("buffer")]),
            .object(["name": .string("Free space"), "tokens": .integer(15_000), "kind": .string("free")])
        ])
        let usage = try XCTUnwrap(ClaudeProtocol.contextUsage(from: .object(near)))
        let summary = try XCTUnwrap(ComposerContextSummary.make(usage: usage, reportsContextWindow: true))
        XCTAssertEqual(summary.severity, .warning)
        try drawDetails("context-claude-near", summary: summary, usage: usage, breakdowns: [],
                        compact: .init(isAvailable: true, unavailableReason: nil, run: {}), height: 300,
                        expected: ["152k / 200k (76%)", L10n.string("Auto-compacts soon"), L10n.string("Compact session")])
    }

    func testCodexContextWindow() throws {
        let tokens = CodexThreadTokenUsage(
            total: CodexTokenUsageBreakdown(inputTokens: 182_000, cachedInputTokens: 120_000, cacheWriteInputTokens: 0,
                                            outputTokens: 9_400, reasoningOutputTokens: 2_100, totalTokens: 191_400),
            last: CodexTokenUsageBreakdown(inputTokens: 61_000, cachedInputTokens: 48_000, cacheWriteInputTokens: 0,
                                           outputTokens: 3_000, reasoningOutputTokens: 800, totalTokens: 64_000),
            modelContextWindow: 256_000)
        let usage = ComposerSessionOptionsProjection.codexContextUsage(tokens)
        let summary = try XCTUnwrap(ComposerContextSummary.make(usage: usage, reportsContextWindow: true))
        try drawDetails("context-codex", summary: summary, usage: usage, breakdowns: ComposerUsageBreakdown.codex(tokens),
                        height: 420, expected: ["64k / 256k (25%)", L10n.string("Last turn"), L10n.string("Cumulative")])
    }

    /// The limit is a menu, so Default fits with the limit it names in the rail's card too. The menu is
    /// not opened; its items are the projection's (`ComposerContextAndConnectorsTests`).
    func testTheContextLimitNamesTheLimitItsDefaultStandsFor() throws {
        let directory = try WindowlessRender.directory("composer-context-qa")
        let usage = try XCTUnwrap(ClaudeProtocol.contextUsage(from: Fixtures.claudeContextUsage))
        let summary = try XCTUnwrap(ComposerContextSummary.make(usage: usage, reportsContextWindow: true))
        let cases: [(name: String, width: CGFloat, isInline: Bool, setting: UInt64?)] = [
            ("context-limit", 340, false, 600_000), ("context-limit-rail", 232, true, 600_000),
            ("context-limit-rail-claude", 232, true, nil)
        ]
        for (name, width, isInline, setting) in cases {
            let slot = ComposerContextLimitSlot.claude(saved: nil, defaultLimit: setting, appliesLater: false)
            let defaultName = setting == nil ? L10n.string("Default (Claude Code)") : L10n.format("Default (%@)", "600k")
            let size = NSSize(width: width, height: 340)
            func details() -> some View {
                ComposerContextUsageDetails(summary: summary, usage: usage, breakdowns: [],
                                            limit: .init(slot: slot, choose: { _ in }), isInline: isInline)
                    .frame(width: size.width, height: size.height, alignment: .top)
            }
            let captures = try WindowlessRender.hostedInBothAppearances(name, in: directory, size: size) { appearance in
                details()
                    .environment(\.colorScheme, appearance.colorScheme)
                    .background(isInline ? ParityTheme.canvas : ParityTheme.elevated)
            }
            for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
            let host = WindowlessRender.Host(details(), size: size)
            defer { host.close() }
            host.settle()
            XCTAssertTrue(host.accessibilityElements().contains {
                $0.role == NSAccessibility.Role.popUpButton.rawValue && $0.label == L10n.string("Context limit")
                    && $0.value == defaultName }, "\(name): \(host.accessibilityElements())")
        }
    }

    func testContextWindowBeforeTheFirstTurn() throws {
        let summary = try XCTUnwrap(ComposerContextSummary.make(usage: nil, reportsContextWindow: true))
        try drawDetails("context-empty", summary: summary, usage: nil, breakdowns: [], height: 110,
                        expected: [L10n.string("Send a message to see context usage.")])
    }

    func testConnectorsMenu() throws {
        let directory = try WindowlessRender.directory("composer-context-qa")
        let servers = try XCTUnwrap(ClaudeMCPServers.fromInit(Fixtures.claudeInit))
        let list = try XCTUnwrap(ComposerConnectorList.make(
            ComposerConnectorsSlot(sessionServers: servers, carriesYardletConnectors: true),
            connectors: Fixtures.yardletConnectors))
        let size = NSSize(width: 600, height: 420)
        let content = HStack(alignment: .top, spacing: 16) {
            // The "+" menu as it opens: its items, "Connectors" last with its hint.
            ComposerMenuList(entries: ComposerPlusMenu.entries(
                carriesImages: true, connectors: list,
                actions: .init(addFiles: {}, addFolder: {}, openCommands: {}, openConnectors: {})), onDismiss: {})
                .background(ParityTheme.elevated, in: RoundedRectangle(cornerRadius: 10))
            ComposerConnectorsMenu(list: list, onManage: {}, onBack: {})
                .background(ParityTheme.elevated, in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(12)
        let captures = try WindowlessRender.hostedInBothAppearances("connectors-menu", in: directory, size: size) { appearance in
            content
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(ParityTheme.canvas)
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
        let host = WindowlessRender.Host(content.frame(width: size.width, height: size.height, alignment: .topLeading),
                                         size: size)
        defer { host.close() }
        host.settle()
        let spoken = host.accessibilityElements().map { "\($0.label) \($0.value)" }
        for text in [L10n.string("Connectors"), L10n.format("%lld need reconnection", Int64(3)),
                     L10n.string("Manage connectors"), "github", L10n.string("Needs authentication"),
                     L10n.string("Turned off for this project")] {
            XCTAssertTrue(spoken.contains { $0.contains(text) }, "No \(text): \(spoken)")
        }
        XCTAssertFalse(spoken.contains { $0.hasPrefix("yardlet ") }, "The server carrying Yardlet's connectors is not listed")
    }

    func testTheRingSitsBesideTheModelMenu() throws {
        let directory = try WindowlessRender.directory("composer-context-qa")
        let usage = try XCTUnwrap(ClaudeProtocol.contextUsage(from: Fixtures.claudeContextUsage))
        let size = NSSize(width: 760, height: 150)
        let captures = try WindowlessRender.hostedInBothAppearances("composer-ring", in: directory, size: size) { appearance in
            PromptComposer(harness: .claudeCode, composerDraft: TaskComposerDraft(), providerUsage: usage, isRunning: false)
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height, alignment: .bottom)
                .background(ParityTheme.canvas)
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
        let host = WindowlessRender.Host(
            PromptComposer(harness: .claudeCode, composerDraft: TaskComposerDraft(), providerUsage: usage, isRunning: false)
                .frame(width: size.width, height: size.height, alignment: .bottom), size: size)
        defer { host.close() }
        host.settle()
        let ring = host.accessibilityElements().first { $0.label == L10n.string("Context window") }
        XCTAssertEqual(ring?.value, "95.1k / 200k (48%)")
    }
}
