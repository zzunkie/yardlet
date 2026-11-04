import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletRemote

/// The Mac side of the phone remote: the conversation the phone reads is the one model the Mac's
/// timeline draws (projected from transcript and Codex fixtures), its requests offer only "Allow
/// once" and the card's plain deny, nothing beyond the conversation (command output, file contents)
/// is sent, and the app model bridge reads the sidebar's tasks and carries out commands through the
/// window's own model calls — on a fake adapter, so no provider runs.
@MainActor
final class RemoteBridgeTests: XCTestCase {
    func testBankedResetRequiresConfirmationAndDoesNotRepeatAnAnsweredToken() async throws {
        let task = SessionRecord(harness: .codex, workspaceURL: URL(filePath: "/tmp/reset-fixture"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Reset")
        let noLimit = SessionRecord(harness: .codex, workspaceURL: task.workspaceURL,
            runtimeExecutableURL: task.runtimeExecutableURL, title: "Already continued")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteReset")))
        let model = AppModel(store: SessionStore(sessions: [task, noLimit], repository: InMemorySessionRepository(sessions: [task, noLimit])),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false, loadsPersistedSelections: false),
            initialTranscripts: [task.id: [TranscriptEntry(content: .user(text: "Continue")),
                TranscriptEntry(content: .usageLimit(HarnessRateLimit(status: .rejected, usedFraction: 1)))]],
            restoresIndexOnLaunch: false)
        defer { Task { await model.shutdown() } }
        model.connections.publishDefaults([HarnessAccountSnapshot(id: "codex", harness: .codex, providerID: nil,
            state: .signedIn, accountLabel: "fixture@example.test", detail: "", credentialOwner: "", checkedAt: Date(),
            usage: [], usageResets: AccountUsageResets(availableCount: 2), canLogin: false, canLogout: false)])
        let bridge = AppModelRemoteBridge(model: model)
        let account = model.connections.choice(for: .codex, connection: nil)
        bridge.resetOffers[task.id] = RemoteResetOffer(token: "confirmation", account: account.id,
            createdAt: Date(), count: 2, resetID: nil)
        var calls = 0
        model.connections.usageResetRunner = { _, _, _ in calls += 1; return .reset }
        bridge.resetOffers[noLimit.id] = RemoteResetOffer(token: "stale-card", account: account.id,
            createdAt: Date(), count: 2, resetID: nil)
        let stale = await bridge.usageReset(taskID: noLimit.id.uuidString, token: "stale-card", confirmed: true)
        if case let .failure(error) = stale { XCTAssertEqual(error.code, .notAllowed) } else { XCTFail("The card no longer offers a reset") }
        XCTAssertEqual(calls, 0)
        let refused = await bridge.usageReset(taskID: task.id.uuidString, token: "confirmation", confirmed: false)
        if case let .failure(error) = refused { XCTAssertEqual(error.code, .notAllowed) } else { XCTFail("Confirmation required") }
        let first = try await bridge.usageReset(taskID: task.id.uuidString, token: "confirmation", confirmed: true).get()
        let replay = try await bridge.usageReset(taskID: task.id.uuidString, token: "confirmation", confirmed: true).get()
        XCTAssertEqual(first, replay)
        XCTAssertEqual(calls, 1, "A lost response cannot consume another banked reset")
        XCTAssertEqual(first.state, "reset")
        for request in [RemoteRequest.usageReset(taskID: task.id.uuidString),
                        .useUsageReset(taskID: task.id.uuidString, token: "confirmation", confirmed: true)] {
            XCTAssertNil(request.requiredPermission)
            XCTAssertEqual(request.taskID, task.id.uuidString)
        }
        XCTAssertTrue(RemoteRequest.useUsageReset(taskID: "task", token: "confirmation", confirmed: true).isCommand)
    }

    func testArchivedTasksArePagedAndRestoredWithoutAttachingAProvider() async throws {
        let records = (0..<101).map { index in
            SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/archive-fixture"),
                runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Archived \(index)",
                updatedAt: Date(timeIntervalSince1970: Double(index)))
        }
        let hidden = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/hidden-archive-fixture"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Hidden", updatedAt: Date(timeIntervalSince1970: 50.5))
        let model = try Self.model(sessions: [], transcripts: [:], archived: records + [hidden])
        let hiddenProject = model.projects.ensureProject(forRoot: hidden.workspaceURL)
        model.projects.hide(hiddenProject.id)
        let bridge = AppModelRemoteBridge(model: model)
        XCTAssertTrue(bridge.snapshot().tasks.isEmpty)
        let first = try await bridge.archivedTasks(cursor: nil).get()
        XCTAssertEqual(first.tasks.count, 100)
        let cursor = try XCTUnwrap(first.cursor)
        let second = try await bridge.archivedTasks(cursor: cursor).get()
        XCTAssertEqual(second.tasks.count, 1)
        XCTAssertNil(second.cursor)
        XCTAssertEqual(Set((first.tasks + second.tasks).map { $0.task.id }).count, 101)
        let hiddenRestore = await bridge.perform(.taskAction(taskID: hidden.id.uuidString, action: .init(.unarchive)))
        XCTAssertEqual(hiddenRestore?.code, .notFound, "A hidden project's archived task is neither listed nor restored")
        XCTAssertTrue(try XCTUnwrap(model.projects.project(id: hiddenProject.id)).isHidden)
        XCTAssertFalse(RemoteJSON.string(first.tasks).contains("/tmp/"))
        let restored = await bridge.perform(.taskAction(taskID: cursor, action: .init(.unarchive)))
        XCTAssertNil(restored)
        XCTAssertTrue(model.store.sessions.contains { $0.id.uuidString == cursor })
        XCTAssertFalse(model.isAttached(try XCTUnwrap(UUID(uuidString: cursor))))
        guard case let .failure(error) = await bridge.archivedTasks(cursor: cursor) else {
            return XCTFail("A removed cursor must not silently skip records")
        }
        XCTAssertEqual(error.code, .invalidCursor)
        await model.shutdown()
    }

    func testSidebarActionsResolveHostRecordsAndRejectUnconfirmedDeletion() async throws {
        let folder = URL(filePath: "/tmp/remote-actions")
        let first = SessionRecord(harness: .claudeCode, workspaceURL: folder,
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "First")
        let second = SessionRecord(harness: .claudeCode, workspaceURL: folder,
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Second")
        let model = try Self.model(sessions: [first, second], transcripts: [:])
        let bridge = AppModelRemoteBridge(model: model)
        XCTAssertTrue(bridge.snapshot().taskActions)
        let renamed = await bridge.perform(.taskAction(taskID: first.id.uuidString, action: .init(.rename, value: "Renamed")))
        XCTAssertNil(renamed)
        XCTAssertEqual(model.store.sessions.first { $0.id == first.id }?.title, "Renamed")
        let unread = await bridge.perform(.taskAction(taskID: first.id.uuidString, action: .init(.markUnread)))
        XCTAssertNil(unread)
        XCTAssertTrue(try XCTUnwrap(model.store.sessions.first { $0.id == first.id }).hasUnreadUpdate)
        let nested = await bridge.perform(.taskAction(taskID: second.id.uuidString, action: .init(.nest, value: first.id.uuidString)))
        XCTAssertNil(nested)
        let cycle = await bridge.perform(.taskAction(taskID: first.id.uuidString, action: .init(.nest, value: second.id.uuidString)))
        XCTAssertEqual(cycle?.code, .notAllowed)
        let refused = await bridge.perform(.taskAction(taskID: first.id.uuidString, action: .init(.delete)))
        XCTAssertEqual(refused?.code, .notAllowed)
        XCTAssertTrue(model.store.sessions.contains { $0.id == first.id })
        let removed = await bridge.perform(.taskAction(taskID: first.id.uuidString, action: .init(.delete, confirmed: true)))
        XCTAssertNil(removed)
        XCTAssertFalse(model.store.sessions.contains { $0.id == first.id })
        let stale = await bridge.perform(.taskAction(taskID: first.id.uuidString, action: .init(.rename, value: "Stale")))
        XCTAssertEqual(stale?.code, .notFound)
    }

    func testHeadlessTerminalBackpressurePreservesOutputBeforeExit() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "remote-terminal-tail-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let task = SessionRecord(harness: .claudeCode, workspaceURL: folder,
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Terminal output")
        let model = try Self.model(sessions: [task], transcripts: [:])
        let bridge = AppModelRemoteBridge(model: model)
        bridge.terminals.launch = .isolatedZsh(in: folder)
        let permit = RemoteTerminalPermit()
        let sink = PausedTerminalSink()
        addTeardownBlock {
            await sink.resume()
            await bridge.closeTerminal(taskID: task.id.uuidString, terminalID: "tail")
            await model.shutdown()
        }
        let opened = await bridge.openTerminal(taskID: task.id.uuidString, terminalID: "tail", columns: 100, rows: 30,
            permit: permit) { update in await sink.accept(update) }
        XCTAssertNil(opened)
        let session = try XCTUnwrap(model.taskWorkspaces.loadedState(for: task.id)?.terminals.first)
        try await waitUntil { session.isAtPrompt && session.bufferText.contains("%") }
        let command = #"printf 'BEGIN_PAYLOAD\n'; printf '%1100000s' '' | tr ' ' x; printf '\nEND_PAYLOAD\n'; exit 7"# + "\r"
        let sent = await bridge.terminalInput(taskID: task.id.uuidString, terminalID: "tail", data: Data(command.utf8), permit: permit)
        XCTAssertNil(sent)
        try await waitUntil { await sink.isPaused }
        XCTAssertTrue(session.isRunning, "The PTY must wait for its consumer instead of dropping output or closing")
        await sink.resume()
        try await waitUntil { await sink.hasExited }
        let bytes = await sink.bytes
        let begin = try XCTUnwrap(bytes.range(of: Data("BEGIN_PAYLOAD\r\n".utf8)))
        let end = try XCTUnwrap(bytes.range(of: Data("\r\nEND_PAYLOAD\r\n".utf8)))
        let payload = bytes[begin.upperBound..<end.lowerBound]
        XCTAssertEqual(payload.count, 1_100_000)
        XCTAssertTrue(payload.allSatisfy { $0 == UInt8(ascii: "x") })
        let exitCode = await sink.exitCode
        XCTAssertEqual(exitCode, 7 << 8, "The exit follows EOF and every output chunk, as raw waitpid status")
        await bridge.closeTerminal(taskID: task.id.uuidString, terminalID: "tail")

        // A host-side close revokes the actual capacity gate, not only the PTY process.
        let stoppedPermit = RemoteTerminalPermit()
        let stoppedSink = PausedTerminalSink()
        await stoppedSink.resume()
        let again = await bridge.openTerminal(taskID: task.id.uuidString, terminalID: "stop", columns: 100, rows: 30,
            permit: stoppedPermit) { update in
                _ = await stoppedPermit.enqueue(update)
                await stoppedSink.accept(update)
            }
        XCTAssertNil(again)
        let stopped = try XCTUnwrap(model.taskWorkspaces.loadedState(for: task.id)?.terminals.first)
        defer { stoppedPermit.revoke(); stopped.end() }
        try await waitUntil { stopped.isAtPrompt && stopped.bufferText.contains("%") }
        _ = await bridge.terminalInput(taskID: task.id.uuidString, terminalID: "stop",
            data: Data((#"printf '%1100000s' '' | tr ' ' x"# + "\r").utf8), permit: stoppedPermit)
        try await waitUntil { stoppedPermit.isWaitingForCapacity }
        stopped.end()
        XCTAssertFalse(stoppedPermit.isValid)
        XCTAssertTrue(bridge.terminals.sessions.isEmpty)
        try await waitUntil { await stoppedSink.hasExited }
        await model.shutdown()
    }

    // MARK: - Projection from timeline fixtures

    func testAClaudeTurnReadsAsTheTimelineDrawsIt() throws {
        let permission = PermissionRequest(
            id: "bash-1", title: "Bash", detail: "Run the migration tests", command: "swift test --filter Migration",
            actions: [
                PermissionRequestAction(id: "allow", label: "Allow", decision: .allow, kind: "allow_once"),
                PermissionRequestAction(id: "allow_always", label: "Always allow", decision: .allow, kind: "allow_always"),
                PermissionRequestAction(id: "deny", label: "Deny", decision: .deny, kind: "reject_once")
            ],
            toolCallID: "toolu-bash")
        let entries = [
            TranscriptEntry(content: .user(text: "Run the migration tests")),
            TranscriptEntry(content: .assistant(text: "Running them now.", isStreaming: false)),
            TranscriptEntry(content: .activity(HarnessActivity(
                id: "toolu-read", kind: "Read", title: "Read", input: #"{"file_path":"/tmp/remote-fixture/Sources/Migration.swift"}"#,
                output: "SECRET FILE CONTENTS"), state: .completed)),
            TranscriptEntry(content: .activity(HarnessActivity(
                id: "toolu-bash", kind: "Bash", title: "Bash",
                input: #"{"command":"swift test --filter Migration","description":"Run the migration tests"}"#), state: .running)),
            TranscriptEntry(content: .permission(permission, state: .pending))
        ]
        let presentation = TranscriptConversationProjection.presentation(
            from: entries, harness: .claudeCode, status: .waitingForApproval, latestTurnIsComplete: false)
        let conversation = RemoteConversationProjection.conversation(presentation, workspaceURL: URL(filePath: "/tmp/remote-fixture"))
        let turn = try XCTUnwrap(conversation.turns.last)
        XCTAssertEqual(turn.items.map(\.kind), [.user, .turn, .assistant, .activity, .activity, .approval])
        XCTAssertEqual(turn.items[0].text, "Run the migration tests")
        XCTAssertEqual(turn.items[1].status, "running")
        XCTAssertEqual(turn.items[2].role, "commentary")
        XCTAssertEqual(turn.items[2].inWork, true)
        // The lines the Mac shows, in Claude Code's words.
        let mac = presentation.turns.last!.work.compactMap { item -> String? in
            switch item.kind {
            case let .tool(tool):
                return ConversationLineWording.tool(tool, phase: item.phase, harness: .claudeCode,
                                                    workspaceURL: URL(filePath: "/tmp/remote-fixture")).text
            case let .command(command):
                return ConversationLineWording.command(command, phase: item.phase, harness: .claudeCode)
                    .map(\.text).joined(separator: ", ")
            default:
                return nil
            }
        }
        XCTAssertEqual(turn.items.filter { $0.kind == .activity }.map(\.title), mac)
        XCTAssertEqual(turn.items[4].status, "running")

        let request = turn.items[5]
        XCTAssertEqual(request.id, "req:bash-1")
        XCTAssertEqual(request.requestId, "bash-1")
        XCTAssertEqual(request.requestKind, "approval")
        XCTAssertEqual(request.status, "pending")
        XCTAssertEqual(request.command, "swift test --filter Migration")
        XCTAssertEqual(request.options, ["allowOnce", "deny"])
        XCTAssertEqual(request.moreOnMac, true, "Always allow stays on the Mac")
        XCTAssertNil(request.inWork)
        XCTAssertNil(request.truncated)
        // A command cut to its limit says so.
        let long = PermissionRequest(id: "bash-2", title: "Bash", detail: nil,
                                     command: String(repeating: "x", count: RemoteText.commandLimit + 10))
        let waiting = TranscriptConversationProjection.presentation(
            from: [TranscriptEntry(content: .user(text: "Go")), TranscriptEntry(content: .permission(long, state: .pending))],
            harness: .claudeCode, status: .waitingForApproval, latestTurnIsComplete: false)
        let cut = RemoteConversationProjection.request(try XCTUnwrap(waiting.turns.last?.requests.first), turnID: "t", inWork: false)
        XCTAssertEqual(cut.command?.count, RemoteText.commandLimit)
        XCTAssertEqual(cut.truncated, true)

        let json = RemoteJSON.string(RemoteEvent.items(turn.items))
        XCTAssertFalse(json.contains("SECRET FILE CONTENTS"))
        XCTAssertEqual(turn.items[1].workCount, 3)
    }

    func testAnAllowedRequestBecomesTheCallsMarkAndTheTurnFolds() throws {
        let permission = PermissionRequest(id: "bash-1", title: "Bash", detail: nil, command: "ls", toolCallID: "toolu-bash")
        let entries = [
            TranscriptEntry(content: .user(text: "List the files")),
            TranscriptEntry(content: .activity(HarnessActivity(id: "toolu-bash", kind: "Bash", title: "Bash",
                                                                input: #"{"command":"ls"}"#), state: .completed)),
            TranscriptEntry(content: .permission(permission, state: .allowed)),
            TranscriptEntry(content: .assistant(text: "Two files.", isStreaming: false))
        ]
        let presentation = TranscriptConversationProjection.presentation(
            from: entries, harness: .claudeCode, status: .completed, latestTurnIsComplete: true)
        let turn = try XCTUnwrap(RemoteConversationProjection.conversation(presentation, workspaceURL: nil).turns.last)
        XCTAssertEqual(turn.items.map(\.kind), [.user, .turn, .activity, .assistant])
        XCTAssertEqual(turn.items[2].approved, true)
        XCTAssertEqual(turn.items[3].role, "answer")
        XCTAssertEqual(turn.items[1].foldsWork, presentation.turns.last?.foldsWork)
        XCTAssertEqual(turn.items[1].foldsWork, true)
    }

    /// A phone answers questions and plan reviews the way the Mac's card does (§15.2–§15.4).
    func testQuestionsAndPlanReviewsAreAnsweredFromPhones() throws {
        let question = PermissionRequest(
            id: "question-1", title: "Question", detail: nil, command: nil,
            structured: .questions([PermissionQuestion(question: "Which layout?", options: [.init(label: "Grid"), .init(label: "List")],
                                                       allowsCustomAnswer: true)]))
        let plan = PermissionRequest(id: "plan-1", title: "Plan", detail: nil, command: nil, structured: .plan("1. Build"))
        for (request, kind, options) in [(question, "question", ["answer"]), (plan, "planReview", ["keepPlanning", "approvePlan"])] {
            let item = try XCTUnwrap(RemoteConversationProjection.conversation(Self.waiting(on: request), workspaceURL: nil)
                .turns.last?.items.last)
            XCTAssertEqual(item.requestKind, kind)
            XCTAssertEqual(item.options, options)
            XCTAssertNil(item.moreOnMac)
        }
        let asked = try XCTUnwrap(RemoteConversationProjection.conversation(Self.waiting(on: question), workspaceURL: nil)
            .turns.last?.items.last)
        XCTAssertEqual(asked.questions, ["Which layout?"])
        XCTAssertEqual(asked.questionSteps, [RemoteQuestionStep(id: "Which layout?", text: "Which layout?",
                                                                options: [.init(label: "Grid"), .init(label: "List")], custom: true,
                                                                skippable: true)])

        // The phone's answers become the card's form input and its route.
        let pending = try XCTUnwrap(Self.waiting(on: question).turns.last?.requests.first)
        let steps = pending.form?.questionSteps ?? []
        let submit = try XCTUnwrap(pending.responses.first { $0.route == .structured })
        func route(_ answers: [RemoteQuestionAnswer]) -> ConversationRequestRoute? {
            AppModelRemoteBridge.formInput(answers, for: steps).flatMap { pending.route(for: submit, input: $0) }
        }
        XCTAssertEqual(route([RemoteQuestionAnswer(questionId: "Which layout?", options: ["Grid"])]),
                       .answer(.questions([PermissionQuestionAnswer(question: "Which layout?", selectedLabels: ["Grid"], customAnswer: nil)])))
        XCTAssertEqual(route([RemoteQuestionAnswer(questionId: "Which layout?", text: "Masonry")]),
                       .answer(.questions([PermissionQuestionAnswer(question: "Which layout?", selectedLabels: [], customAnswer: "Masonry")])))
        XCTAssertNil(route([RemoteQuestionAnswer(questionId: "Which layout?", options: ["Table"])]), "not one of its options")
        XCTAssertNil(route([RemoteQuestionAnswer(questionId: "Which layout?", options: ["Grid", "List"])]), "one answer only")
        // Claude Code takes an answer that leaves a question out.
        XCTAssertEqual(route([RemoteQuestionAnswer(questionId: "Which layout?", skipped: true)]), .answer(.questions([])))
        XCTAssertNil(route([]), "unanswered")
    }

    private static func waiting(on request: PermissionRequest) -> ConversationPresentation {
        TranscriptConversationProjection.presentation(
            from: [TranscriptEntry(content: .user(text: "Go")), TranscriptEntry(content: .permission(request, state: .pending))],
            harness: .claudeCode, status: .waitingForApproval, latestTurnIsComplete: false)
    }

    /// A card's answers go with the catalog keys they were made from and a line with its words, so another
    /// Mac's Yardlet shows them in its own language and draws the verb as the Mac does (§6.4, §15.19).
    func testAnswersCarryTheirKeysAndLinesTheirWords() throws {
        let offer = ClaudePermissionSuggestionOffer(
            action: PermissionRequestAction(id: ClaudePermissionSuggestions.ActionID.allowAlways,
                                            text: LocalizedText("Always allow in this project (saved to %@)",
                                                                .verbatim(".claude/settings.local.json")),
                                            decision: .allow, kind: ClaudePermissionSuggestions.ActionID.allowAlways),
            updates: [])
        let request = PermissionRequest(id: "bash-1", title: "Bash", detail: nil, command: "swift test",
                                        actions: ClaudePermissionSuggestions.actions(for: offer))
        let entries = [
            TranscriptEntry(content: .user(text: "Run the tests")),
            TranscriptEntry(content: .activity(HarnessActivity(id: "toolu-read", kind: "Read", title: "Read",
                                                                input: #"{"file_path":"/tmp/remote-fixture/Parser.swift"}"#),
                                               state: .completed)),
            TranscriptEntry(content: .permission(request, state: .pending))
        ]
        let presentation = TranscriptConversationProjection.presentation(
            from: entries, harness: .claudeCode, status: .waitingForApproval, latestTurnIsComplete: false)
        let turn = try XCTUnwrap(RemoteConversationProjection.conversation(presentation, workspaceURL: URL(filePath: "/tmp/remote-fixture"))
            .turns.last)
        let pending = try XCTUnwrap(turn.items.last { $0.kind == .approval })
        let choices = try XCTUnwrap(pending.choices)
        XCTAssertEqual(choices.map { $0.text?.key }, ["Deny", "Allow", "Always allow in this project (saved to %@)"])
        XCTAssertEqual(choices.last?.text?.args, [RemoteLocalizedText(text: ".claude/settings.local.json")])
        let read = try XCTUnwrap(turn.items.first { $0.kind == .activity })
        let words = try XCTUnwrap(read.words?.first)
        XCTAssertEqual(words.verb, L10n.string("claude.read.done"))
        XCTAssertEqual(words.trailing, "Parser.swift")
        XCTAssertEqual(read.title, ConversationLineWords(leading: words.leading ?? "", verb: words.verb,
                                                         trailing: words.trailing ?? "").text)

        // A client shows a key in its own language, here a Korean one reading an English Mac's answer, and the
        // Mac's words where its catalog lacks the key or the key does not take the arguments sent.
        let korean: (String) -> String? = { key in
            let value = L10n.string(key, languageCode: "ko")
            return value == key ? nil : value
        }
        var english = try XCTUnwrap(choices.last)
        english.title = "Always allow in this project (saved to .claude/settings.local.json)"
        XCTAssertEqual(RemoteTurnProjection.title(of: english, lookup: korean), "이 프로젝트에서 항상 허용 (.claude/settings.local.json에 저장)")
        english.text = RemoteLocalizedText(key: "A key no catalog has")
        XCTAssertEqual(RemoteTurnProjection.title(of: english, lookup: korean), english.title)
        english.text = RemoteLocalizedText(key: "Always allow in this project (saved to %@)")
        XCTAssertEqual(RemoteTurnProjection.title(of: english, lookup: korean), english.title, "One argument short")
        XCTAssertEqual(LocalizedText.placeholderCount("Exit code %lld"), -1)
        XCTAssertEqual(LocalizedText.placeholderCount("%2$@ and %1$@, 100%%"), 2)
    }

    func testAPlainApprovalOffersAllowOnceTheSessionsAllowAndDenyAndAStandingRuleStaysOnTheMac() throws {
        func pending(_ actions: [PermissionRequestAction]) -> ConversationRequest? {
            let request = PermissionRequest(id: "r", title: "Run", detail: nil, command: "ls", actions: actions)
            let presentation = TranscriptConversationProjection.presentation(
                from: [TranscriptEntry(content: .user(text: "Go")), TranscriptEntry(content: .permission(request, state: .pending))],
                harness: .openCode, status: .waitingForApproval, latestTurnIsComplete: false)
            return presentation.turns.last?.requests.first
        }
        func answers(_ actions: [PermissionRequestAction]) -> [RemoteApprovalAnswer] {
            pending(actions).map(RemoteApprovalPolicy.answers(for:)) ?? []
        }
        XCTAssertEqual(answers([]), [.allowOnce, .deny])
        XCTAssertEqual(answers([
            PermissionRequestAction(id: "always", label: "Always", decision: .allow, kind: "allow_always"),
            PermissionRequestAction(id: "reject", label: "Reject", decision: .deny, kind: "reject_once")
        ]), [.deny], "Only a standing allow is offered, so allowing stays on the Mac")
        XCTAssertEqual(answers([
            PermissionRequestAction(id: "allow", label: "Allow", decision: .allow, kind: "allow_once"),
            PermissionRequestAction(id: "reject_always", label: "Never", decision: .deny, kind: "reject_always")
        ]), [.allowOnce], "A standing deny is a rule too")

        // Claude Code's suggestion kept for the session joins them (§15.13); one saved to a file does not.
        let session = [
            PermissionRequestAction(id: "allow", label: "Allow", decision: .allow, kind: "allow_once"),
            PermissionRequestAction(id: "allow_session", label: "Allow and switch to Accept edits mode for this session",
                                    decision: .allow, kind: "allow_session"),
            PermissionRequestAction(id: "deny", label: "Deny", decision: .deny, kind: "reject_once")
        ]
        XCTAssertEqual(answers(session), [.allowOnce, .allowForSession, .deny])
        let item = RemoteConversationProjection.request(try XCTUnwrap(pending(session)), turnID: "t", inWork: false)
        XCTAssertEqual(item.optionTitles?["allowForSession"], "Allow and switch to Accept edits mode for this session")
        XCTAssertNil(item.moreOnMac)
        let saved = [
            PermissionRequestAction(id: "allow", label: "Allow", decision: .allow, kind: "allow_once"),
            PermissionRequestAction(id: "allow_always", label: "Always allow in this project (saved to .claude/settings.local.json)",
                                    decision: .allow, kind: "allow_always"),
            PermissionRequestAction(id: "deny", label: "Deny", decision: .deny, kind: "reject_once")
        ]
        XCTAssertEqual(answers(saved), [.allowOnce, .deny])
        let kept = RemoteConversationProjection.request(try XCTUnwrap(pending(saved)), turnID: "t", inWork: false)
        // Every answer of the card, in its order and words, is a choice; the one saved to a file asks once more (§15.19).
        XCTAssertEqual(kept.choices?.map(\.title), try XCTUnwrap(pending(saved)).responses.map(\.title))
        XCTAssertEqual(kept.choices?.filter { $0.standing == true }.map(\.title),
                       ["Always allow in this project (saved to .claude/settings.local.json)"])
        XCTAssertEqual(item.choices?.contains { $0.standing == true }, false, "Allow for session ends with the task")
        XCTAssertTrue(RemoteApprovalPolicy.leavesStandingRule(.codex(.mcpElicitation(action: .accept, meta: .object(["persist": .string("always")])))))
        XCTAssertFalse(RemoteApprovalPolicy.leavesStandingRule(.codex(.mcpElicitation(action: .accept, meta: .object(["persist": .string("session")])))))
        XCTAssertTrue(RemoteApprovalPolicy.leavesStandingRule(.codex(.command(.acceptWithExecpolicyAmendment(["swift", "test"])))))
        XCTAssertFalse(RemoteApprovalPolicy.leavesStandingRule(.codex(.command(.acceptForSession))))
        XCTAssertEqual(kept.moreOnMac, true)
        XCTAssertEqual(kept.macNote, L10n.format("Only on the Mac: %@",
                                                 "Always allow in this project (saved to .claude/settings.local.json)"))
    }

    func testANewTaskFromThePhoneOffersTheNewTaskScreensChoicesButNotThoseTheMacConfirms() {
        // Claude Code launches in a permission mode; Bypass permissions asks first on the Mac, so the
        // phone is not offered it (§15.16), and a createTask naming it finds no such choice.
        let options = ComposerSessionOptionsProjection.newTask(harness: .claudeCode, choice: nil, catalogs: HarnessModelCatalogStore(),
                                                               connection: nil, workspaceURL: nil)
        let settings = AppModelRemoteBridge.settings(options)
        let permission = settings.first { $0.id == ClaudeLaunchOption.permissionMode }
        XCTAssertEqual(permission?.value, ClaudePermissionMode.manual)
        XCTAssertTrue(permission?.choices.contains { $0.value == ClaudePermissionMode.plan } == true)
        XCTAssertFalse(permission?.choices.contains { $0.value == ClaudePermissionMode.bypassPermissions } == true)
        XCTAssertTrue(ClaudePermissionMode.selectable.contains(ClaudePermissionMode.bypassPermissions),
                      "The Mac's own menu still offers it, after asking")
        let remote = AppModelRemoteBridge.taskSettings(options)
        XCTAssertNotNil(remote.first { $0.role == "permission" }?.choices.first {
            $0.value == ClaudePermissionMode.bypassPermissions
        }?.confirm)
        XCTAssertFalse(AppModelRemoteBridge.newTaskRequiresConfirmation(options))
        var elevated = options
        elevated.permission?.selector?.currentValue = ClaudePermissionMode.bypassPermissions
        XCTAssertTrue(AppModelRemoteBridge.newTaskRequiresConfirmation(elevated),
                      "An inherited elevated choice also needs confirmation on the client")
    }

    func testNewTaskComposerChecksConfirmationAndKeepsTheHostsChoices() async throws {
        let model = try Self.model(sessions: [], transcripts: [:])
        model.connections.usesFixtureSnapshots = true
        model.runtimeSelections.select(URL(filePath: "/usr/bin/true"), for: .claudeCode)
        let bridge = AppModelRemoteBridge(model: model)
        let beforeSelection = model.connections.selection
        let beforeChoice = model.composerDrafts.home.modelChoices[.claudeCode]
        let accountID = AccountChoice.nativeID(for: .claudeCode)
        let options = try await bridge.newTaskComposerOptions(projectID: RemoteTaskProjection.chatsProjectID,
            harness: HarnessKind.claudeCode.rawValue, settings: [:], accountID: accountID).get()
        XCTAssertTrue(options.accounts?.contains { $0.id == accountID && $0.current == true } == true)
        XCTAssertNil(options.accountLine, "A specific account has no automatic-assignment explanation")
        let automatic = try await bridge.newTaskComposerOptions(projectID: RemoteTaskProjection.chatsProjectID,
            harness: HarnessKind.claudeCode.rawValue, settings: [:], accountID: "automatic").get()
        let assignment = model.automaticStart(harness: .claudeCode, model: nil, now: Date()).assignment
        XCTAssertEqual(automatic.accountLine, assignment.accountName + " · " + assignment.reasonLine())
        XCTAssertNotNil(options.settings.first { $0.role == "permission" }?.choices.first {
            $0.value == ClaudePermissionMode.bypassPermissions
        }?.confirm)
        let refusal = await bridge.createTask(RemoteTaskStart(projectID: RemoteTaskProjection.chatsProjectID,
            text: "Run", harness: HarnessKind.claudeCode.rawValue,
            settings: [ClaudeLaunchOption.permissionMode: ClaudePermissionMode.bypassPermissions], accountID: accountID))
        guard case let .failure(error) = refusal else { return XCTFail("Unconfirmed elevation must not start a task") }
        XCTAssertEqual(error.code, .notAllowed)
        XCTAssertEqual(model.connections.selection, beforeSelection)
        XCTAssertEqual(model.composerDrafts.home.modelChoices[.claudeCode], beforeChoice)
        XCTAssertTrue(model.store.sessions.isEmpty)
        await model.shutdown()
    }

    func testNewTaskOptionsReadTheSameDefaultsAndAccountLabelAsTheLocalComposer() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "remote-home-defaults-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"model":"fable","effortLevel":"xhigh"}"#.utf8).write(to: root.appending(path: "settings.json"))
        let catalogs = HarnessModelCatalogStore(locations: HarnessModelSettingsLocations(
            claudeConfigDirectory: root, codexHome: root.appending(path: "codex"),
            codexYardletHome: root.appending(path: "other")), environment: [:])
        catalogs.recordClaude(ModelVisibilityFixtures.claudeModels, for: nil)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteHomeDefaults")))
        let runtimes = RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false, loadsPersistedSelections: false)
        runtimes.select(URL(filePath: "/usr/bin/true"), for: .claudeCode)
        let connections = ProviderConnectionStore()
        connections.usesFixtureSnapshots = true
        connections.publishDefaults([HarnessAccountSnapshot(id: HarnessKind.claudeCode.rawValue, harness: .claudeCode,
            providerID: nil, state: .signedIn, accountLabel: "Current connection", detail: "", credentialOwner: "Claude Code",
            checkedAt: Date(), usage: [], canLogin: false, canLogout: false)])
        let model = AppModel(store: SessionStore(sessions: [], repository: InMemorySessionRepository()),
            runtimeSelections: runtimes, connections: connections, modelCatalogs: catalogs, restoresIndexOnLaunch: false)
        model.composerDrafts.home.harness = .claudeCode
        XCTAssertNil(catalogs.defaults(for: .claudeCode, connection: nil, workspaceURL: nil))
        let reply = try await AppModelRemoteBridge(model: model).newTaskComposerOptions(
            projectID: RemoteTaskProjection.chatsProjectID, harness: "claude-code", settings: [:], accountID: nil).get()
        let localOptions = ComposerSessionOptionsProjection.newTask(harness: .claudeCode, choice: nil,
            catalogs: catalogs, connection: nil, workspaceURL: nil)
        XCTAssertEqual(reply.settings, AppModelRemoteBridge.taskSettings(localOptions))
        XCTAssertEqual(reply.settings.first { $0.role == "model" }?.value, "fable")
        XCTAssertEqual(reply.settings.first { $0.role == "effort" }?.value, "xhigh")
        XCTAssertEqual(localOptions.model?.menu.title, "Fable · " + L10n.string("Extra high"))
        let localAccount = try XCTUnwrap(connections.choices(for: [.claudeCode]).first)
        XCTAssertEqual(reply.accounts?.first { $0.current == true }?.name, ProviderConnectionDisplay(choice: localAccount).title)
        XCTAssertEqual(reply.accounts?.first { $0.current == true }?.name, "Current connection")
        let remoteOptions = RemoteTaskSettingsProjection.options(reply.settings, task: RemoteTask(id: "", title: "",
            harness: "claude-code", harnessName: "Claude Code", projectId: nil, attention: .idle, lastActivityAt: 0))
        XCTAssertEqual(remoteOptions.model?.menu.title, localOptions.model?.menu.title)
        await model.shutdown()
    }

    func testAPhonesFormValuesAreTheFormsOwnOrRefused() {
        let form = CodexMCPElicitationForm(fields: [
            .init(id: "count", title: "Count", description: nil, isRequired: true,
                  kind: .number(isInteger: true, minimum: nil, maximum: nil), defaultValue: nil),
            .init(id: "private", title: "Private", description: nil, isRequired: false, kind: .boolean, defaultValue: .flag(true))
        ])
        XCTAssertEqual(try? AppModelRemoteBridge.fieldValues(["count": .number(3), "private": .flag(false)], for: form).get(),
                       ["count": .text("3"), "private": .flag(false)])
        // A number too large for an integer does not stop Yardlet: the form's own check refuses it.
        let huge = try? AppModelRemoteBridge.fieldValues(["count": .number(1e20)], for: form).get()
        XCTAssertNotNil(huge.flatMap { form.issue(of: form.fields[0], in: $0) })
        // A value of the wrong kind is refused, never replaced by the default.
        XCTAssertNil(try? AppModelRemoteBridge.fieldValues(["private": .text("false")], for: form).get())
        XCTAssertNil(try? AppModelRemoteBridge.fieldValues(["other": .flag(true)], for: form).get())
    }

    func testTheCodexTimelineFixtureProjectsWithUniqueIDsAndCappedText() throws {
        let state = ConversationFixtures.codexTimeline()
        let presentation = CodexConversationProjection.presentation(state, workspaceURL: ConversationFixtures.workspace,
                                                                   historySelection: nil)
        let conversation = RemoteConversationProjection.conversation(presentation, workspaceURL: ConversationFixtures.workspace)
        XCTAssertEqual(conversation.turns.map(\.id), presentation.turns.map(\.id))
        let items = conversation.turns.flatMap(\.items)
        XCTAssertEqual(Set(items.map(\.id)).count, items.count)
        XCTAssertEqual(items.filter { $0.kind == .turn }.count, presentation.turns.count)
        for turn in conversation.turns {
            let header = try XCTUnwrap(turn.items.first { $0.kind == .turn })
            XCTAssertEqual(header.workCount, turn.items.filter { $0.inWork == true }.count)
            XCTAssertTrue(turn.items.allSatisfy { $0.turnId == turn.id })
        }
        XCTAssertTrue(items.allSatisfy { ($0.title?.count ?? 0) <= RemoteText.titleLimit })
        XCTAssertTrue(items.allSatisfy { ($0.detail?.count ?? 0) <= RemoteText.requestDetailLimit })
        XCTAssertTrue(items.contains { $0.kind == .activity && $0.activity == "command" })
        // Pending Codex requests offer what the notification's "Allow once" would.
        for request in presentation.turns.flatMap(\.requests) where request.state == .pending {
            let item = try XCTUnwrap(items.first { $0.id == "req:\(request.id)" })
            let allowOnce: ConversationRequestRoute? = if case let .codexServerRequest(server) = request.source {
                NotificationApprovalProjection.allowOnce(for: server)
            } else { nil }
            XCTAssertEqual(item.options?.contains("allowOnce"), allowOnce != nil, request.id)
            // And the card's allow for the session on a command or file change, never more permissions (§15.13).
            let sessionAllows: [ConversationRequestRoute] = [.codex(.command(.acceptForSession)),
                                                            .codex(.fileChange(.acceptForSession)),
                                                            .codex(.legacyReview(.approvedForSession))]
            XCTAssertEqual(item.options?.contains("allowForSession"),
                           request.responses.contains { sessionAllows.contains($0.route) }, request.id)
        }
        XCTAssertTrue(items.contains { $0.options?.contains("allowForSession") == true },
                      "The fixture's command approval offers Allow for session")
    }

    func testEveryFixtureConversationProjects() throws {
        for harness in HarnessCatalog.builtIns.map(\.id) where harness != .codex {
            let entries = try ConversationFixtures.completedTranscript(for: harness)
            let presentation = TranscriptConversationProjection.presentation(
                from: entries, harness: harness, status: .completed, latestTurnIsComplete: true)
            let conversation = RemoteConversationProjection.conversation(presentation, workspaceURL: ConversationFixtures.workspace)
            let items = conversation.turns.flatMap(\.items)
            XCTAssertEqual(Set(items.map(\.id)).count, items.count, "\(harness)")
            XCTAssertTrue(items.contains { $0.kind == .assistant && $0.role == "answer" }, "\(harness)")
        }
    }

    func testLongTextIsCut() throws {
        let presentation = TranscriptConversationProjection.presentation(
            from: [TranscriptEntry(content: .user(text: "Write a lot")),
                   TranscriptEntry(content: .assistant(text: String(repeating: "word ", count: 10_000), isStreaming: true))],
            harness: .claudeCode, status: .running, latestTurnIsComplete: false)
        let answer = try XCTUnwrap(RemoteConversationProjection.conversation(presentation, workspaceURL: nil)
            .turns.last?.items.first { $0.kind == .assistant })
        XCTAssertEqual(answer.text?.count, RemoteText.assistantLimit)
        XCTAssertEqual(answer.truncated, true)
        XCTAssertEqual(answer.streaming, true)
    }

    /// A message the person did not send says who sent it in either detail (§6.2), so a phone draws it apart from the
    /// person's own: another task's with the person's words it passed on, cut as a message is, a background command's
    /// notice, and a check-in Claude Code's own schedule sent.
    func testMessagesThePersonDidNotSendSayWhoSentThemInEitherDetail() throws {
        let quote = String(repeating: "Check the small phones too. ", count: 1_000)
        let fromParent = TaskMessage(senderID: UUID().uuidString, senderName: "Fix the footer links",
                                     body: "Check the footer at 320 pt as well.", relation: .parent,
                                     quotes: [.init(text: quote, sentAt: "2026-11-03T09:12:00+09:00")])
        let entries = [
            TranscriptEntry(content: .user(text: "Check the footer at 375 pt")),
            TranscriptEntry(content: .assistant(text: "It wraps cleanly.", isStreaming: false)),
            TranscriptEntry(content: .user(text: fromParent.text(in: .yardlet))),
            TranscriptEntry(content: .assistant(text: "Two links wrap.", isStreaming: false)),
            TranscriptEntry(content: .user(text: "<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n"
                + "<summary>Background command \"Run the visual tests\" completed (exit code 0)</summary>\n</task-notification>")),
            TranscriptEntry(content: .assistant(text: "The visual tests passed.", isStreaming: false)),
            TranscriptEntry(content: .user(text: "Check the footer links again."), origin: .scheduled),
            TranscriptEntry(content: .assistant(text: "Every link answers.", isStreaming: false))
        ]
        let presentation = TranscriptConversationProjection.presentation(
            from: entries, harness: .claudeCode, status: .completed, latestTurnIsComplete: true)
        let standard = RemoteConversationProjection.conversation(presentation, workspaceURL: nil)
        let full = RemoteConversationProjection.conversation(presentation, workspaceURL: nil) {
            RemoteConversationProjection.turn($0, harness: .claudeCode, workspaceURL: nil, full: .init())
        }
        for (conversation, isFull) in [(standard, false), (full, true)] {
            let sent = conversation.turns.flatMap(\.items).filter { $0.kind == .user }
            XCTAssertEqual(sent.map(\.text), ["Check the footer at 375 pt", "Check the footer at 320 pt as well.",
                                              "Background command \"Run the visual tests\" completed (exit code 0)",
                                              "Check the footer links again."])
            XCTAssertNil(sent[0].sender)
            XCTAssertEqual(sent[1].sender?.kind, "task")
            XCTAssertEqual(sent[1].sender?.name, "Fix the footer links")
            XCTAssertEqual(sent[1].sender?.relation, "parent")
            XCTAssertEqual(sent[1].sender?.taskId, fromParent.senderID)
            let quoted = try XCTUnwrap(sent[1].sender?.quotes?.first?.text.count)
            if isFull { XCTAssertGreaterThan(quoted, RemoteText.userLimit) } else { XCTAssertEqual(quoted, RemoteText.userLimit) }
            XCTAssertEqual(sent[1].sender?.quotes?.first?.sentAt, "2026-11-03T09:12:00+09:00")
            XCTAssertEqual(sent[2].sender, RemoteSender(kind: "backgroundTask", status: "completed"))
            XCTAssertEqual(sent[3].scheduled, true)
            XCTAssertEqual(sent[3].sender, RemoteSender(kind: "claudeSchedule"))
        }
        // Another Yardlet window draws them as its own timeline does, the task message under a link to the task that sent it.
        let window = RemoteConversationModel(taskID: "T", harness: .claudeCode, hostName: "Mac Studio")
        window.load(standard.turns.flatMap(\.items), cursor: nil, hasOlder: false)
        let drawn = window.presentation.turns.flatMap(\.prompt)
        XCTAssertEqual(drawn.compactMap(\.taskMessage?.senderID), [fromParent.senderID])
        XCTAssertEqual(drawn.compactMap(\.backgroundTaskNotice?.status), ["completed"])
    }

    /// Full detail (§15.24) on a long conversation: a sent picture's preview is made once, off the main actor, and
    /// projects again only the turn that holds it; a streaming answer projects only its turn, in each detail.
    func testAFullConversationProjectsOnlyTheTurnsAChangeTouches() async throws {
        let session = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/remote-full", directoryHint: .isDirectory),
                                    runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Long", status: .running)
        var entries: [TranscriptEntry] = []
        for turn in 0..<300 {
            let images = turn >= 297 ? [TranscriptImageAttachment(url: URL(filePath: "/tmp/remote-full/picture-\(turn).png"))] : nil
            entries.append(TranscriptEntry(content: .user(text: "Message \(turn)", images: images)))
            entries.append(TranscriptEntry(content: .assistant(text: "Done \(turn)", isStreaming: false)))
        }
        let model = try Self.model(sessions: [session], transcripts: [session.id: entries])
        final class Count: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            var value: Int { lock.withLock { count } }
            func add() { lock.withLock { count += 1 } }
        }
        let made = Count(), changes = Count()
        let bridge = AppModelRemoteBridge(model: model) { url, _ in
            made.add()
            return Data(url.lastPathComponent.utf8)
        }
        bridge.setChangeHandler { change in if case .conversation = change { changes.add() } }
        let taskID = session.id.uuidString
        bridge.setWatchedTasks([taskID])
        let first = try XCTUnwrap(bridge.conversation(of: taskID, detail: .full))
        XCTAssertEqual(bridge.projectedTurnCount, 300)
        XCTAssertTrue(first.turns.allSatisfy { $0.items.first?.images == nil })
        // Each preview tells its own turn once it is made.
        try await waitUntil { made.value == 3 && changes.value >= 3 }
        let previewed = try XCTUnwrap(bridge.conversation(of: taskID, detail: .full))
        XCTAssertEqual(bridge.projectedTurnCount, 303)
        XCTAssertEqual(previewed.turns.suffix(3).map { $0.items.first?.images?.first?.data },
                       (297..<300).map { Data("picture-\($0).png".utf8) })
        XCTAssertEqual(previewed.turns.suffix(3).map { $0.items.first?.imageCount }, [1, 1, 1])

        // A phone reads the same conversation in its own detail; the two keep their turns apart.
        let basic = try XCTUnwrap(bridge.conversation(of: taskID))
        _ = await bridge.taskRail(taskID: taskID)
        XCTAssertEqual(bridge.projectedTurnCount, 603)
        XCTAssertNil(basic.turns.last?.items.first?.images)
        for index in 1...20 {
            let before = changes.value
            var streamed = entries
            streamed[streamed.count - 1].content = .assistant(text: "Done 299" + String(repeating: " word", count: index),
                                                             isStreaming: true)
            model.transcripts[session.id] = streamed
            try await waitUntil { changes.value > before }
            _ = bridge.conversation(of: taskID, detail: .full)
            _ = bridge.conversation(of: taskID)
            _ = await bridge.taskRail(taskID: taskID)
        }
        XCTAssertEqual(bridge.projectedTurnCount, 643)
        XCTAssertEqual(made.value, 3)
    }

    // MARK: - Tasks

    func testTheSnapshotIsTheSidebarsTasksWithItsAttention() async throws {
        let folder = URL(filePath: "/tmp/remote-bridge-fixture", directoryHint: .isDirectory)
        let waiting = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
                                    title: "Approve", status: .waitingForApproval, updatedAt: Date(timeIntervalSince1970: 300))
        let unread = SessionRecord(harness: .codex, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/codex"),
                                   title: "Done", status: .completed, updatedAt: Date(timeIntervalSince1970: 200),
                                   hasUnreadUpdate: true, completionState: .completed)
        let child = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
                                  title: "Child", updatedAt: Date(timeIntervalSince1970: 100), parentTaskID: unread.id)
        let permission = PermissionRequest(id: "bash-9", title: "Bash", detail: nil,
                                           command: "curl -H 'Authorization: Bearer sk-live-9f8e7d6c' https://example.test")
        let queued = QueuedFollowUp(draft: CodexComposerDraft(inputs: [.text("Then update the changelog")]))
        let model = try Self.model(sessions: [waiting, unread, child], transcripts: [
            waiting.id: [TranscriptEntry(content: .user(text: "Go")), TranscriptEntry(content: .permission(permission, state: .pending))],
            unread.id: [TranscriptEntry(createdAt: Date(timeIntervalSince1970: 180), content: .user(text: "Check the update")),
                        TranscriptEntry(content: .assistant(text: "The update is ready.", isStreaming: false))]
        ], queues: [waiting.id: [queued]])
        let bridge = AppModelRemoteBridge(model: model)
        let snapshot = bridge.snapshot()
        XCTAssertEqual(snapshot.tasks.map(\.title), ["Approve", "Done", "Child"])
        XCTAssertEqual(snapshot.tasks[1].answerLine, "The update is ready.")
        XCTAssertEqual(snapshot.tasks[1].latestTurnStartedAt, 180_000)
        XCTAssertEqual(snapshot.tasks[1].completed, true)
        XCTAssertEqual(snapshot.tasks[0].completed, false)
        XCTAssertEqual(snapshot.tasks.map(\.attention), [.waiting, .unread, .idle])
        XCTAssertEqual(snapshot.tasks.map(\.indicator), [.awaitingApproval, .unread, nil])
        XCTAssertEqual(snapshot.tasks[0].pendingRequest, .approval)
        XCTAssertEqual(snapshot.tasks[0].running, true)
        XCTAssertEqual(snapshot.tasks[2].parentTaskId, unread.id.uuidString)
        XCTAssertEqual(snapshot.newestRequestIDs[waiting.id.uuidString], "bash-9")
        let summary = try XCTUnwrap(snapshot.requestSummaries[waiting.id.uuidString])
        XCTAssertTrue(summary.hasPrefix("Bash: curl"), summary)
        XCTAssertFalse(summary.contains("sk-live-9f8e7d6c"), "A secret never reaches a lock screen")
        XCTAssertEqual(snapshot.projects.count, 1)
        XCTAssertFalse(RemoteJSON.string(snapshot.projects).contains("/tmp"), "No folder paths leave the Mac")
        // The same definition as the Dock badge.
        XCTAssertEqual(snapshot.tasks.filter { $0.attention == .waiting || $0.attention == .unread }.count,
                       model.attentionBadgeCount)

        let signals = SignalRecorder()
        bridge.setChangeHandler { change in signals.record(change) }
        let conversation = try XCTUnwrap(bridge.conversation(of: waiting.id.uuidString))
        let lastItems = try XCTUnwrap(conversation.turns.last?.items)
        XCTAssertEqual(lastItems.dropLast().last?.options, ["allowOnce", "deny"])
        // The composer's queue chip, as a queued message at the end of the conversation.
        XCTAssertEqual(lastItems.last?.id, "queued:\(queued.id.uuidString)")
        XCTAssertEqual(lastItems.last?.queued, true)
        XCTAssertEqual(lastItems.last?.text, "Then update the changelog")
        XCTAssertEqual(lastItems.last?.options, ["sendNow", "stopAndSend", "remove", "edit"], "The chip's actions (§15.15, §15.33)")
        XCTAssertNil(bridge.conversation(of: UUID().uuidString))
        XCTAssertNotNil(snapshot.followUp, "A Mac that takes §15.13–§15.18 always says what Return does")
        XCTAssertEqual(snapshot.tasks.map(\.steers), [true, true, true])
        XCTAssertEqual(snapshot.tasks.map(\.acceptsImages), [true, true, true])

        // A tab the agent handed to the person is a wait on the phone, with the bar's two answers (§15.18).
        model.browserHandoffWaits[child.id] = [BrowserHandoffWait(notice: "yardlet-handoff-1", tabKey: nil,
                                                                  reason: "Sign in to GitHub")]
        try await waitUntil { bridge.snapshot().tasks.first { $0.id == child.id.uuidString }?.attention == .waiting }
        let handedOver = try XCTUnwrap(bridge.snapshot().tasks.first { $0.id == child.id.uuidString })
        XCTAssertEqual(handedOver.pendingKind, "browserHandoff")
        XCTAssertEqual(handedOver.pendingSummary, "Sign in to GitHub")
        let handoff = try XCTUnwrap(bridge.conversation(of: child.id.uuidString)?.turns.last?.items.last)
        XCTAssertEqual(handoff.requestKind, "browserHandoff")
        XCTAssertEqual(handoff.options, ["done", "decline"])
        let gone = await bridge.perform(.answerHandoff(taskID: child.id.uuidString, requestID: "yardlet-handoff-1", answer: .done))
        XCTAssertEqual(gone?.code, .requestNotFound, "No tab, nothing to answer")
        model.browserHandoffWaits[child.id] = nil

        let removed = await bridge.perform(.actOnQueued(taskID: waiting.id.uuidString, itemID: "queued:\(queued.id.uuidString)",
                                                        action: .remove))
        XCTAssertNil(removed)
        try await waitUntil { model.followUps.queue(for: waiting.id).isEmpty }

        // Marking read is the window's own call, and the change is told.
        let error = await bridge.perform(.markRead(taskID: unread.id.uuidString))
        XCTAssertNil(error)
        XCTAssertEqual(model.store.sessions.first { $0.id == unread.id }?.hasUnreadUpdate, false)
        try await waitUntil { signals.changes.contains(.tasks) }
        XCTAssertEqual(bridge.snapshot().tasks.first { $0.id == unread.id.uuidString }?.attention, .idle)

        // A task moved in the Mac's sidebar is nested where it was moved to on the phone too.
        func parent(of task: SessionRecord) -> String? {
            bridge.snapshot().tasks.first { $0.id == task.id.uuidString }?.parentTaskId
        }
        await model.nest(child.id, under: waiting.id)
        try await waitUntil { parent(of: child) == waiting.id.uuidString }
        await model.nest(waiting.id, under: unread.id)
        try await waitUntil { parent(of: waiting) == unread.id.uuidString }
        XCTAssertEqual(parent(of: child), waiting.id.uuidString, "The tasks under it go with it")
        await model.detachFromParent(try XCTUnwrap(model.store.sessions.first { $0.id == waiting.id }))
        try await waitUntil { parent(of: waiting) == nil }
        await model.shutdown()
    }

    /// The phone nests by `parentTaskId` alone, so it carries the task the Mac's sidebar draws each task
    /// under: none for a task whose parent is in another list, pinned apart or in a split view, the
    /// nearest listed task past an archived parent, and below the sidebar's deepest level the task its
    /// own parent sits under.
    func testTasksNestOnThePhoneWhereTheSidebarNestsThem() async throws {
        let folder = URL(filePath: "/tmp/remote-bridge-nesting/app", directoryHint: .isDirectory)
        let otherFolder = URL(filePath: "/tmp/remote-bridge-nesting/site", directoryHint: .isDirectory)
        var minutes = 0.0
        func task(_ title: String, in place: URL = folder, under parent: SessionRecord? = nil,
                  pinned: Bool = false) -> SessionRecord {
            minutes += 1
            return SessionRecord(harness: .claudeCode, workspaceURL: place, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
                                 title: title, updatedAt: Date(timeIntervalSince1970: 1_000_000 - minutes * 60),
                                 isPinned: pinned, parentTaskID: parent?.id)
        }
        let top = task("Plan the release")
        let child = task("Write the notes", under: top)
        let grandchild = task("Check the links", under: child)
        let greatGrandchild = task("Fix one link", under: grandchild)
        let elsewhere = task("Update the site", in: otherFolder, under: top)
        let pinned = task("Pinned work", pinned: true)
        let underPinned = task("From pinned work", under: pinned)
        let left = task("Left pane")
        let right = task("Right pane")
        let underSplit = task("From the left pane", under: left)
        let archived = task("Archived step", under: top)
        let underArchived = task("After the archived step", under: archived)
        let model = try Self.model(
            sessions: [top, child, grandchild, greatGrandchild, elsewhere, pinned, underPinned, left, right, underSplit,
                       underArchived],
            transcripts: [:], archived: [archived])
        try await model.store.loadArchivedSessions()
        model.splits.activate(.session(left.id))
        model.splits.split(.right, placing: right.id)

        let parents = Dictionary(uniqueKeysWithValues: AppModelRemoteBridge(model: model).snapshot().tasks.map {
            ($0.id, $0.parentTaskId)
        })
        func parent(of task: SessionRecord) -> String?? { parents[task.id.uuidString] }
        XCTAssertEqual(parent(of: child), top.id.uuidString)
        XCTAssertEqual(parent(of: grandchild), child.id.uuidString)
        XCTAssertEqual(parent(of: greatGrandchild), child.id.uuidString,
                       "Past the deepest level it sits beside its parent, as the sidebar draws it")
        XCTAssertEqual(parent(of: elsewhere), .some(nil), "Another project's list shows it at its top")
        XCTAssertEqual(parent(of: underPinned), .some(nil), "Pinned is a list of its own")
        XCTAssertEqual(parent(of: underSplit), .some(nil), "A split view nests nothing")
        XCTAssertEqual(parent(of: underArchived), top.id.uuidString, "The nearest listed task past an archived one")
        XCTAssertEqual(parent(of: top), .some(nil))
        await model.shutdown()
    }

    // MARK: - Scheduled tasks (§15.21)

    func testRemoteScheduleEditsKeepHostAuthorityAndRequireConfirmation() async throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let originalPath = "/tmp/host-private-folder"
        var original = ScheduledTask(name: "Original", prompt: "TOKEN=private-value Read /tmp/other-private-file",
            trigger: .daily(.init(hour: 9, minute: 0)),
            destination: ScheduleDestination(harness: .claudeCode, accountID: "host-account", workspacePath: originalPath),
            createdAt: now)
        original.state.runs = [.init(at: now, trigger: .manual, outcome: .failed, failure: "SECRET=value /tmp/account-home")]
        original.state.runs[0].account = AccountAssignment(
            choice: AccountChoice(harness: .claudeCode, connection: nil, snapshot: nil, knownLabel: "Work"),
            origin: .automatic,
            replacing: AccountChoice(harness: .claudeCode, connection: nil, snapshot: nil, knownLabel: "Personal"))
        let model = try Self.model(sessions: [], transcripts: [:], schedules: [original])
        // Existing schedules keep their harness even if its executable temporarily disappears.
        model.runtimeSelections.select(URL(filePath: "/missing-schedule-runtime"), for: .claudeCode)
        model.scheduledTasks.now = { now }
        // A hidden project's schedule reads like one in an unregistered folder and keeps its place when saved back.
        let hiddenProject = model.projects.ensureProject(forRoot: URL(filePath: originalPath))
        model.projects.hide(hiddenProject.id)
        original.destination.projectID = hiddenProject.id
        model.scheduledTasks.update(original)
        let connections = ProviderConnectionStore()
        let selected = try connections.add(name: "Selected account", harness: .claudeCode, home: URL(filePath: "/tmp/selected-schedule-account"))
        connections.selection[.claudeCode] = selected.id
        XCTAssertEqual(AppModelRemoteBridge.scheduleConnection(accountID: nil, harness: .claudeCode, connections: connections), selected)
        XCTAssertNil(AppModelRemoteBridge.scheduleConnection(accountID: AccountChoice.nativeID(for: .claudeCode), harness: .claudeCode, connections: connections))
        XCTAssertNil(AppModelRemoteBridge.scheduleConnection(accountID: "removed-account", harness: .claudeCode, connections: connections))
        let bridge = AppModelRemoteBridge(model: model)
        let options = try await bridge.scheduledTaskOptions(projectID: RemoteTaskProjection.chatsProjectID,
            harness: HarnessKind.claudeCode.rawValue, settings: [:], scheduleID: original.id.uuidString).get()
        XCTAssertEqual(options.harness.harness, HarnessKind.claudeCode.rawValue)
        let list = try await bridge.scheduledTasks().get()
        let data = try XCTUnwrap(list.first?.definition)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("private-value") || text.contains(originalPath) || text.contains("account-home"))
        XCTAssertNil(list.first?.projectName)
        var supplied = try JSONDecoder().decode(ScheduledTask.self, from: data)
        XCTAssertEqual(supplied.state.runs.count, original.state.runs.count)
        XCTAssertEqual(supplied.state.runs.first?.account?.switchLine, original.state.runs.first?.account?.switchLine)
        XCTAssertNil(supplied.destination.accountID)
        XCTAssertEqual(supplied.destination.workspacePath, "yardlet-host-folder")
        XCTAssertNil(supplied.destination.projectID)
        supplied.name = "Edited"
        supplied.id = UUID()
        supplied.destination.accountID = "forged-account"
        supplied.state.runs = []
        supplied.origin = .init(app: .claudeApp, sourceID: "/tmp/forged-source")
        supplied.isEnabled = false
        let forgedAccount = try await bridge.saveScheduledTask(scheduleID: original.id.uuidString, definition: JSONEncoder().encode(supplied),
            settings: [:], confirmed: false)
        guard case let .failure(accountError) = forgedAccount else { return XCTFail("An unlisted account was accepted") }
        XCTAssertEqual(accountError.code, .notAllowed)
        supplied.destination.accountID = nil
        let saved = try await bridge.saveScheduledTask(scheduleID: original.id.uuidString, definition: JSONEncoder().encode(supplied),
            settings: [:], confirmed: false).get()
        XCTAssertEqual(saved, original.id.uuidString)
        let actual = try XCTUnwrap(model.scheduledTasks.schedule(id: original.id))
        XCTAssertEqual(actual.name, "Edited")
        XCTAssertEqual(actual.prompt, original.prompt, "An unchanged masked prompt preserves the host's full instructions")
        XCTAssertEqual(actual.destination.workspacePath, originalPath)
        XCTAssertEqual(actual.destination.projectID, hiddenProject.id)
        XCTAssertEqual(actual.destination.accountID, "host-account")
        XCTAssertEqual(actual.state.runs, original.state.runs)
        XCTAssertEqual(actual.isEnabled, original.isEnabled)
        XCTAssertNil(actual.origin)
        let elevated = try await bridge.saveScheduledTask(scheduleID: original.id.uuidString, definition: JSONEncoder().encode(supplied),
            settings: ["permissionMode": "bypassPermissions"], confirmed: false)
        guard case let .failure(error) = elevated else { return XCTFail("Unconfirmed elevated permissions saved") }
        XCTAssertEqual(error.code, .notAllowed)
        _ = try await bridge.saveScheduledTask(scheduleID: original.id.uuidString, definition: JSONEncoder().encode(supplied),
            settings: ["permissionMode": "bypassPermissions"], confirmed: true).get()
        XCTAssertEqual(model.scheduledTasks.schedule(id: original.id)?.destination.modelChoice?.permissionMode, "bypassPermissions")
        let selectable = try model.connections.add(name: "Schedule account", harness: .claudeCode,
            home: URL(filePath: "/tmp/remote-schedule-account-private-home"))
        let accountOptions = try await bridge.scheduledTaskOptions(projectID: RemoteTaskProjection.chatsProjectID,
            harness: HarnessKind.claudeCode.rawValue, settings: [:], scheduleID: original.id.uuidString, accountID: selectable.id).get()
        XCTAssertEqual(accountOptions.scheduleAccountID, selectable.id)
        XCTAssertEqual(accountOptions.scheduleAccounts?.first { $0.id == selectable.id }?.name, selectable.name)
        let accountWire = String(decoding: try JSONEncoder().encode(accountOptions.scheduleAccounts), as: UTF8.self)
        XCTAssertFalse(accountWire.contains("homePath") || accountWire.contains("private-home"))
        let unknownAccount = await bridge.scheduledTaskOptions(projectID: RemoteTaskProjection.chatsProjectID,
            harness: HarnessKind.claudeCode.rawValue, settings: [:], scheduleID: original.id.uuidString, accountID: "unlisted-account")
        guard case let .failure(optionError) = unknownAccount else { return XCTFail("An unlisted account's catalogs were offered") }
        XCTAssertEqual(optionError.code, .notAllowed)
        supplied.destination.accountID = selectable.id
        _ = try await bridge.saveScheduledTask(scheduleID: original.id.uuidString, definition: JSONEncoder().encode(supplied),
            settings: [:], confirmed: false).get()
        XCTAssertEqual(model.scheduledTasks.schedule(id: original.id)?.destination.accountID, selectable.id)
        XCTAssertNil(model.scheduledTasks.schedule(id: original.id)?.destination.modelChoice, "Changing accounts resets the previous account's picks")
        supplied.destination.projectID = UUID()
        let invalidProject = try await bridge.saveScheduledTask(scheduleID: original.id.uuidString, definition: JSONEncoder().encode(supplied),
            settings: [:], confirmed: true)
        guard case let .failure(projectError) = invalidProject else { return XCTFail("Unknown project accepted") }
        XCTAssertEqual(projectError.code, .notFound)
        supplied.destination.mode = .continueTask
        supplied.destination.targetTaskID = UUID()
        let invalidTask = try await bridge.saveScheduledTask(scheduleID: original.id.uuidString, definition: JSONEncoder().encode(supplied),
            settings: [:], confirmed: true)
        guard case let .failure(taskError) = invalidTask else { return XCTFail("Unknown task accepted") }
        XCTAssertEqual(taskError.code, .notFound)
        let refusedDelete = await bridge.deleteScheduledTasks(scheduleIDs: [original.id.uuidString], completedOnly: false, confirmed: false)
        XCTAssertEqual(refusedDelete?.code, .notAllowed)
        let completedDelete = await bridge.deleteScheduledTasks(scheduleIDs: [original.id.uuidString], completedOnly: true, confirmed: true)
        XCTAssertNil(completedDelete)
        XCTAssertNotNil(model.scheduledTasks.schedule(id: original.id), "Delete All preserves schedules that are no longer finished")
        let deleted = await bridge.deleteScheduledTasks(scheduleIDs: [original.id.uuidString], completedOnly: false, confirmed: true)
        XCTAssertNil(deleted)
        XCTAssertNil(model.scheduledTasks.schedule(id: original.id))
        await model.shutdown()
    }

    func testScheduledTasksAreTheMacsListAndActThroughItsMenu() async throws {
        let now = Date(timeIntervalSince1970: 1_792_158_000)
        let folder = URL(filePath: "/tmp/remote-bridge-schedules", directoryHint: .isDirectory)
        let working = SessionRecord(harness: .codex, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/codex"),
                                    title: "Morning check", status: .running, updatedAt: now)
        let idle = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
                                 title: "Weekly sync", status: .completed, updatedAt: now.addingTimeInterval(-60),
                                 completionState: .completed)
        func run(_ outcome: ScheduledTaskRun.Outcome, hoursAgo: Double, task: UUID? = nil,
                 skip: ScheduledTaskRun.SkipReason? = nil, failure: String? = nil) -> ScheduledTaskRun {
            ScheduledTaskRun(at: now.addingTimeInterval(-hoursAgo * 3_600), trigger: .scheduled, outcome: outcome,
                             skipReason: skip, failure: failure, taskID: task)
        }
        // Made now, so no slot before it is due and each one's next run is its next slot.
        let created = now
        // Enabled, and the task its last run started still works.
        var morning = ScheduledTask(name: "Morning check", prompt: "Check the inbox", trigger: .daily(ScheduleTime(hour: 9, minute: 0)),
                                    destination: ScheduleDestination(harness: .codex, workspacePath: "/tmp/remote-schedules/acme-web"),
                                    createdAt: created)
        morning.state.runs = [run(.started, hoursAgo: 1, task: working.id)]
        // Paused; it continues a task, and its last run was skipped while that task was busy.
        var weekly = ScheduledTask(name: "Weekly sync", prompt: "Sync", trigger: .weekly(days: [.monday], time: ScheduleTime(hour: 10, minute: 0)),
                                   destination: ScheduleDestination(mode: .continueTask, harness: .claudeCode, targetTaskID: idle.id),
                                   isEnabled: false, createdAt: created)
        weekly.state.runs = [run(.skipped, hoursAgo: 2, skip: .targetBusy), run(.started, hoursAgo: 26, task: idle.id)]
        // Turned itself off after failed starts; a repeating schedule resumes.
        var screenshots = ScheduledTask(name: "Nightly screenshots", prompt: "Shoot", trigger: .daily(ScheduleTime(hour: 2, minute: 0)),
                                        destination: ScheduleDestination(harness: .claudeCode, workspacePath: "/tmp/remote-schedules/acme-web"),
                                        isEnabled: false, createdAt: created)
        screenshots.state.stopReason = .repeatedFailures
        screenshots.state.consecutiveFailures = 3
        screenshots.state.runs = [run(.failed, hoursAgo: 3, failure: "No simulator")]
        // A one-off chat that ran, whose task is no longer in the sidebar.
        var reminder = ScheduledTask(name: "Reminder", prompt: "Remind me", trigger: .once(now.addingTimeInterval(-86_400)),
                                     destination: ScheduleDestination(harness: .claudeCode), isEnabled: false, createdAt: created)
        reminder.state.stopReason = .finished
        reminder.state.runs = [run(.started, hoursAgo: 24, task: UUID())]

        let model = try Self.model(sessions: [working, idle], transcripts: [:], schedules: [morning, weekly, screenshots, reminder])
        let center = model.scheduledTasks
        center.now = { now }
        let bridge = AppModelRemoteBridge(model: model)
        XCTAssertTrue(bridge.snapshot().scheduledTasks)
        let listed = try await bridge.scheduledTasks().get()
        // The Mac's list order: what will run, then what is off (here as old, so by name), then the one-offs that ran.
        let order = [morning, screenshots, weekly, reminder]
        XCTAssertEqual(listed.map(\.id), order.map(\.id.uuidString), "The Mac's list order")
        // The Mac's own words, in its language.
        for (remote, schedule) in zip(listed, order) {
            let nextRun = center.nextRun(of: schedule)
            XCTAssertEqual(remote.when, ScheduleText.summary(schedule.trigger, calendar: center.calendar(), now: now))
            XCTAssertEqual(remote.status, ScheduleText.status(schedule, nextRun: nextRun, isStarting: false, now: now,
                                                              calendar: center.calendar()))
            XCTAssertEqual(remote.nextRunAt, nextRun.map(RemoteJSON.milliseconds))
            XCTAssertEqual(remote.lastRun?.line, schedule.state.runs.first.map { ScheduleText.latestRun($0, now: now, calendar: center.calendar()) })
            XCTAssertEqual(remote.lastRun?.at, schedule.state.runs.first.map { RemoteJSON.milliseconds($0.at) })
        }
        XCTAssertTrue(listed[0].enabled)
        XCTAssertTrue(listed[0].running, "The task its last run started works")
        XCTAssertNotNil(listed[0].nextRunAt)
        XCTAssertNil(listed[0].canResume)
        XCTAssertEqual(listed[0].projectName, "acme-web", "A folder outside any project, as the sidebar names it")
        XCTAssertEqual(listed[0].harnessName, "Codex")
        XCTAssertEqual(listed[0].lastRun?.outcome, .started)
        XCTAssertEqual(listed[0].lastRun?.taskId, working.id.uuidString)

        XCTAssertFalse(listed[2].enabled)
        XCTAssertEqual(listed[2].status, L10n.string("Paused"))
        XCTAssertNil(listed[2].nextRunAt)
        XCTAssertEqual(listed[2].canResume, true)
        XCTAssertFalse(listed[2].running, "The task its latest started run continued is idle")
        XCTAssertEqual(listed[2].projectName, "remote-bridge-schedules", "The project of the task it continues")
        XCTAssertEqual(listed[2].lastRun?.outcome, .skipped)
        XCTAssertNil(listed[2].lastRun?.taskId)
        XCTAssertEqual(listed[2].lastRun?.line.hasSuffix(ScheduleText.skipReason(.targetBusy)), true)

        XCTAssertEqual(listed[1].canResume, true)
        XCTAssertEqual(listed[1].lastRun?.outcome, .failed)
        XCTAssertEqual(listed[1].lastRun?.line.hasSuffix(ScheduleText.couldNotStart("No simulator")), true)

        XCTAssertNil(listed[3].canResume, "A one-off that ran is edited, not resumed")
        XCTAssertNil(listed[3].projectName, "A chat")
        XCTAssertEqual(listed[3].lastRun?.outcome, .started)
        XCTAssertNil(listed[3].lastRun?.taskId, "Its task is not in the snapshot")
        XCTAssertFalse(listed[3].running)

        // Pause and Resume as the menu offers them; the change is told.
        let signals = SignalRecorder()
        bridge.setChangeHandler { change in signals.record(change) }
        let unknown = await bridge.perform(.runScheduledTask(scheduleID: UUID().uuidString))
        XCTAssertEqual(unknown?.code, .notFound)
        let refused = await bridge.perform(.setScheduledTaskEnabled(scheduleID: reminder.id.uuidString, enabled: true))
        XCTAssertEqual(refused?.code, .notAllowed)
        XCTAssertEqual(center.schedule(id: reminder.id)?.isEnabled, false)
        let resumed = await bridge.perform(.setScheduledTaskEnabled(scheduleID: weekly.id.uuidString, enabled: true))
        XCTAssertNil(resumed)
        XCTAssertEqual(center.schedule(id: weekly.id)?.isEnabled, true)
        try await waitUntil { signals.changes.contains(.schedules) }
        let afterResuming = try await bridge.scheduledTasks().get()
        XCTAssertEqual(Array(afterResuming.map(\.id).prefix(2)), [morning, weekly].map(\.id.uuidString),
                       "Resumed, it runs again and joins the ones that run, by next run")
        XCTAssertEqual(afterResuming[1].enabled, true)

        // Run now while the task of its previous run works is recorded as a skip, as on the Mac.
        let ran = await bridge.perform(.runScheduledTask(scheduleID: morning.id.uuidString))
        XCTAssertNil(ran)
        try await waitUntil { (try? await bridge.scheduledTasks().get().first?.lastRun?.outcome) == .skipped }
        XCTAssertEqual(center.schedule(id: morning.id)?.state.runs.first?.skipReason, .previousRunActive)

        // The run's task finishes: the list follows the task.
        try await model.store.updateSession(id: working.id, status: .completed)
        try await waitUntil { (try? await bridge.scheduledTasks().get().first?.running) == false }
        await model.shutdown()
    }

    // MARK: - Files (§15.22)

    /// A task's outputs are its Outputs card, in its order, and a phone's reads are checked against the folders the task
    /// was given and those outputs.
    func testATasksOutputsAreItsOutputsCardAndItsFoldersAreItsOwn() async throws {
        let folder = URL(filePath: "/tmp/remote-bridge-files", directoryHint: .isDirectory)
        let session = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
                                    title: "Write the report", additionalRoots: ["/tmp/remote-bridge-files-docs"])
        func written(_ path: String, at seconds: TimeInterval) -> TranscriptEntry {
            TranscriptEntry(createdAt: Date(timeIntervalSince1970: seconds), content: .activity(HarnessActivity(
                id: "write-\(seconds)", kind: "Write", title: "Write", diff: HarnessActivityDiff(path: path, newText: "x")),
                state: .completed))
        }
        // A source file it wrote inside its folder is a change, not an output.
        let entries = [written("/tmp/elsewhere/summary.pdf", at: 100), written("docs/chart.png", at: 200),
                       written("Sources/Parser.swift", at: 300)]
        let model = try Self.model(sessions: [session], transcripts: [session.id: entries])
        let bridge = AppModelRemoteBridge(model: model)
        XCTAssertTrue(bridge.snapshot().taskFiles)
        let card = SessionRailContent.outputs(entries: entries, codexChanges: [], workspaceURL: folder)
        let outputs = try await bridge.taskOutputs(taskID: session.id.uuidString).get()
        XCTAssertEqual(outputs.map(\.path), card.map { $0.url.path(percentEncoded: false) })
        XCTAssertEqual(outputs.map(\.name), ["chart.png", "summary.pdf"])
        XCTAssertEqual(outputs.map(\.writtenAt), [200_000, 100_000])
        XCTAssertEqual(outputs.compactMap(\.size), [], "The server reads the sizes")
        let scope = try await bridge.fileScope(taskID: session.id.uuidString).get()
        XCTAssertEqual(scope.folder, session.workspaceURL)
        XCTAssertEqual(scope.otherFolders, session.additionalRootURLs)
        XCTAssertEqual(scope.outputs, card.map(\.url))
        if case let .failure(error) = await bridge.fileScope(taskID: UUID().uuidString) {
            XCTAssertEqual(error.code, .notFound)
        } else {
            XCTFail("A task the sidebar does not list has no files")
        }
        await model.shutdown()
    }

    func testWorkspaceFileIndexUsesTheReadFileBoundary() async throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appending(path: "remote-index-\(UUID())")
        let root = base.appending(path: "workspace")
        try manager.createDirectory(at: root.appending(path: "Sources"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        try Data("safe".utf8).write(to: root.appending(path: "Sources/main.swift"))
        try Data("private".utf8).write(to: base.appending(path: "secret.txt"))
        try manager.createSymbolicLink(at: root.appending(path: "linked.txt"), withDestinationURL: base.appending(path: "secret.txt"))
        try manager.createSymbolicLink(at: root.appending(path: "outside"), withDestinationURL: base)
        let session = SessionRecord(harness: .claudeCode, workspaceURL: root, runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Files")
        let model = try Self.model(sessions: [session], transcripts: [:])
        let bridge = AppModelRemoteBridge(model: model)
        let scope = try await bridge.fileScope(taskID: session.id.uuidString).get()
        let index = try RemoteFileReader.index(in: scope).get()
        XCTAssertEqual(index.paths, ["Sources/main.swift"])
        XCTAssertFalse(index.isLimited)
        XCTAssertEqual(try RemoteFileReader.read(index.paths[0], offset: 0, in: scope).get().data, Data("safe".utf8))
        if case let .failure(error) = RemoteFileReader.index(in: .init(folder: base), home: root.path) {
            XCTAssertEqual(error.code, .notFound)
        } else { XCTFail("A folder containing home must not enumerate") }
        await model.shutdown()
    }

    // MARK: - Browser tabs (§15.25)

    /// A task's browser tabs for the remote are the ones its panel lists, pictured through the agent's screenshot call
    /// at the size asked for, and driven by the agent's trusted input, which counts as the person's. A password typed
    /// keeps the agent's scripts off the page before it goes in, as one typed in the panel does; the Mac's clipboard is
    /// not pasted, and nothing reaches a tab under a passkey window. A watched tab paints until no one watches it, and
    /// its many draws are told once until it is pictured. Another task's tabs are not this task's.
    func testATasksBrowserTabsArePicturedAndDrivenAsThePanelsAre() async throws {
        let folder = URL(filePath: "/tmp/remote-bridge-browser", directoryHint: .isDirectory)
        let task = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
                                 title: "Publish the notes")
        let other = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
                                  title: "Something else")
        let model = try Self.model(sessions: [task, other], transcripts: [:])
        let connection = AnsweringHostConnection()
        let client = BrowserHostClient(idleGrace: .seconds(60), agentVisibleWindow: .milliseconds(20)) { connection }
        let bridge = AppModelRemoteBridge(model: model, browser: RemoteTabBridge.Environment(
            client: { client }, usesMacEditingCommands: true, marksTypedSecrets: { true }))
        let signals = SignalRecorder()
        bridge.setChangeHandler { signals.record($0) }
        XCTAssertTrue(bridge.snapshot().browserTabs)

        let docs = try client.openTab(forSession: task.id, url: "https://docs.github.com", viewport: .offscreenDefault)
        let signIn = try client.newTab(forSession: task.id, url: "https://github.com/login", viewport: .offscreenDefault,
                                       select: true)
        _ = try client.openTab(forSession: other.id, url: "https://example.com/private", viewport: .offscreenDefault)
        connection.eventHandler?(.title(tab: signIn.id, title: "Sign in to GitHub"))
        connection.eventHandler?(.address(tab: signIn.id, url: "https://github.com/login"))
        model.browserHandoffWaits[task.id] = [BrowserHandoffWait(notice: "yardlet-handoff-7", tabKey: signIn.key,
                                                                 reason: "Sign in so I can publish")]
        let listed = try await bridge.browserTabs(taskID: task.id.uuidString).get()
        XCTAssertEqual(listed.map(\.tabId), [docs.key.uuidString, signIn.key.uuidString])
        XCTAssertEqual(listed.map(\.active), [nil, true])
        XCTAssertEqual(listed[1].title, "Sign in to GitHub")
        XCTAssertEqual(listed[1].url, "https://github.com/login")
        XCTAssertEqual(listed[1].requestId, "yardlet-handoff-7")
        XCTAssertEqual(listed[1].reason, "Sign in so I can publish")
        XCTAssertFalse(RemoteJSON.string(listed).contains("private"), "another task's tab is not listed")
        guard case let .failure(unknown) = await bridge.browserTabs(taskID: UUID().uuidString) else { return XCTFail("An unknown task listed") }
        XCTAssertEqual(unknown.code, .notFound)
        let watch = { (tab: BrowserTab) in RemoteTabWatch(taskID: task.id.uuidString, tabID: tab.key.uuidString) }
        let tabID = signIn.key.uuidString
        let taskID = task.id.uuidString

        // Watched, the tab paints while no panel shows it; its draws are told once until it is pictured.
        try await waitUntilAsync { connection.visibility(of: signIn).last == true }
        await bridge.setWatchedTabs([watch(signIn)])
        XCTAssertEqual(connection.visibility(of: signIn).last, false, "a watched tab is shown to its engine")
        for _ in 0..<5 { connection.eventHandler?(.frame(tab: signIn.id, frame: Self.frame)) }
        connection.eventHandler?(.frame(tab: docs.id, frame: Self.frame))
        XCTAssertEqual(signals.changes.filter { if case .tabPainted = $0 { true } else { false } },
                       [.tabPainted(taskID: taskID, tabID: tabID)])

        connection.layout = (width: 1280, height: 800, pageY: 120, ratio: 2)
        let frame = try await bridge.captureTab(taskID: taskID, tabID: tabID, maxWidth: 640, maxHeight: 1600).get()
        XCTAssertEqual(frame.image, Data("JPEG".utf8))
        XCTAssertEqual([frame.width, frame.height], [640, 400])
        XCTAssertEqual([frame.viewportWidth, frame.viewportHeight], [1280, 800])
        let shot = try XCTUnwrap(connection.calls.last { $0.method == "Page.captureScreenshot" }?.params)
        XCTAssertEqual(shot["format"]?.stringValue, "jpeg")
        XCTAssertEqual(shot["quality"]?.integerValue, 60)
        XCTAssertEqual(shot["clip"]?["y"]?.doubleValue, 120)
        XCTAssertEqual(shot["clip"]?["scale"]?.doubleValue, 0.25, "half the page's CSS pixels, at a device scale of 2")
        connection.eventHandler?(.frame(tab: signIn.id, frame: Self.frame))
        XCTAssertEqual(signals.changes.filter { if case .tabPainted = $0 { true } else { false } }.count, 2,
                       "told again after the picture")

        // A click and keys are the agent's trusted input, and the person's.
        let unwatched = connection.calls.count
        let clicked = await bridge.tabInput(taskID: taskID, tabID: tabID, input: .click(x: 320, y: 145), permit: RemoteTabPermit())
        XCTAssertNil(clicked)
        let sent = connection.calls.dropFirst(unwatched).filter { $0.method.hasPrefix("Input.") }
        XCTAssertEqual(sent.map(\.method), Array(repeating: "Input.dispatchMouseEvent", count: 3))
        XCTAssertEqual(sent.compactMap { $0.params["type"]?.stringValue }, ["mouseMoved", "mousePressed", "mouseReleased"])
        XCTAssertEqual(connection.calls.last?.params["x"]?.doubleValue, 320)
        XCTAssertNotNil(signIn.lastPersonUse, "the remote's input is the person's")
        let backspace = await bridge.tabInput(taskID: taskID, tabID: tabID, input: .key("Backspace"), permit: RemoteTabPermit())
        XCTAssertNil(backspace)
        XCTAssertEqual(connection.calls.last { $0.params["type"]?.stringValue == "rawKeyDown" }?.params["commands"],
                       .array([.string("deleteBackward")]))
        let paste = await bridge.tabInput(taskID: taskID, tabID: tabID, input: .key("Meta+v"), permit: RemoteTabPermit())
        XCTAssertEqual(paste?.code, .notAllowed, "the Mac's clipboard is not the person's")

        // Typed into a password field: the page is held from the agent's scripts before the text goes in.
        connection.eventHandler?(.passwordField(tab: signIn.id, isFocused: true))
        let focused = try await bridge.browserTabs(taskID: taskID).get()
        XCTAssertEqual(focused[1].passwordField, true)
        XCTAssertFalse(signIn.vaultFills.holdShownDocument(in: []))
        let before = connection.calls.count
        let typed = await bridge.tabInput(taskID: taskID, tabID: tabID, input: .text("hunter2"), permit: RemoteTabPermit())
        XCTAssertNil(typed)
        let typing = connection.calls.dropFirst(before).map(\.method)
        XCTAssertEqual(typing.first, "Page.getFrameTree")
        XCTAssertEqual(typing.last, "Input.insertText")
        XCTAssertTrue(signIn.vaultFills.holdShownDocument(in: []))

        // The panel's Back; nothing under a passkey window; another task's tab is not found.
        let back = await bridge.tabInput(taskID: taskID, tabID: tabID, input: RemoteTabInput(kind: .navigate, action: "back"), permit: RemoteTabPermit())
        XCTAssertNil(back)
        XCTAssertTrue(connection.sent.contains(.navigation(tab: signIn.id, action: .back)))
        connection.eventHandler?(.chromiumWindow(isShown: true, titles: ["Use a passkey"], kinds: ["passkey"], ids: [4],
                                                 tabs: [signIn.id]))
        let underWindow = await bridge.tabInput(taskID: taskID, tabID: tabID, input: .click(x: 10, y: 10), permit: RemoteTabPermit())
        XCTAssertEqual(underWindow?.code, .notAllowed)
        let foreign = await bridge.tabInput(taskID: other.id.uuidString, tabID: tabID, input: .click(x: 10, y: 10), permit: RemoteTabPermit())
        XCTAssertEqual(foreign?.code, .notFound)

        // Address changes and closes obey the same task, window, file and lifetime boundaries.
        let underDialog = await bridge.openTab(taskID: taskID, tabID: tabID, address: "localhost:3000", permit: RemoteTabPermit())
        if case let .failure(error) = underDialog { XCTAssertEqual(error.code, .notAllowed) }
        else { XCTFail("An address opened under a passkey window") }
        let closeUnderDialog = await bridge.closeTab(taskID: taskID, tabID: tabID, permit: RemoteTabPermit())
        XCTAssertEqual(closeUnderDialog?.code, .notAllowed)
        connection.eventHandler?(.chromiumWindow(isShown: false, titles: [], kinds: [], ids: [], tabs: []))
        let foreignClose = await bridge.closeTab(taskID: other.id.uuidString, tabID: tabID, permit: RemoteTabPermit())
        XCTAssertEqual(foreignClose?.code, .notFound)
        let revoked = RemoteTabPermit()
        revoked.revoke()
        let unopened = await bridge.openTab(taskID: taskID, tabID: nil, address: "https://example.com", permit: revoked)
        if case let .failure(error) = unopened { XCTAssertEqual(error.code, .notAllowed) }
        else { XCTFail("A cancelled watch opened a tab") }
        for address in ["file:///etc/hosts", "javascript:alert(1)", "mailto:test@example.com"] {
            let rejected = await bridge.openTab(taskID: taskID, tabID: nil, address: address, permit: RemoteTabPermit())
            if case .success = rejected { XCTFail("Opened an address outside the remote boundary") }
        }
        let navigation = try await bridge.openTab(taskID: taskID, tabID: tabID,
                                                  address: "localhost:3000/preview", permit: RemoteTabPermit()).get()
        XCTAssertEqual(navigation, tabID)
        XCTAssertTrue(connection.sent.contains(.navigate(tab: signIn.id, url: "http://localhost:3000/preview")))
        let closed = await bridge.closeTab(taskID: taskID, tabID: tabID, permit: RemoteTabPermit())
        XCTAssertNil(closed)
        XCTAssertTrue(connection.sent.contains(.requestClose(tab: signIn.id)))

        // No one watches: the tab hides again as one no panel shows.
        await bridge.setWatchedTabs([])
        try await waitUntilAsync { connection.visibility(of: signIn).last == true }
        let told = signals.changes.count
        connection.eventHandler?(.frame(tab: signIn.id, frame: Self.frame))
        connection.eventHandler?(.title(tab: signIn.id, title: "GitHub"))
        XCTAssertEqual(signals.changes.count, told, "a tab no one watches tells nothing")
    }

    /// What a remote device may not do through a task's tab, each checked where the input is sent (the security review of
    /// §15.25): keys outside characters and the editing and moving keys, and every spelling of the clipboard's commands;
    /// typing into a password field the page cannot be marked for; anything once its watch ended, or while a Chromium
    /// window whose tab is not known is up (Back included); a `file:` page outside the task's files, shown or driven; and
    /// opening another app on this Mac from a remote click without asking here. A phone's size draws the tab as a phone
    /// while it watches, and the tab takes back the size it had before, the agent's while its turn goes on.
    func testARemoteDeviceDrivesOnlyWhatThePanelWouldAndSizesTheTabAsAPhone() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "remote-tab-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("<p>notes</p>".utf8).write(to: folder.appending(path: "notes.html"))
        let task = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
                                 title: "Sign in")
        let model = try Self.model(sessions: [task], transcripts: [:])
        let connection = AnsweringHostConnection()
        let client = BrowserHostClient(idleGrace: .seconds(60), agentVisibleWindow: .milliseconds(20)) { connection }
        let apps = RecordingExternalApps()
        client.externalApps = apps
        let bridge = AppModelRemoteBridge(model: model, browser: RemoteTabBridge.Environment(
            client: { client }, usesMacEditingCommands: true, marksTypedSecrets: { true }))
        let tab = try client.openTab(forSession: task.id, url: "https://github.com/login", viewport: .offscreenDefault)
        connection.eventHandler?(.address(tab: tab.id, url: "https://github.com/login"))
        let taskID = task.id.uuidString, tabID = tab.key.uuidString
        func input(_ input: RemoteTabInput, permit: RemoteTabPermit = RemoteTabPermit()) async -> RemoteError? {
            await bridge.tabInput(taskID: taskID, tabID: tabID, input: input, permit: permit)
        }

        // Keys: characters and the editing and moving keys; never the clipboard, Insert or the function keys.
        for key in ["a", "Shift+A", "Enter", "Shift+Tab", "Meta+a", "Alt+Backspace", "Meta+ArrowLeft", "Meta+z", "PageDown"] {
            let refusal = await input(.key(key))
            XCTAssertNil(refusal, key)
        }
        for key in ["Meta+v", "Control+v", "Shift+Insert", "Meta+Shift+v", "Meta+Alt+Shift+v", "Control+Shift+v", "Meta+c",
                    "Control+x", "Shift+Delete", "Control+y", "Insert", "Control+Insert", "F5"] {
            let refusal = await input(.key(key))
            XCTAssertEqual(refusal?.code, .notAllowed, key)
        }

        // A character typed into a password field marks the page first, by text or by key; when it cannot, nothing goes.
        connection.eventHandler?(.passwordField(tab: tab.id, isFocused: true))
        var before = connection.calls.count
        let keyed = await input(.key("s"))
        XCTAssertNil(keyed)
        XCTAssertEqual(connection.calls.dropFirst(before).first?.method, "Page.getFrameTree", "marked before the key")
        connection.answersFrameTree = false
        connection.eventHandler?(.newDocument(tab: tab.id, url: "https://github.com/login"))
        before = connection.calls.count
        let unmarked = await input(.text("hunter2"))
        XCTAssertEqual(unmarked?.code, .unavailable)
        XCTAssertFalse(connection.calls.dropFirst(before).contains { $0.method == "Input.insertText" }, "nothing typed unprotected")
        let unmarkedKey = await input(.key("x"))
        XCTAssertEqual(unmarkedKey?.code, .unavailable)
        connection.answersFrameTree = true
        connection.eventHandler?(.passwordField(tab: tab.id, isFocused: false))

        // A watch that ended sends nothing more.
        let ended = RemoteTabPermit()
        ended.revoke()
        before = connection.calls.count
        let late = await input(.click(x: 5, y: 5), permit: ended)
        XCTAssertEqual(late?.code, .notAllowed)
        XCTAssertEqual(connection.calls.count, before)

        // A sign-in window Chromium did not name a tab for keeps every tab from the remote, Back too.
        connection.eventHandler?(.chromiumWindow(isShown: true, titles: ["Sign in"], kinds: ["signIn"], ids: [7], tabs: [-1]))
        for refused in [RemoteTabInput.click(x: 5, y: 5), RemoteTabInput(kind: .navigate, action: "back")] {
            let refusal = await input(refused)
            XCTAssertEqual(refusal?.code, .notAllowed, "\(refused)")
        }
        XCTAssertFalse(connection.sent.contains(.navigation(tab: tab.id, action: .back)))
        connection.eventHandler?(.chromiumWindow(isShown: false, titles: nil))

        // Another app opens from a remote click only when someone here chooses it.
        let clicked = await input(.click(x: 5, y: 5))
        XCTAssertNil(clicked)
        connection.eventHandler?(.externalApp(tab: tab.id, request: BrowserExternalAppRequest(
            url: "mailto:team@example.test", origin: "https://github.com", userGesture: true, remembered: false)))
        XCTAssertTrue(apps.opened.isEmpty, "a remote click's mailto: waits for the Mac")
        XCTAssertNotNil(tab.externalAppQuestion)

        // A file page: the task's own shows; one outside it is named by its scheme only, and neither pictured nor driven.
        await bridge.setWatchedTabs([RemoteTabWatch(taskID: taskID, tabID: tabID)])
        connection.eventHandler?(.address(tab: tab.id, url: folder.appending(path: "notes.html").absoluteString))
        let own = await bridge.captureTab(taskID: taskID, tabID: tabID, maxWidth: 640, maxHeight: 640)
        XCTAssertNotNil(try? own.get())
        connection.eventHandler?(.address(tab: tab.id, url: "file:///etc/hosts"))
        let outside = await bridge.captureTab(taskID: taskID, tabID: tabID, maxWidth: 640, maxHeight: 640)
        guard case let .failure(refused) = outside else { return XCTFail("A file outside the task's was pictured") }
        XCTAssertEqual(refused.code, .notAllowed)
        let drivenOutside = await input(.click(x: 5, y: 5))
        XCTAssertEqual(drivenOutside?.code, .notAllowed)
        let listedOutside = try await bridge.browserTabs(taskID: taskID).get()
        XCTAssertEqual(listedOutside.first?.url, "file://")
        connection.eventHandler?(.address(tab: tab.id, url: "https://github.com/login"))

        // A phone's own size, as `browser_resize` draws it, while it watches; then the size the tab had.
        func metrics() -> [JSONValue] {
            connection.calls.filter { $0.method == "Emulation.setDeviceMetricsOverride" || $0.method == "Emulation.clearDeviceMetricsOverride" }
                .map { $0.method == "Emulation.clearDeviceMetricsOverride" ? .string("cleared") : $0.params["width"] ?? .null }
        }
        let phone = RemoteTabViewport(width: 390, height: 844, mobile: true)
        await bridge.setWatchedTabs([RemoteTabWatch(taskID: taskID, tabID: tabID, viewport: phone)])
        try await waitUntilAsync { tab.emulation?.owner == .remote && metrics().last == .integer(390) }
        XCTAssertEqual(tab.emulation?.mobile, true)
        XCTAssertTrue(connection.calls.contains { $0.method == "Emulation.setTouchEmulationEnabled" && $0.params["enabled"] == .bool(true) })
        try await waitUntilAsync {
            connection.calls.contains { $0.method == "Emulation.setUserAgentOverride" && $0.params["userAgent"]?.stringValue?.contains("Android") == true }
        }
        await bridge.setWatchedTabs([RemoteTabWatch(taskID: taskID, tabID: tabID)])
        try await waitUntilAsync { tab.emulation == nil && metrics().last == .string("cleared") }

        // Over the agent's size during its turn, the agent's comes back; once its turn ended, the tab's own.
        tab.noteAgentActivity()
        try await tab.emulate(BrowserViewportEmulation(width: 1024, height: 768, owner: .agent))
        await bridge.setWatchedTabs([RemoteTabWatch(taskID: taskID, tabID: tabID, viewport: phone)])
        try await waitUntilAsync { tab.emulation?.owner == .remote }
        await bridge.setWatchedTabs([])
        try await waitUntilAsync { tab.emulation?.owner == .agent && metrics().last == .integer(1024) }
        await bridge.setWatchedTabs([RemoteTabWatch(taskID: taskID, tabID: tabID, viewport: phone)])
        try await waitUntilAsync { tab.emulation?.owner == .remote }
        await tab.endAgentEmulation()
        XCTAssertEqual(tab.emulation?.owner, .remote, "the agent's turn ending leaves the phone's size")
        await bridge.setWatchedTabs([])
        try await waitUntilAsync { tab.emulation == nil && metrics().last == .string("cleared") }
    }

    /// The second and third reviews of §15.25's host: a page that moves while it is pictured or driven, even away and
    /// back to the same address, is not sent or driven past the page checked; a file page outside the task's hides its
    /// title, also from the page the tab moves to next; a popup a remote click opened asks on the Mac before another app
    /// opens, also after the agent read the tab, and so does one the agent's page opened; the host refuses a remote
    /// click's downloads before the click goes; and the phone's sizes asked meanwhile make one change, the latest, which
    /// never comes back after the agent's later one.
    func testARemoteDevicesInputHoldsAcrossMovesPopupsDownloadsAndSizes() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "remote-tab-moves-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("<p>notes</p>".utf8).write(to: folder.appending(path: "notes.html"))
        let inside = folder.appending(path: "notes.html").absoluteString
        let task = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
                                 title: "Sign in")
        let model = try Self.model(sessions: [task], transcripts: [:])
        let connection = AnsweringHostConnection()
        let client = BrowserHostClient(idleGrace: .seconds(60), agentVisibleWindow: .milliseconds(20)) { connection }
        let apps = RecordingExternalApps()
        client.externalApps = apps
        let bridge = AppModelRemoteBridge(model: model, browser: RemoteTabBridge.Environment(
            client: { client }, usesMacEditingCommands: true, marksTypedSecrets: { true }))
        let tab = try client.openTab(forSession: task.id, url: inside, viewport: .offscreenDefault)
        connection.eventHandler?(.address(tab: tab.id, url: inside))
        let taskID = task.id.uuidString, tabID = tab.key.uuidString
        await bridge.setWatchedTabs([RemoteTabWatch(taskID: taskID, tabID: tabID)])

        // Moved to a file outside the task's while it was pictured: the picture does not go.
        connection.onCall = { method in
            if method == "Page.captureScreenshot" { connection.eventHandler?(.address(tab: tab.id, url: "file:///etc/hosts")) }
        }
        let moved = await bridge.captureTab(taskID: taskID, tabID: tabID, maxWidth: 640, maxHeight: 640)
        guard case .failure = moved else { return XCTFail("A page that moved during its picture was sent") }
        connection.onCall = nil
        connection.eventHandler?(.title(tab: tab.id, title: "/etc/hosts"))
        let listed = try await bridge.browserTabs(taskID: taskID).get()
        XCTAssertEqual(listed.first?.url, "file://")
        XCTAssertNil(listed.first?.title, "a file outside the task's is not named by its title either")
        // Nor is the page it moves to next named by that file's title before it names itself.
        connection.eventHandler?(.address(tab: tab.id, url: "https://github.com/login"))
        let next = try await bridge.browserTabs(taskID: taskID).get()
        XCTAssertEqual(next.first?.url, "https://github.com/login")
        XCTAssertNil(next.first?.title)
        connection.eventHandler?(.title(tab: tab.id, title: "Sign in to GitHub"))
        let named = try await bridge.browserTabs(taskID: taskID).get()
        XCTAssertEqual(named.first?.title, "Sign in to GitHub")

        // Away to a file outside the task's and back while pictured: the picture may be of the page between; it does not go.
        connection.eventHandler?(.address(tab: tab.id, url: inside))
        connection.onCall = { method in
            guard method == "Page.captureScreenshot" else { return }
            connection.eventHandler?(.address(tab: tab.id, url: "file:///etc/hosts"))
            connection.eventHandler?(.address(tab: tab.id, url: inside))
        }
        let roundTrip = await bridge.captureTab(taskID: taskID, tabID: tabID, maxWidth: 640, maxHeight: 640)
        guard case .failure = roundTrip else { return XCTFail("A page that left and came back during its picture was sent") }

        // Away and back during a click: the steps after the move are not sent, though the address is the one checked.
        connection.onCall = { method in
            guard method == "Input.dispatchMouseEvent" else { return }
            connection.eventHandler?(.address(tab: tab.id, url: "file:///etc/hosts"))
            connection.eventHandler?(.address(tab: tab.id, url: inside))
        }
        var before = connection.calls.count
        let sentBefore = connection.sent.count
        let clicked = await bridge.tabInput(taskID: taskID, tabID: tabID, input: .click(x: 5, y: 5), permit: RemoteTabPermit())
        XCTAssertEqual(clicked?.code, .notAllowed)
        XCTAssertEqual(connection.calls.dropFirst(before).filter { $0.method == "Input.dispatchMouseEvent" }.count, 1,
                       "only the step before the move")
        // The host was told to refuse the tab's downloads before the click went.
        let clickSent = Array(connection.sent.dropFirst(sentBefore))
        let refused = try XCTUnwrap(clickSent.firstIndex(of: .refuseDownloads(tab: tab.id, isRefused: true)))
        let firstStep = try XCTUnwrap(clickSent.firstIndex { if case .devTools(_, let message) = $0 { message.contains("Input.dispatchMouseEvent") } else { false } })
        XCTAssertLessThan(refused, firstStep)
        connection.onCall = nil
        connection.eventHandler?(.address(tab: tab.id, url: "https://github.com/login"))

        // The keys and buttons editing text takes, no more.
        for key in ["Shift+A", "Alt+ArrowLeft", "Meta+Backspace", "Shift+Meta+z", "Meta+a", "Shift+Enter"] {
            let refusal = await bridge.tabInput(taskID: taskID, tabID: tabID, input: .key(key), permit: RemoteTabPermit())
            XCTAssertNil(refusal, key)
        }
        for key in ["Meta+l", "Meta+o", "Meta+s", "Meta+p", "Alt+Meta+i", "Control+a", "Shift+Meta+a", "Alt+v", "Meta+Enter"] {
            let refusal = await bridge.tabInput(taskID: taskID, tabID: tabID, input: .key(key), permit: RemoteTabPermit())
            XCTAssertEqual(refusal?.code, .notAllowed, key)
        }
        for button in ["middle", "right"] {
            let refusal = await bridge.tabInput(taskID: taskID, tabID: tabID, input: .click(x: 5, y: 5, button: button),
                                                permit: RemoteTabPermit())
            XCTAssertEqual(refusal?.code, .notAllowed, button)
        }

        // A popup a remote click opened asks on the Mac before another app opens, though the agent read the tab between.
        let clickedOpen = await bridge.tabInput(taskID: taskID, tabID: tabID, input: .click(x: 5, y: 5), permit: RemoteTabPermit())
        XCTAssertNil(clickedOpen)
        tab.noteAgentActivity()
        connection.eventHandler?(.popupOpened(tab: 90, opener: tab.id, url: "https://github.com/share", background: false))
        let popup = try XCTUnwrap(client.tabs(forSession: task.id).first { $0.id == 90 })
        connection.eventHandler?(.externalApp(tab: popup.id, request: BrowserExternalAppRequest(
            url: "mailto:team@example.test", origin: "https://github.com", userGesture: true, remembered: true)))
        XCTAssertTrue(apps.opened.isEmpty)
        XCTAssertNotNil(popup.externalAppQuestion)
        // A blocked pop-up it opens as a tab of the task refuses downloads from its first request.
        connection.eventHandler?(.newWindow(tab: tab.id, url: "https://github.com/notes.pdf", background: false, userGesture: true))
        let opened = try XCTUnwrap(client.tabs(forSession: task.id).last)
        XCTAssertTrue(connection.sent.contains(.refuseDownloads(tab: opened.id, isRefused: true)))
        // The person's own click here takes downloads again, before it goes.
        let ownBefore = connection.sent.count
        tab.send(.mouse(tab: tab.id, input: BrowserMouseInput(kind: .down, x: 5, y: 5, button: .left)))
        XCTAssertEqual(Array(connection.sent.dropFirst(ownBefore)).prefix(1),
                       [.refuseDownloads(tab: tab.id, isRefused: false)])

        // A popup the agent's input opened asks before another app opens, as the agent's own page does.
        tab.noteAgentActivity()
        connection.eventHandler?(.popupOpened(tab: 91, opener: tab.id, url: "https://github.com/compose", background: false))
        let agents = try XCTUnwrap(client.tabs(forSession: task.id).first { $0.id == 91 })
        connection.eventHandler?(.externalApp(tab: agents.id, request: BrowserExternalAppRequest(
            url: "mailto:team@example.test", origin: "https://github.com", userGesture: true, remembered: true)))
        XCTAssertTrue(apps.opened.isEmpty)
        XCTAssertNotNil(agents.externalAppQuestion)

        // The agent sizes the tab right after a phone did: the agent's size stays, and the phone's end leaves it.
        before = connection.calls.count
        tab.noteAgentActivity()
        await bridge.setWatchedTabs([RemoteTabWatch(taskID: taskID, tabID: tabID, viewport: RemoteTabViewport(width: 390, height: 844))])
        let agent = Task { try await tab.emulate(BrowserViewportEmulation(width: 1024, height: 768, owner: .agent)) }
        try await agent.value
        await bridge.setWatchedTabs([RemoteTabWatch(taskID: taskID, tabID: tabID)])
        try await waitUntilAsync { tab.emulation?.owner == .agent }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(tab.emulation?.width, 1024, "no phone's size came back")
        let widths = connection.calls.dropFirst(before).filter { $0.method == "Emulation.setDeviceMetricsOverride" }
            .compactMap { $0.params["width"]?.integerValue }
        XCTAssertEqual(widths.last, 1024)

        // Sizes a phone asks for while another change runs make one change when its turn comes: the latest.
        before = connection.calls.count
        var askedMeanwhile = false
        connection.onCall = { method in
            guard method == "Emulation.setDeviceMetricsOverride", !askedMeanwhile else { return }
            askedMeanwhile = true
            for width in [390, 400, 410] {
                tab.sizeForRemote(BrowserViewportEmulation(width: width, height: 844, mobile: true, owner: .remote))
            }
        }
        try await tab.emulate(BrowserViewportEmulation(width: 800, height: 600, owner: .agent))
        try await waitUntilAsync { tab.emulation?.width == 410 }
        connection.onCall = nil
        XCTAssertEqual(connection.calls.dropFirst(before).filter { $0.method == "Emulation.setDeviceMetricsOverride" }
            .compactMap { $0.params["width"]?.integerValue }, [800, 410])
    }

    /// The fourth review of §15.25's host: a frame showing a file outside the task's keeps the page from the remote, also
    /// one that came and went while the page was pictured, and a frame that moves during a picture or between an input's
    /// steps stops it; the agent's acting on a page after a
    /// remote device's input lets it download (its downloads are its own) while another app still asks; a tab a page
    /// opens as a blocked pop-up is the agent's when the agent drove that page; a held tab's title belongs to its
    /// address; a refused download's empty pop-up closes and its opener says so; a password field that took the
    /// keyboard before the host said so is protected; and a page's dialog shows as what the tab waits on.
    func testARemoteDeviceSeesNoFrameOutsideTheTaskAndLeavesTheAgentItsOwnDownloads() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "remote-tab-frames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("<iframe></iframe>".utf8).write(to: folder.appending(path: "report.html"))
        try Data("<p>notes</p>".utf8).write(to: folder.appending(path: "notes.html"))
        let page = folder.appending(path: "report.html").absoluteString
        let notes = folder.appending(path: "notes.html").absoluteString
        let task = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
                                 title: "Report")
        let other = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
                                  title: "Held")
        let model = try Self.model(sessions: [task, other], transcripts: [:])
        let connection = AnsweringHostConnection()
        let client = BrowserHostClient(idleGrace: .seconds(60), agentVisibleWindow: .milliseconds(20)) { connection }
        let apps = RecordingExternalApps()
        client.externalApps = apps
        let bridge = AppModelRemoteBridge(model: model, browser: RemoteTabBridge.Environment(
            client: { client }, usesMacEditingCommands: true, marksTypedSecrets: { true }))
        let tab = try client.openTab(forSession: task.id, url: page, viewport: .offscreenDefault)
        connection.eventHandler?(.address(tab: tab.id, url: page))
        let taskID = task.id.uuidString, tabID = tab.key.uuidString
        await bridge.setWatchedTabs([RemoteTabWatch(taskID: taskID, tabID: tabID)])
        func frames(child: String, loader: String = "C1") -> String {
            #"{"frameTree":{"frame":{"id":"main","loaderId":"L1","url":"\#(page)"},"#
                + #""childFrames":[{"frame":{"id":"child","parentId":"main","loaderId":"\#(loader)","url":"\#(child)"}}]}}"#
        }
        func inputs(since mark: Int) -> Int { connection.calls.dropFirst(mark).filter { $0.method.hasPrefix("Input.") }.count }

        // A frame of the task's page shows a file outside the task's: neither pictured nor driven.
        connection.frameTree = frames(child: "file:///etc/hosts")
        let embedded = await bridge.captureTab(taskID: taskID, tabID: tabID, maxWidth: 640, maxHeight: 640)
        guard case let .failure(refused) = embedded else { return XCTFail("A page framing a file outside the task's was pictured") }
        XCTAssertEqual(refused.code, .notAllowed)
        var before = connection.calls.count
        let drivenEmbedded = await bridge.tabInput(taskID: taskID, tabID: tabID, input: .click(x: 5, y: 5), permit: RemoteTabPermit())
        XCTAssertEqual(drivenEmbedded?.code, .notAllowed)
        XCTAssertEqual(inputs(since: before), 0)

        // Its frame shows one of the task's own: pictured. A frame that moves while pictured, or between a click's steps,
        // stops it, though the tab's address stays.
        connection.frameTree = frames(child: notes)
        let own = await bridge.captureTab(taskID: taskID, tabID: tabID, maxWidth: 640, maxHeight: 640)
        XCTAssertNotNil(try? own.get())
        connection.onCall = { method in
            if method == "Page.captureScreenshot" { connection.frameTree = frames(child: notes, loader: "C2") }
        }
        let framed = await bridge.captureTab(taskID: taskID, tabID: tabID, maxWidth: 640, maxHeight: 640)
        guard case .failure = framed else { return XCTFail("A page whose frame moved during its picture was sent") }
        // A frame that shows a file outside the task's and goes again while the page is pictured: the tree reads the
        // same before and after, and the picture still does not go.
        connection.onCall = { method in
            guard method == "Page.captureScreenshot" else { return }
            connection.eventHandler?(.devTools(tab: tab.id, message:
                #"{"method":"Page.frameNavigated","params":{"frame":{"id":"brief","parentId":"main","loaderId":"B1","url":"file:///etc/hosts"}}}"#))
        }
        let passing = await bridge.captureTab(taskID: taskID, tabID: tabID, maxWidth: 640, maxHeight: 640)
        guard case let .failure(passed) = passing else { return XCTFail("A page that showed an outside file during its picture was sent") }
        XCTAssertEqual(passed.code, .notAllowed)
        connection.onCall = { method in
            if method == "Input.dispatchMouseEvent" { connection.frameTree = frames(child: notes, loader: "C3") }
        }
        before = connection.calls.count
        let movedFrame = await bridge.tabInput(taskID: taskID, tabID: tabID, input: .click(x: 5, y: 5), permit: RemoteTabPermit())
        XCTAssertEqual(movedFrame?.code, .notAllowed)
        XCTAssertEqual(inputs(since: before), 1, "only the step before the frame moved")
        connection.onCall = nil
        connection.frameTree = nil
        connection.eventHandler?(.address(tab: tab.id, url: "https://example.com/receipts"))

        // After the remote click the tab's downloads are refused; the agent reading it keeps that, the agent acting on
        // it lifts it before its input goes, and another app still asks.
        XCTAssertTrue(connection.sent.contains(.refuseDownloads(tab: tab.id, isRefused: true)))
        before = connection.sent.count
        tab.noteAgentActivity()
        XCTAssertFalse(connection.sent.dropFirst(before).contains(.refuseDownloads(tab: tab.id, isRefused: false)))
        tab.noteAgentInput()
        XCTAssertEqual(Array(connection.sent.dropFirst(before)), [.refuseDownloads(tab: tab.id, isRefused: false)])
        // An act that failed before it reached the page gives the refusal back; one that went keeps it lifted.
        tab.undoAgentInput()
        XCTAssertEqual(connection.sent.last, .refuseDownloads(tab: tab.id, isRefused: true))
        tab.noteAgentInput()
        XCTAssertEqual(connection.sent.last, .refuseDownloads(tab: tab.id, isRefused: false))
        connection.eventHandler?(.externalApp(tab: tab.id, request: BrowserExternalAppRequest(
            url: "mailto:billing@example.test", origin: "https://example.com", userGesture: true, remembered: true)))
        XCTAssertTrue(apps.opened.isEmpty, "another app still waits for the Mac")
        XCTAssertNotNil(tab.externalAppQuestion)
        tab.answerExternalApp(open: false, alwaysAllow: false)

        // A blocked pop-up the agent's page opens as a tab is the agent's.
        connection.eventHandler?(.newWindow(tab: tab.id, url: "https://example.com/receipt.pdf", background: false, userGesture: true))
        let opened = try XCTUnwrap(client.tabs(forSession: task.id).last)
        XCTAssertTrue(opened.openedByAgent)
        XCTAssertFalse(connection.sent.contains(.refuseDownloads(tab: opened.id, isRefused: true)))

        // A remote click again; its download, refused in an empty pop-up the page opened for it, closes that pop-up and
        // says so on the tab.
        let clicked = await bridge.tabInput(taskID: taskID, tabID: tabID, input: .click(x: 5, y: 5), permit: RemoteTabPermit())
        XCTAssertNil(clicked)
        var told: [String] = []
        tab.addEventObserver { if case let .remoteDownloadStopped(_, name) = $0 { told.append(name) } }
        connection.eventHandler?(.popupOpened(tab: 95, opener: tab.id, url: "about:blank", background: false))
        let blank = try XCTUnwrap(client.tabs(forSession: task.id).first { $0.id == 95 })
        connection.eventHandler?(.remoteDownloadStopped(tab: blank.id, fileName: "receipt.pdf"))
        XCTAssertNil(client.tabs(forSession: task.id).first { $0.id == 95 }, "the empty pop-up closed")
        XCTAssertEqual(told, ["receipt.pdf"])

        // A password field that took the keyboard (a Tab) before the host said so is protected before the text goes in.
        XCTAssertFalse(tab.isPasswordFieldFocused)
        connection.focusedField = "password"
        before = connection.calls.count
        let typed = await bridge.tabInput(taskID: taskID, tabID: tabID, input: .text("hunter2"), permit: RemoteTabPermit())
        XCTAssertNil(typed)
        XCTAssertTrue(tab.vaultFills.holdShownDocument(in: []))
        let typing = connection.calls.dropFirst(before).map(\.method)
        XCTAssertLessThan(try XCTUnwrap(typing.firstIndex(of: "Runtime.evaluate")), try XCTUnwrap(typing.firstIndex(of: "Input.insertText")))

        // A page's dialog is what the tab waits on, for the remote to say, and holds it from the remote.
        connection.eventHandler?(.javaScriptDialog(tab: tab.id, dialog: BrowserJavaScriptDialog(
            id: 3, kind: .confirm, message: "Leave?", defaultPrompt: "", origin: "https://example.com", isReload: false)))
        let waiting = try await bridge.browserTabs(taskID: taskID).get()
        XCTAssertEqual(waiting.first { $0.tabId == tabID }?.waiting, "javaScriptDialog")
        let underDialog = await bridge.captureTab(taskID: taskID, tabID: tabID, maxWidth: 640, maxHeight: 640)
        guard case let .failure(dialogRefusal) = underDialog else { return XCTFail("A page under its dialog was pictured") }
        XCTAssertEqual(dialogRefusal.code, .notAllowed)

        // A held tab's title is its address's: a file's does not name the page the tab moves to next.
        client.rememberTabs(BrowserRememberedTabs(addresses: ["https://example.com", "file:///etc/hosts"], keys: [UUID(), UUID()],
                                                  titles: ["Example", "hosts"], favicons: [nil, nil], fronted: 0),
                            forSession: other.id)
        _ = try await bridge.browserTabs(taskID: other.id.uuidString).get()
        let held = try XCTUnwrap(client.tabs(forSession: other.id).last)
        XCTAssertEqual(held.titleAddress, "file:///etc/hosts")
        connection.eventHandler?(.address(tab: held.id, url: "https://example.com/next"))
        let next = try await bridge.browserTabs(taskID: other.id.uuidString).get()
        XCTAssertNil(next.last?.title)
    }

    private static let frame = BrowserFrame(layer: .view, surface: 1, pixelWidth: 2560, pixelHeight: 1600, sequence: 1,
                                            paintedAt: 0, source: "accelerated")

    // MARK: - Commands through the window's paths

    func testCommandsGoThroughTheComposerTheCardAndTheStopButton() async throws {
        let adapter = FakeHarnessAdapter(kind: .claudeCode)
        let suite = testDefaultsSuite("RemoteBridgeTests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            restoresIndexOnLaunch: false)
        let created = await model.createSession(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/remote-bridge-commands"),
                                                runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Remote")
        let session = try XCTUnwrap(created)
        let bridge = AppModelRemoteBridge(model: model)
        let taskID = session.id.uuidString

        // Not attached yet: an answer has nowhere to go.
        let awaited28 = await bridge.perform(.answerApproval(taskID: taskID, requestID: "x", answer: .allowOnce))?.code
        XCTAssertEqual(awaited28,
                       .requestNotFound)
        let awaited29 = await bridge.perform(.stopTurn(taskID: taskID))?.code
        XCTAssertEqual(awaited29, .notRunning)
        let awaited30 = await bridge.perform(.markRead(taskID: UUID().uuidString))?.code
        XCTAssertEqual(awaited30, .notFound)

        // The composer's send: it attaches and sends, with the task's own settings.
        let awaited31 = await bridge.perform(.sendMessage(taskID: taskID, text: "Run the tests"))
        XCTAssertNil(awaited31)
        try await waitUntilAsync { await adapter.sentPrompts == ["Run the tests"] }

        let permission = PermissionRequest(id: "bash-1", title: "Bash", detail: nil, command: "swift test")
        await adapter.emit(.permissionRequested(permission), for: session.id, sequence: 1)
        await adapter.emit(.sessionStatusChanged(.waitingForApproval), for: session.id, sequence: 2)
        try await waitUntil { model.store.sessions.first?.status == .waitingForApproval }
        let awaited32 = await bridge.perform(.answerApproval(taskID: taskID, requestID: "other", answer: .allowOnce))?.code
        XCTAssertEqual(awaited32,
                       .requestNotFound)
        let awaited33 = await bridge.perform(.answerApproval(taskID: taskID, requestID: "bash-1", answer: .allowOnce))
        XCTAssertNil(awaited33)
        let decisions = await adapter.permissionDecisions
        XCTAssertEqual(decisions["bash-1"], .allow)
        XCTAssertTrue(model.transcriptBySessionID[session.id]?.contains { $0.content == .permission(permission, state: .allowed) } == true)

        // A choice the card offers goes by its own route (§15.19).
        let second = PermissionRequest(id: "bash-2", title: "Bash", detail: nil, command: "rm -rf build")
        await adapter.emit(.permissionRequested(second), for: session.id, sequence: 4)
        try await waitUntil { bridge.conversation(of: taskID)?.turns.last?.items.contains { $0.requestId == "bash-2" } == true }
        let choices = try XCTUnwrap(bridge.conversation(of: taskID)?.turns.last?.items.last { $0.requestId == "bash-2" }?.choices)
        let deny = try XCTUnwrap(choices.first { $0.role == "destructive" })
        let wrong = await bridge.perform(.chooseAnswer(taskID: taskID, requestID: "bash-2", choice: "9"))?.code
        XCTAssertEqual(wrong, .notAllowed)
        let chosen = await bridge.perform(.chooseAnswer(taskID: taskID, requestID: "bash-2", choice: deny.id))
        XCTAssertNil(chosen)
        let denied = await adapter.permissionDecisions
        XCTAssertEqual(denied["bash-2"], .deny)

        // Editing a message on the Mac: the phone's text is not taken as the edit.
        model.composerDrafts.tasks.draft(for: session.id).editState = ConversationEditState(
            session: session, targetID: "t", previousID: nil, originalText: "x", draft: TaskDraftSnapshot(), entries: [])
        let awaited34 = await bridge.perform(.sendMessage(taskID: taskID, text: "Other"))?.code
        XCTAssertEqual(awaited34, .busy)
        model.composerDrafts.tasks.draft(for: session.id).editState = nil

        await adapter.emit(.sessionStatusChanged(.running), for: session.id, sequence: 3)
        try await waitUntil { model.store.sessions.first?.status == .running }
        let awaited35 = await bridge.perform(.stopTurn(taskID: taskID))
        XCTAssertNil(awaited35)
        await model.shutdown()
    }

    func testTheFirstRemoteComposerObservesASuggestionArrivingAfterItsRead() async throws {
        let preferences = UserDefaults.yardlet
        let previous = preferences.object(forKey: NextMessageSuggestionPreference.key)
        preferences.set(true, forKey: NextMessageSuggestionPreference.key)
        defer {
            if let previous { preferences.set(previous, forKey: NextMessageSuggestionPreference.key) }
            else { preferences.removeObject(forKey: NextMessageSuggestionPreference.key) }
        }
        let session = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/composer-suggestion"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Next message", status: .completed)
        let model = try Self.model(sessions: [session], transcripts: [:])
        XCTAssertNil(model.composerDrafts.tasks.existingDraft(for: session.id))
        let bridge = AppModelRemoteBridge(model: model)
        let signals = SignalRecorder()
        bridge.setChangeHandler { signals.record($0) }
        bridge.setWatchedTasks([session.id.uuidString])
        let first = try await bridge.composerState(taskID: session.id.uuidString).get()
        XCTAssertNil(first.nextMessageSuggestion)
        model.composerDrafts.tasks.draft(for: session.id).nextMessageSuggestion = "Run the parser tests"
        try await waitUntil {
            signals.changes.contains { change in
                if case let .composerState(id) = change { return id == session.id.uuidString }
                return false
            }
        }
        let updated = try await bridge.composerState(taskID: session.id.uuidString).get()
        XCTAssertEqual(updated.nextMessageSuggestion, "Run the parser tests")
        await model.shutdown()
    }

    func testComposerEditsKeepHostAttachmentsAndDraftAndRejectProviderHeldMessages() async throws {
        let session = SessionRecord(harness: .codex, workspaceURL: URL(filePath: "/tmp/composer-queue"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Queue")
        let attachment = CodexUserInput.localImage(URL(filePath: "/tmp/composer-queue/image.png"))
        let queued = QueuedFollowUp(draft: CodexComposerDraft(inputs: [.text("Original"), attachment]))
        let held = QueuedFollowUp(draft: CodexComposerDraft(inputs: [.text("Provider held")]), state: .sent)
        let model = try Self.model(sessions: [session], transcripts: [:], queues: [session.id: [queued, held]])
        model.composerDrafts.tasks.draft(for: session.id).text = "Host draft"
        let bridge = AppModelRemoteBridge(model: model)
        let result = await bridge.composerAction(taskID: session.id.uuidString, action: "edit",
            itemID: "queued:\(queued.id.uuidString)", value: "Changed")
        _ = try result.get()
        XCTAssertEqual(model.followUps.item(queued.id, in: session.id)?.draft.inputs, [.text("Changed"), attachment])
        XCTAssertEqual(model.composerDrafts.tasks.draft(for: session.id).text, "Host draft")
        let refusal = await bridge.composerAction(taskID: session.id.uuidString, action: "edit",
            itemID: "queued:\(held.id.uuidString)", value: "Changed")
        guard case let .failure(error) = refusal else { return XCTFail("Provider-held messages cannot be overwritten") }
        XCTAssertEqual(error.code, .notAllowed)
        XCTAssertEqual(model.followUps.item(held.id, in: session.id)?.draft.text, "Provider held")
        await model.shutdown()
    }

    // MARK: - Helpers

    private static func model(sessions: [SessionRecord], transcripts: [UUID: [TranscriptEntry]],
                              queues: [UUID: [QueuedFollowUp]] = [:], schedules: [ScheduledTask] = [],
                              archived: [SessionRecord] = []) throws -> AppModel {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteBridgeTests")))
        let repository = InMemorySessionRepository(sessions: sessions + archived, archived: archived.map(\.id))
        return AppModel(
            store: SessionStore(sessions: sessions, repository: repository),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            initialTranscripts: transcripts,
            initialCodexQueues: queues,
            codexQueueRepository: InMemoryRemoteQueueRepository(),
            scheduleRepository: InMemoryScheduledTaskRepository(snapshot: ScheduleSnapshot(schedules: schedules)),
            restoresIndexOnLaunch: false)
    }


    private func waitUntilAsync(timeout: Duration = testWaitLimit, _ condition: () async -> Bool,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + timeout
        while await !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Condition not met in time", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Sleep

    func testAPairedPhoneKeepsTheMacAwakeWhileATaskWaitsOnAnApproval() {
        let folder = URL(filePath: "/tmp/remote-bridge-fixture", directoryHint: .isDirectory)
        let waiting = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
                                    title: "Approve", status: .waitingForApproval)
        let idle = SessionRecord(harness: .codex, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/codex"),
                                 title: "Idle", status: .ready)
        XCTAssertFalse(AppModel.keepsMacAwake(hasRunningWork: false, phoneCanAnswer: false, sessions: [waiting]),
                       "Without a phone, waiting is not working, as in the Codex app")
        XCTAssertTrue(AppModel.keepsMacAwake(hasRunningWork: false, phoneCanAnswer: true, sessions: [waiting, idle]))
        XCTAssertFalse(AppModel.keepsMacAwake(hasRunningWork: false, phoneCanAnswer: true, sessions: [idle]))
        XCTAssertTrue(AppModel.keepsMacAwake(hasRunningWork: true, phoneCanAnswer: false, sessions: [idle]))
    }

    // MARK: - Host Settings (§15.36)

    func testHostSettingsBridgeValidatesMutationsAndSignalsChanges() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "remote-bridge-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteBridgeSettings")))
        let runtimes = RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false, loadsPersistedSelections: false)
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: runtimes,
            preferences: defaults,
            restoresIndexOnLaunch: false)
        let instructions = YardletInstructionsStore(directory: folder.appending(path: "instructions"), defaults: defaults)
        instructions.text = "Prefer small diffs."
        model.yardletInstructions = instructions
        model.routingEvaluation = RoutingEvaluationStore(directory: folder.appending(path: "evaluation"), defaults: defaults)
        model.lidSleepHelper = LidSleepHelper(backend: FakeLidSleepHelperBackend(status: .needsApproval))
        model.tokenUsage = TokenUsageCenter(
            directory: folder.appending(path: "usage"),
            summary: TokenUsageSummary(days: [], groups: [:], updatedAt: Date()))

        let bridge = AppModelRemoteBridge(model: model)
        let signals = SignalRecorder()
        bridge.setChangeHandler { signals.record($0) }

        let initial = try await bridge.hostSettings().get()
        XCTAssertNotNil(initial.values["follow_up_behavior"])
        XCTAssertNotNil(initial.values["memory_saver"])
        XCTAssertNil(initial.values["language"], "Client-local language is excluded from host Settings")
        XCTAssertNil(initial.values["check_for_updates"], "Client-local update check is excluded from host Settings")
        XCTAssertEqual(initial.instructions?.text, "Prefer small diffs.")
        XCTAssertEqual(initial.instructions?.hasEvaluation, true)
        XCTAssertEqual(initial.lidHelperStatus, "needsApproval")

        // A client-local setting cannot be changed through setHostSetting.
        let localRefusal = await bridge.setHostSetting(setting: "language", value: "ko", confirmed: true)
        guard case let .failure(localError) = localRefusal else { return XCTFail("Expected client-local setting refusal") }
        XCTAssertEqual(localError.code, .notAllowed)

        // Settings with asksEveryTime require confirmed: true.
        let unconfirmed = await bridge.setHostSetting(setting: "agent_browser_tools", value: "off", confirmed: false)
        guard case let .failure(unconfirmedError) = unconfirmed else { return XCTFail("Expected unconfirmed refusal") }
        XCTAssertEqual(unconfirmedError.code, .notAllowed)
        let confirmed = try await bridge.setHostSetting(setting: "agent_browser_tools", value: "off", confirmed: true).get()
        XCTAssertEqual(confirmed.values["agent_browser_tools"], "off")

        // Turning off lid-closed sleep when the helper is not ready on the host is refused.
        let lidRefusal = await bridge.setHostSetting(setting: "keep_working_with_lid_closed", value: "on", confirmed: true)
        guard case let .failure(lidError) = lidRefusal else { return XCTFail("Expected lid helper refusal") }
        XCTAssertEqual(lidError.code, .notAllowed)

        // When the helper is ready on the host, the lid-closed setting can be turned on and off.
        model.lidSleepHelper = LidSleepHelper(backend: FakeLidSleepHelperBackend(status: .ready))
        let lidAllowed = try await bridge.setHostSetting(setting: "keep_working_with_lid_closed", value: "on", confirmed: true).get()
        XCTAssertEqual(lidAllowed.values["keep_working_with_lid_closed"], "on")

        // Ordinary host settings apply immediately and emit .hostSettings while watched.
        await bridge.setWatchesHostSettings(true)
        let followUp = try await bridge.setHostSetting(setting: "follow_up_behavior", value: "queue", confirmed: false).get()
        XCTAssertEqual(followUp.values["follow_up_behavior"], "queue")
        XCTAssertEqual(defaults.string(forKey: FollowUpMode.preferenceKey), "queue")
        try await waitUntilAsync { signals.changes.contains(.hostSettings) }

        // Instructions save updates the store and rejects oversized payloads.
        let savedInstructions = try await bridge.saveHostInstructions(text: "Run focused tests first.").get()
        XCTAssertEqual(savedInstructions.instructions?.text, "Run focused tests first.")
        XCTAssertEqual(instructions.text, "Run focused tests first.")
        let oversized = await bridge.saveHostInstructions(text: String(repeating: "x", count: 70_000))
        guard case let .failure(oversizedError) = oversized else { return XCTFail("Expected oversized refusal") }
        XCTAssertEqual(oversizedError.code, .tooLarge)

        await bridge.setWatchesHostSettings(false)
        await model.shutdown()
    }
}

