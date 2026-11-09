import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The Codex app's `/status` command in a Codex task: where it is listed, the read-only
/// `account/rateLimits/read` it sends, and the panel's rows built from the task's thread, context
/// and the account's rate limits.
@MainActor
final class CodexStatusPanelTests: XCTestCase {
    private let english = CodexStatusProjection.Words(languageCode: "en", locale: Locale(identifier: "en_US"))
    private let korean = CodexStatusProjection.Words(languageCode: "ko", locale: Locale(identifier: "ko_KR"))
    private let now = Date(timeIntervalSince1970: 1_791_000_000)

    // MARK: - Command

    func testStatusIsListedInEveryCodexComposerWithTheAppWording() {
        var context = CodexComposerCommandContext(hasThread: true, workspaceURL: URL(filePath: "/tmp/codex-status"))
        let changes: [(inout CodexComposerCommandContext) -> Void] = [
            { $0.isRunning = true }, { $0.hasDraftContent = true }, { $0.hasThread = false }, { $0.isGitRepository = false }
        ]
        for change in changes {
            change(&context)
            let row = CodexComposerCommands.catalog(context).first { $0.name == "status" }
            XCTAssertEqual(row?.title, L10n.string("Status slash command"), "Status is not limited by a running turn, draft text or thread")
            XCTAssertEqual(row?.description, L10n.string("Show chat ID, context usage, and rate limits"))
            XCTAssertEqual(row.flatMap { CodexComposerCommands.command(for: $0, in: context) }, .status)
        }
        XCTAssertFalse(CodexComposerCommand.status.requiresEmptyComposer)
        let titles = CodexComposerCommands.catalog(context).filter { $0.group == nil }.map(\.displayTitle)
        XCTAssertEqual(titles, titles.sorted(), "Status sorts by its title with the others")
        XCTAssertEqual(ComposerCommands.matching(CodexComposerCommands.catalog(context), query: "status").first?.name, "status")
        XCTAssertFalse(CodexComposerCommands.isBuiltin("/status"), "Only the list runs it, as the other Codex app commands")

        let wording: [(String, String, String)] = [
            ("Status slash command", "Status", "상태"),
            ("Show chat ID, context usage, and rate limits", "Show chat ID, context usage, and rate limits",
             "채팅 ID, 컨텍스트 사용량, 속도 제한을 표시합니다"),
            ("Status panel", "Status", "상태"), ("Close", "Close", "닫기"),
            ("Session/Thread:", "Session/Thread:", "세션/대화:"), ("Session:", "Session:", "세션:"),
            ("Thread:", "Thread:", "대화:"), ("Threads:", "Threads:", "대화:"),
            ("Collapse thread list", "Collapse thread list", "대화 목록 접기"),
            ("Context:", "Context:", "컨텍스트:"), ("Rate limit:", "Rate limit:", "요금 한도:"),
            ("Unavailable", "Unavailable", "사용할 수 없음"), ("Alert:", "Alert:", "경고:"),
            ("reset time unavailable", "reset time unavailable", "초기화 시간 사용할 수 없음")
        ]
        for (key, en, ko) in wording {
            XCTAssertEqual(L10n.string(key, languageCode: "en"), en, key)
            XCTAssertEqual(L10n.string(key, languageCode: "ko"), ko, key)
        }
        XCTAssertEqual(korean.format("Show %lld more threads", Int64(3)), "대화 3개 더 보기")
        XCTAssertEqual(english.format("Show %lld more threads", Int64(3)), "Show 3 more threads")
    }

    // MARK: - Native request

