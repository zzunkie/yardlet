import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// The composer's context ring and connector list for every harness, in the Claude app's Code
/// composer form (2.37337.1) and words. No provider, process or network.
@MainActor
final class ComposerContextAndConnectorsTests: XCTestCase {
    // MARK: Context

    /// Claude Code 2.1.293's `get_context_usage` answer (`detail: "summary"` carries the same fields).
    static let claudeContextUsage: JSONValue = {
        func category(_ name: String, _ tokens: Int64, _ kind: String? = nil) -> JSONValue {
            var row: [String: JSONValue] = ["name": .string(name), "tokens": .integer(tokens), "color": .string("inactive")]
            if let kind { row["kind"] = .string(kind) }
            return .object(row)
        }
        return .object([
            "categories": .array([
                category("System prompt", 3_100, "used"), category("System tools", 17_900, "used"),
                category("MCP tools", 6_200, "used"), category("Custom agents", 900, "used"),
                category("Memory files", 4_300, "used"), category("Skills", 1_200, "used"),
                category("Messages", 61_500, "used"), category("Autocompact buffer", 33_000, "buffer"),
                category("Free space", 71_900, "free"),
                // A CLI that sends no kind: the Claude app's name rule decides.
                .object(["name": .string("MCP tools (deferred)"), "tokens": .integer(2_400), "isDeferred": .bool(true)])
            ]),
            "totalTokens": .integer(95_100), "maxTokens": .integer(200_000), "rawMaxTokens": .integer(200_000),
            "percentage": .integer(48), "autoCompactThreshold": .integer(167_000), "isAutoCompactEnabled": .bool(true),
            "autocompactSource": .string("model-default"), "model": .string("claude-opus-5-5")
        ])
    }()

    func testClaudeContextUsageReadsTheWindowCategoriesAndAutoCompact() throws {
        let usage = try XCTUnwrap(ClaudeProtocol.contextUsage(from: Self.claudeContextUsage))
        XCTAssertEqual(usage.contextUsedTokens, 95_100)
        XCTAssertEqual(usage.contextWindowTokens, 200_000)
        let summary = try XCTUnwrap(ComposerContextSummary.make(usage: usage, reportsContextWindow: true))
        XCTAssertEqual(summary.summaryText, "95.1k / 200k (48%)")
        XCTAssertEqual(summary.help, L10n.format("Context %@", "95.1k / 200k (48%)"))
        XCTAssertEqual(summary.severity, .normal)
        XCTAssertFalse(summary.offersCompact, "Compact session waits for half the window")
        // 167k − 95.1k = 71.9k, rounded down to two digits.
        XCTAssertEqual(summary.autoCompactHint, L10n.format("%@ until auto-compact", "71k"))

        // Largest first, then the buffer, the free space and what is not loaded.
        XCTAssertEqual(summary.legend.map(\.name), [
            "Messages", "System tools", "MCP tools", "Memory files", "System prompt", "Skills", "Custom agents",
            "Autocompact buffer", "Free space", "MCP tools (deferred)"
        ])
        XCTAssertEqual(summary.legend.first?.tokensText, "61.5k")
        XCTAssertEqual(summary.legend.first?.shareText, "30.8%")
        XCTAssertEqual(summary.legend.last?.shareText, "—")
        XCTAssertEqual(summary.legend.last?.kind, .deferred)
        // The meter: five categories, the other two as "Other", then the buffer.
        XCTAssertEqual(summary.meter.map(\.kind), [
            .used(colorIndex: 0), .used(colorIndex: 1), .used(colorIndex: 2), .used(colorIndex: 3), .used(colorIndex: 4),
            .other, .buffer
        ])
        XCTAssertEqual(summary.meter[5].fraction, 2_100.0 / 200_000, accuracy: 0.000_001)

        // A CLI that sends only `maxTokens` keeps working.
        var older = Self.claudeContextUsage.objectValue ?? [:]
        older.removeValue(forKey: "rawMaxTokens")
        XCTAssertEqual(ClaudeProtocol.contextUsage(from: .object(older))?.contextWindowTokens, 200_000)
    }

