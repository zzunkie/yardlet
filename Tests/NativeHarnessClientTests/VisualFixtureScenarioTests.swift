import Foundation
import XCTest
@testable import NativeHarnessClient

#if DEBUG
@MainActor
final class VisualFixtureScenarioTests: XCTestCase {
    func testFixtureAppearanceSelectorIsBoundedToLightOrDark() {
        XCTAssertEqual(
            VisualFixtureAppearance.requested(arguments: ["NativeHarnessClient", "--ui-fixture-appearance=dark"]),
            .dark
        )
        XCTAssertEqual(
            VisualFixtureAppearance.requested(arguments: ["NativeHarnessClient", "--ui-fixture-appearance=LIGHT"]),
            .light
        )
        XCTAssertNil(
            VisualFixtureAppearance.requested(arguments: ["NativeHarnessClient", "--ui-fixture-appearance=system"])
        )
        XCTAssertNil(VisualFixtureAppearance.requested(arguments: ["NativeHarnessClient"]))
    }

    func testConversationFixtureCoversPopulatedCapabilityStatesWithoutPersistentStorage() async throws {
        let fixture = VisualFixtureScenario.conversation

        XCTAssertEqual(fixture.sessions.count, 2)
        let populated = try XCTUnwrap(fixture.sessions.first)
        let entries = try XCTUnwrap(fixture.transcripts[populated.id])

        XCTAssertTrue(entries.contains { entry in
            if case .assistant(_, isStreaming: true) = entry.content { return true }
            return false
        })
        XCTAssertTrue(entries.contains { entry in
            if case .activity(_, state: .running) = entry.content { return true }
            return false
        })
        XCTAssertTrue(entries.contains { entry in
            if case .permission(_, state: .pending) = entry.content { return true }
            return false
        })
        XCTAssertTrue(entries.contains { entry in
            if case .plan = entry.content { return true }
            return false
        })
        XCTAssertTrue(fixture.transcripts.values.joined().contains { entry in
            if case .error = entry.content { return true }
            return false
        })

        let model = fixture.makeModel()
        await model.restoreIndex()
        XCTAssertTrue(
            model.runtimeSelections.selectedURLs.isEmpty,
            "The visual fixture must not discover or wake installed CLI runtimes."
        )
        XCTAssertEqual(model.store.sessions, fixture.sessions)
        XCTAssertEqual(model.transcriptBySessionID.dictionary, fixture.transcripts)
        let typedState = try XCTUnwrap(fixture.codexPresentation[populated.id])
        XCTAssertEqual(model.codexPresentationBySessionID[populated.id], typedState)
        XCTAssertEqual(typedState.thread?.turns.count, 2)
        XCTAssertEqual(typedState.thread?.turns.last?.plan?.steps.count, 3)
        let firstDraft = try XCTUnwrap(typedState.thread?.turns.first?.userInputDraft)
        XCTAssertEqual(firstDraft.text, "Inspect the native Codex task surface.")
        XCTAssertEqual(firstDraft.inputs.count, 4)
        XCTAssertEqual(firstDraft.inputs[1], .localImage(URL(string: "/fixture/visual-context.png")!, detail: .auto))
        XCTAssertEqual(firstDraft.inputs[2], .skill(name: "verification", path: URL(string: "/fixture/verification/SKILL.md")!))
        XCTAssertEqual(firstDraft.inputs[3], .mention(name: "Sources", path: URL(string: "/fixture/Sources")!))
        XCTAssertEqual(typedState.serverRequestsByID["s:visual-command-approval"]?.kind, .commandExecutionApproval)
        XCTAssertEqual(typedState.serverRequestsByID["s:visual-permissions-approval"]?.kind, .permissionsApproval)
        XCTAssertEqual(typedState.serverRequestsByID["s:visual-tool-input"]?.kind, .toolUserInput)
        XCTAssertEqual(typedState.serverRequestsByID["s:visual-mcp-elicitation"]?.kind, .mcpElicitation)
        XCTAssertEqual(typedState.serverRequestsByID["s:visual-dynamic-tool-call"]?.kind, .dynamicToolCall)
        XCTAssertEqual(typedState.serverRequestsByID["s:visual-auth-refresh"]?.kind, .authenticationRefresh)
        XCTAssertEqual(typedState.serverRequestsByID["s:visual-attestation"]?.kind, .attestation)
        XCTAssertEqual(typedState.serverRequestsByID["s:visual-current-time"]?.kind, .currentTime)
        XCTAssertEqual(typedState.serverRequestsByID["s:visual-unknown-request"]?.kind, .unknown("future/unknownRequest"))
        XCTAssertEqual(fixture.codexQueues[populated.id]?.count, 2)
        XCTAssertEqual(model.followUps.queue(for: populated.id).map(\.state), [.pending, .failed])
        XCTAssertEqual(model.codexCapabilitiesBySessionID, fixture.codexCapabilities)
        XCTAssertEqual(model.providerCapabilitiesBySessionID, fixture.providerCapabilities)
        XCTAssertEqual(fixture.codexCapabilities[populated.id]?.skills.count, 2)
        XCTAssertEqual(fixture.codexCapabilities[populated.id]?.plugins.count, 3)
        await model.shutdown()
    }

