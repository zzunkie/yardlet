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
            waiting.id: [TranscriptEntry(content: .user(text: "Go")), TranscriptEntry(content: .permission(permission, state: .pending))]
        ], queues: [waiting.id: [queued]])
        let bridge = AppModelRemoteBridge(model: model)
        let snapshot = bridge.snapshot()
        XCTAssertEqual(snapshot.tasks.map(\.title), ["Approve", "Done", "Child"])
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
        XCTAssertEqual(lastItems.last?.options, ["sendNow", "stopAndSend", "remove"], "The chip's actions (§15.15)")
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

    // MARK: - Helpers

    private static func model(sessions: [SessionRecord], transcripts: [UUID: [TranscriptEntry]],
                              queues: [UUID: [QueuedFollowUp]] = [:]) throws -> AppModel {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteBridgeTests")))
        return AppModel(
            store: SessionStore(sessions: sessions, repository: InMemorySessionRepository(sessions: sessions)),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            initialTranscripts: transcripts,
            initialCodexQueues: queues,
            codexQueueRepository: InMemoryRemoteQueueRepository(),
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
