import Foundation
import XCTest
@testable import NativeHarnessClient

/// Claude Code's `AskUserQuestion` and `ExitPlanMode` arrive as permission requests whose input
/// is the question form or the plan itself. These cover reading that input, returning the answer
/// in the shape the CLI accepts, and carrying both across the YHP route the app ships.
final class ClaudeAnswerableRequestTests: XCTestCase {
    private var questionInput: JSONValue {
        .object([
            "title": .string("Before I build your deck"),
            "questions": .array([
                .object([
                    "question": .string("Which library should we use for date formatting?"),
                    "header": .string("Library"),
                    "multiSelect": .bool(false),
                    "options": .array([
                        .object([
                            "label": .string("date-fns"),
                            "description": .string("Small and tree-shakeable")
                        ]),
                        .object([
                            "label": .string("Luxon"),
                            "preview": .string("```ts\nDateTime.now().toISODate()\n```")
                        ])
                    ])
                ]),
                .object([
                    "question": .string("Which features do you want to enable?"),
                    "header": .string("Features"),
                    "multiSelect": .bool(true),
                    "options": .array([
                        .object(["label": .string("Dark mode")]),
                        .object(["label": .string("Offline cache")]),
                        .object(["label": .string("Telemetry")])
                    ])
                ])
            ])
        ])
    }

    private var planInput: JSONValue {
        .object(["plan": .string("## Steps\n1. Read the adapter\n2. Add the card")])
    }

    // MARK: - Reading the provider's own request

    func testQuestionInputIsReadAsTheProviderWroteIt() throws {
        guard case let .questions(questions)? = ClaudeProtocol.structure(
            toolName: "AskUserQuestion",
            input: questionInput
        ) else {
            return XCTFail("AskUserQuestion did not produce an answerable request")
        }
        XCTAssertEqual(questions.count, 2)
        XCTAssertEqual(questions[0].question, "Which library should we use for date formatting?")
        XCTAssertEqual(questions[0].header, "Library")
        XCTAssertFalse(questions[0].allowsMultipleSelections)
        XCTAssertEqual(questions[0].options.map(\.label), ["date-fns", "Luxon"])
        XCTAssertEqual(questions[0].options[0].description, "Small and tree-shakeable")
        XCTAssertNil(questions[0].options[1].description)
        XCTAssertNil(questions[0].options[0].preview)
        XCTAssertEqual(questions[0].options[1].preview, "```ts\nDateTime.now().toISODate()\n```")
        XCTAssertTrue(questions[1].allowsMultipleSelections)
        XCTAssertEqual(
            questions[1].options.map(\.label),
            ["Dark mode", "Offline cache", "Telemetry"]
        )
    }

    func testPlanInputIsReadAsAPlanAndOtherToolsStayPlainApprovals() throws {
        guard case let .plan(plan)? = ClaudeProtocol.structure(
            toolName: "ExitPlanMode",
            input: planInput
        ) else {
            return XCTFail("ExitPlanMode did not produce a plan request")
        }
        XCTAssertEqual(plan, "## Steps\n1. Read the adapter\n2. Add the card")

        XCTAssertNil(ClaudeProtocol.structure(
            toolName: "Bash",
            input: .object(["command": .string("git status")])
        ))
        // A malformed or empty form is not answerable and must stay a plain approval.
        XCTAssertNil(ClaudeProtocol.structure(
            toolName: "AskUserQuestion",
            input: .object(["questions": .array([])])
        ))
        XCTAssertNil(ClaudeProtocol.structure(
            toolName: "AskUserQuestion",
            input: .object(["questions": .array([.object(["question": .string("Which?")])])])
        ))
        XCTAssertNil(ClaudeProtocol.structure(
            toolName: "ExitPlanMode",
            input: .object(["plan": .string("   ")])
        ))
    }

    // MARK: - The shape the answer goes back in