    func testFixtureServerRequestResponsesResolveWithoutRuntimeWake() async throws {
        let fixture = VisualFixtureScenario.conversation
        let session = try XCTUnwrap(fixture.sessions.first(where: { $0.harness == .codex }))
        let model = fixture.makeModel()

        await model.respondCodex(
            to: "s:visual-command-approval",
            response: .command(.accept),
            in: session
        )
        await model.respondCodex(
            to: "s:visual-permissions-approval",
            response: .permissions(
                permissions: .object(["network": .object(["enabled": .bool(true)])]),
                scope: .session,
                strictAutoReview: nil
            ),
            in: session
        )

        let state = try XCTUnwrap(model.codexPresentationBySessionID[session.id])
        XCTAssertEqual(
            state.serverRequestsByID["s:visual-command-approval"]?.resolution,
            .resolved(.object(["decision": .string("accept")]))
        )
        XCTAssertEqual(
            state.serverRequestsByID["s:visual-permissions-approval"]?.resolution,
            .resolved(.object([
                "permissions": .object(["network": .object(["enabled": .bool(true)])]),
                "scope": .string("session")
            ]))
        )
        XCTAssertFalse(model.isAttached(session.id))
        await model.shutdown()
    }

    func testAccountFixtureProvidesQuotaAndAccountHistoryWithoutRuntimeWork() {
        let snapshots = VisualFixtureScenario.accountSnapshots
        XCTAssertEqual(snapshots.count, 3)
        XCTAssertEqual(snapshots.first?.state, .signedIn)
        XCTAssertEqual(snapshots.last?.harness, .openCode)
        XCTAssertTrue(snapshots.last?.canLogin ?? false)
        XCTAssertTrue(snapshots.flatMap(\.usage).contains { $0.evidence == .exactQuota })
        XCTAssertEqual(snapshots.flatMap(\.usage).filter { $0.evidence == .accountUsage }.count, 3)
    }

    func testFixtureRequiresExplicitLaunchArgument() {
        XCTAssertNil(VisualFixtureScenario.requested(arguments: ["NativeHarnessClient"]))
        XCTAssertNotNil(VisualFixtureScenario.requested(arguments: [
            "NativeHarnessClient",
            "--ui-fixture=conversation",
            "--ui-fixture-workspace=/tmp/native-harness-fixture"
        ]))
        XCTAssertEqual(
            VisualFixtureScenario.requested(arguments: [
                "NativeHarnessClient",
                "--ui-fixture=conversation",
                "--ui-fixture-workspace=/tmp/native-harness-fixture"
            ])?.sessions.first?.workspaceURL.path(percentEncoded: false),
            "/tmp/native-harness-fixture"
        )
        XCTAssertNotNil(VisualFixtureScenario.requested(arguments: [
            "NativeHarnessClient",
            "--ui-fixture=settings"
        ]))
        XCTAssertNotNil(VisualFixtureScenario.requested(arguments: [
            "NativeHarnessClient",
            "--ui-fixture=harness-transcripts"
        ]))
    }