    func testTheRingWarnsAt75AndIsCriticalAt90AsTheClaudeAppDoes() {
        func summary(_ used: UInt64) -> ComposerContextSummary? {
            ComposerContextSummary.make(usage: usage(used: used, window: 200_000), reportsContextWindow: false)
        }
        XCTAssertEqual(summary(148_000)?.severity, .normal)    // 74%
        XCTAssertEqual(summary(150_000)?.severity, .warning)   // 75%
        XCTAssertEqual(summary(178_000)?.severity, .warning)   // 89%
        XCTAssertEqual(summary(180_000)?.severity, .critical)  // 90%
        XCTAssertEqual(summary(98_000)?.offersCompact, false)  // 49%
        XCTAssertEqual(summary(100_000)?.offersCompact, true)  // 50%
        XCTAssertEqual(ComposerContextSummary.tokenText(950), "950")
        XCTAssertEqual(ComposerContextSummary.tokenText(1_000), "1k")
        XCTAssertEqual(ComposerContextSummary.tokenText(45_230), "45.2k")
        XCTAssertEqual(ComposerContextSummary.tokenText(1_500_000), "1.5M")
        XCTAssertEqual(ComposerContextSummary.roundedDownToTwoDigits(71_900), 71_000)
        XCTAssertEqual(ComposerContextSummary.roundedDownToTwoDigits(123_456), 120_000)
    }

    func testAutoCompactIsSoonWithin30kAndSilentWhenOff() {
        let near = HarnessContextBreakdown(categories: [.init(name: "Autocompact buffer", tokens: 33_000, kind: .buffer)],
                                           windowTokens: 200_000, autoCompactThresholdTokens: 167_000,
                                           isAutoCompactEnabled: true)
        XCTAssertEqual(ComposerContextSummary.autoCompactHint(near, used: 150_000, window: 200_000),
                       L10n.string("Auto-compacts soon"))
        // Without a reported threshold: the window less the buffer.
        var noThreshold = near
        noThreshold.autoCompactThresholdTokens = nil
        XCTAssertEqual(ComposerContextSummary.autoCompactHint(noThreshold, used: 100_000, window: 200_000),
                       L10n.format("%@ until auto-compact", "67k"))
        // An API that compacts by itself keeps no buffer and compacts at the window.
        let auto = HarnessContextBreakdown(categories: [], windowTokens: 200_000, isAutoCompactEnabled: true,
                                           autoCompactSource: "auto")
        XCTAssertEqual(ComposerContextSummary.autoCompactHint(auto, used: 100_000, window: 200_000),
                       L10n.format("%@ until auto-compact", "100k"))
        var off = near
        off.isAutoCompactEnabled = false
        XCTAssertNil(ComposerContextSummary.autoCompactHint(off, used: 150_000, window: 200_000))
    }