    func testStatusReadsTheTaskAccountRateLimitsWithoutATurnThroughBothRoutes() async throws {
        for routed in [false, true] {
            let fixture = try CommandFixture(routed: routed)
            defer { fixture.cleanup() }
            let model = fixture.model, session = fixture.session
            await model.prepareCodexComposerCommands(for: session)
            await fixture.transport.enqueue(method: "account/rateLimits/read", result: rateLimitResponse())
            let draft = model.composerDrafts.tasks.draft(for: session.id)
            draft.text = "keep this"

            await model.runCodexComposerCommand(.status, in: try current(model, session))
            let reading = try XCTUnwrap(model.codexStatusBySessionID[session.id])
            XCTAssertFalse(reading.isReading)
            XCTAssertEqual(reading.rateLimits?.general?.primary, CodexRateLimitWindow(
                usedPercent: 36, windowDurationMinutes: 300, resetsAt: Int64(now.timeIntervalSince1970) + 7_200))
            XCTAssertEqual(reading.rateLimits?.models.map(\.limitName), ["GPT-5.3-Codex-Spark"])
            let requests = await fixture.transport.requests
            XCTAssertEqual(requests.filter { $0.method == "account/rateLimits/read" }.map(\.params), [.null])
            XCTAssertFalse(requests.contains { ["turn/start", "thread/start", "turn/steer", "thread/fork"].contains($0.method) })
            XCTAssertEqual(draft.text, "keep this", "Status sends nothing and leaves the draft")
            XCTAssertNil(draft.notice)

            // A later reading that fails keeps the last one; closing forgets the panel.
            await model.runCodexComposerCommand(.status, in: try current(model, session))
            XCTAssertEqual(model.codexStatusBySessionID[session.id]?.rateLimits, reading.rateLimits)
            XCTAssertEqual(model.codexStatusBySessionID[session.id]?.isReading, false)
            model.closeCodexStatus(for: session)
            XCTAssertNil(model.codexStatusBySessionID[session.id])
            await model.shutdown()
        }
    }

    func testATaskWithoutAThreadReadsItsAccountWithoutStartingOne() async throws {
        for routed in [false, true] {
            let fixture = try CommandFixture(routed: routed, providerSessionID: nil)
            defer { fixture.cleanup() }
            await fixture.transport.enqueue(method: "account/rateLimits/read", result: rateLimitResponse())
            await fixture.model.runCodexComposerCommand(.status, in: fixture.session)
            XCTAssertEqual(fixture.model.codexStatusBySessionID[fixture.session.id]?.rateLimits?.general?.secondary?.windowDurationMinutes,
                           10_080)
            let methods = await fixture.transport.requestMethods
            XCTAssertEqual(methods, ["initialize", "account/rateLimits/read"], "No thread is started or resumed")
            XCTAssertFalse(fixture.model.isAttached(fixture.session.id))
            XCTAssertNil(try current(fixture.model, fixture.session).providerSessionID)
            await fixture.model.shutdown()
        }
    }

    func testAnUnreadableAccountShowsUnavailableAndClosingWhileReadingKeepsItClosed() async throws {
        let fixture = try CommandFixture(routed: false, providerSessionID: nil)
        defer { fixture.cleanup() }
        let model = fixture.model, session = fixture.session
        // Signed out or an API key: the App Server answers with an error.
        await model.runCodexComposerCommand(.status, in: session)
        let reading = try XCTUnwrap(model.codexStatusBySessionID[session.id])
        XCTAssertNil(reading.rateLimits)
        XCTAssertFalse(reading.isReading)
        XCTAssertEqual(projection(rateLimits: reading.rateLimits, withContext: false, threadID: nil).rows,
                       [.value(label: "Rate limit:", text: "Unavailable", metadata: nil)])

        await fixture.transport.suspendNextRequest("account/rateLimits/read")
        await fixture.transport.enqueue(method: "account/rateLimits/read", result: rateLimitResponse())
        let open = Task { await model.runCodexComposerCommand(.status, in: session) }
        try await waitUntil { await fixture.transport.isRequestSuspended }
        XCTAssertEqual(model.codexStatusBySessionID[session.id]?.isReading, true)
        XCTAssertEqual(projection(rateLimits: nil, isReading: true).rows.count, 2,
                       "Session and context only: no rate-limit row while the first reading is on its way")
        model.closeCodexStatus(for: session)
        await fixture.transport.releaseSuspendedRequest()
        await open.value
        XCTAssertNil(model.codexStatusBySessionID[session.id], "A panel closed while reading stays closed")
        await model.shutdown()
    }