    func testHarnessTranscriptFixtureCoversEveryNonCodexHarnessWithoutRuntimeWake() async throws {
        let fixture = VisualFixtureScenario.harnessTranscripts
        let expectedHarnesses = Set(
            HarnessCatalog.builtIns.lazy.map(\.id).filter { $0 != .codex }
        )

        XCTAssertEqual(Set(fixture.sessions.map(\.harness)), expectedHarnesses)
        XCTAssertEqual(fixture.sessions.count, expectedHarnesses.count)
        XCTAssertTrue(fixture.sessions.allSatisfy { session in
            session.status == .ready && session.completionState == .completed
        })

        for session in fixture.sessions {
            let entries = try XCTUnwrap(fixture.transcripts[session.id])
            let turns = TranscriptConversationProjection.presentation(
                from: entries, harness: session.harness, status: session.status,
                latestTurnIsComplete: session.completionState == .completed
            ).turns
            XCTAssertTrue(turns.contains { $0.foldsWork && $0.hasWorkDetails },
                          "Missing completed work for \(session.harness.rawValue)")
            XCTAssertTrue(turns.contains { !$0.answers.isEmpty }, "Missing final answer for \(session.harness.rawValue)")
            XCTAssertTrue(entries.contains { entry in
                if case .reasoning(_, isStreaming: false) = entry.content { return true }
                return false
            }, "Missing reasoning block for \(session.harness.rawValue)")
            XCTAssertTrue(entries.contains { entry in
                guard case let .activity(activity, _) = entry.content else { return false }
                return activity.input != nil && activity.output != nil && activity.diff != nil
            }, "Missing separated tool card for \(session.harness.rawValue)")
            XCTAssertTrue(entries.contains { entry in
                guard case let .permission(request, state) = entry.content else { return false }
                return state == .pending && request.actions.count == 4
            }, "Missing provider approval options for \(session.harness.rawValue)")
        }

        let model = fixture.makeModel()
        await model.restoreIndex()
        XCTAssertTrue(model.runtimeSelections.selectedURLs.isEmpty)
        XCTAssertTrue(fixture.sessions.allSatisfy { !model.isAttached($0.id) })
        let grok = try XCTUnwrap(fixture.sessions.first { $0.harness == .grokBuild })
        XCTAssertEqual(
            model.providerCapabilitiesBySessionID[grok.id]?.selectors.map(\.id),
            ["model", "reasoning_effort"]
        )
        XCTAssertEqual(model.providerUsageBySessionID[grok.id]?.contextUsedTokens, 10_445)
        await model.refreshConversationStatus(for: grok)
        XCTAssertFalse(model.isAttached(grok.id))
        await model.shutdown()
    }

    func testSettingsFixtureSeedsInitialSectionWithoutRuntimeWake() async throws {
        let fixture = try XCTUnwrap(VisualFixtureScenario.requested(arguments: [
            "NativeHarnessClient",
            "--ui-fixture=settings",
            "--ui-fixture-settings-section=notifications"
        ]))
        XCTAssertEqual(fixture.initialSettingsSection, "notifications")
        XCTAssertNil(fixture.initialCodexCapabilitySection)
        XCTAssertNil(fixture.initialCodexHistoryQuery)

        let model = fixture.makeModel()
        XCTAssertEqual(model.initialSettingsSection, "notifications")
        XCTAssertTrue(model.runtimeSelections.selectedURLs.isEmpty)
        await model.restoreIndex()
        await model.shutdown()
    }