/// A browser host whose tabs answer DevTools as an idle page does: the layout `layout` names, a picture, and an empty
/// result for anything else.
@MainActor
final class AnsweringHostConnection: BrowserHostConnection {
    var eventHandler: ((BrowserHostEvent) -> Void)?
    private(set) var sent: [BrowserHostCommand] = []
    private(set) var calls: [(method: String, params: JSONValue)] = []
    var layout = (width: 1280.0, height: 800.0, pageY: 0.0, ratio: 2.0)
    /// Off: the page does not say which document it shows, as when it is between documents.
    var answersFrameTree = true
    /// The page's frames when set (`Page.getFrameTree`'s result), else one main frame.
    var frameTree: String?
    /// What the focused field is, as the vault's world reads it: `password`, `other` or `unknown`.
    var focusedField = "other"
    /// Called with each DevTools method as it arrives, before it is answered.
    var onCall: ((String) -> Void)?

    func send(_ command: BrowserHostCommand) {
        sent.append(command)
        guard case .devTools(let tab, let message) = command,
              let object = try? JSONDecoder().decode(JSONValue.self, from: Data(message.utf8)),
              let id = object["id"]?.integerValue, let method = object["method"]?.stringValue else { return }
        calls.append((method, object["params"] ?? .object([:])))
        onCall?(method)
        let result: String = switch method {
        case "Page.getLayoutMetrics":
            #"{"cssVisualViewport":{"clientWidth":\#(layout.width),"clientHeight":\#(layout.height),"pageX":0,"pageY":\#(layout.pageY)}}"#
        case "Runtime.evaluate" where object["params"]?["expression"]?.stringValue?.contains("activeElement") == true:
            #"{"result":{"type":"string","value":"\#(focusedField)"}}"#
        case "Page.createIsolatedWorld": #"{"executionContextId":7}"#
        case "Page.getFrameTree" where answersFrameTree && frameTree != nil: frameTree ?? ""
        case "Runtime.evaluate" where object["params"]?["expression"]?.stringValue?.contains("navigator.userAgent") == true:
            #"{"result":{"type":"object","value":["Mozilla/5.0 (Macintosh) Chrome/154.0.0.0 Safari/537.36",[]]}}"#
        case "Runtime.evaluate": #"{"result":{"type":"number","value":\#(layout.ratio)}}"#
        case "Page.captureScreenshot": #"{"data":"\#(Data("JPEG".utf8).base64EncodedString())"}"#
        case "Page.getFrameTree" where answersFrameTree:
            #"{"frameTree":{"frame":{"id":"main","loaderId":"L1","url":"https://github.com/login"}}}"#
        case "Page.getFrameTree": #"{"frameTree":{"frame":{}}}"#
        default: "{}"
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.eventHandler?(.devTools(tab: tab, message: #"{"id":\#(id),"result":\#(result)}"#)) }
        }
    }

    func terminate() {}

    func visibility(of tab: BrowserTab) -> [Bool] {
        sent.compactMap { if case .visibility(let id, let hidden) = $0, id == tab.id { hidden } else { nil } }
    }
}

/// The Mac's other apps as the browser asks for them: every address has an app, and what was opened is kept.
@MainActor
final class RecordingExternalApps: BrowserExternalApps {
    private(set) var opened: [URL] = []
    func appName(for url: URL) -> String? { "Mail" }
    func open(_ url: URL) { opened.append(url) }
}

final class SignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RemoteBridgeChange] = []
    func record(_ change: RemoteBridgeChange) { lock.withLock { recorded.append(change) } }
    var changes: [RemoteBridgeChange] { lock.withLock { recorded } }
}