    // MARK: - Projection

    func testPanelRowsFollowTheCodexAppFieldByField() throws {
        let limits = CodexAccountRateLimits(response: rateLimitResponse())
        let rows = projection(rateLimits: limits).rows
        let resets = { (offset: TimeInterval) in
            CodexStatusProjection.resetTime(self.now.addingTimeInterval(offset), now: self.now, locale: Locale(identifier: "en_US"))
        }
        XCTAssertEqual(rows, [
            .identifiers(label: "Session/Thread:", ids: ["thread-1"]),
            .value(label: "Context:", text: "75% left", metadata: "(64,000 used / 256K)"),
            .rateLimit(label: "5h limit:", remainingPercent: 64, text: "64% left", metadata: "(resets \(resets(7_200)))"),
            .rateLimit(label: "7d limit:", remainingPercent: 88, text: "88% left", metadata: "(resets \(resets(259_200)))"),
            .section("GPT-5.3-Codex-Spark limit:"),
            .rateLimit(label: "5h limit:", remainingPercent: 100, text: "100% left", metadata: "(reset time unavailable)")
        ])

        let koreanRows = projection(rateLimits: limits, words: korean).rows
        let koreanTime = CodexStatusProjection.resetTime(now.addingTimeInterval(7_200), now: now, locale: Locale(identifier: "ko_KR"))
        XCTAssertEqual(Array(koreanRows.prefix(3)), [
            .identifiers(label: "세션/대화:", ids: ["thread-1"]),
            .value(label: "컨텍스트:", text: "75% 남음", metadata: "(64,000 사용/256K)"),
            .rateLimit(label: "5시간 한도:", remainingPercent: 64, text: "64% 남음", metadata: "(\(koreanTime) 초기화)")
        ])
        XCTAssertEqual(koreanRows[4], .section("GPT-5.3-Codex-Spark 한도:"))
        XCTAssertEqual(koreanRows[5], .rateLimit(label: "5시간 한도:", remainingPercent: 100, text: "100% 남음",
                                                 metadata: "(초기화 시간 사용할 수 없음)"))

        // Another model shows only the general limit; so does a task whose model is unknown.
        for model in ["gpt-5.5", nil] {
            let general = projection(rateLimits: limits, selectedModel: model).rows
            XCTAssertFalse(general.contains { if case .section = $0 { return true } else { return false } })
            XCTAssertEqual(general.count, 4)
        }
    }