    func testSettingsFixtureAcceptsDeterministicNotificationStatusWithoutOSPermission() async throws {
        let authorized = try XCTUnwrap(VisualFixtureScenario.requested(arguments: [
            "NativeHarnessClient",
            "--ui-fixture=settings",
            "--ui-fixture-settings-section=notifications",
            "--ui-fixture-notification-status=authorized"
        ]))
        XCTAssertEqual(authorized.initialNotificationAuthorization, .authorized)
        let authorizedModel = authorized.makeModel()
        let authorizedStatus = await authorizedModel.systemNotificationCenter.authorization()
        XCTAssertEqual(authorizedStatus, .authorized)
        await authorizedModel.shutdown()

        let denied = try XCTUnwrap(VisualFixtureScenario.requested(arguments: [
            "NativeHarnessClient",
            "--ui-fixture=settings",
            "--ui-fixture-notification-status=denied"
        ]))
        XCTAssertEqual(denied.initialNotificationAuthorization, .denied)
        let deniedModel = denied.makeModel()
        let deniedStatus = await deniedModel.systemNotificationCenter.authorization()
        XCTAssertEqual(deniedStatus, .denied)
        await deniedModel.shutdown()

        XCTAssertNil(VisualFixtureScenario.requested(arguments: [
            "NativeHarnessClient",
            "--ui-fixture=settings",
            "--ui-fixture-notification-status=unexpected"
        ])?.initialNotificationAuthorization)
    }

    func testHistoryFixtureOpensTheImportSearchWithoutRuntimeWake() async throws {
        let fixture = try XCTUnwrap(VisualFixtureScenario.requested(arguments: [
            "NativeHarnessClient",
            "--ui-fixture=history"
        ]))
        XCTAssertNil(fixture.initialCodexCapabilitySection, "The capability sheet has no History section")
        XCTAssertEqual(fixture.initialCodexHistoryQuery, "native")

        let model = fixture.makeModel()
        let session = try XCTUnwrap(fixture.sessions.first(where: { $0.harness == .codex }))
        let page = try await model.importableConversations(harness: .codex, workspaceURL: session.workspaceURL,
            connection: nil, searchTerm: fixture.initialCodexHistoryQuery ?? "")

        XCTAssertEqual(page.conversations.map(\.providerSessionID), ["visual-codex-session"])
        XCTAssertFalse(model.isAttached(session.id))
        await model.shutdown()
    }

    func testFixtureAdditionalRootsReachOnlyThePopulatedTask() throws {
        let fixture = try XCTUnwrap(VisualFixtureScenario.requested(arguments: [
            "NativeHarnessClient",
            "--ui-fixture=conversation",
            "--ui-fixture-surface=diff",
            "--ui-fixture-workspace=/tmp/native-harness-fixture",
            "--ui-fixture-additional-root=/tmp/native-harness-second",
            "--ui-fixture-additional-root=/tmp/native-harness-fixture"
        ]))
        XCTAssertEqual(fixture.initialTaskSurface, "diff")
        // The cwd never repeats as an extra root.
        XCTAssertEqual(fixture.sessions.first?.additionalRoots, ["/tmp/native-harness-second"])
        XCTAssertTrue(fixture.sessions.dropFirst().allSatisfy(\.additionalRoots.isEmpty))
        XCTAssertEqual(
            VisualFixtureScenario.requested(arguments: ["NativeHarnessClient", "--ui-fixture=conversation"])?
                .sessions.first?.additionalRoots,
            []
        )
    }

    func testFixtureSurfaceArgumentIsValidatedAndCarriedIntoModel() async throws {
        let terminalFixture = try XCTUnwrap(VisualFixtureScenario.requested(arguments: [
            "NativeHarnessClient",
            "--ui-fixture=conversation",
            "--ui-fixture-surface=TERMINAL"
        ]))
        XCTAssertEqual(terminalFixture.initialTaskSurface, "terminal")
        let terminalModel = terminalFixture.makeModel()
        XCTAssertEqual(terminalModel.initialTaskSurface, "terminal")

        let browserFixture = try XCTUnwrap(VisualFixtureScenario.requested(arguments: [
            "NativeHarnessClient",
            "--ui-fixture=conversation",
            "--ui-fixture-surface=browser"
        ]))
        XCTAssertEqual(browserFixture.initialTaskSurface, "browser")

        let fullFixture = try XCTUnwrap(VisualFixtureScenario.requested(arguments: [
            "NativeHarnessClient",
            "--ui-fixture=conversation",
            "--ui-fixture-surface=FULL"
        ]))
        XCTAssertEqual(fullFixture.initialTaskSurface, "full")

        let invalidFixture = try XCTUnwrap(VisualFixtureScenario.requested(arguments: [
            "NativeHarnessClient",
            "--ui-fixture=conversation",
            "--ui-fixture-surface=webview"
        ]))
        XCTAssertNil(invalidFixture.initialTaskSurface)
        let browserModel = browserFixture.makeModel()
        let fullModel = fullFixture.makeModel()
        let invalidModel = invalidFixture.makeModel()
        await terminalModel.shutdown()
        await browserModel.shutdown()
        await fullModel.shutdown()
        await invalidModel.shutdown()
    }