    /// One ring for every harness that reports a window; none where it reports none.
    func testEveryHarnessThatReportsAWindowGetsTheSameRing() throws {
        // Claude Code and Codex before their first report: the empty ring and the Claude app's words.
        let empty = try XCTUnwrap(ComposerContextSummary.make(usage: nil, reportsContextWindow: true))
        XCTAssertNil(empty.percent)
        XCTAssertEqual(empty.help, L10n.string("Send a message to see context usage."))

        // Codex: the last turn against the model window.
        let codexUsage = CodexThreadTokenUsage(
            total: CodexTokenUsageBreakdown(inputTokens: 182_000, cachedInputTokens: 120_000, cacheWriteInputTokens: 0,
                                            outputTokens: 9_400, reasoningOutputTokens: 2_100, totalTokens: 191_400),
            last: CodexTokenUsageBreakdown(inputTokens: 61_000, cachedInputTokens: 48_000, cacheWriteInputTokens: 0,
                                           outputTokens: 3_000, reasoningOutputTokens: 800, totalTokens: 64_000),
            modelContextWindow: 256_000)
        let codex = ComposerSessionOptionsProjection.make(harness: .codex, session: nil, providerCapabilities: nil,
                                                          providerUsage: nil, codexTokenUsage: codexUsage, isAttached: true)
        XCTAssertEqual(ComposerContextSummary.make(usage: codex.contextUsage, reportsContextWindow: codex.reportsContextWindow)?
            .summaryText, "64k / 256k (25%)")
        XCTAssertEqual(codex.compact, .codexCommand)
        // A Codex model without a window: no ring rather than a guess.
        let windowless = CodexThreadTokenUsage(total: codexUsage.total, last: codexUsage.last, modelContextWindow: nil)
        let codexWithoutWindow = ComposerSessionOptionsProjection.make(
            harness: .codex, session: nil, providerCapabilities: nil, providerUsage: nil,
            codexTokenUsage: windowless, isAttached: true)
        XCTAssertNil(ComposerContextSummary.make(usage: codexWithoutWindow.contextUsage,
                                                 reportsContextWindow: codexWithoutWindow.reportsContextWindow))

        // Pi's `get_session_stats` `contextUsage` is `{tokens, contextWindow, percent}`.
        let pi = PiRPCEventProjector().usage(from: .object([
            "tokens": .object(["input": .integer(1_200), "output": .integer(300)]),
            "contextUsage": .object(["tokens": .integer(41_000), "contextWindow": .integer(200_000), "percent": .number(20.5)])
        ]))
        XCTAssertEqual(pi?.contextUsedTokens, 41_000)
        XCTAssertEqual(ComposerContextSummary.make(usage: pi, reportsContextWindow: false)?.summaryText, "41k / 200k (21%)")

        // Cursor reports tokens but no window: nothing.
        let cursor = ComposerSessionOptionsProjection.make(
            harness: .cursorAgent, session: nil, providerCapabilities: nil,
            providerUsage: HarnessProtocolUsage(inputTokens: 900, cachedInputTokens: nil, outputTokens: 40,
                reasoningTokens: nil, totalCostUSD: nil, contextWindowTokens: nil, contextUsedTokens: nil,
                extensionValues: [:]), isAttached: true)
        XCTAssertNil(ComposerContextSummary.make(usage: cursor.contextUsage, reportsContextWindow: cursor.reportsContextWindow))

        let claude = ComposerSessionOptionsProjection.make(harness: .claudeCode, session: nil, providerCapabilities: nil,
                                                           providerUsage: nil, isAttached: true)
        XCTAssertTrue(claude.reportsContextWindow)
        XCTAssertEqual(claude.compact, .providerCommand("/compact"))
    }

    /// The Korean words are the Claude app's own (`ko-KR.json`).
    func testKoreanWordingIsTheClaudeApps() {
        let expected: [String: String] = [
            "Context window": "컨텍스트 윈도우",
            "Context %@": "컨텍스트 %@",
            "%@ until auto-compact": "자동 압축까지 %@ 토큰 남음",
            "Auto-compacts soon": "곧 자동 압축됨",
            "Send a message to see context usage.": "컨텍스트 사용량을 확인하려면 메시지를 보내세요.",
            "Compact session": "세션 압축",
            "Available when reconnected": "다시 연결되면 사용할 수 있습니다",
            "Connectors": "커넥터",
            "Manage connectors": "커넥터 관리",
            "Connected": "연결됨",
            "Needs authentication": "인증 필요",
            "Failed": "실패",
            "Connecting…": "연결 중…",
            "Turned off for this project": "이 프로젝트에서 꺼짐",
            "%lld need reconnection": "%lld개 재연결 필요"
        ]
        for (key, korean) in expected {
            XCTAssertEqual(L10n.string(key, languageCode: "ko"), korean, key)
            XCTAssertNotEqual(L10n.string(key, languageCode: "en"), "", key)
        }
    }

    // MARK: Connectors

    static let claudeInit: JSONValue = .object([
        "type": .string("system"), "subtype": .string("init"), "session_id": .string("s-1"),
        "mcp_servers": .array([
            .object(["name": .string("yardlet"), "status": .string("connected")]),
            .object(["name": .string("github"), "status": .string("failed")]),
            .object(["name": .string("linear"), "status": .string("needs-auth")]),
            .object(["name": .string("claude.ai Gmail"), "status": .string("connected")]),
            .object(["name": .string("notion"), "status": .string("pending")]),
            .object(["name": .string("slack"), "status": .string("disabled")])
        ])
    ])

