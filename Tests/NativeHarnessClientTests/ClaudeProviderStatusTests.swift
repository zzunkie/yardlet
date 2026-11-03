import Foundation
import XCTest
@testable import NativeHarnessClient

/// Claude Code's plan-limit, retry, compaction and context-usage frames, in the shapes 2.1.291
/// sends them, through the projection, the transcript, the adapter and the protocol bridge.
final class ClaudeProviderStatusTests: XCTestCase {
    private let sessionID = "8d0c6b8e-3c9f-4d5e-9a63-0f3b8f1f2a10"

    // MARK: - Plan limits

    func testRateLimitEventKeepsTheLimitingWindowAndEveryMeasuredWindow() throws {
        let frame = try json(rejectedSessionLimit)
        let limit = try XCTUnwrap(ClaudeEventProjector.rateLimit(from: frame["rate_limit_info"]))
        XCTAssertEqual(limit.status, .rejected)
        XCTAssertEqual(limit.window, .session)
        XCTAssertNil(limit.model)
        XCTAssertEqual(limit.resetsAt, Date(timeIntervalSince1970: 1_791_309_600))
        XCTAssertEqual(limit.usedFraction, 1.02)
        XCTAssertFalse(limit.isUsingOverage)
        XCTAssertEqual(limit.windows, [
            .init(window: .session, model: nil, usedFraction: 1.02, resetsAt: Date(timeIntervalSince1970: 1_791_309_600)),
            .init(window: .weekly, model: nil, usedFraction: 0.41, resetsAt: Date(timeIntervalSince1970: 1_791_781_200)),
            .init(window: .model, model: "Fable", usedFraction: 0.07, resetsAt: Date(timeIntervalSince1970: 1_791_781_200))
        ])

        let warning = try XCTUnwrap(ClaudeEventProjector.rateLimit(from: try json(#"""
        {"status":"allowed_warning","resetsAt":1791781200,"rateLimitType":"seven_day_opus","utilization":0.91}
        """#)))
        XCTAssertEqual(warning.status, .warning)
        XCTAssertEqual(warning.window, .model)
        XCTAssertEqual(warning.model, "Opus")
        XCTAssertNil(ClaudeEventProjector.rateLimit(from: try json(#"{"status":"paused"}"#)))
    }

    func testALimitStopsTheTurnWithOneCardInsteadOfTheCLIsTextAndAGenericError() throws {
        var projection = ClaudeSessionProjection()
        var builder = TranscriptBuilder()
        builder.appendUser("Refactor the parser")
        var payloads: [HarnessEventPayload] = []
        for frame in [rejectedSessionLimit, rateLimitAssistantMessage, rateLimitResult] {
            let projected = projection.payloads(from: try json(frame))
            payloads += projected
            projected.forEach { builder.apply($0) }
        }

        XCTAssertFalse(payloads.contains { if case .error = $0 { true } else { false } })
        XCTAssertFalse(payloads.contains { if case .assistantMessageCompleted = $0 { true } else { false } })
        XCTAssertEqual(payloads.last, .turnCompleted)
        guard case let .usageLimit(limit) = builder.entries.last?.content else {
            return XCTFail("The turn ends on its limit card: \(builder.entries.map(\.content))")
        }
        XCTAssertEqual(builder.entries.count, 2)
        XCTAssertEqual(limit.window, .session)
        XCTAssertEqual(limit.resetsAt, Date(timeIntervalSince1970: 1_791_309_600))
        XCTAssertEqual(limit.message, "You've hit your session limit · resets 3pm (Asia/Seoul)")
        XCTAssertEqual(ProviderNoticeText.limitHeadline(limit), L10n.string("Session limit reached"))
    }

    /// A saved conversation keeps the CLI's words for a refused request but not its limit report, so
    /// the card read back from it, after a relaunch or for a task whose CLI is not running, takes the
    /// limit and reset from those words, as of when the record was written. Without them it had no
    /// reset, and nothing to continue with once the reset passed.
    func testACardReadBackFromASavedConversationNamesItsResetFromTheCLIsWords() throws {
        let cases: [(written: String, words: String, window: HarnessRateLimit.Window?, model: String?, resetsAt: String?)] = [
            ("2026-11-02T18:41:24.456Z", "You've hit your session limit · resets 3:50am (Asia/Seoul)",
             .session, nil, "2026-11-02T18:50:00Z"),
            // A time already past that day is the next day's.
            ("2026-11-01T14:24:37.120Z", "You've hit your session limit · resets 1:50am (Asia/Seoul)",
             .session, nil, "2026-11-01T16:50:00Z"),
            ("2026-10-29T08:07:38.000Z", "You've hit your session limit · resets 5:40pm (Asia/Tokyo)",
             .session, nil, "2026-10-29T08:40:00Z"),
            ("2026-11-03T02:09:43.000Z", "You've hit your weekly limit · resets Nov 5 at 8am (Asia/Seoul)",
             .weekly, nil, "2026-11-04T23:00:00Z"),
            ("2026-12-28T10:00:00.000Z", "You've hit your Opus limit · resets Jan 2, 2027 at 9:30pm (America/New_York) · progress saved",
             .model, "Opus", "2027-01-03T02:30:00Z"),
            ("2026-11-03T02:09:43.000Z", "You've hit your limit", nil, nil, nil)
        ]
        for example in cases {
            var projection = ClaudeSessionProjection()
            var builder = TranscriptBuilder()
            builder.appendUser("Refactor the parser")
            let record: [String: Any] = [
                "type": "assistant", "timestamp": example.written, "error": "rate_limit", "isApiErrorMessage": true,
                "message": ["role": "assistant", "model": "<synthetic>", "content": [["type": "text", "text": example.words]]]
            ]
            let frame = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: record))
            projection.payloads(from: frame).forEach { builder.apply($0) }
            guard case let .usageLimit(limit) = builder.entries.last?.content else {
                return XCTFail("The record reads as the limit card: \(example.words)")
            }
            XCTAssertEqual(limit.window, example.window, example.words)
            XCTAssertEqual(limit.model, example.model, example.words)
            XCTAssertEqual(limit.resetsAt, example.resetsAt.flatMap { try? Date($0, strategy: .iso8601) }, example.words)
            XCTAssertEqual(limit.message, example.words)
        }
    }

    func testAReportAfterTheCLIsMessageFillsInTheSameCard() throws {
        var projection = ClaudeSessionProjection()
        var builder = TranscriptBuilder()
        builder.appendUser("Continue")
        for frame in [rateLimitAssistantMessage, rejectedSessionLimit, rateLimitResult] {
            projection.payloads(from: try json(frame)).forEach { builder.apply($0) }
        }
        let cards = builder.entries.compactMap { entry -> HarnessRateLimit? in
            if case let .usageLimit(limit) = entry.content { return limit }
            return nil
        }
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.window, .session)
        XCTAssertEqual(cards.first?.message, "You've hit your session limit · resets 3pm (Asia/Seoul)")
    }

    func testARejectedTurnWithoutTheCLIsLimitMessageStillShowsTheCard() throws {
        var projection = ClaudeSessionProjection()
        _ = projection.payloads(from: try json(rejectedSessionLimit))
        let payloads = projection.payloads(from: try json(rateLimitResult))
        XCTAssertTrue(payloads.contains {
            if case let .usageLimitReached(limit) = $0 { return limit.window == .session }
            return false
        })
        XCTAssertFalse(payloads.contains { if case .error = $0 { true } else { false } })

        // The next turn starts clean: an unrelated failure is a plain error again.
        let next = projection.payloads(from: try json(#"{"type":"result","is_error":true,"result":"Not logged in"}"#))
        XCTAssertTrue(next.contains(.error(message: "Not logged in", recoverable: true)))
    }

    func testPaidUsageCoveringARejectionIsNotALimit() throws {
        var projection = ClaudeSessionProjection()
        let covered = try json(#"""
        {"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1791309600,
          "rateLimitType":"five_hour","isUsingOverage":true,"overageStatus":"allowed"},"uuid":"u1","session_id":"s"}
        """#)
        let payloads = projection.payloads(from: covered)
        XCTAssertEqual(payloads.count, 1)
        let failure = projection.payloads(from: try json(#"{"type":"result","is_error":true,"result":"Overloaded"}"#))
        XCTAssertTrue(failure.contains(.error(message: "Overloaded", recoverable: true)))
    }

    func testAStreamReportUpdatesTheAccountsRowsInEitherNaming() throws {
        let checked = try XCTUnwrap(ClaudeUsageProbe.usage(from: try json(#"""
        {"rate_limits":{"limits":[{"kind":"session","group":"session","percent":40},
          {"kind":"weekly_all","group":"weekly","percent":10,"resets_at":"2030-01-02T00:00:00+00:00"},
          {"kind":"weekly_scoped","group":"weekly","percent":3,"scope":{"model":{"display_name":"Fable"}}}]}}
        """#)))
        let limit = try XCTUnwrap(ClaudeEventProjector.rateLimit(from: try json(rejectedSessionLimit)["rate_limit_info"]))
        let updated = ClaudeUsageProbe.usage(checked, updatedBy: limit)
        XCTAssertEqual(updated.map(\.id), checked.map(\.id), "Each report replaces the row it measured")
        XCTAssertEqual(updated.map { (($0.usedFraction ?? -1) * 100).rounded() }, [100, 41, 7])
        XCTAssertEqual(updated[0].resetsAt, Date(timeIntervalSince1970: 1_791_309_600))
        XCTAssertEqual(updated[0].detail, L10n.format("%.0f%% remaining", 0.0))

        let older = try XCTUnwrap(ClaudeUsageProbe.usage(from: try json(#"""
        {"rate_limits":{"five_hour":{"utilization":5},"seven_day":{"utilization":50}}}
        """#)))
        let weekly = HarnessRateLimit(status: .rejected, window: .weekly)
        XCTAssertEqual(ClaudeUsageProbe.usage(older, updatedBy: weekly).map(\.usedFraction), [0.05, 1],
            "A refused window without a figure is full")
        XCTAssertEqual(ClaudeUsageProbe.usage([], updatedBy: limit).map(\.id),
            ["claude:session:", "claude:weekly_all:", "claude:weekly_scoped:Fable"])
    }

    @MainActor
    func testTheAccountListFollowsTheSessionsReportWithoutAnotherCheck() throws {
        let store = ProviderConnectionStore()
        let account = ProviderConnection(id: "work", name: "work@example.test", harness: .claudeCode, providerID: nil,
            homePath: "/tmp/claude-work", credentialSelector: nil)
        try store.save(account)
        let checkedAt = Date(timeIntervalSince1970: 1_791_000_000)
        store.publish(HarnessAccountSnapshot(id: "work", harness: .claudeCode, providerID: nil, state: .signedIn,
            accountLabel: "work@example.test", detail: "", credentialOwner: "Claude Code", checkedAt: checkedAt,
            usage: ClaudeUsageProbe.usage([], updatedBy: HarnessRateLimit(status: .allowed, window: .session, usedFraction: 0.2)),
            canLogin: false, canLogout: true), for: account)
        store.recordRateLimit(HarnessRateLimit(status: .warning, window: .session, usedFraction: 0.92), for: account)
        XCTAssertEqual(try XCTUnwrap(store.snapshots["work"]?.usage.first?.usedFraction), 0.92, accuracy: 0.0001)
        XCTAssertEqual(store.snapshots["work"]?.checkedAt, checkedAt)
        XCTAssertEqual(try XCTUnwrap(store.remainingFraction(for: account)), 0.08, accuracy: 0.0001)

        let unchecked = ProviderConnection(id: "new", name: "new", harness: .claudeCode, providerID: nil,
            homePath: "/tmp/claude-new", credentialSelector: nil)
        store.recordRateLimit(HarnessRateLimit(status: .rejected, window: .session), for: unchecked)
        XCTAssertNil(store.snapshots["new"], "An account never checked stays unchecked")
    }

    // MARK: - Retries and compaction

    func testRetryFramesNameTheCauseAndTheAttempt() throws {
        var projection = ClaudeSessionProjection()
        let overloaded = projection.payloads(from: try json(#"""
        {"type":"system","subtype":"api_retry","attempt":2,"max_retries":10,"retry_delay_ms":1200,
          "error_status":529,"error":"overloaded","uuid":"r1","session_id":"s"}
        """#))
        XCTAssertEqual(overloaded, [.providerRetrying(HarnessProviderRetry(attempt: 2, maxRetries: 10, cause: .overloaded))])
        let timeout = try XCTUnwrap(ClaudeEventProjector.retry(from: try json(#"""
        {"type":"system","subtype":"api_retry","attempt":1,"max_retries":1,"retry_delay_ms":0,"error_status":null,
          "error":"unknown","no_response":{"waited_ms":30000,"retry_wait_ms":60000},"uuid":"r2","session_id":"s"}
        """#)))
        XCTAssertEqual(timeout.cause, .connection)
        let status = try XCTUnwrap(ClaudeEventProjector.retry(from: try json(#"""
        {"type":"system","subtype":"api_retry","attempt":3,"max_retries":10,"retry_delay_ms":0,"error_status":503,
          "uuid":"r3","session_id":"s"}
        """#)))
        XCTAssertEqual(status.cause, .serverError)

        XCTAssertEqual(ProviderNoticeText.retry(HarnessProviderRetry(attempt: 2, maxRetries: 10, cause: .overloaded)),
            L10n.string("API overloaded") + " · " + L10n.format("Retrying (%lld/%lld)", Int64(2), Int64(10)))
        XCTAssertEqual(ProviderNoticeText.retry(HarnessProviderRetry(attempt: 1, maxRetries: 5, cause: .other)),
            L10n.format("Retrying (%lld/%lld)", Int64(1), Int64(5)))
    }

    func testACompactionIsOneMarkerThatSettlesWithTheSavedTokens() throws {
        var projection = ClaudeSessionProjection()
        var builder = TranscriptBuilder()
        builder.appendUser("Keep going")
        for frame in [compacting, compacting, compactBoundary, compactSucceeded] {
            projection.payloads(from: try json(frame)).forEach { builder.apply($0) }
        }
        let markers = builder.entries.compactMap { entry -> HarnessContextCompaction? in
            if case let .compaction(compaction) = entry.content { return compaction }
            return nil
        }
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers.first?.phase, .completed)
        XCTAssertEqual(markers.first?.savedTokens, 125_782)
        XCTAssertEqual(ProviderNoticeText.compaction(try XCTUnwrap(markers.first)),
            L10n.format("Compacted session · saved %@ tokens", "126K"))

        // The status may also arrive before the boundary.
        var reversed = ClaudeSessionProjection()
        var other = TranscriptBuilder()
        for frame in [compacting, compactSucceeded, compactBoundary] {
            reversed.payloads(from: try json(frame)).forEach { other.apply($0) }
        }
        XCTAssertEqual(other.entries.map(\.content), [.compaction(HarnessContextCompaction(
            phase: .completed, tokensBefore: 167_012, tokensAfter: 41_230))])
    }

    func testAFailedOrUnfinishedCompactionDoesNotStayRunning() throws {
        var projection = ClaudeSessionProjection()
        var builder = TranscriptBuilder()
        for frame in [compacting, #"""
        {"type":"system","subtype":"status","status":null,"compact_result":"failed",
          "compact_error":"Conversation too long to summarize","uuid":"c9","session_id":"s"}
        """#] {
            projection.payloads(from: try json(frame)).forEach { builder.apply($0) }
        }
        XCTAssertEqual(builder.entries.last?.content, .compaction(HarnessContextCompaction(
            phase: .failed, message: "Conversation too long to summarize")))

        var unfinished = TranscriptBuilder()
        unfinished.apply(.contextCompaction(HarnessContextCompaction(phase: .started)))
        unfinished.apply(.turnCompleted)
        XCTAssertEqual(unfinished.entries.last?.content, .compaction(HarnessContextCompaction(phase: .completed)))
        let restored = TranscriptBuilder(entries: [TranscriptEntry(content: .compaction(HarnessContextCompaction(phase: .started)))])
        XCTAssertTrue(restored.entries.isEmpty, "A restored transcript cannot know how a running compaction ended")
    }

    // MARK: - Adapter

    func testTheAdapterReadsContextUsageAfterEachResultAndKeepsAnnouncedModes() async throws {
        let transport = FakeClaudeTransport()
        await transport.setContextUsageResponse(try json(#"""
        {"categories":[{"name":"System prompt","tokens":4394,"color":"promptBorder","kind":"used"}],
          "totalTokens":20265,"maxTokens":1000000,"rawMaxTokens":1000000,"percentage":2,"model":"claude-fable-5-1",
          "autoCompactThreshold":967000,"isAutoCompactEnabled":true,"apiUsage":null}
        """#))
        let adapter = ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in transport })
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/workspace"), initialPrompt: nil))
        let recorder = PayloadLog()
        let collector = Task { for await event in await adapter.events(for: handle) { await recorder.append(event.payload) } }
        defer { collector.cancel() }

        try await adapter.send("hello", to: handle)
        await transport.emit(try json(compacting))
        await transport.emit(try json(#"{"type":"result","subtype":"success","is_error":false,"result":"done"}"#))
        let usage = try await waitForPayload(in: recorder) { payload -> HarnessProtocolUsage? in
            guard case let .usageUpdated(usage) = payload, usage.contextUsedTokens != nil else { return nil }
            return usage
        }
        XCTAssertEqual(usage.contextUsedTokens, 20_265)
        XCTAssertEqual(usage.contextWindowTokens, 1_000_000)
        XCTAssertEqual(try XCTUnwrap(ConversationSessionStatusProjection.contextFraction(usage)), 0.020265, accuracy: 0.000001)
        let request = await transport.requestedValues.last { $0["request"]?["subtype"]?.stringValue == "get_context_usage" }
        XCTAssertEqual(request?["request"]?["detail"]?.stringValue, "summary")

        // The status frame that reported the compaction also announced the mode.
        let payloads = await recorder.payloads
        XCTAssertTrue(payloads.contains(.contextCompaction(HarnessContextCompaction(phase: .started))))
        let state = try await adapter.providerCapabilities(for: handle)
        XCTAssertEqual(state.selectors.first { $0.id == "permissionMode" }?.currentValue, "acceptEdits")
        await adapter.close(handle)
    }

    func testATaskLaunchesInItsSavedModeAndCanSwitchToTheBypass() async throws {
        for (saved, launched) in [("acceptEdits", "acceptEdits"), ("manual", "default"), ("plan", "plan"),
                                  ("bypassPermissions", "bypassPermissions")] {
            let transport = FakeClaudeTransport(initializeResponse: .object([
                "models": .array([]), "current_permission_mode": .string(launched)
            ]))
            let adapter = ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in transport })
            let localID = UUID()
            await adapter.setLaunchOptions(["permissionMode": saved], for: localID)
            let handle = try await adapter.resumeSession(providerSessionID: sessionID, localSessionID: localID,
                workspaceURL: URL(filePath: "/tmp/workspace"))
            let startedWith = await transport.configuration
            let configuration = try XCTUnwrap(startedWith)
            XCTAssertEqual(ClaudePermissionMode.launchArgument(for: configuration.permissionMode), launched, saved)
            let arguments = ClaudeProcessTransport.arguments(for: configuration)
            let index = try XCTUnwrap(arguments.firstIndex(of: "--permission-mode"))
            XCTAssertEqual(arguments[index + 1], launched, saved)
            // Every launch lets the session switch to the bypass later, without turning it on.
            XCTAssertEqual(arguments.filter { $0 == "--allow-dangerously-skip-permissions" }.count, 1, saved)
            XCTAssertFalse(arguments.contains("--dangerously-skip-permissions"), saved)

            // Restoring the saved option asks the CLI for nothing it already launched with.
            _ = try await adapter.setProviderOption(id: "permissionMode", value: saved, in: handle)
            let subtypes = await transport.requestSubtypes
            XCTAssertFalse(subtypes.contains("set_permission_mode"), saved)

            // Switching to the bypass in the running session is the CLI's own mode change.
            if saved != ClaudePermissionMode.bypassPermissions {
                let state = try await adapter.setProviderOption(id: "permissionMode", value: "bypassPermissions",
                                                                in: handle)
                let requests = await transport.requestedValues
                let request = requests.last { $0["request"]?["subtype"]?.stringValue == "set_permission_mode" }
                XCTAssertEqual(request?["request"]?["mode"]?.stringValue, "bypassPermissions", saved)
                XCTAssertEqual(state.selectors.first { $0.id == "permissionMode" }?.currentValue, "bypassPermissions")
            }
            do {
                _ = try await adapter.setProviderOption(id: "permissionMode", value: "bypass", in: handle)
                XCTFail("Only the selector's own modes are set")
            } catch {}
            await adapter.close(handle)
        }
        let unchanged = ClaudeProcessTransport.arguments(for: ClaudeLaunchConfiguration(
            providerSessionID: sessionID, workspaceURL: URL(filePath: "/tmp/workspace"), resumesExistingSession: true
        ))
        XCTAssertEqual(unchanged.filter { $0 == "--permission-mode" }.count, 1)
        XCTAssertEqual(unchanged[try XCTUnwrap(unchanged.firstIndex(of: "--permission-mode")) + 1], "default",
            "A task without a saved mode launches in Manual, as before")
        XCTAssertEqual(ClaudePermissionMode.launchArgument(for: "bypass"), "default", "An unknown mode launches in Manual")
    }

    func testTheProductRouteCarriesLimitsRetriesCompactionAndContextUsageUnchanged() async throws {
        let directTransport = FakeClaudeTransport()
        let routedTransport = FakeClaudeTransport()
        let contextUsage = try json(#"{"totalTokens":81000,"maxTokens":200000,"percentage":41}"#)
        await directTransport.setContextUsageResponse(contextUsage)
        await routedTransport.setContextUsageResponse(contextUsage)
        let localID = UUID()
        let direct = ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in directTransport })
        let routed = YHPProviderCompatibilityAdapter(
            adapter: ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in routedTransport }),
            manifest: HarnessProtocolCompatibilityManifest.claude()
        )
        let workspace = URL(filePath: "/tmp/claude-yhp-status")
        let directHandle = try await direct.resumeSession(providerSessionID: sessionID, localSessionID: localID,
            workspaceURL: workspace)
        let routedHandle = try await routed.resumeSession(providerSessionID: sessionID, localSessionID: localID,
            workspaceURL: workspace)
        let directLog = PayloadLog(), routedLog = PayloadLog()
        let collectors = [
            Task { for await event in await direct.events(for: directHandle) { await directLog.append(event.payload) } },
            Task { for await event in await routed.events(for: routedHandle) { await routedLog.append(event.payload) } }
        ]
        defer { collectors.forEach { $0.cancel() } }
        // A resumed conversation reads its context usage once before any turn.
        for log in [directLog, routedLog] {
            try await waitForContextUsageCount(1, in: log)
        }
        try await direct.send("go", to: directHandle)
        try await routed.send("go", to: routedHandle)
        for frame in [#"""
            {"type":"system","subtype":"api_retry","attempt":1,"max_retries":10,"retry_delay_ms":500,"error_status":529,
              "error":"overloaded","uuid":"r1","session_id":"s"}
            """#, compacting, compactBoundary, compactSucceeded, rejectedSessionLimit, rateLimitAssistantMessage,
            rateLimitResult] {
            await directTransport.emit(try json(frame))
            await routedTransport.emit(try json(frame))
        }
        for log in [directLog, routedLog] {
            try await waitForContextUsageCount(2, in: log)
        }
        let directPayloads = await directLog.payloads
        let routedPayloads = await routedLog.payloads
        XCTAssertEqual(routedPayloads, directPayloads)
        XCTAssertTrue(directPayloads.contains(.providerRetrying(HarnessProviderRetry(attempt: 1, maxRetries: 10, cause: .overloaded))))
        XCTAssertTrue(directPayloads.contains { if case .usageLimitReached = $0 { true } else { false } })
        XCTAssertTrue(directPayloads.contains { if case .rateLimitUpdated = $0 { true } else { false } })
        await direct.close(directHandle)
        await routed.close(routedHandle)
    }

    // MARK: - Fixtures

    private var rejectedSessionLimit: String {
        #"""
        {"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1791309600,"rateLimitType":"five_hour",
          "utilization":1.02,"unifiedWindows":{"five_hour":{"utilization":1.02,"resetsAt":1791309600},
          "seven_day":{"utilization":0.41,"resetsAt":1791781200},
          "seven_day_overage_included":{"utilization":0.07,"resetsAt":1791781200}},
          "isUsingOverage":false,"overageStatus":"rejected","overageDisabledReason":"out_of_credits"},
          "uuid":"5b1d2c64-0a2f-4f43-8d8e-1f1c0c2b8f11","session_id":"8d0c6b8e-3c9f-4d5e-9a63-0f3b8f1f2a10"}
        """#
    }

    private var rateLimitAssistantMessage: String {
        #"""
        {"type":"assistant","message":{"id":"7f6b0a1e-2d4c-4b8e-9f2a-3c5d6e7f8a9b","type":"message","role":"assistant",
          "model":"<synthetic>","content":[{"type":"text","text":"You've hit your session limit · resets 3pm (Asia/Seoul)"}],
          "stop_reason":"stop_sequence","usage":{"input_tokens":0,"output_tokens":0}},"parent_tool_use_id":null,
          "error":"rate_limit","uuid":"0e1f2a3b-4c5d-6e7f-8a9b-0c1d2e3f4a5b","session_id":"8d0c6b8e-3c9f-4d5e-9a63-0f3b8f1f2a10"}
        """#
    }

    private var rateLimitResult: String {
        #"""
        {"type":"result","subtype":"success","is_error":true,"duration_ms":412,"num_turns":1,
          "result":"You've hit your session limit · resets 3pm (Asia/Seoul)","total_cost_usd":0,
          "usage":{"input_tokens":0,"output_tokens":0},"session_id":"8d0c6b8e-3c9f-4d5e-9a63-0f3b8f1f2a10"}
        """#
    }

    private var compacting: String {
        #"""
        {"type":"system","subtype":"status","status":"compacting","permissionMode":"acceptEdits",
          "uuid":"a1b2c3d4-0000-4000-8000-000000000001","session_id":"8d0c6b8e-3c9f-4d5e-9a63-0f3b8f1f2a10"}
        """#
    }

    private var compactBoundary: String {
        #"""
        {"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"auto","pre_tokens":167012,
          "post_tokens":41230,"duration_ms":38120},"uuid":"a1b2c3d4-0000-4000-8000-000000000002",
          "session_id":"8d0c6b8e-3c9f-4d5e-9a63-0f3b8f1f2a10"}
        """#
    }

    private var compactSucceeded: String {
        #"""
        {"type":"system","subtype":"status","status":null,"compact_result":"success",
          "uuid":"a1b2c3d4-0000-4000-8000-000000000003","session_id":"8d0c6b8e-3c9f-4d5e-9a63-0f3b8f1f2a10"}
        """#
    }

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private func waitForContextUsageCount(_ count: Int, in log: PayloadLog) async throws {
        let deadline = ContinuousClock.now + testWaitLimit
        while ContinuousClock.now < deadline {
            let readings = await log.payloads.filter { payload in
                if case let .usageUpdated(usage) = payload { return usage.contextUsedTokens != nil }
                return false
            }
            if readings.count >= count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(count) context readings")
        throw CancellationError()
    }

    private func waitForPayload<Value>(
        in log: PayloadLog,
        _ match: @escaping (HarnessEventPayload) -> Value?
    ) async throws -> Value {
        let deadline = ContinuousClock.now + testWaitLimit
        while ContinuousClock.now < deadline {
            if let value = await log.payloads.lazy.compactMap(match).first { return value }
            try await Task.sleep(for: .milliseconds(20))
        }
        let seen = await log.payloads
        XCTFail("Timed out waiting for a payload in \(seen)")
        throw CancellationError()
    }
}

private actor PayloadLog {
    private(set) var payloads: [HarnessEventPayload] = []
    func append(_ payload: HarnessEventPayload) { payloads.append(payload) }
}