    func testFixtureHistorySearchUsesSeededRowsWithoutProviderWake() async throws {
        let fixture = VisualFixtureScenario.conversation
        let model = fixture.makeModel()
        let session = try XCTUnwrap(fixture.sessions.first)

        let all = try await model.importableConversations(harness: .codex, workspaceURL: session.workspaceURL,
                                                          connection: nil)
        XCTAssertEqual(all.conversations.map(\.providerSessionID), ["visual-codex-session", "fixture-history-2"])
        XCTAssertEqual(all.conversations.map(\.snippet), [nil, nil])
        let matches = try await model.importableConversations(harness: .codex, workspaceURL: session.workspaceURL,
                                                              connection: nil, searchTerm: " native ")
        XCTAssertEqual(matches.conversations.map(\.providerSessionID), ["visual-codex-session"])
        XCTAssertEqual(matches.conversations.first?.snippet,
                       "Keep the common shell small and preserve provider-specific capabilities.")
        XCTAssertNil(matches.nextCursor)
        XCTAssertFalse(model.isAttached(session.id))
        await model.shutdown()
    }

    func testOpeningFixtureHistoryResultRetainsLocalSearchSelectionWithoutProviderWake() async throws {
        let fixture = VisualFixtureScenario.conversation
        let session = try XCTUnwrap(fixture.sessions.first)
        let selection = CodexHistorySearchSelection(
            query: "provider",
            snippet: "Keep the provider-specific capabilities."
        )
        let conversation = ImportableConversation(codex: CodexThreadSummary(
            id: "visual-codex-session",
            title: session.title,
            preview: "Preserve the task surface while the native shell is restored.",
            workspaceURL: session.workspaceURL,
            updatedAt: session.updatedAt,
            forkedFromID: nil
        ))
        let model = fixture.makeModel()

        let opened = await model.importConversation(conversation, connection: nil, historySelection: selection)

        XCTAssertEqual(opened?.id, session.id)
        XCTAssertEqual(model.store.selectedSessionID, session.id)
        XCTAssertEqual(model.codexHistorySelectionBySessionID[session.id], selection)
        await model.importConversation(conversation, connection: nil)
        XCTAssertNil(model.codexHistorySelectionBySessionID[session.id])
        await model.shutdown()
    }

    func testOpeningSeededHistoryRowReusesHydratedFixtureThreadWithoutProviderWake() async throws {
        let fixture = VisualFixtureScenario.conversation
        let session = try XCTUnwrap(fixture.sessions.first)
        let thread = try XCTUnwrap(fixture.codexHistory.first)
        let selection = CodexHistorySearchSelection(
            query: "native",
            snippet: thread.preview
        )
        let model = fixture.makeModel()

        await model.importConversation(ImportableConversation(codex: thread, snippet: thread.preview), connection: nil,
                                       historySelection: selection)

        XCTAssertEqual(model.store.sessions, fixture.sessions)
        XCTAssertEqual(model.store.selectedSessionID, session.id)
        XCTAssertFalse(model.isAttached(session.id))
        XCTAssertEqual(model.codexHistorySelectionBySessionID[session.id], selection)
        XCTAssertEqual(
            CodexHistorySearchProjection.matchingTurnIDs(
                in: try XCTUnwrap(model.codexPresentationBySessionID[session.id]),
                query: selection.query
            ),
            ["visual-turn-001"]
        )

        // A seeded row no fixture task continues is not resumed: the fixture has no provider.
        let other = try XCTUnwrap(fixture.codexHistory.last)
        let refused = await model.importConversation(ImportableConversation(codex: other), connection: nil)
        XCTAssertNil(refused)
        XCTAssertEqual(model.store.sessions, fixture.sessions)
        XCTAssertNotNil(model.bootstrapError)
        await model.shutdown()
    }

