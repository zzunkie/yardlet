import Foundation
import XCTest
@testable import NativeHarnessClient

/// A Claude task stopped by a plan limit, through the app model on the product route: the card,
/// continuing under another account that shares the history, the automatic continue once the
/// limit resets, and the retry and warning lines while the task runs.
@MainActor final class ClaudeUsageLimitAppModelTests: XCTestCase {
    func testContinuingUnderAnotherAccountSwitchesThenAsksClaudeToPickUp() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        // The harness's runtime, which the task runs, is the CLI the Claude app bundles, at that app's
        // versioned path.
        let bundled = try bundledCLI("2.1.290", beside: fixture.cli)
        model.runtimeSelections.select(bundled, for: .claudeCode)
        let created = await model.createSession(harness: .claudeCode, workspaceURL: fixture.shared,
            runtimeExecutableURL: bundled, title: "Limit", connection: fixture.first)
        let task = try XCTUnwrap(created, model.errorBySessionID.values.first ?? "Missing task")
        let providerID = try XCTUnwrap(task.providerSessionID)
        model.composerDrafts.tasks.draft(for: task.id).text = "Keep my draft"

        let transport = try XCTUnwrap(fixture.transports.all.first)
        let resetsAt = Date().addingTimeInterval(3_600)
        for frame in limitFrames(resetsAt: resetsAt) { await transport.emit(frame) }
        let card = try await waitForLimitCard(in: model, task: task)
        // Another task's message waits for the continue the default setting armed.
        let held = await model.deliverTaskMessage(TaskMessage(senderID: UUID().uuidString, senderName: "Planner",
            body: "Also check the docs"), to: task)
        guard case .afterReset = held else { return XCTFail("Held for the continue: \(held)") }
        try await waitUntil { model.store.sessions.first?.status == .failed }
        XCTAssertFalse(model.transcriptBySessionID[task.id]?.contains {
            if case .error = $0.content { return true }
            return false
        } ?? true, "The card takes the place of a generic error")

        XCTAssertEqual(Set(model.usageLimitAccounts(for: task)), [fixture.next, fixture.signedOut],
            "Only accounts sharing the history are offered, never the current one")

        // A refused switch leaves the task where it was, still waiting for its reset, and says why on the card.
        await model.continueAfterUsageLimit(using: fixture.signedOut, for: task)
        XCTAssertEqual(model.store.sessions.first?.connection, fixture.first)
        XCTAssertEqual(model.usageLimitAutoContinue[task.id]?.waits(for: resetsAt), true)
        XCTAssertEqual(model.usageLimitSwitchErrorBySessionID[task.id], ProviderConnectionError.signedOut.localizedDescription)
        let nothingSent = await transport.sentValues
        XCTAssertTrue(nothingSent.isEmpty)
        XCTAssertEqual(model.transcriptBySessionID[task.id]?.last?.id, card)

        // The Claude app has updated meanwhile and removed the version the task recorded. The next
        // account's login is asked of the CLI the task resumes with, the harness's runtime, which
        // follows the app to where it keeps the CLI now.
        let updated = try bundledCLI("2.1.291", beside: fixture.cli)
        try FileManager.default.removeItem(at: task.runtimeExecutableURL)
        await model.continueAfterUsageLimit(using: fixture.next, for: task)
        XCTAssertNil(model.usageLimitSwitchErrorBySessionID[task.id])