    func testAnswersRideOnUpdatedInputBesideTheProvidersOwnKeys() throws {
        let response = ClaudeProtocol.permissionResponse(
            requestID: "permission-1",
            decision: .allow,
            originalInput: questionInput,
            answers: [
                PermissionQuestionAnswer(
                    question: "Which library should we use for date formatting?",
                    selectedLabels: ["date-fns"]
                ),
                PermissionQuestionAnswer(
                    question: "Which features do you want to enable?",
                    selectedLabels: ["Dark mode", "Telemetry"]
                )
            ]
        )
        let payload = try XCTUnwrap(response["response"]?["response"])
        XCTAssertEqual(payload["behavior"]?.stringValue, "allow")
        let updated = try XCTUnwrap(payload["updatedInput"])
        // Only `answers` is added; everything the provider sent comes back untouched, which is
        // what the CLI admits.
        XCTAssertEqual(
            updated.objectValue?.keys.sorted(),
            ["answers", "questions", "title"]
        )
        XCTAssertEqual(updated["questions"], questionInput["questions"])
        XCTAssertEqual(updated["title"], questionInput["title"])
        let answers = try XCTUnwrap(updated["answers"])
        // A single-select question answers with its one label as a plain string.
        XCTAssertEqual(
            answers["Which library should we use for date formatting?"],
            .string("date-fns")
        )
        // A multi-select question answers with the picked labels as an array, which is the only
        // kind of question the CLI accepts one from. Joining them here would be the caller
        // guessing at a quoting rule the CLI owns.
        XCTAssertEqual(
            answers["Which features do you want to enable?"],
            .array([.string("Dark mode"), .string("Telemetry")])
        )
    }

    func testAMultiSelectLabelThatReadsLikeASeparatorStaysItsOwnAnswer() throws {
        let input: JSONValue = .object([
            "questions": .array([
                .object([
                    "question": .string("Which regions?"),
                    "multiSelect": .bool(true),
                    "options": .array([
                        .object(["label": .string("Seoul, KR")]),
                        .object(["label": .string("Tokyo, JP")])
                    ])
                ])
            ])
        ])
        let response = ClaudeProtocol.permissionResponse(
            requestID: "permission-3",
            decision: .allow,
            originalInput: input,
            answers: [
                PermissionQuestionAnswer(
                    question: "Which regions?",
                    selectedLabels: ["Seoul, KR", "Tokyo, JP"]
                )
            ]
        )
        XCTAssertEqual(
            response["response"]?["response"]?["updatedInput"]?["answers"]?["Which regions?"],
            .array([.string("Seoul, KR"), .string("Tokyo, JP")])
        )
    }

    func testASingleSelectAnswerStaysAStringEvenWhenTheFormMixesBothKinds() throws {
        let response = ClaudeProtocol.permissionResponse(
            requestID: "permission-4",
            decision: .allow,
            originalInput: questionInput,
            answers: [
                PermissionQuestionAnswer(
                    question: "Which library should we use for date formatting?",
                    selectedLabels: ["Luxon"]
                )
            ]
        )
        let answers = try XCTUnwrap(
            response["response"]?["response"]?["updatedInput"]?["answers"]
        )
        XCTAssertEqual(answers.objectValue?.keys.sorted(), ["Which library should we use for date formatting?"])
        XCTAssertEqual(
            answers["Which library should we use for date formatting?"],
            .string("Luxon")
        )
    }

    /// The person's own answer ("Other") goes where a label would, as the CLI takes it: the string
    /// itself for a question that takes one answer, the array's last entry after the labels for a
    /// multiple-selection question (the CLI takes one more entry than the options).
    func testAnOwnAnswerGoesWhereALabelWould() throws {
        let response = ClaudeProtocol.permissionResponse(
            requestID: "permission-5",
            decision: .allow,
            originalInput: questionInput,
            answers: [
                PermissionQuestionAnswer(question: "Which library should we use for date formatting?",
                                         selectedLabels: [], customAnswer: "Temporal, once it ships"),
                PermissionQuestionAnswer(question: "Which features do you want to enable?",
                                         selectedLabels: ["Dark mode"], customAnswer: "Keyboard shortcuts")
            ]
        )
        let answers = try XCTUnwrap(response["response"]?["response"]?["updatedInput"]?["answers"])
        XCTAssertEqual(answers["Which library should we use for date formatting?"], .string("Temporal, once it ships"))
        XCTAssertEqual(answers["Which features do you want to enable?"],
                       .array([.string("Dark mode"), .string("Keyboard shortcuts")]))
    }