    func testOpeningFixtureSubagentCreatesNotLoadedChildWithoutRuntimeWake() async throws {
        let fixture = VisualFixtureScenario.conversation
        let parent = try XCTUnwrap(fixture.sessions.first(where: { $0.harness == .codex }))
        let model = fixture.makeModel()

        await model.openCodexSubagent(threadID: "visual-child-001", from: parent)

        let child = try XCTUnwrap(
            model.store.sessions.first(where: { $0.providerSessionID == "visual-child-001" })
        )
        XCTAssertEqual(model.store.selectedSessionID, child.id)
        XCTAssertFalse(model.isAttached(child.id))
        let childState = try XCTUnwrap(model.codexPresentationBySessionID[child.id])
        XCTAssertEqual(childState.thread?.id, "visual-child-001")
        XCTAssertEqual(childState.thread?.parentThreadID, "visual-codex-session")
        XCTAssertEqual(childState.thread?.status, .notLoaded)
        XCTAssertTrue(childState.thread?.turns.isEmpty == true)
        XCTAssertTrue(childState.serverRequestsByID.isEmpty)
        await model.shutdown()
    }

    func testFixtureQueueSubmissionRemainsClientOwnedWithoutRuntimeWake() async throws {
        let fixture = VisualFixtureScenario.conversation
        let session = try XCTUnwrap(fixture.sessions.first(where: { $0.harness == .codex }))
        let model = fixture.makeModel()
        let originalQueue = model.followUps.queue(for: session.id)

        await model.submitCodex(
            CodexComposerDraft(inputs: [.text("Queue this after the approval")]),
            action: .queue,
            to: session
        )

        let queue = model.followUps.queue(for: session.id)
        XCTAssertEqual(queue.count, originalQueue.count + 1)
        XCTAssertEqual(queue.last?.draft.text, "Queue this after the approval")
        XCTAssertEqual(queue.last?.state, .pending)
        XCTAssertFalse(model.isAttached(session.id))
        await model.shutdown()
    }

    func testFixtureAutomaticSubmissionQueuesActiveTurnWithoutRuntimeWake() async throws {
        let fixture = VisualFixtureScenario.conversation
        let session = try XCTUnwrap(fixture.sessions.first(where: { $0.harness == .codex }))
        let preferences = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests")))
        preferences.set(CodexFollowUpMode.queue.rawValue, forKey: CodexFollowUpMode.preferenceKey)
        let model = fixture.makeModel(preferences: preferences)
        let originalQueue = model.followUps.queue(for: session.id)

        await model.send("Automatic input while the fixture turn is active", to: session)

        let queue = model.followUps.queue(for: session.id)
        XCTAssertEqual(queue.count, originalQueue.count + 1)
        XCTAssertEqual(queue.last?.draft.text, "Automatic input while the fixture turn is active")
        XCTAssertEqual(queue.last?.state, .pending)
        XCTAssertFalse(model.isAttached(session.id))
        await model.shutdown()
    }