private extension RemoteEvent {
    static func items(_ items: [RemoteItem]) -> RemoteEvent {
        var event = RemoteEvent(.conversationReset)
        event.items = items
        return event
    }
}

/// A follow-up queue kept in memory only.
final class InMemoryRemoteQueueRepository: CodexQueueRepository {
    private var queues: [UUID: [QueuedFollowUp]] = [:]
    private var paused = Set<UUID>()
    private var shell: [UUID: [ClaudeShellDelivery]] = [:]

    func load(for sessionID: UUID) -> [QueuedFollowUp] { queues[sessionID] ?? [] }
    func save(_ queue: [QueuedFollowUp], for sessionID: UUID) { queues[sessionID] = queue }
    func remove(for sessionID: UUID) {
        queues[sessionID] = nil
        paused.remove(sessionID)
    }
    func isPaused(for sessionID: UUID) -> Bool { paused.contains(sessionID) }
    func setPaused(_ isPaused: Bool, for sessionID: UUID) {
        if isPaused { paused.insert(sessionID) } else { paused.remove(sessionID) }
    }
    func loadShellDeliveries(for sessionID: UUID) -> [ClaudeShellDelivery] { shell[sessionID] ?? [] }
    func saveShellDeliveries(_ deliveries: [ClaudeShellDelivery], for sessionID: UUID) { shell[sessionID] = deliveries }
}

private actor PausedTerminalSink {
    private(set) var bytes = Data()
    private(set) var isPaused = false
    private(set) var hasExited = false
    private(set) var exitCode: Int32?
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func accept(_ update: RemoteTerminalUpdate) async {
        switch update {
        case let .output(data):
            bytes.append(data)
            if !isPaused, !released, bytes.count >= 300_000 {
                isPaused = true
                await withCheckedContinuation { continuation = $0 }
            }
        case let .exited(status): exitCode = status; hasExited = true
        }
    }
    func resume() { released = true; continuation?.resume(); continuation = nil }
}