        let switched = try XCTUnwrap(model.store.sessions.first)
        XCTAssertEqual(switched.connection, fixture.next)
        XCTAssertEqual(switched.runtimeExecutableURL.path, updated.path)
        XCTAssertEqual(switched.providerSessionID, providerID)
        XCTAssertEqual(model.composerDrafts.tasks.draft(for: task.id).text, "Keep my draft")
        let resumedTransport = try XCTUnwrap(fixture.transports.all.last)
        XCTAssertFalse(resumedTransport === transport)
        let sent = await resumedTransport.sentValues.compactMap { $0["message"]?["content"]?.stringValue }
        XCTAssertEqual(sent, [UsageLimitContinuation.afterAccountSwitch])
        XCTAssertEqual(model.transcriptBySessionID[task.id]?.last?.content,
            .user(text: UsageLimitContinuation.afterAccountSwitch))
        XCTAssertNotEqual(model.transcriptBySessionID[task.id]?.last?.id, card)
        XCTAssertNil(model.usageLimitAutoContinue[task.id])
        // What waited for the continue follows it on the new account, as it does after an automatic move.
        await resumedTransport.emit(try json(#"{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"s"}"#))
        try await waitUntil { await resumedTransport.sentValues.count == 2 }
        let followed = await resumedTransport.sentValues.last?["message"]?["content"]?.stringValue
        XCTAssertTrue(followed?.contains("Also check the docs") == true, followed ?? "")
        let old = await transport.sentValues
        XCTAssertTrue(old.isEmpty, "Nothing went under the spent account")
    }

    func testTheAutomaticContinueWaitsForTheResetAndThenAsksClaudeToPickUp() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        model.usageLimitResumeGrace = .zero
        // The CLI names the reset in whole seconds.
        let task = try await limitedTask(in: fixture, resetsAt: Date().addingTimeInterval(2))
        let transport = try XCTUnwrap(fixture.transports.all.first)
        let resetsAt = try await limitCardReset(in: model, task: task)

        model.setUsageLimitAutoContinue(true, resetsAt: resetsAt, for: task)
        XCTAssertEqual(model.usageLimitAutoContinue[task.id]?.resetsAt, resetsAt)
        // What another task and a schedule's run (through auto-fix's delivery) send meanwhile waits for
        // the continue, as Claude Code holds what is queued during its wait, instead of starting a turn
        // the limit would stop again and taking the wait away.
        let delivery = await model.deliverTaskMessage(TaskMessage(senderID: UUID().uuidString, senderName: "Planner",
            body: "Also check the docs"), to: task)
        XCTAssertEqual(delivery, .afterReset(resetsAt))
        let scheduled = await model.deliverAutoFix("Run the nightly check", to: task.id)
        XCTAssertTrue(scheduled)
        XCTAssertEqual(model.usageLimitAutoContinue[task.id]?.resetsAt, resetsAt, "The wait stays armed")
        let early = await transport.sentValues.count
        XCTAssertEqual(early, 0, "Nothing is sent before the reset")
        try await waitUntil {
            await transport.sentValues.contains { $0["message"]?["content"]?.stringValue == UsageLimitContinuation.afterReset }
        }
        XCTAssertNil(model.usageLimitAutoContinue[task.id])
        XCTAssertEqual(model.transcriptBySessionID[task.id]?.last?.content, .user(text: UsageLimitContinuation.afterReset))
        // They follow the continue, each as the turn before it ends.
        for count in [2, 3] {
            await transport.emit(try json(#"{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"s"}"#))
            try await waitUntil { await transport.sentValues.count == count }
        }
        let sent = await transport.sentValues.compactMap { $0["message"]?["content"]?.stringValue }
        XCTAssertEqual(sent.count, 3)
        XCTAssertEqual(sent.first, UsageLimitContinuation.afterReset)
        XCTAssertTrue(sent.dropFirst().first?.contains("Also check the docs") == true, "\(sent)")
        XCTAssertEqual(sent.last, "Run the nightly check")
    }

    /// A limit that stops a task and resets within a day arms its continue as it comes, as Claude
    /// Code's own "Continue automatically at usage limit" does unless turned off; one days out waits
    /// for the person. Turned off, the setting disarms what it armed and leaves nothing of it but its
    /// value, a new limit arms nothing, and the person's own choice on a card stands.
    func testALimitThatResetsWithinADayContinuesByDefaultUntilTheSettingIsTurnedOff() async throws {
        let soon = try makeFixture()
        soon.model.usageLimitResumeGrace = .zero
        // The CLI names the reset in whole seconds.
        let task = try await limitedTask(in: soon, resetsAt: Date().addingTimeInterval(2))
        let transport = try XCTUnwrap(soon.transports.all.first)
        try await waitUntil { soon.model.usageLimitAutoContinue[task.id]?.armedBy == .setting }
        try await waitUntil {
            await transport.sentValues.contains { $0["message"]?["content"]?.stringValue == UsageLimitContinuation.afterReset }
        }

        let weekly = try makeFixture()
        let later = try await limitedTask(in: weekly, resetsAt: Date().addingTimeInterval(3 * 86_400))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(weekly.model.usageLimitAutoContinue[later.id], "A reset days out waits for the person")

        let off = try makeFixture()
        let model = off.model
        let stopped = try await limitedTask(in: off)
        let resetsAt = try await limitCardReset(in: model, task: stopped)
        try await waitUntil { model.usageLimitAutoContinue[stopped.id]?.armedBy == .setting }
        off.defaults.set(false, forKey: UsageLimitAutoContinuePreference.key)
        try await waitUntil { model.usageLimitAutoContinue[stopped.id] == nil }
        XCTAssertNil(off.defaults.object(forKey: UsageLimitAutoContinue.preferenceKey), "Only the setting's value is left")
        let offTransport = try XCTUnwrap(off.transports.all.first)
        for frame in limitFrames(resetsAt: resetsAt) { await offTransport.emit(frame) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(model.usageLimitAutoContinue[stopped.id], "Off, a new limit arms nothing")

        model.setUsageLimitAutoContinue(true, resetsAt: resetsAt, for: stopped)
        off.defaults.set(true, forKey: UsageLimitAutoContinuePreference.key)
        off.defaults.set(false, forKey: UsageLimitAutoContinuePreference.key)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNotNil(model.usageLimitAutoContinue[stopped.id], "The person's own choice stands")
        XCTAssertNil(model.usageLimitAutoContinue[stopped.id]?.armedBy)
    }

    /// Coming back after the reset, the card's Resume asks Claude to pick up under the task's own
    /// account and runtime; before the reset it sends nothing.
    func testResumeAfterTheResetAsksClaudeToPickUpUnderTheSameAccount() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        // The CLI names the reset in whole seconds.
        let task = try await limitedTask(in: fixture, resetsAt: Date().addingTimeInterval(2))
        let transport = try XCTUnwrap(fixture.transports.all.first)
        let card = try await waitForLimitCard(in: model, task: task)
        guard case let .usageLimit(limit)? = model.transcriptBySessionID[task.id]?.last?.content,
              let resetsAt = limit.resetsAt else { return XCTFail("The card names its reset") }

        await model.continueAfterUsageLimitReset(entryID: card, for: task)
        let early = await transport.sentValues.count
        XCTAssertEqual(early, 0, "Nothing is sent before the reset")

        try await waitUntil { Date() > resetsAt }
        await model.continueAfterUsageLimitReset(entryID: card, for: task)
        try await waitUntil { await !transport.sentValues.isEmpty }
        let sent = await transport.sentValues.compactMap { $0["message"]?["content"]?.stringValue }
        XCTAssertEqual(sent, [UsageLimitContinuation.afterReset])
        XCTAssertEqual(fixture.transports.all.count, 1, "The same runtime continues")
        XCTAssertEqual(model.store.sessions.first?.connection, fixture.first)
        XCTAssertEqual(model.store.sessions.first?.providerSessionID, task.providerSessionID)
        XCTAssertEqual(model.transcriptBySessionID[task.id]?.last?.content, .user(text: UsageLimitContinuation.afterReset))
    }

    func testTheAutomaticContinueStaysQuietWhenTheTaskChangedMeanwhile() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        model.usageLimitResumeGrace = .zero
        let task = try await limitedTask(in: fixture, resetsAt: Date().addingTimeInterval(2))
        let transport = try XCTUnwrap(fixture.transports.all.first)
        let resetsAt = try await limitCardReset(in: model, task: task)

        // Something arrived after the card: the task is no longer where the limit left it.
        model.setUsageLimitAutoContinue(true, resetsAt: resetsAt, for: task)
        await transport.emit(.object([
            "type": .string("assistant"),
            "message": .object(["content": .array([.object(["type": .string("text"), "text": .string("Late note")])])])
        ]))
        try await waitUntil { model.usageLimitAutoContinue[task.id] == nil }
        try await Task.sleep(for: .milliseconds(200))
        let afterChange = await transport.sentValues
        XCTAssertTrue(afterChange.isEmpty)

        // A message the person sends takes over from an armed continue at once, and goes now. If the
        // turn it starts hits the limit again, the card it ends on is armed in its place, as Claude
        // Code keeps its wait then; the setting, off here, has no part in it.
        fixture.defaults.set(false, forKey: UsageLimitAutoContinuePreference.key)
        let later = Date().addingTimeInterval(3_600)
        model.setUsageLimitAutoContinue(true, resetsAt: later, for: task)
        await model.send(HarnessUserInput(text: "Use the other approach"), to: task)
        XCTAssertNil(model.usageLimitAutoContinue[task.id])
        try await Task.sleep(for: .milliseconds(600))
        let sent = await transport.sentValues.compactMap { $0["message"]?["content"]?.stringValue }
        XCTAssertEqual(sent, ["Use the other approach"])
        for frame in limitFrames(resetsAt: later) { await transport.emit(frame) }
        try await waitUntil { model.usageLimitAutoContinue[task.id] != nil }
        XCTAssertEqual(model.usageLimitAutoContinue[task.id]?.waits(for: later), true)
        XCTAssertNil(model.usageLimitAutoContinue[task.id]?.armedBy, "The person's own choice carries over")

        // Archiving the task takes its armed continue along, the saved one too, so nothing is sent at
        // the reset, nor after the task is unarchived or Yardlet relaunched; nothing else its
        // continuations kept for it stays either.
        XCTAssertNotNil(UsageLimitAutoContinue.load(from: fixture.defaults)[task.id])
        XCTAssertFalse(continuationState(of: task.id, in: model.continuations).isEmpty)
        await model.archive(try XCTUnwrap(model.store.sessions.first { $0.id == task.id }))
        XCTAssertFalse(model.store.sessions.contains { $0.id == task.id })
        XCTAssertNil(model.usageLimitAutoContinue[task.id])
        XCTAssertNil(UsageLimitAutoContinue.load(from: fixture.defaults)[task.id])
        XCTAssertEqual(continuationState(of: task.id, in: model.continuations), [])
    }

    /// An armed continue outlasts a relaunch, which Claude Code's own wait does not, and goes once the
    /// reset has passed, to the card read back from the task's saved conversation: that card names its
    /// reset only in the CLI's words, and the notice of a subagent the same limit stopped follows it.
    func testAnArmedContinueOutlastsARelaunchAndGoesToTheCardReadBack() async throws {
        let fixture = try makeFixture()
        var zone = Calendar(identifier: .gregorian)
        zone.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        // The CLI's words name the reset to the minute: one that passed while Yardlet was closed.
        let resetsAt = try XCTUnwrap(zone.dateInterval(of: .minute, for: Date().addingTimeInterval(-300))?.start)
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.timeZone = zone.timeZone
        time.dateFormat = "h:mma"
        let words = "You've hit your session limit · resets \(time.string(from: resetsAt).lowercased()) (Asia/Seoul)"
        let task = SessionRecord(harness: .claudeCode, workspaceURL: fixture.shared, runtimeExecutableURL: fixture.cli,
            title: "Limit", titleOrigin: .manual, status: .failed, providerSessionID: UUID().uuidString.lowercased(),
            connection: fixture.first)
        let written = resetsAt.addingTimeInterval(-600)
        let notice = """
            <task-notification>
            <task-id>a56354ab8ecfc0f4e</task-id>
            <status>failed</status>
            <summary>Agent "Review the parser" failed: \(words)</summary>
            </task-notification>
            """
        try savedConversation([
            ["type": "user", "timestamp": written.addingTimeInterval(-5),
             "message": ["role": "user", "content": "Refactor the parser"]],
            ["type": "assistant", "timestamp": written, "error": "rate_limit", "isApiErrorMessage": true,
             "message": ["role": "assistant", "model": "<synthetic>", "content": [["type": "text", "text": words]]]],
            ["type": "user", "timestamp": written.addingTimeInterval(0.2), "origin": ["kind": "task-notification"],
             "message": ["role": "user", "content": notice]]
        ], of: task, in: fixture)
        let repository = InMemorySessionRepository(sessions: [task])

        // Armed before the quit, while the reset was still ahead.
        let before = fixture.makeModel(SessionStore(sessions: [task], repository: repository))
        before.usageLimitResumeGrace = .seconds(3_600)
        before.setUsageLimitAutoContinue(true, resetsAt: resetsAt, for: task)
        XCTAssertFalse(continuationTimers(in: before.continuations).isEmpty)
        await before.shutdown()
        XCTAssertEqual(UsageLimitAutoContinue.load(from: fixture.defaults)[task.id]?.resetsAt, resetsAt)
        XCTAssertEqual(continuationTimers(in: before.continuations), [], "The quit stops the timer; the record waits")

        let store = SessionStore(repository: repository)
        try await store.restore()
        let after = fixture.makeModel(store)
        after.usageLimitResumeGrace = .zero
        await after.refreshNativeClaudeConversation(for: try XCTUnwrap(store.sessions.first))
        let entries = after.transcriptBySessionID[task.id] ?? []
        let card = try XCTUnwrap(UsageLimitContinuation.card(in: entries), "\(entries.map(\.content))")
        XCTAssertNotEqual(card.id, entries.last?.id, "The subagent's notice follows the card")
        guard case let .usageLimit(limit) = card.content else { return XCTFail("A limit card") }
        XCTAssertEqual(limit.resetsAt, resetsAt)
        XCTAssertEqual(limit.window, .session)

        await after.continueWorkInterruptedByRestart()
        try await waitUntil { fixture.transports.all.last != nil }
        let transport = try XCTUnwrap(fixture.transports.all.last)
        try await waitUntil {
            await transport.sentValues.contains { $0["message"]?["content"]?.stringValue == UsageLimitContinuation.afterReset }
        }
        let configuration = await transport.configuration
        XCTAssertEqual(configuration?.providerSessionID, task.providerSessionID, "The same conversation continues")
        XCTAssertEqual(after.store.sessions.first?.connection, fixture.first)
        XCTAssertNil(after.usageLimitAutoContinue[task.id])
        XCTAssertTrue(UsageLimitAutoContinue.load(from: fixture.defaults).isEmpty, "It goes once")
        await after.shutdown()
    }

    /// With Settings › Harness Accounts' moves to an account with room on, a task a limit stopped whose limit
    /// resets after its cache would expire moves at the end of its turn to the account with room, keeps
    /// its conversation and why it moved, and asks Claude to pick up there. The continue the default
    /// setting armed as the limit came stands aside for the move. A background command the turn started
    /// goes on in the CLI after the limit, as after any turn end, so the move waits for it rather than
    /// closing the CLI that runs it, and goes once it ends.
    func testALimitThatResetsAfterTheCacheExpiresMovesTheTaskToAnAccountWithRoom() async throws {
        for runsACommand in [false, true] {
            let fixture = try makeFixture()
            let model = fixture.model
            read(fixture.first, used: 0.5, in: model)
            read(fixture.next, used: 0.2, in: model)
            model.startAccountMoves()
            let command = try json(#"{"type":"system","subtype":"task_started","task_id":"t-shell","tool_use_id":"shell","description":"npm run dev","task_type":"local_bash","is_backgrounded":true}"#)
            let task = try await limitedTask(in: fixture, resetsAt: Date().addingTimeInterval(2 * 3_600),
                                             before: runsACommand ? [command] : [])
            let card = try await waitForLimitCard(in: model, task: task)
            if runsACommand {
                try await waitUntil { model.accountMoveHolds[task.id]?.waitsFor == .backgroundWork }
                XCTAssertEqual(model.store.sessions.first?.connection, fixture.first, "The move waits for the command")
                XCTAssertEqual(fixture.transports.all.count, 1)
                await fixture.transports.all.first?.emit(try json(
                    #"{"type":"system","subtype":"task_notification","task_id":"t-shell","status":"completed","summary":"Done"}"#))
            }

            try await waitUntil { model.store.sessions.first?.connection == fixture.next && fixture.transports.all.count == 2 }
            let resumed = try XCTUnwrap(fixture.transports.all.last)
            try await waitUntil {
                await resumed.sentValues.contains { $0["message"]?["content"]?.stringValue == UsageLimitContinuation.afterAccountSwitch }
            }
            XCTAssertEqual(fixture.transports.all.count, 2)
            XCTAssertEqual(model.store.sessions.first?.providerSessionID, task.providerSessionID)
            let assignment = try XCTUnwrap(model.accountAssignments.assignment(for: task.id))
            XCTAssertEqual(assignment.accountID, fixture.next.id)
            XCTAssertEqual(assignment.replacedAccountName, fixture.first.name)
            XCTAssertNil(model.usageLimitAutoContinue[task.id])
            XCTAssertNotEqual(model.transcriptBySessionID[task.id]?.last?.id, card)
            XCTAssertNil(model.accountSwitchesAfterTurn[task.id])
        }
    }

    /// A limit that resets before the task's cache expires keeps the task where it is, armed to
    /// continue at the reset, as is one with no account with room to go to, or with room only on an
    /// account whose model list leaves out the task's model (a model only the task's plan offers);
    /// turning the setting off disarms what it armed and leaves the card as it was. The default
    /// continue is off here, so the move's own wait is the one armed.
    func testALimitThatResetsBeforeTheCacheExpiresWaitsForTheReset() async throws {
        let cases: [(nextUsed: Double, resetsIn: TimeInterval, taskModel: String?)] = [
            (0.2, 20 * 60, nil), (0.95, 2 * 3_600, nil), (0.2, 2 * 3_600, "claude-mythos-5-1")
        ]
        for (nextUsed, resetsIn, taskModel) in cases {
            let fixture = try makeFixture()
            let model = fixture.model
            fixture.defaults.set(false, forKey: UsageLimitAutoContinuePreference.key)
            read(fixture.first, used: 0.5, in: model)
            read(fixture.next, used: nextUsed, in: model)
            if let taskModel {
                let opus = HarnessModelOption(value: "opus", name: "Opus")
                model.modelCatalogs.recordClaude([opus, HarnessModelOption(value: taskModel, name: taskModel)], for: fixture.first)
                model.modelCatalogs.recordClaude([opus], for: fixture.next)
            }
            model.startAccountMoves()
            let resetsAt = Date().addingTimeInterval(resetsIn)
            let task = try await limitedTask(in: fixture, resetsAt: resetsAt,
                                             options: taskModel.map { [ClaudeLaunchOption.model: $0] } ?? [:])
            let card = try await waitForLimitCard(in: model, task: task)

            try await waitUntil { model.usageLimitAutoContinue[task.id]?.waits(for: resetsAt) == true }
            XCTAssertEqual(model.usageLimitAutoContinue[task.id]?.armedBy, .accountMove)
            XCTAssertNotNil(UsageLimitAutoContinue.load(from: model.preferences)[task.id], "Kept as one the person armed is")
            XCTAssertEqual(model.store.sessions.first?.connection, fixture.first)
            XCTAssertEqual(fixture.transports.all.count, 1)
            let sent = await fixture.transports.all[0].sentValues
            XCTAssertTrue(sent.isEmpty, "Nothing is sent before the reset")
            XCTAssertNil(model.accountAssignments.assignment(for: task.id))

            model.preferences.set(false, forKey: AccountMovePreference.key)
            model.followAccountMovePreference()
            XCTAssertNil(model.usageLimitAutoContinue[task.id])
            XCTAssertNil(UsageLimitAutoContinue.load(from: model.preferences)[task.id], "Nothing is left to arm again")
            XCTAssertNil(model.accountMoveLook)
            XCTAssertEqual(model.transcriptBySessionID[task.id]?.last?.id, card)
        }
    }

    /// An idle task on a nearly spent account moves to an account with room once its cache has
    /// expired, without starting its CLI. One whose cache lives stays, and is looked at again when it
    /// expires; with no account with room elsewhere nothing moves.
    func testAnIdleTaskLeavesANearlySpentAccountOnceItsCacheHasExpired() async throws {
        var rested: SessionRecord?, recent: SessionRecord?
        let fixture = try makeFixture { first, cli in
            let workspace = cli.deletingLastPathComponent()
            // It recorded a version of the Claude app's CLI that the app has removed since.
            rested = SessionRecord(harness: .claudeCode, workspaceURL: workspace,
                runtimeExecutableURL: Self.bundledCLIPath("2.1.290", beside: cli),
                title: "Rested", updatedAt: Date().addingTimeInterval(-2 * 3_600), providerSessionID: "rested",
                connection: first)
            recent = SessionRecord(harness: .claudeCode, workspaceURL: workspace, runtimeExecutableURL: cli,
                title: "Recent", updatedAt: Date().addingTimeInterval(-10 * 60), providerSessionID: "recent",
                connection: first)
            return [rested, recent].compactMap { $0 }
        }
        let model = fixture.model
        let (restedTask, recentTask) = try (XCTUnwrap(rested), XCTUnwrap(recent))
        // The newest install, so the harness's runtime, which the rested task resumes with.
        let updated = try bundledCLI("2.1.291", beside: fixture.cli)
        model.runtimeSelections.select(updated, for: .claudeCode)
        try await model.store.restore()
        func task(_ id: UUID) -> SessionRecord? { model.store.sessions.first { $0.id == id } }

        // Nowhere with room: nothing moves.
        read(fixture.first, used: 0.95, in: model)
        read(fixture.next, used: 0.93, in: model)
        model.startAccountMoves()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(task(restedTask.id)?.connection, fixture.first)

        read(fixture.next, used: 0.2, in: model)
        try await waitUntil { task(restedTask.id)?.connection == fixture.next }
        XCTAssertEqual(task(restedTask.id)?.providerSessionID, "rested")
        XCTAssertEqual(task(restedTask.id)?.runtimeExecutableURL.path, updated.path, "The login was asked of the CLI it resumes with")
        XCTAssertEqual(model.accountAssignments.assignment(for: restedTask.id)?.replacedAccountName, fixture.first.name)
        XCTAssertEqual(task(recentTask.id)?.connection, fixture.first, "Its cache lives")
        XCTAssertEqual(model.accountMoveLook?.at, task(recentTask.id).map {
            $0.updatedAt.addingTimeInterval(AccountRouting.promptCacheLifetime)
        }, "Looked at again once its cache has expired")
        XCTAssertTrue(fixture.transports.all.isEmpty, "No CLI starts for the move")
    }

    /// A task whose turn ended with a background command still running waits to move to the account
    /// chosen during the turn, and what is sent meanwhile waits for the move; the account chosen again
    /// once the task is idle waits the same way. When its runtime closes another way first (an
    /// immediate switch, as a limit card's Continue with another account makes), the command ends with that CLI:
    /// its row stops, the move settles, and what waited goes to the new runtime rather than waiting
    /// for a command no process runs (2026-11-10: a task's messages, the person's own among them,
    /// waited hours behind a background shell the closed CLI had taken with it).
    func testWhatWaitsForAMoveGoesOnceTheRuntimeRunningItsBackgroundWorkCloses() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        let created = await model.createSession(harness: .claudeCode, workspaceURL: fixture.shared,
            runtimeExecutableURL: fixture.cli, title: "Background", connection: fixture.first)
        let task = try XCTUnwrap(created, model.errorBySessionID.values.first ?? "Missing task")
        let closing = try XCTUnwrap(fixture.transports.all.first)
        func backgroundRows() -> Int {
            BackgroundTasksProjection(entries: model.transcriptBySessionID[task.id] ?? []).rows.count
        }

        await closing.emit(try json(#"{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"message_start","message":{}},"session_id":"s"}"#))
        try await waitUntil { model.store.sessions.first?.status == .running }
        await model.chooseAccount(fixture.next, for: task)
        XCTAssertEqual(model.accountSwitchesAfterTurn[task.id], fixture.next)
        await closing.emit(try json(#"{"type":"system","subtype":"task_started","task_id":"t-shell","tool_use_id":"shell","description":"npm run dev","task_type":"local_bash","is_backgrounded":true}"#))
        await closing.emit(try json(#"{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"s"}"#))
        try await waitUntil { model.store.sessions.first?.status == .ready && backgroundRows() == 1 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.store.sessions.first?.connection, fixture.first, "The move waits for the background work")
        // Chosen again once the task is idle, the account waits the same way rather than ending the command.
        model.cancelAccountSwitchAfterTurn(for: task.id)
        await model.chooseAccount(fixture.next, for: try XCTUnwrap(model.store.sessions.first))
        try await waitUntil { model.accountMoveHolds[task.id]?.waitsFor == .backgroundWork }
        XCTAssertEqual(model.accountMoveHolds[task.id]?.owner, .person)
        XCTAssertEqual(model.store.sessions.first?.connection, fixture.first)
        XCTAssertEqual(backgroundRows(), 1)

        await model.switchAccount(to: fixture.next, for: try XCTUnwrap(model.store.sessions.first))
        XCTAssertEqual(model.store.sessions.first?.connection, fixture.next)
        XCTAssertEqual(backgroundRows(), 0, "The command ended with its CLI")
        await model.send(HarnessUserInput(text: "Morning check"), to: task)

        let resumed = try XCTUnwrap(fixture.transports.all.last)
        XCTAssertFalse(resumed === closing)
        try await waitUntil {
            await resumed.sentValues.contains { $0["message"]?["content"]?.stringValue == "Morning check" }
        }
        XCTAssertTrue(model.followUps.queue(for: task.id).isEmpty)
        XCTAssertNil(model.accountSwitchesAfterTurn[task.id])
    }

    /// Yardlet takes a task's runtime off it in several ways: its account changes, it starts again
    /// for a context limit, the person chose another CLI for its harness in Settings (as an update
    /// changes it, `AccountChoiceTests`), or the task is archived. Whichever it is, its CLI is
    /// stopped once, the task is left ready with no error, and what still ran in that CLI reads as
    /// stopped. A change the task goes on from at once (an account, a context limit) has its next
    /// runtime by then; another CLI starts at the task's next message, and it is the one chosen.
    /// (A stream that ends by itself is `AppModelTests.testEndedReadyStreamDetachesWithoutManufacturingFailure`.)
    /// Each goes through `AppModel.detachRuntime`, and the coordination log says why the runtime went.
    func testEachWayATaskLosesItsRuntimeStopsItsCLIOnceAndLeavesTheTaskReady() async throws {
        enum Way: String, CaseIterable { case accountChange, contextLimit, cliChanged, archived }
        let reasons: [Way: RuntimeDetachReason] = [.accountChange: .accountChange, .contextLimit: .contextLimit,
                                                   .cliChanged: .cliChanged, .archived: .taskRemoved]
        for way in Way.allCases {
            let fixture = try makeFixture()
            let model = fixture.model
            let log = fixture.shared.appending(path: "task-coordination.log")
            model.coordinationLog.fileURL = log
            let created = await model.createSession(harness: .claudeCode, workspaceURL: fixture.shared,
                runtimeExecutableURL: fixture.cli, title: way.rawValue, connection: fixture.first)
            let task = try XCTUnwrap(created, model.errorBySessionID.values.first ?? "Missing task")
            let first = try XCTUnwrap(fixture.transports.all.first)
            func backgroundRows() -> Int {
                BackgroundTasksProjection(entries: model.transcriptBySessionID[task.id] ?? []).rows.count
            }
            // A context limit and a changed CLI wait for background work instead of ending it, and an
            // archived task takes its conversation along.
            let runsBackgroundWork = way == .accountChange

            await first.emit(try json(#"{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"message_start","message":{}},"session_id":"s"}"#))
            try await waitUntil { model.store.sessions.first?.status == .running }
            if runsBackgroundWork {
                await first.emit(try json(#"{"type":"system","subtype":"task_started","task_id":"t-shell","tool_use_id":"shell","description":"npm run dev","task_type":"local_bash","is_backgrounded":true}"#))
            }
            await first.emit(try json(#"{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"s"}"#))
            try await waitUntil {
                model.store.sessions.first?.status == .ready && backgroundRows() == (runsBackgroundWork ? 1 : 0)
            }
            let current = try XCTUnwrap(model.store.sessions.first)
            let newer = fixture.shared.appending(path: "claude-newer")

            switch way {
            case .accountChange: await model.switchAccount(to: fixture.next, for: current)
            case .contextLimit: await model.continuations.chooseContextLimit("200000", for: current)
            case .cliChanged:
                model.followRuntimeChoices()
                try FileManager.default.copyItem(at: fixture.cli, to: newer)
                model.runtimeSelections.select(newer, for: .claudeCode)
                try await waitUntil { await first.stopCount == 1 && !model.isAttached(task.id) }
            case .archived: await model.archive(current)
            }

            XCTAssertNil(model.errorBySessionID[task.id], way.rawValue)
            switch way {
            case .accountChange, .contextLimit:
                XCTAssertTrue(model.isAttached(task.id), way.rawValue)
                XCTAssertEqual(fixture.transports.all.count, 2, way.rawValue)
                XCTAssertEqual(model.store.sessions.first?.status, .ready, way.rawValue)
            case .cliChanged:
                XCTAssertFalse(model.isAttached(task.id), way.rawValue)
                XCTAssertEqual(fixture.transports.all.count, 1, way.rawValue)
                XCTAssertEqual(model.store.sessions.first?.status, .ready, way.rawValue)
                XCTAssertEqual(model.store.sessions.first?.runtimeExecutableURL, fixture.cli.standardizedFileURL,
                               "The row keeps the CLI the task last started with")
            case .archived:
                XCTAssertTrue(model.store.sessions.isEmpty, way.rawValue)
            }
            if way != .archived { XCTAssertEqual(backgroundRows(), 0, way.rawValue) }
            let stops = await first.stopCount
            XCTAssertEqual(stops, 1, "\(way.rawValue): its CLI is stopped once")
            model.coordinationLog.flush()
            let detached = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
                .map { try JSONDecoder().decode(TaskCoordinationLog.Entry.self, from: Data($0.utf8)) }
                .filter { $0.event == "runtime-detached" }
            XCTAssertEqual(detached, [TaskCoordinationLog.Entry(event: "runtime-detached", task: task.id.uuidString,
                harness: "claude-code", reason: reasons[way]?.rawValue)], way.rawValue)
            if way == .cliChanged {
                await model.send(HarnessUserInput(text: "Next"), to: task)
                XCTAssertTrue(model.isAttached(task.id))
                XCTAssertEqual(fixture.transports.all.count, 2)
                XCTAssertEqual(model.store.sessions.first?.runtimeExecutableURL, newer.standardizedFileURL,
                               "The next start runs the CLI the person chose")
            }
        }
    }

    /// A move Yardlet chose itself never holds up the person and never waits forever (2026-11-11). An
    /// idle task on a nearly spent account whose cache has expired, with a background command running,
    /// waits to move to the account with room, and the line above the composer says it waits for that
    /// command. Another task's message and a schedule's run wait for the move; the person's own message
    /// goes at once on the current account and calls the move off, and what waited follows its turn.
    /// A move that waits past its deadline is given up rather than forced: the command keeps running
    /// in the same CLI, and what waited goes there.
    func testAMoveYardletChoseGivesWayToThePersonAndIsGivenUpAtItsDeadline() async throws {
        for personSends in [true, false] {
            var rested: SessionRecord?
            let fixture = try makeFixture { first, cli in
                rested = SessionRecord(harness: .claudeCode, workspaceURL: cli.deletingLastPathComponent(),
                    runtimeExecutableURL: cli, title: "Dev server", updatedAt: Date().addingTimeInterval(-2 * 3_600),
                    providerSessionID: "dev", connection: first)
                return [rested].compactMap { $0 }
            }
            let model = fixture.model
            let task = try XCTUnwrap(rested)
            try await model.store.restore()
            model.accountMoveSleep = { try await Task.sleep(for: .milliseconds(10)) }
            var now = Date()
            model.accountMoveClock = { now }
            await model.resume(task)
            let transport = try XCTUnwrap(fixture.transports.all.first)
            func sent(_ text: String) async -> Bool {
                await transport.sentValues.contains { $0["message"]?["content"]?.stringValue?.contains(text) == true }
            }
            func backgroundRows() -> Int {
                BackgroundTasksProjection(entries: model.transcriptBySessionID[task.id] ?? []).rows.count
            }
            model.mutateTranscript(for: task.id, publishImmediately: true) {
                $0.apply(.activityStarted(HarnessActivity(id: "shell", kind: "Bash", title: "npm run dev", isBackground: true,
                    subtask: HarnessSubtaskReference(taskID: "t-shell", taskType: "local_bash"))))
            }
            XCTAssertEqual(backgroundRows(), 1)
            read(fixture.first, used: 0.95, in: model)
            read(fixture.next, used: 0.2, in: model)
            model.startAccountMoves()

            try await waitUntil { model.accountMoveHolds[task.id] != nil }
            XCTAssertEqual(model.accountSwitchesAfterTurn[task.id], fixture.next)
            XCTAssertEqual(model.accountMoveHolds[task.id], AccountMoveHold(owner: .yardlet, waitsFor: .backgroundWork, since: now))
            XCTAssertEqual(model.accountMoveHolds[task.id]?.deadline, now.addingTimeInterval(AccountMoveHold.yardletWaitLimit))

            let held = await model.deliverTaskMessage(TaskMessage(senderID: UUID().uuidString, senderName: "Planner",
                body: "Also check the docs"), to: task)
            XCTAssertEqual(held, .afterAccountMove)
            let scheduled = await model.deliverAutoFix("Any new failures?", to: task.id)
            XCTAssertTrue(scheduled)
            XCTAssertEqual(model.followUps.queue(for: task.id).count, 2, "Both wait for the move")
            let nothingYet = await transport.sentValues
            XCTAssertTrue(nothingYet.isEmpty)

            if personSends {
                await model.send(HarnessUserInput(text: "Keep going here"), to: task)
                try await waitUntil { await sent("Keep going here") }
                XCTAssertNil(model.accountSwitchesAfterTurn[task.id], "The person's message called the move off")
                XCTAssertNil(model.accountMoveHolds[task.id])
                XCTAssertEqual(model.followUps.queue(for: task.id).count, 2, "What waited follows the person's turn")
                await transport.emit(try json(#"{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"s"}"#))
            } else {
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(model.accountSwitchesAfterTurn[task.id], fixture.next, "Within its deadline it waits")
                now = now.addingTimeInterval(AccountMoveHold.yardletWaitLimit)
                try await waitUntil { model.accountSwitchesAfterTurn[task.id] == nil }
                XCTAssertNil(model.accountMoveHolds[task.id])
                XCTAssertFalse(model.canMoveAutomatically(try XCTUnwrap(model.store.sessions.first)),
                               "Given up, it is not chosen again until the task works again")
            }
            try await waitUntil { await sent("Also check the docs") }
            XCTAssertEqual(model.store.sessions.first?.connection, fixture.first)
            XCTAssertEqual(fixture.transports.all.count, 1, "The CLI running the command was kept")
            XCTAssertEqual(backgroundRows(), 1)
        }
    }

    /// A schedule's run that would move its task off a nearly spent account moves it only as any move
    /// would go at once: moving closes the task's CLI, and what still runs in it. With a background
    /// command running the task stays and the run goes on the CLI that keeps the command; with a move
    /// already waiting, the run's message waits for that move rather than starting another one, also
    /// once the command has ended and before that move looks again (2026-11-10: a run moved a task at
    /// once, ending its background shell, while a move chosen during its turn still waited).
    func testAScheduledRunLeavesATaskWhoseMoveWouldWaitOnItsAccount() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        read(fixture.first, used: 0.95, in: model)
        read(fixture.next, used: 0.2, in: model)
        // A waiting move looks again later than this test waits.
        model.accountMoveSleep = { try await Task.sleep(for: testWaitLimit * 2) }
        let created = await model.createSession(harness: .claudeCode, workspaceURL: fixture.shared,
            runtimeExecutableURL: fixture.cli, title: "Watch", connection: fixture.first)
        let task = try XCTUnwrap(created, model.errorBySessionID.values.first ?? "Missing task")
        let transport = try XCTUnwrap(fixture.transports.all.first)
        func status() -> SessionStatus? { model.store.sessions.first?.status }
        func backgroundRows() -> Int {
            BackgroundTasksProjection(entries: model.transcriptBySessionID[task.id] ?? []).rows.count
        }
        func sent(_ text: String) async -> Bool {
            await transport.sentValues.contains { $0["message"]?["content"]?.stringValue == text }
        }
        func runSchedule(_ prompt: String) async throws -> ScheduledTaskRun {
            var destination = ScheduleDestination(harness: .claudeCode)
            destination.mode = .continueTask
            destination.targetTaskID = task.id
            let schedule = ScheduledTask(name: prompt, prompt: prompt, trigger: .daily(ScheduleTime(hour: 9, minute: 0)),
                                         destination: destination)
            model.scheduledTasks.create(schedule)
            await model.scheduledTasks.runNow(schedule.id)
            let run = try XCTUnwrap(model.scheduledTasks.schedule(id: schedule.id)?.state.runs.first)
            XCTAssertEqual(run.outcome, .started, run.failure ?? "")
            XCTAssertNil(run.account)
            XCTAssertEqual(model.store.sessions.first?.connection, fixture.first)
            return run
        }
        let result = try json(#"{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"s"}"#)

        await transport.emit(try json(#"{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"message_start","message":{}},"session_id":"s"}"#))
        await transport.emit(try json(#"{"type":"system","subtype":"task_started","task_id":"t-shell","tool_use_id":"shell","description":"npm run dev","task_type":"local_bash","is_backgrounded":true}"#))
        await transport.emit(result)
        try await waitUntil { status() == .ready && backgroundRows() == 1 }
        _ = try await runSchedule("Any new failures?")
        try await waitUntil { await sent("Any new failures?") }
        XCTAssertEqual(backgroundRows(), 1, "The command still runs")
        XCTAssertEqual(fixture.transports.all.count, 1)

        // The account chosen during the turn the run started waits for the command, then for the next look.
        try await waitUntil { status() == .running }
        await model.chooseAccount(fixture.next, for: try XCTUnwrap(model.store.sessions.first))
        XCTAssertEqual(model.accountSwitchesAfterTurn[task.id], fixture.next)
        await transport.emit(result)
        await transport.emit(try json(#"{"type":"system","subtype":"task_notification","task_id":"t-shell","status":"completed","summary":"Done"}"#))
        try await waitUntil { status() == .ready && backgroundRows() == 0 }
        _ = try await runSchedule("Anything else?")
        XCTAssertEqual(model.accountSwitchesAfterTurn[task.id], fixture.next, "The move already waiting stays the one")
        XCTAssertEqual(model.followUps.queue(for: task.id).count, 1, "The run's message waits for it")

        // Cancelling that move keeps the task here, and the run's message goes here.
        model.cancelAccountSwitchAfterTurn(for: task.id)
        try await waitUntil { await sent("Anything else?") }
        XCTAssertEqual(fixture.transports.all.count, 1)
    }

    func testRetriesWarningsAndReportsFollowTheRunningTask() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        model.connections.publish(HarnessAccountSnapshot(id: fixture.first.id, harness: .claudeCode, providerID: nil,
            state: .signedIn, accountLabel: "first@example.test", detail: "", credentialOwner: "Claude Code",
            checkedAt: Date(), usage: ClaudeUsageProbe.usage([], updatedBy: HarnessRateLimit(
                status: .allowed, window: .session, usedFraction: 0.1)), canLogin: false, canLogout: true), for: fixture.first)
        let created = await model.createSession(harness: .claudeCode, workspaceURL: fixture.shared,
            runtimeExecutableURL: fixture.cli, title: "Retry", connection: fixture.first)
        let task = try XCTUnwrap(created)
        let transport = try XCTUnwrap(fixture.transports.all.first)
        await model.send(HarnessUserInput(text: "Go"), to: task)

        await transport.emit(try json(#"""
        {"type":"system","subtype":"api_retry","attempt":2,"max_retries":10,"retry_delay_ms":800,"error_status":529,
          "error":"overloaded","uuid":"r1","session_id":"s"}
        """#))
        try await waitUntil { model.providerRetryBySessionID[task.id] != nil }
        XCTAssertEqual(model.providerRetryBySessionID[task.id], HarnessProviderRetry(attempt: 2, maxRetries: 10, cause: .overloaded))

        await transport.emit(try json(#"""
        {"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":4102444800,
          "rateLimitType":"five_hour","utilization":0.91},"uuid":"w1","session_id":"s"}
        """#))
        try await waitUntil { model.rateLimitWarningBySessionID[task.id] != nil }
        XCTAssertNotNil(model.providerRetryBySessionID[task.id], "A limit report says nothing about the retry")
        XCTAssertEqual(try XCTUnwrap(model.connections.snapshots[fixture.first.id]?.usage.first?.usedFraction),
            0.91, accuracy: 0.0001, "The account list follows the session's own report")

        await transport.emit(try json(#"""
        {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Back"}}}
        """#))
        try await waitUntil { model.providerRetryBySessionID[task.id] == nil }

        await transport.emit(try json(#"""
        {"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":4102444800,
          "rateLimitType":"five_hour","utilization":0.2},"uuid":"w2","session_id":"s"}
        """#))
        try await waitUntil { model.rateLimitWarningBySessionID[task.id] == nil }

        // A turn a sign-in failure ended has nothing to retry. One its retries could not get past has:
        // Retry sends the Claude app's retry message as the person's and leaves the draft alone.
        model.composerDrafts.tasks.draft(for: task.id).text = "Keep my draft"
        await transport.emit(try json(#"""
        {"type":"result","subtype":"success","is_error":true,"api_error_status":401,"terminal_reason":"api_error",
          "result":"Failed to authenticate. API Error: 401","session_id":"s"}
        """#))
        try await waitUntil { model.store.sessions.first?.status == .failed }
        let beforeRetry = await transport.sentValues.count
        await model.retryTurn("latest", in: task)
        let refused = await transport.sentValues.count
        XCTAssertEqual(refused, beforeRetry)

        await transport.emit(try json(#"""
        {"type":"result","subtype":"success","is_error":true,"api_error_status":529,"terminal_reason":"api_error",
          "result":"API Error: Repeated 529 Overloaded errors","session_id":"s"}
        """#))
        try await waitUntil {
            model.transcriptBySessionID[task.id]?.last?.content == .error(
                message: "API Error: Repeated 529 Overloaded errors", recoverable: true, transient: true)
        }
        await model.retryTurn("latest", in: task)
        let retried = await transport.sentValues.dropFirst(beforeRetry).compactMap { $0["message"]?["content"]?.stringValue }
        XCTAssertEqual(retried, [RestartContinuation.claudeRetry])
        XCTAssertEqual(model.composerDrafts.tasks.draft(for: task.id).text, "Keep my draft")
    }

    func testATaskResumesInTheModeItLastChose() async throws {
        let fixture = try makeFixture(currentPermissionMode: "acceptEdits")
        let model = fixture.model
        let session = try await model.store.createSession(harness: .claudeCode, workspaceURL: fixture.shared,
            runtimeExecutableURL: fixture.cli, title: "Mode", titleOrigin: .manual,
            providerOptions: ["permissionMode": "acceptEdits"], connection: fixture.first)
        await model.resume(session)
        let transport = try XCTUnwrap(fixture.transports.all.first)
        let configuration = await transport.configuration
        XCTAssertEqual(configuration?.permissionMode, "acceptEdits")
        let subtypes = await transport.requestSubtypes
        XCTAssertFalse(subtypes.contains("set_permission_mode"), "The launch already carried the saved mode")
        await model.loadProviderCapabilities(for: session)
        XCTAssertEqual(model.providerCapabilitiesBySessionID[session.id]?.selectors
            .first { $0.id == "permissionMode" }?.currentValue, "acceptEdits")
    }

    // MARK: - Fixtures

    private struct Fixture {
        let model: AppModel
        let defaults: UserDefaults
        /// Another app model on the same preferences and saved conversations, as at the next launch.
        let makeModel: @MainActor (SessionStore) -> AppModel
        let shared: URL
        let cli: URL
        let first: ProviderConnection
        let next: ProviderConnection
        let signedOut: ProviderConnection
        let transports: TransportLog
    }

    private final class TransportLog: @unchecked Sendable {
        private let lock = NSLock()
        private var transports: [FakeClaudeTransport] = []
        private let initializeResponse: JSONValue
        init(initializeResponse: JSONValue) { self.initializeResponse = initializeResponse }
        func make() -> FakeClaudeTransport {
            let transport = FakeClaudeTransport(initializeResponse: initializeResponse)
            lock.withLock { transports.append(transport) }
            return transport
        }
        var all: [FakeClaudeTransport] { lock.withLock { transports } }
    }

    private func makeFixture(currentPermissionMode: String? = nil,
                             sessions: (ProviderConnection, URL) -> [SessionRecord] = { _, _ in [] }) throws -> Fixture {
        let shared = try directory()
        let projects = shared.appending(path: "projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let first = try account(linkingTo: projects, signedIn: true)
        let next = try account(linkingTo: projects, signedIn: true)
        let signedOut = try account(linkingTo: projects, signedIn: false)
        let separate = try directory()
        try FileManager.default.createDirectory(at: separate.appending(path: "projects"), withIntermediateDirectories: true)
        let cli = shared.appending(path: "claude-fixture")
        try Data("""
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo '2.1.291 (Claude Code)'; exit 0; fi
        if [ "$1" = "auth" ] && [ -f "$CLAUDE_CONFIG_DIR/.signed-in" ]; then echo '{"loggedIn":true}'; else echo '{"loggedIn":false}'; fi

        """.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        var initialize: [String: JSONValue] = ["models": .array([])]
        if let currentPermissionMode { initialize["current_permission_mode"] = .string(currentPermissionMode) }
        let transports = TransportLog(initializeResponse: .object(initialize))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests.UsageLimit")))
        let homes = [first, next, signedOut, separate].map(connection)
        let makeModel: @MainActor (SessionStore) -> AppModel = { store in
            let model = AppModel(store: store,
                runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
                registry: HarnessRegistry { _, url in
                    YHPProviderCompatibilityAdapter(
                        adapter: ClaudeAdapter(executableURL: url, transportFactory: { _ in transports.make() }),
                        manifest: HarnessProtocolCompatibilityManifest.claude()
                    )
                }, preferences: defaults, transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
                restoresIndexOnLaunch: false)
            for home in homes { try? model.connections.save(home) }
            // The default login keeps its conversations where the accounts do, so automatic assignment uses them.
            model.connections.defaultLoginEnvironment = ["CLAUDE_CONFIG_DIR": shared.path]
            self.addTeardownBlock { await model.shutdown() }
            return model
        }
        let model = makeModel(SessionStore(repository: InMemorySessionRepository(sessions: sessions(connection(first), cli))))
        return Fixture(model: model, defaults: defaults, makeModel: makeModel, shared: shared, cli: cli,
            first: connection(first), next: connection(next), signedOut: connection(signedOut), transports: transports)
    }

    /// - Parameter before: frames of the turn before the limit stops it.
    private func limitedTask(in fixture: Fixture, resetsAt: Date = Date().addingTimeInterval(3_600),
                             options: [String: String] = [:], before: [JSONValue] = []) async throws -> SessionRecord {
        let created = await fixture.model.createSession(harness: .claudeCode, workspaceURL: fixture.shared,
            runtimeExecutableURL: fixture.cli, title: "Limit", connection: fixture.first, providerOptions: options)
        _ = try XCTUnwrap(created, fixture.model.errorBySessionID.values.first ?? "Missing task")
        let transport = try XCTUnwrap(fixture.transports.all.first)
        for frame in before + limitFrames(resetsAt: resetsAt) { await transport.emit(frame) }
        try await waitUntil { fixture.model.store.sessions.first?.status == .failed }
        return try XCTUnwrap(fixture.model.store.sessions.first)
    }

    /// The frames Claude Code 2.1.291 writes when a request is refused by the session limit.
    private func limitFrames(resetsAt: Date) -> [JSONValue] {
        let reset = Int64(resetsAt.timeIntervalSince1970)
        let text = "You've hit your session limit · resets 3pm (Asia/Seoul)"
        return [
            .object([
                "type": .string("rate_limit_event"),
                "rate_limit_info": .object([
                    "status": .string("rejected"), "resetsAt": .integer(reset), "rateLimitType": .string("five_hour"),
                    "utilization": .number(1.0), "isUsingOverage": .bool(false), "overageStatus": .string("rejected")
                ]),
                "uuid": .string(UUID().uuidString), "session_id": .string("s")
            ]),
            .object([
                "type": .string("assistant"), "parent_tool_use_id": .null, "error": .string("rate_limit"),
                "message": .object(["role": .string("assistant"), "model": .string("<synthetic>"),
                    "content": .array([.object(["type": .string("text"), "text": .string(text)])])]),
                "uuid": .string(UUID().uuidString), "session_id": .string("s")
            ]),
            .object([
                "type": .string("result"), "subtype": .string("success"), "is_error": .bool(true),
                "result": .string(text), "session_id": .string("s")
            ])
        ]
    }

    private func limitCardReset(in model: AppModel, task: SessionRecord) async throws -> Date {
        let card = try await waitForLimitCard(in: model, task: task)
        let limit = model.transcriptBySessionID[task.id]?.first { $0.id == card }.flatMap { entry -> HarnessRateLimit? in
            if case let .usageLimit(limit) = entry.content { return limit }
            return nil
        }
        return try XCTUnwrap(limit?.resetsAt, "The card names its reset")
    }

    /// Writes a task's saved conversation where its account's CLI keeps it, each record after the one
    /// before.
    private func savedConversation(_ records: [[String: Any]], of task: SessionRecord, in fixture: Fixture) throws {
        let folder = fixture.shared.appending(path: "projects/project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var parent: String?
        let lines = try records.map { record in
            var record = record
            let uuid = UUID().uuidString.lowercased()
            record["uuid"] = uuid
            record["parentUuid"] = parent ?? NSNull()
            record["sessionId"] = task.providerSessionID
            record["timestamp"] = (record["timestamp"] as? Date)?.ISO8601Format(
                Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            parent = uuid
            return String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: folder.appending(path: "\(task.providerSessionID ?? "").jsonl"))
    }

    /// Shows a signed-in reading of the account with its 5 hour limit used as given, so a move reads it
    /// without asking a CLI.
    private func read(_ connection: ProviderConnection, used: Double, in model: AppModel) {
        model.connections.usesFixtureSnapshots = true
        let now = Date()
        model.connections.publish(HarnessAccountSnapshot(id: connection.id, harness: .claudeCode, providerID: nil,
            state: .signedIn, accountLabel: connection.name, detail: "", credentialOwner: "", checkedAt: now,
            usage: [AccountUsageMetric(id: "claude:session:", label: "5 hour limit", usedFraction: used, detail: "",
                resetsAt: now.addingTimeInterval(4 * 3_600), evidence: .exactQuota, windowMinutes: 300)],
            canLogin: false, canLogout: false), for: connection)
    }

    private func waitForLimitCard(in model: AppModel, task: SessionRecord) async throws -> UUID {
        var card: UUID?
        try await waitUntil {
            card = model.transcriptBySessionID[task.id]?.last { entry in
                if case .usageLimit = entry.content { return true }
                return false
            }?.id
            return card != nil
        }
        return try XCTUnwrap(card)
    }


    /// The coordinator's per-task collections that still hold the task, by name: whatever a
    /// continuation keeps for a task is keyed or listed by its ID.
    private func continuationState(of id: UUID, in continuations: TaskContinuationCoordinator) -> [String] {
        Mirror(reflecting: continuations).children.compactMap { child in
            let holds = switch child.value {
            case let keyed as [UUID: Any]: keyed[id] != nil
            case let listed as Set<UUID>: listed.contains(id)
            case let line as RestartResumeLine: line.waiting.contains(id) || line.starting.contains(id)
            default: false
            }
            return holds ? child.label : nil
        }
    }

    /// The coordinator's timers still waiting to continue a task, by the name of what holds them.
    private func continuationTimers(in continuations: TaskContinuationCoordinator) -> [String] {
        Mirror(reflecting: continuations).children.compactMap { child in
            guard let timers = child.value as? [UUID: Task<Void, Never>],
                  timers.values.contains(where: { !$0.isCancelled }) else { return nil }
            return child.label
        }
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "claude-limit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// Where the Claude app keeps the CLI it bundles under `version`, in the fixture's folder.
    private static func bundledCLIPath(_ version: String, beside cli: URL) -> URL {
        cli.deletingLastPathComponent().appending(path: "Claude/claude-code/\(version)/claude.app/Contents/MacOS/claude")
            .standardizedFileURL
    }

    /// A copy of the fixture CLI at `bundledCLIPath`, as the Claude app installs a version.
    private func bundledCLI(_ version: String, beside cli: URL) throws -> URL {
        let url = Self.bundledCLIPath(version, beside: cli)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: cli, to: url)
        return url
    }

    private func account(linkingTo projects: URL, signedIn: Bool) throws -> URL {
        let root = try directory()
        try FileManager.default.createSymbolicLink(at: root.appending(path: "projects"), withDestinationURL: projects)
        if signedIn { try Data().write(to: root.appending(path: ".signed-in")) }
        return root
    }

    private func connection(_ home: URL) -> ProviderConnection {
        ProviderConnection(id: home.lastPathComponent, name: home.lastPathComponent, harness: .claudeCode,
            providerID: nil, homePath: home.path, credentialSelector: nil)
    }

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
}