    func testFixtureAutomaticSubmissionSteersByDefaultAndFailsClosedWithoutRuntimeWake() async throws {
        let fixture = VisualFixtureScenario.conversation
        let session = try XCTUnwrap(fixture.sessions.first(where: { $0.harness == .codex }))
        let preferences = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests")))
        let model = fixture.makeModel(preferences: preferences)

        await model.send("Steer the fixture turn by default", to: session)

        let failed = try XCTUnwrap(model.followUps.queue(for: session.id).last)
        XCTAssertEqual(failed.draft.text, "Steer the fixture turn by default")
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.failureMessage, L10n.string("Codex steer is unavailable for this runtime"))
        XCTAssertFalse(model.isAttached(session.id))
        await model.shutdown()
    }

    func testFixtureQueueCancelRetryAndMoveStayClientOwned() async throws {
        let fixture = VisualFixtureScenario.conversation
        let session = try XCTUnwrap(fixture.sessions.first(where: { $0.harness == .codex }))
        let model = fixture.makeModel()
        let originalQueue = model.followUps.queue(for: session.id)
        let pendingID = try XCTUnwrap(originalQueue.first?.id)
        let failedID = try XCTUnwrap(originalQueue.last?.id)

        model.moveQueued(pendingID, in: session, to: originalQueue.count - 1)
        XCTAssertEqual(model.followUps.queue(for: session.id).map(\.id), [failedID, pendingID])
        await model.removeQueued(pendingID, for: session)
        XCTAssertEqual(model.followUps.queue(for: session.id).map(\.id), [failedID])

        model.retryQueued(failedID, for: session)

        let retried = try XCTUnwrap(model.followUps.queue(for: session.id).first)
        XCTAssertEqual(retried.id, failedID)
        XCTAssertEqual(retried.state, .pending)
        XCTAssertNil(retried.failureMessage)
        XCTAssertFalse(model.isAttached(session.id))
        await model.shutdown()
    }

    func testFixtureSteerFailsClosedWithoutRuntimeWake() async throws {
        let fixture = VisualFixtureScenario.conversation
        let session = try XCTUnwrap(fixture.sessions.first(where: { $0.harness == .codex }))
        let model = fixture.makeModel()

        await model.submitCodex(
            CodexComposerDraft(inputs: [.text("Steer the active turn")]),
            action: .steer,
            to: session
        )

        let failed = try XCTUnwrap(model.followUps.queue(for: session.id).last)
        XCTAssertEqual(failed.draft.text, "Steer the active turn")
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(
            failed.failureMessage,
            L10n.string("Codex steer is unavailable for this runtime")
        )
        XCTAssertEqual(model.errorBySessionID[session.id], failed.failureMessage)
        XCTAssertFalse(model.isAttached(session.id))
        await model.shutdown()
    }

    func testRestoredHistorySelectionLoadsWithoutRuntimeWake() async throws {
        let suiteName = testDefaultsSuite("NativeHarnessClientTests.history-restart")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let selectionRepository = UserDefaultsCodexHistorySelectionRepository(
            defaults: defaults,
            keyPrefix: "selection."
        )
        let session = SessionRecord(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/history-restart"),
            runtimeExecutableURL: URL(filePath: "/usr/bin/true"),
            title: "History restart",
            providerSessionID: "history-thread"
        )
        let backingRepository = InMemorySessionRepository(sessions: [session])
        let thread = CodexThreadSummary(
            id: "history-thread",
            title: session.title,
            preview: "A selected history result.",
            workspaceURL: session.workspaceURL,
            updatedAt: session.updatedAt,
            forkedFromID: nil
        )
        let selection = CodexHistorySearchSelection(
            query: "selected history",
            snippet: "A selected history result."
        )

        let firstModel = AppModel(
            store: SessionStore(
                sessions: [session],
                repository: backingRepository
            ),
            runtimeSelections: RuntimeSelectionStore(
                defaults: defaults,
                discoversRuntimes: false,
                loadsPersistedSelections: false
            ),
            codexHistorySelectionRepository: selectionRepository,
            restoresIndexOnLaunch: false,
            isVisualFixture: true
        )
        await firstModel.importConversation(ImportableConversation(codex: thread), connection: nil,
                                            historySelection: selection)
        XCTAssertFalse(firstModel.isAttached(session.id))
        await firstModel.shutdown()

        let restoredModel = AppModel(
            store: SessionStore(repository: backingRepository),
            runtimeSelections: RuntimeSelectionStore(
                defaults: defaults,
                discoversRuntimes: false,
                loadsPersistedSelections: false
            ),
            codexHistorySelectionRepository: selectionRepository,
            restoresIndexOnLaunch: true,
            isVisualFixture: true
        )
        await restoredModel.restoreIndex()

        XCTAssertEqual(
            restoredModel.codexHistorySelectionBySessionID[session.id],
            selection
        )
        XCTAssertFalse(restoredModel.isAttached(session.id))
        await restoredModel.shutdown()
    }
}
#endif