    static let yardletConnectors: [ConnectorRecord] = [
        ConnectorRecord(name: "Linear", slug: "linear", serverURL: URL(string: "https://mcp.linear.app/mcp")!,
                        authorization: .oauth, status: .connected,
                        tools: [.object(["name": .string("linear_list_issues")]),
                                .object(["name": .string("linear_get_issue")])]),
        ConnectorRecord(name: "Sentry", slug: "sentry", serverURL: URL(string: "https://mcp.sentry.dev/mcp")!,
                        authorization: .oauth, status: .signInRequired),
        ConnectorRecord(name: "Notion", slug: "notion", serverURL: URL(string: "https://mcp.notion.com/mcp")!)
    ]

    func testClaudeConnectorsListTheSessionsServersAndYardletsConnectors() throws {
        let servers = try XCTUnwrap(ClaudeMCPServers.fromInit(Self.claudeInit))
        var capabilities = ProviderCapabilityState()
        capabilities.mcpServers = servers
        let options = ComposerSessionOptionsProjection.make(harness: .claudeCode, session: nil,
                                                            providerCapabilities: capabilities, providerUsage: nil,
                                                            isAttached: true)
        let list = try XCTUnwrap(ComposerConnectorList.make(options.connectors, connectors: Self.yardletConnectors))
        // Those that need the user first; the `yardlet` server carrying the connectors is not listed.
        XCTAssertEqual(list.rows.map(\.name), ["Sentry", "github", "linear", "Linear", "Notion", "claude.ai Gmail",
                                               "notion", "slack"])
        XCTAssertEqual(list.rows.map(\.statusText), [
            L10n.string("Needs authentication"), L10n.string("Failed"), L10n.string("Needs authentication"),
            L10n.format("Connected · %lld tools", Int64(2)), L10n.string("Not connected"), L10n.string("Connected"),
            L10n.string("Connecting…"), L10n.string("Turned off for this project")
        ])
        XCTAssertEqual(list.rows.map(\.source), [.yardlet, .session, .session, .yardlet, .yardlet, .session, .session,
                                                 .session])
        XCTAssertEqual(list.needsReconnectionCount, 3)
        XCTAssertEqual(list.hint, L10n.format("%lld need reconnection", Int64(3)))
    }

    /// When the harness reports the `yardlet` server down, the connectors it carries are down too.
    func testYardletsConnectorsFollowTheServerThatCarriesThem() throws {
        let slot = ComposerConnectorsSlot(sessionServers: [HarnessMCPServerStatus(name: "yardlet", state: .failed)],
                                          carriesYardletConnectors: true)
        let list = try XCTUnwrap(ComposerConnectorList.make(slot, connectors: Self.yardletConnectors))
        XCTAssertEqual(list.rows.first { $0.name == "Linear" }?.state, .failed)
        XCTAssertEqual(list.rows.first { $0.name == "Sentry" }?.state, .needsAuthentication)
        let pending = ComposerConnectorList.make(ComposerConnectorsSlot(
            sessionServers: [HarnessMCPServerStatus(name: "yardlet", state: .pending)], carriesYardletConnectors: true),
            connectors: Self.yardletConnectors)
        XCTAssertEqual(pending?.rows.first { $0.name == "Linear" }?.state, .pending)
        // Before the harness reports anything, each connector shows its own state.
        let unreported = ComposerConnectorList.make(ComposerConnectorsSlot(sessionServers: nil,
                                                                           carriesYardletConnectors: true),
                                                    connectors: Self.yardletConnectors)
        XCTAssertEqual(unreported?.rows.first { $0.name == "Linear" }?.state, .connected)
        XCTAssertEqual(ComposerConnectorList.make(ComposerConnectorsSlot(sessionServers: nil,
                                                                         carriesYardletConnectors: true),
                                                  connectors: [])?.rows, [],
                       "With nothing connected the list is only Manage connectors")
    }