    /// The answers the call's result recorded (`tool_use_result`, saved as `toolUseResult`) read back
    /// as the options picked and the person's own words, a multiple-selection answer split as the
    /// CLI joined it (an entry with ", " or a quote is a JSON string), the CLI's placeholders as no
    /// answer.
    func testTheRecordedAnswersReadBackFromTheCallsResult() throws {
        let result: JSONValue = .object([
            "questions": questionInput["questions"] ?? .null,
            "answers": .object([
                "Which library should we use for date formatting?": .string("Temporal, once it ships"),
                "Which features do you want to enable?": .string(#"Dark mode, Telemetry, "Undo, and redo""#)
            ])
        ])
        let answered = try XCTUnwrap(ClaudeProtocol.answeredQuestions(input: questionInput, result: result))
        XCTAssertEqual(answered.questions.map(\.question), [
            "Which library should we use for date formatting?", "Which features do you want to enable?"
        ])
        XCTAssertTrue(answered.questions.allSatisfy(\.allowsCustomAnswer), "Claude Code always takes an own answer")
        XCTAssertEqual(answered.answers, [
            PermissionQuestionAnswer(question: "Which library should we use for date formatting?", selectedLabels: [],
                                     customAnswer: "Temporal, once it ships"),
            PermissionQuestionAnswer(question: "Which features do you want to enable?",
                                     selectedLabels: ["Dark mode", "Telemetry"], customAnswer: "Undo, and redo")
        ])

        let placeholders: JSONValue = .object(["answers": .object([
            "Which library should we use for date formatting?": .string("date-fns"),
            "Which features do you want to enable?": .string("[No preference]")
        ])])
        XCTAssertEqual(try XCTUnwrap(ClaudeProtocol.answeredQuestions(input: questionInput, result: placeholders)).answers,
                       [PermissionQuestionAnswer(question: "Which library should we use for date formatting?",
                                                 selectedLabels: ["date-fns"])])
        XCTAssertNil(ClaudeProtocol.answeredQuestions(input: questionInput, result: .object(["questions": .array([])])),
                     "A result that records no answers is none")
        XCTAssertEqual(ClaudeProtocol.splitJoinedAnswers(#"a, "b, c", "say \"hi\"""#), ["a", "b, c", #"say "hi""#])
        XCTAssertNil(ClaudeProtocol.splitJoinedAnswers(#"a, b"c"#), "A string the CLI's join cannot have written")
    }

    func testAnApprovalWithNoAnswersStillReturnsTheOriginalInputUnchanged() throws {
        let response = ClaudeProtocol.permissionResponse(
            requestID: "permission-1",
            decision: .allow,
            originalInput: planInput
        )
        XCTAssertEqual(
            response["response"]?["response"]?["updatedInput"],
            planInput
        )
    }

    func testADeclinedPlanCarriesTheReasonTheUserWroteAsTheDenyMessage() throws {
        let withReason = ClaudeProtocol.permissionResponse(
            requestID: "permission-2",
            decision: .deny,
            originalInput: planInput,
            denialMessage: "Split step 2 into its own turn"
        )
        let payload = try XCTUnwrap(withReason["response"]?["response"])
        XCTAssertEqual(payload["behavior"]?.stringValue, "deny")
        XCTAssertEqual(payload["message"]?.stringValue, "Split step 2 into its own turn")
        XCTAssertEqual(payload["interrupt"]?.boolValue, false)

        // No reason keeps the denial wording the plain deny has always sent.
        let withoutReason = ClaudeProtocol.permissionResponse(
            requestID: "permission-2",
            decision: .deny,
            originalInput: planInput,
            denialMessage: "   "
        )
        XCTAssertEqual(
            withoutReason["response"]?["response"]?["message"]?.stringValue,
            "User denied this action"
        )
    }

    // MARK: - Saved transcripts

    func testSavedPermissionCardsWithoutAnAnswerableFormKeepDecoding() throws {
        let legacy = Data("""
        {"id":"permission-1","title":"Run command","command":"git status"}
        """.utf8)
        let decoded = try JSONDecoder().decode(PermissionRequest.self, from: legacy)
        XCTAssertEqual(decoded.id, "permission-1")
        XCTAssertEqual(decoded.command, "git status")
        XCTAssertTrue(decoded.actions.isEmpty)
        XCTAssertNil(decoded.structured)

        let answerable = PermissionRequest(
            id: "permission-2",
            title: "Question",
            detail: nil,
            command: nil,
            structured: .questions([
                PermissionQuestion(
                    question: "Which?",
                    header: "Pick",
                    options: [PermissionQuestionOption(label: "A")],
                    allowsMultipleSelections: true
                )
            ])
        )
        let roundTripped = try JSONDecoder().decode(
            PermissionRequest.self,
            from: JSONEncoder().encode(answerable)
        )
        XCTAssertEqual(roundTripped, answerable)
    }

    func testAnsweredCardsResolveTheWayApprovalCardsDo() throws {
        var builder = TranscriptBuilder()
        let request = PermissionRequest(
            id: "permission-1",
            title: "Question",
            detail: nil,
            command: nil,
            structured: .questions([
                PermissionQuestion(
                    question: "Which?",
                    options: [PermissionQuestionOption(label: "A")]
                )
            ])
        )
        builder.apply(.permissionRequested(request))
        guard case let .permission(pending, pendingState) = try XCTUnwrap(
            builder.entries.last
        ).content else {
            return XCTFail("the answerable request did not reach the transcript")
        }
        XCTAssertEqual(pendingState, .pending)
        XCTAssertEqual(pending.structured, request.structured)

        builder.resolvePermission(id: "permission-1", decision: .allow)
        guard case let .permission(answered, answeredState) = try XCTUnwrap(
            builder.entries.last
        ).content else {
            return XCTFail("the answered card left the transcript")
        }
        XCTAssertEqual(answeredState, .allowed)
        XCTAssertEqual(answered.structured, request.structured)

        var declined = TranscriptBuilder()
        declined.apply(.permissionRequested(PermissionRequest(
            id: "permission-2",
            title: "Plan",
            detail: nil,
            command: nil,
            structured: .plan("## Steps")
        )))
        declined.resolvePermission(id: "permission-2", decision: .deny)
        guard case let .permission(_, declinedState) = try XCTUnwrap(
            declined.entries.last
        ).content else {
            return XCTFail("the plan card left the transcript")
        }
        XCTAssertEqual(declinedState, .denied)
    }

    // MARK: - Adapter

    func testTheAdapterPublishesTheFormAndAnswersItOnTheWire() async throws {
        let transport = FakeClaudeTransport()
        let adapter = ClaudeAdapter(
            executableURL: URL(filePath: "/tmp/fake-claude"),
            transportFactory: { _ in transport }
        )
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/workspace"),
                initialPrompt: nil
            )
        )
        let recorder = AnswerableEventRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                await recorder.append(event.payload)
            }
        }
        defer { collector.cancel() }

        await transport.emit(canUseTool(
            requestID: "question-1",
            toolName: "AskUserQuestion",
            input: questionInput
        ))
        let request = try await waitForPermission(in: recorder)
        XCTAssertEqual(request.id, "question-1")
        // The form's own heading stands in for a description the request did not send.
        XCTAssertEqual(request.detail, "Before I build your deck")
        guard case let .questions(questions)? = request.structured else {
            return XCTFail("the adapter did not publish the question form")
        }
        XCTAssertEqual(questions.count, 2)

        try await adapter.respond(
            to: "question-1",
            answer: .questions([
                PermissionQuestionAnswer(
                    question: "Which features do you want to enable?",
                    selectedLabels: ["Dark mode", "Telemetry"]
                )
            ]),
            in: handle
        )
        let sent = await transport.sentValues
        let answered = try XCTUnwrap(sent.last?["response"]?["response"])
        XCTAssertEqual(answered["behavior"]?.stringValue, "allow")
        XCTAssertEqual(
            answered["updatedInput"]?["answers"]?["Which features do you want to enable?"],
            .array([.string("Dark mode"), .string("Telemetry")])
        )
        // The same request cannot be answered twice.
        do {
            try await adapter.respond(to: "question-1", decision: .allow, in: handle)
            XCTFail("a resolved request accepted a second answer")
        } catch let error as HarnessAdapterError {
            guard case .invalidProviderEvent = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        await adapter.close(handle)
    }

    func testTheAdapterPublishesThePlanAndCarriesTheReasonBack() async throws {
        let transport = FakeClaudeTransport()
        let adapter = ClaudeAdapter(
            executableURL: URL(filePath: "/tmp/fake-claude"),
            transportFactory: { _ in transport }
        )
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/workspace"),
                initialPrompt: nil
            )
        )
        let recorder = AnswerableEventRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                await recorder.append(event.payload)
            }
        }
        defer { collector.cancel() }

        await transport.emit(canUseTool(
            requestID: "plan-1",
            toolName: "ExitPlanMode",
            input: planInput
        ))
        let request = try await waitForPermission(in: recorder)
        XCTAssertEqual(
            request.structured,
            .plan("## Steps\n1. Read the adapter\n2. Add the card")
        )

        try await adapter.respond(
            to: "plan-1",
            answer: .denial(reason: "Split step 2 into its own turn"),
            in: handle
        )
        let sent = await transport.sentValues
        let declined = try XCTUnwrap(sent.last?["response"]?["response"])
        XCTAssertEqual(declined["behavior"]?.stringValue, "deny")
        XCTAssertEqual(declined["message"]?.stringValue, "Split step 2 into its own turn")
        await adapter.close(handle)
    }

    // MARK: - The route the app ships

    func testTheFormAndItsAnswerCrossTheYHPRouteTheAppShips() async throws {
        let transport = FakeClaudeTransport()
        let routed = YHPProviderCompatibilityAdapter(
            adapter: ClaudeAdapter(
                executableURL: URL(filePath: "/tmp/fake-claude"),
                transportFactory: { _ in transport }
            ),
            manifest: HarnessProtocolCompatibilityManifest.claude()
        )
        let handle = try await routed.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/workspace"),
                initialPrompt: nil
            )
        )
        let recorder = AnswerableEventRecorder()
        let collector = Task {
            for await event in await routed.events(for: handle) {
                await recorder.append(event.payload)
            }
        }
        defer { collector.cancel() }

        await transport.emit(canUseTool(
            requestID: "question-yhp",
            toolName: "AskUserQuestion",
            input: questionInput
        ))
        let request = try await waitForPermission(in: recorder)
        guard case let .questions(questions)? = request.structured else {
            return XCTFail("the question form did not survive the YHP route")
        }
        XCTAssertEqual(
            questions.map(\.question),
            [
                "Which library should we use for date formatting?",
                "Which features do you want to enable?"
            ]
        )
        XCTAssertEqual(questions.map(\.allowsMultipleSelections), [false, true])
        XCTAssertEqual(questions[0].options[0].description, "Small and tree-shakeable")
        XCTAssertEqual(questions[0].options[1].preview, "```ts\nDateTime.now().toISODate()\n```")

        try await routed.respond(
            to: "question-yhp",
            answer: .questions([
                PermissionQuestionAnswer(
                    question: "Which library should we use for date formatting?",
                    selectedLabels: ["date-fns"]
                ),
                PermissionQuestionAnswer(
                    question: "Which features do you want to enable?",
                    selectedLabels: ["Dark mode", "Telemetry"]
                )
            ]),
            in: handle
        )
        let sent = await transport.sentValues
        let answered = try XCTUnwrap(sent.last?["response"]?["response"])
        XCTAssertEqual(answered["behavior"]?.stringValue, "allow")
        // The picked labels cross YHP unjoined, so each kind of question keeps its own shape.
        XCTAssertEqual(
            answered["updatedInput"]?["answers"]?[
                "Which library should we use for date formatting?"
            ],
            .string("date-fns")
        )
        XCTAssertEqual(
            answered["updatedInput"]?["answers"]?["Which features do you want to enable?"],
            .array([.string("Dark mode"), .string("Telemetry")])
        )
        XCTAssertEqual(answered["updatedInput"]?["questions"], questionInput["questions"])
        await routed.close(handle)
    }

    /// An own answer crosses YHP to the wire, and the answers the call's result recorded cross back
    /// on the call's card, which the answered question card reads.
    func testAnOwnAnswerAndTheRecordedAnswersCrossTheYHPRouteTheAppShips() async throws {
        let transport = FakeClaudeTransport()
        let routed = YHPProviderCompatibilityAdapter(
            adapter: ClaudeAdapter(
                executableURL: URL(filePath: "/tmp/fake-claude"),
                transportFactory: { _ in transport }
            ),
            manifest: HarnessProtocolCompatibilityManifest.claude()
        )
        let handle = try await routed.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/workspace"),
                initialPrompt: nil
            )
        )
        let recorder = AnswerableEventRecorder()
        let collector = Task {
            for await event in await routed.events(for: handle) {
                await recorder.append(event.payload)
            }
        }
        defer { collector.cancel() }

        await transport.emit(.object([
            "type": .string("assistant"),
            "message": .object(["content": .array([.object([
                "type": .string("tool_use"), "id": .string("toolu_ask"), "name": .string("AskUserQuestion"),
                "input": questionInput
            ])])])
        ]))
        await transport.emit(canUseTool(requestID: "question-own", toolName: "AskUserQuestion", input: questionInput))
        let request = try await waitForPermission(in: recorder, id: "question-own")
        guard case let .questions(questions)? = request.structured else {
            return XCTFail("the question form did not survive the YHP route")
        }
        XCTAssertEqual(questions.map(\.allowsCustomAnswer), [true, true])
        try await routed.respond(
            to: "question-own",
            answer: .questions([
                PermissionQuestionAnswer(question: "Which library should we use for date formatting?",
                                         selectedLabels: [], customAnswer: "Temporal"),
                PermissionQuestionAnswer(question: "Which features do you want to enable?",
                                         selectedLabels: ["Telemetry"], customAnswer: "Undo, and redo")
            ]),
            in: handle
        )
        let sent = await transport.sentValues
        let answers = try XCTUnwrap(sent.last?["response"]?["response"]?["updatedInput"]?["answers"])
        XCTAssertEqual(answers["Which library should we use for date formatting?"], .string("Temporal"))
        XCTAssertEqual(answers["Which features do you want to enable?"],
                       .array([.string("Telemetry"), .string("Undo, and redo")]))

        // The CLI's result for the call, with the answers as it records them.
        await transport.emit(.object([
            "type": .string("user"),
            "message": .object(["role": .string("user"), "content": .array([.object([
                "type": .string("tool_result"), "tool_use_id": .string("toolu_ask"),
                "content": .string("User has answered your questions.")
            ])])]),
            "tool_use_result": .object([
                "questions": questionInput["questions"] ?? .null,
                "answers": .object([
                    "Which library should we use for date formatting?": .string("Temporal"),
                    "Which features do you want to enable?": .string(#"Telemetry, "Undo, and redo""#)
                ])
            ])
        ]))
        let deadline = ContinuousClock.now + testWaitLimit
        var recorded: HarnessAnsweredQuestions?
        while recorded == nil, ContinuousClock.now < deadline {
            recorded = await recorder.answeredQuestions(callID: "toolu_ask")
            if recorded == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let answered = try XCTUnwrap(recorded, "the recorded answers did not cross on the call's card")
        XCTAssertEqual(answered.answers, [
            PermissionQuestionAnswer(question: "Which library should we use for date formatting?", selectedLabels: [],
                                     customAnswer: "Temporal"),
            PermissionQuestionAnswer(question: "Which features do you want to enable?", selectedLabels: ["Telemetry"],
                                     customAnswer: "Undo, and redo")
        ])
        await routed.close(handle)
    }

    func testTheDeclinedPlanReasonCrossesTheYHPRouteTheAppShips() async throws {
        let transport = FakeClaudeTransport()
        let routed = YHPProviderCompatibilityAdapter(
            adapter: ClaudeAdapter(
                executableURL: URL(filePath: "/tmp/fake-claude"),
                transportFactory: { _ in transport }
            ),
            manifest: HarnessProtocolCompatibilityManifest.claude()
        )
        let handle = try await routed.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/workspace"),
                initialPrompt: nil
            )
        )
        let recorder = AnswerableEventRecorder()
        let collector = Task {
            for await event in await routed.events(for: handle) {
                await recorder.append(event.payload)
            }
        }
        defer { collector.cancel() }

        await transport.emit(canUseTool(
            requestID: "plan-yhp",
            toolName: "ExitPlanMode",
            input: planInput
        ))
        let request = try await waitForPermission(in: recorder)
        XCTAssertEqual(
            request.structured,
            .plan("## Steps\n1. Read the adapter\n2. Add the card")
        )

        try await routed.respond(
            to: "plan-yhp",
            answer: .denial(reason: "Split step 2 into its own turn"),
            in: handle
        )
        let sent = await transport.sentValues
        let declined = try XCTUnwrap(sent.last?["response"]?["response"])
        XCTAssertEqual(declined["behavior"]?.stringValue, "deny")
        XCTAssertEqual(declined["message"]?.stringValue, "Split step 2 into its own turn")

        // A plain deny over the same route keeps sending no reason of its own.
        await transport.emit(canUseTool(
            requestID: "plan-yhp-2",
            toolName: "ExitPlanMode",
            input: planInput
        ))
        _ = try await waitForPermission(in: recorder, id: "plan-yhp-2")
        try await routed.respond(to: "plan-yhp-2", decision: .deny, in: handle)
        let plain = await transport.sentValues
        XCTAssertEqual(
            plain.last?["response"]?["response"]?["message"]?.stringValue,
            "User denied this action"
        )
        await routed.close(handle)
    }

    // MARK: - Helpers

    private func canUseTool(
        requestID: String,
        toolName: String,
        input: JSONValue
    ) -> JSONValue {
        .object([
            "type": .string("control_request"),
            "request_id": .string(requestID),
            "request": .object([
                "subtype": .string("can_use_tool"),
                "tool_name": .string(toolName),
                "input": input
            ])
        ])
    }

    private func waitForPermission(
        in recorder: AnswerableEventRecorder,
        id: String? = nil,
        timeout: Duration = testWaitLimit
    ) async throws -> PermissionRequest {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let request = await recorder.permission(id: id) { return request }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("no permission request arrived")
        throw HarnessAdapterError.invalidProviderEvent("no permission request arrived")
    }
}

private actor AnswerableEventRecorder {
    private var payloads: [HarnessEventPayload] = []

    func append(_ payload: HarnessEventPayload) { payloads.append(payload) }

    func answeredQuestions(callID: String) -> HarnessAnsweredQuestions? {
        payloads.compactMap { payload -> HarnessAnsweredQuestions? in
            guard case let .activityCompleted(activity) = payload, activity.id == callID else { return nil }
            return activity.answeredQuestions
        }.last
    }

    func permission(id: String?) -> PermissionRequest? {
        payloads.compactMap { payload -> PermissionRequest? in
            guard case let .permissionRequested(request) = payload else { return nil }
            return id == nil || request.id == id ? request : nil
        }.last
    }
}