    /// The shape the installed App Server (codex-cli 0.157.1) returned for a personal account on
    /// 2026-10-08: one weekly window, no second window, and only the general `codex` bucket.
    func testTheInstalledServersWeeklyOnlyResponseShowsOneSevenDayRow() throws {
        let response = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"ordinaryUsageAllowed":true,
         "rateLimits":{"limitId":"codex","limitName":null,"normalModelSlug":null,
           "primary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":1791975634},"secondary":null,
           "credits":{"hasCredits":true,"unlimited":false,"balance":"0"},"individualLimit":null,
           "spendControlReached":false,"planType":"plus","rateLimitReachedType":null},
         "rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":null,"normalModelSlug":null,
           "primary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":1791975634},"secondary":null}},
         "rateLimitResetCredits":{"availableCount":3,"credits":[]},"accountId":"account","rateLimitUpsell":null}
        """#.utf8))
        let limits = CodexAccountRateLimits(response: response)
        XCTAssertEqual(limits.general?.primary?.windowDurationMinutes, 10_080)
        XCTAssertNil(limits.general?.secondary)
        XCTAssertEqual(limits.models, [])
        let rows = projection(rateLimits: limits).rows.filter { if case .rateLimit = $0 { true } else { false } }
        XCTAssertEqual(rows.count, 1)
        guard case let .rateLimit(label, remaining, text, _) = rows.first else { return XCTFail("No limit row") }
        XCTAssertEqual(label, "7d limit:")
        XCTAssertEqual(remaining, 100)
        XCTAssertEqual(text, "100% left")
    }

    func testMissingDataLeavesItsRowOutOrSaysUnavailable() throws {
        // No thread yet, no context reading, and no rate limits read.
        XCTAssertEqual(CodexStatusProjection(threadID: nil, descendantThreadIDs: [], tokenUsage: nil, rateLimits: nil,
                                             selectedModel: nil, now: now, words: english).rows,
                       [.value(label: "Rate limit:", text: "Unavailable", metadata: nil)])
        // A context reading without the model window says nothing about what is left.
        XCTAssertEqual(CodexStatusProjection(threadID: "t", descendantThreadIDs: [],
                                             tokenUsage: usage(last: 1_000, window: nil), rateLimits: nil,
                                             isReadingRateLimits: true, selectedModel: nil, words: english).rows,
                       [.identifiers(label: "Session/Thread:", ids: ["t"])])
        // A full window, a window under 1,000 tokens, and usage past the window.
        func context(_ last: Int64, _ window: Int64) -> CodexStatusProjection.Row? {
            CodexStatusProjection(threadID: nil, descendantThreadIDs: [], tokenUsage: usage(last: last, window: window),
                                  rateLimits: nil, isReadingRateLimits: true, selectedModel: nil, words: english).rows.first
        }
        XCTAssertEqual(context(300_000, 272_000), .value(label: "Context:", text: "0% left", metadata: "(272,000 used / 272K)"))
        XCTAssertEqual(context(100, 400), .value(label: "Context:", text: "75% left", metadata: "(100 used / 400)"))
        XCTAssertEqual(context(1_234, 128_000), .value(label: "Context:", text: "99% left", metadata: "(1,234 used / 128K)"))

        // Windows without a length are not listed; a nearly spent one is still mentioned.
        let unlisted = CodexAccountRateLimits(general: CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 93, windowDurationMinutes: nil, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 40, windowDurationMinutes: 0, resetsAt: nil)))
        XCTAssertEqual(projection(rateLimits: unlisted, withContext: false, threadID: nil).rows, [
            .value(label: "Rate limit:", text: "Unavailable", metadata: nil), .spacer,
            .value(label: "Alert:", text: "7% left on Rate limit", metadata: nil)
        ])
        XCTAssertEqual(projection(rateLimits: unlisted, withContext: false, threadID: nil, words: korean).rows.last,
                       .value(label: "경고:", text: "요금 한도에 7% 남음", metadata: nil))
        // An over-spent window has nothing left; an empty response is unavailable.
        let spent = CodexAccountRateLimits(general: CodexRateLimitSnapshot(
            primary: CodexRateLimitWindow(usedPercent: 130, windowDurationMinutes: 300, resetsAt: Int64(now.timeIntervalSince1970))))
        XCTAssertEqual(projection(rateLimits: spent, withContext: false, threadID: nil).rows,
                       [.rateLimit(label: "5h limit:", remainingPercent: 0, text: "0% left", metadata: "(resets now)")])
        XCTAssertEqual(CodexAccountRateLimits(response: .object([:])), CodexAccountRateLimits(general: nil))
    }

    func testSessionThreadAndSubagentIdentifiers() {
        func ids(session: String?, thread: String?, descendants: [String]) -> [CodexStatusProjection.Row] {
            CodexStatusProjection(sessionID: session, threadID: thread, descendantThreadIDs: descendants, tokenUsage: nil,
                                  rateLimits: nil, isReadingRateLimits: true, selectedModel: nil, words: english).rows
        }
        XCTAssertEqual(ids(session: "root", thread: "root", descendants: []), [.identifiers(label: "Session/Thread:", ids: ["root"])])
        XCTAssertEqual(ids(session: "root", thread: "root", descendants: ["child"]),
                       [.identifiers(label: "Session:", ids: ["root"]), .identifiers(label: "Thread:", ids: ["child"])])
        XCTAssertEqual(ids(session: "root", thread: "fork", descendants: ["a", "b", "a"]),
                       [.identifiers(label: "Session:", ids: ["root"]), .identifiers(label: "Threads:", ids: ["fork", "a", "b"])])
        XCTAssertEqual(ids(session: nil, thread: "only", descendants: []), [.identifiers(label: "Session/Thread:", ids: ["only"])])

        // Spawned agents come from the thread's own items, in the order they started.
        let state = taskState(items: [
            .collaboration(CodexCollaborationItem(tool: "spawnAgent", status: "completed", senderThreadID: "root",
                receiverThreadIDs: ["agent-1", "agent-2"], prompt: nil, model: nil, reasoningEffort: nil, agentStates: [:])),
            .collaboration(CodexCollaborationItem(tool: "sendInput", status: "completed", senderThreadID: "root",
                receiverThreadIDs: ["agent-9"], prompt: nil, model: nil, reasoningEffort: nil, agentStates: [:])),
            .subagentActivity(CodexSubagentActivityItem(agentThreadID: "agent-3", agentPath: "/a", kind: "started")),
            .subagentActivity(CodexSubagentActivityItem(agentThreadID: "agent-1", agentPath: "/a", kind: "completed"))
        ])
        XCTAssertEqual(CodexStatusProjection.descendantThreadIDs(in: state), ["agent-1", "agent-2", "agent-3"])
        XCTAssertEqual(CodexStatusProjection.descendantThreadIDs(in: nil), [])
    }

    func testWindowNamesAndResetTimesFollowTheCodexApp() {
        let labels: [(Int64?, String)] = [(nil, "Rate limit"), (0, "Rate limit"), (300, "5h limit"), (290, "5h limit"),
            (60, "1h limit"), (120, "2h limit"), (90, "90m limit"), (1_440, "1d limit"), (10_080, "7d limit"),
            (43_200, "1mo limit"), (86_400, "2mo limit"), (525_600, "1y limit")]
        for (minutes, label) in labels {
            XCTAssertEqual(CodexStatusProjection.windowLabel(minutes: minutes, words: english), label, "\(String(describing: minutes))")
        }
        XCTAssertEqual(CodexStatusProjection.windowLabel(minutes: 10_080, words: korean), "7일 한도")
        XCTAssertEqual(CodexStatusProjection.windowLabel(minutes: 300, words: korean), "5시간 한도")
        XCTAssertEqual(CodexStatusProjection.windowLabel(minutes: 43_200, words: korean), "1개월 한도")

        let en = Locale(identifier: "en_US"), ko = Locale(identifier: "ko_KR")
        XCTAssertEqual(CodexStatusProjection.resetTime(now, now: now, locale: en), "now")
        XCTAssertEqual(CodexStatusProjection.resetTime(now.addingTimeInterval(-60), now: now, locale: ko), "지금")
        let soon = now.addingTimeInterval(3 * 3_600)
        XCTAssertEqual(CodexStatusProjection.resetTime(soon, now: now, locale: en),
                       soon.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(en)))
        let later = now.addingTimeInterval(86_400)
        let date = CodexStatusProjection.resetTime(later, now: now, locale: en)
        XCTAssertEqual(date, later.formatted(Date.FormatStyle().month(.abbreviated).day().locale(en)))
        XCTAssertFalse(date.contains(":"), "A day or more away reads as a date")
        XCTAssertEqual(CodexStatusProjection.normalizedLimitName(" GPT_5.3 Codex-Spark "), "gpt-5-3-codex-spark")
    }

    // MARK: - Rendering

    /// The panel alone, and attached above a composer card, drawn without a window.
    func testWindowlessPanelRenderInLightAndDark() throws {
        let directory = try WindowlessRender.directory("codex-status-qa")
        let limits = CodexAccountRateLimits(response: rateLimitResponse())
        for (language, words) in [("en", english), ("ko", korean)] {
            let full = projection(rateLimits: limits, words: words)
            let agents = CodexStatusProjection(sessionID: "019a1f2c-7d4e-7c3a-9f10-6b2d8e4c1a55", threadID: "019a1f2c-7d4e-7c3a-9f10-6b2d8e4c1a55",
                descendantThreadIDs: (1...7).map { "019a1f2d-0000-7000-8000-00000000000\($0)" }, tokenUsage: nil,
                rateLimits: CodexAccountRateLimits(general: nil), selectedModel: nil, now: now, words: words)
            for appearance in [ColorScheme.light, .dark] {
                let suffix = "\(language)-\(appearance == .dark ? "dark" : "light")"
                try render(VStack(spacing: 0) {
                    CodexStatusPanel(projection: full, onClose: {}).attachedAboveComposer()
                    composerStandIn.zIndex(1)
                }, width: 820, appearance: appearance, to: directory.appending(path: "panel-attached-\(suffix).png"))
                try render(CodexStatusPanel(projection: agents, onClose: {}).padding(8), width: 640, appearance: appearance,
                           to: directory.appending(path: "panel-subagents-unavailable-\(suffix).png"))
            }
        }
    }

    /// The panel above the real Codex composer, and a narrow panel that drops its bars once laid
    /// out, in an unshown window.
    func testPanelAboveTheRealComposerAndNarrowInAnUnshownWindow() throws {
        let limits = CodexAccountRateLimits(response: rateLimitResponse())
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .darkAqua ? "dark" : "light"
            try snapshot(VStack(spacing: 0) {
                Spacer(minLength: 0)
                CodexStatusPanel(projection: projection(rateLimits: limits), onClose: {}).attachedAboveComposer()
                PromptComposer(harness: .codex, composerDraft: TaskComposerDraft(), isRunning: false,
                               codexHasThread: true, actions: ComposerActions(runCodexCommand: { _ in }))
                    .zIndex(1)
            }, size: CGSize(width: 820, height: 420), appearance: appearance, name: "composer-\(suffix).png")
            for (language, words) in [("en", english), ("ko", korean)] {
                try snapshot(VStack {
                    CodexStatusPanel(projection: projection(rateLimits: limits, words: words), onClose: {})
                    Spacer(minLength: 0)
                }.padding(8), size: CGSize(width: 380, height: 300), appearance: appearance,
                    name: "panel-narrow-\(language)-\(suffix).png")
            }
        }
    }

    // MARK: - Fixtures

    /// The composer card's own shape, so the tray's tuck under it shows without a window.
    private var composerStandIn: some View {
        RoundedRectangle(cornerRadius: ParityTheme.composerCornerRadius)
            .fill(ParityTheme.input)
            .overlay { RoundedRectangle(cornerRadius: ParityTheme.composerCornerRadius).stroke(ParityTheme.separator) }
            .frame(height: 96)
            .frame(maxWidth: ParityTheme.contentWidth)
            .padding(.horizontal, 24)
            .padding(.top, 6)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
    }

    private func snapshot<Content: View>(_ content: Content, size: CGSize, appearance: NSAppearance.Name, name: String) throws {
        let host = WindowlessRender.Host(content.frame(width: size.width, height: size.height).background(ParityTheme.canvas),
                                         size: size, appearance: appearance == .darkAqua ? .dark : .light)
        defer { host.close() }
        // Layout settles the panel's width before it is drawn.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try WindowlessRender.writePNG(host.capture().bitmap,
                                      to: WindowlessRender.directory("codex-status-qa").appending(path: name))
    }

    private func render<Content: View>(_ content: Content, width: CGFloat, appearance: ColorScheme, to url: URL) throws {
        let image = try WindowlessRender.image(content.frame(width: width).background(ParityTheme.canvas)
            .environment(\.colorScheme, appearance))
        XCTAssertEqual(CGFloat(image.width), width * 2)
        XCTAssertGreaterThan(image.height, 100)
        try WindowlessRender.writePNG(image, to: url)
    }

    private func projection(rateLimits: CodexAccountRateLimits?, isReading: Bool = false,
                            withContext: Bool = true, threadID: String? = "thread-1",
                            selectedModel: String? = "gpt-5.3-codex-spark", words: CodexStatusProjection.Words? = nil)
        -> CodexStatusProjection {
        CodexStatusProjection(threadID: threadID, descendantThreadIDs: [],
                              tokenUsage: withContext ? usage(last: 64_000, window: 256_000) : nil,
                              rateLimits: rateLimits, isReadingRateLimits: isReading, selectedModel: selectedModel,
                              now: now, words: words ?? english)
    }

    private func usage(last: Int64, window: Int64?) -> CodexThreadTokenUsage {
        let breakdown = { (total: Int64) in
            CodexTokenUsageBreakdown(inputTokens: total, cachedInputTokens: 0, cacheWriteInputTokens: 0,
                                     outputTokens: 0, reasoningOutputTokens: 0, totalTokens: total)
        }
        return CodexThreadTokenUsage(total: breakdown(last * 3), last: breakdown(last), modelContextWindow: window)
    }

    /// The installed App Server's `GetAccountRateLimitsResponse`: the general `codex` bucket and
    /// a model's own.
    private func rateLimitResponse() -> JSONValue {
        let seconds = Int64(now.timeIntervalSince1970)
        let general = JSONValue.object([
            "limitId": .string("codex"), "limitName": .null, "planType": .string("pro"),
            "primary": .object(["usedPercent": .integer(36), "windowDurationMins": .integer(300), "resetsAt": .integer(seconds + 7_200)]),
            "secondary": .object(["usedPercent": .integer(12), "windowDurationMins": .integer(10_080),
                                  "resetsAt": .integer(seconds + 259_200)])
        ])
        let spark = JSONValue.object([
            "limitId": .string("codex_bengalfox"), "limitName": .string("GPT-5.3-Codex-Spark"),
            "primary": .object(["usedPercent": .integer(0), "windowDurationMins": .integer(300), "resetsAt": .null]),
            "secondary": .null
        ])
        let unnamed = JSONValue.object(["limitId": .string("other"),
            "primary": .object(["usedPercent": .integer(50), "windowDurationMins": .integer(60)])])
        return .object(["rateLimits": general, "accountId": .null,
                        "rateLimitsByLimitId": .object(["codex": general, "codex_bengalfox": spark, "other": unnamed])])
    }

    private func taskState(items: [CodexItemContent]) -> CodexTaskState {
        CodexTaskState(thread: CodexThreadState(
            id: "root", sessionID: "root", name: nil, preview: "", workspacePath: nil, cliVersion: nil, modelProvider: nil,
            parentThreadID: nil, forkedFromID: nil, status: .idle, canAcceptDirectInput: true, createdAt: nil, updatedAt: nil,
            turns: [CodexTurnState(id: "turn", status: .completed, startedAt: nil, completedAt: nil, durationMilliseconds: nil,
                itemsView: .full, items: items.enumerated().map { index, content in
                    CodexItemState(id: "item-\(index)", lifecycle: .completed, content: content, raw: .object([:]))
                }, itemsNextCursor: nil, plan: nil, tokenUsage: nil, error: nil, raw: .object([:]))],
            turnsNextCursor: nil, turnsBackwardsCursor: nil, itemsBackwardsCursor: nil, raw: .object([:])))
    }

    private func current(_ model: AppModel, _ session: SessionRecord) throws -> SessionRecord {
        try XCTUnwrap(model.store.sessions.first { $0.id == session.id })
    }
}