    func testCodexMCPServerStatusListDecodes() {
        let page = CodexMCPServers.decode(.object([
            "data": .array([
                .object(["name": .string("yardlet"), "runtimeStatus": .string("connected"), "authStatus": .string("unsupported"),
                         "tools": .object(["browser_snapshot": .object([:])]), "toolsError": .null]),
                .object(["name": .string("figma"), "runtimeStatus": .string("authenticationRequired"),
                         "authStatus": .string("notLoggedIn"), "tools": .object([:])]),
                .object(["name": .string("docs"), "runtimeStatus": .string("starting"), "authStatus": .string("unsupported")]),
                // 0.157.1 without a running thread: no runtime status, so sign-in and errors decide.
                .object(["name": .string("linear"), "runtimeStatus": .null, "authStatus": .string("notLoggedIn")]),
                .object(["name": .string("broken"), "runtimeStatus": .null, "authStatus": .string("unsupported"),
                         "toolsError": .string("spawn failed")]),
                .object(["name": .string("bank"), "runtimeStatus": .null, "authStatus": .string("oAuth"),
                         "tools": .object(["a": .object([:]), "b": .object([:])])])
            ]),
            "nextCursor": .string("next")
        ]))
        XCTAssertEqual(page.nextCursor, "next")
        XCTAssertEqual(page.servers.map(\.state), [.connected, .needsAuthentication, .pending, .needsAuthentication,
                                                   .failed, .connected])
        XCTAssertEqual(page.servers.map(\.toolCount), [1, nil, nil, nil, nil, 2])
        XCTAssertEqual(CodexMCPServers.listParams(threadID: "t-1", cursor: nil), .object([
            "cursor": .null, "limit": .integer(100), "detail": .string("toolsAndAuthOnly"), "threadId": .string("t-1")
        ]))

        let options = ComposerSessionOptionsProjection.make(
            harness: .codex, session: nil,
            codexCapabilities: { var state = CodexCapabilityState(); state.mcpServers = page.servers; return state }(),
            providerCapabilities: nil, providerUsage: nil, isAttached: true)
        let list = ComposerConnectorList.make(options.connectors, connectors: [])
        XCTAssertEqual(list?.rows.map(\.name), ["figma", "linear", "broken", "docs", "bank"])
    }

    /// Every harness that takes the Yardlet MCP server per session lists Yardlet's connectors
    /// (Antigravity among them, over ACP); one that takes no server and reports none has no list.
    func testWhichHarnessesListConnectors() {
        for harness in HarnessCatalog.builtIns.map(\.id) {
            let options = ComposerSessionOptionsProjection.make(harness: harness, session: nil, providerCapabilities: nil,
                                                                providerUsage: nil, isAttached: true)
            let carries = AgentToolInjectionRoute.route(for: harness) != nil
            XCTAssertEqual(options.connectors?.carriesYardletConnectors ?? false, carries, harness.rawValue)
            let list = ComposerConnectorList.make(options.connectors, connectors: Self.yardletConnectors)
            XCTAssertEqual(list != nil, carries, harness.rawValue)
        }
        XCTAssertEqual(AgentToolInjectionRoute.route(for: .antigravityCLI), .acpSessionMCPServers)
        XCTAssertNil(ComposerSessionOptionsProjection.make(harness: .pi, session: nil, providerCapabilities: nil,
                                                           providerUsage: nil, isAttached: true).connectors)
        XCTAssertNotNil(ComposerSessionOptionsProjection.make(harness: .openCode, session: nil, providerCapabilities: nil,
                                                              providerUsage: nil, isAttached: true).connectors)
    }

    private func usage(used: UInt64, window: UInt64) -> HarnessProtocolUsage {
        HarnessProtocolUsage(inputTokens: nil, cachedInputTokens: nil, outputTokens: nil, reasoningTokens: nil,
                             totalCostUSD: nil, contextWindowTokens: window, contextUsedTokens: used, extensionValues: [:])
    }
}
