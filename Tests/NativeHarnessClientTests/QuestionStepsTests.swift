import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The question card as the Claude app's Code card and the Codex app's input panel ask: one question at
/// a time with its place among several, the person's own answer under the options where the provider
/// takes one, Skip and Next, every answer sent at once from the last question in the provider's own
/// shape, and, once answered, each question with what it was answered with, read back from the
/// provider's record so the card reads the same when the conversation is opened again (2026-10-23:
/// a user reported that the card had no field for a typed answer and asked for one question at a time).
@MainActor
final class QuestionStepsTests: XCTestCase {
    static let scope = PermissionQuestion(
        question: "Which parts should the release notes cover?", header: "Scope",
        options: [
            PermissionQuestionOption(label: "Composer", description: "Return, ⌘Return and the queue"),
            PermissionQuestionOption(label: "Streaming", description: "The live line while a turn runs"),
            PermissionQuestionOption(label: "Question card", description: "Option and button text")
        ],
        allowsMultipleSelections: true, allowsCustomAnswer: true)
    static let audience = PermissionQuestion(
        question: "Who will read them?", header: "Audience",
        options: [
            PermissionQuestionOption(label: "The team", description: "Engineers who build Yardlet"),
            PermissionQuestionOption(label: "Everyone", description: "A short public summary")
        ],
        allowsCustomAnswer: true)
    static let tone = PermissionQuestion(
        question: "Which tone?", header: "Tone",
        options: [PermissionQuestionOption(label: "Plain"), PermissionQuestionOption(label: "Friendly")],
        allowsCustomAnswer: true)

    static func claudeRequest(_ questions: [PermissionQuestion], state: ConversationRequestState = .pending,
                              recorded: [String: ConversationQuestionAnswer]? = nil) -> ConversationRequest {
        let permission = PermissionRequest(id: "ask", title: "Claude has questions", detail: nil, command: nil,
                                           structured: .questions(questions), toolCallID: "ask-tool")
        return ConversationRequest(
            id: "ask", title: permission.title, form: .choices(questions), state: state,
            responses: state == .pending ? ConversationRequestResponses.questions : [], toolCallID: "ask-tool",
            recordedAnswers: recorded,
            source: .transcript(TranscriptEntry(content: .permission(permission, state: state == .pending ? .pending : .allowed))))
    }

    // MARK: - Steps

    /// Next waits for an answer or a skip, and says why; the last question says which earlier one
    /// still waits. A question that takes one answer starts on its first option.
    func testTheCardGoesOnOnlyFromAnAnsweredOrSkippedQuestion() {
        let steps = ConversationRequestForm.choices([Self.scope, Self.audience, Self.tone]).questionSteps
        var input = ConversationRequestFormInput()
        input.preselect(steps)
        XCTAssertNil(input.selections[Self.scope.question], "A multiple-selection question starts on nothing")
        XCTAssertEqual(input.answer(for: steps[1]), ConversationQuestionAnswer(options: ["The team"]))
        XCTAssertEqual(input.answer(for: steps[2]), ConversationQuestionAnswer(options: ["Plain"]))

        var stepper = ConversationQuestionStepper(steps: steps)
        XCTAssertTrue(stepper.isStepped)
        XCTAssertFalse(input.isSettled(steps[0]))
        XCTAssertEqual(stepper.blocker(input), L10n.string("Choose an option or skip this question"))
        stepper.move(to: 2)
        XCTAssertTrue(stepper.isLast)
        XCTAssertEqual(stepper.blocker(input), L10n.format("Question %lld is unanswered", Int64(1)))
        input.skip(steps[0])
        XCTAssertNil(stepper.blocker(input))
        XCTAssertNil(stepper.firstUnsettled(input))
        stepper.move(to: 9)
        XCTAssertEqual(stepper.index, 2, "The card stays among its questions")
    }

    /// Typing answers a question that takes one answer with the words instead of its option, as the
    /// Codex app does; picking an option again answers with the option and keeps the words typed. A
    /// multiple-selection question takes the words with its options.
    func testTheOwnAnswerAndTheOptionsTakeTurnsAsTheProviderAllows() {
        let steps = ConversationRequestForm.choices([Self.scope, Self.audience]).questionSteps
        var input = ConversationRequestFormInput()
        input.preselect(steps)
        input.setCustomAnswer("  Reviewers outside the team ", for: steps[1])
        XCTAssertEqual(input.answer(for: steps[1]), ConversationQuestionAnswer(custom: "Reviewers outside the team"))
        XCTAssertTrue(input.isCustomAnswerChosen(for: steps[1]))
        input.toggle("Everyone", for: steps[1])
        XCTAssertEqual(input.answer(for: steps[1]), ConversationQuestionAnswer(options: ["Everyone"]))
        XCTAssertEqual(input.text[steps[1].id], "  Reviewers outside the team ", "The words stay typed")
        input.toggle("Everyone", for: steps[1])
        XCTAssertEqual(input.answer(for: steps[1])?.options, ["Everyone"], "A radio button stays picked")
        input.chooseCustomAnswer(for: steps[1])
        XCTAssertEqual(input.answer(for: steps[1]), ConversationQuestionAnswer(custom: "Reviewers outside the team"))

        input.toggle("Question card", for: steps[0])
        input.toggle("Composer", for: steps[0])
        input.setCustomAnswer("Keyboard shortcuts", for: steps[0])
        XCTAssertEqual(input.answer(for: steps[0]),
                       ConversationQuestionAnswer(options: ["Composer", "Question card"], custom: "Keyboard shortcuts"))
    }

    /// Claude Code's answer: the options in the provider's order, the person's own words after them,
    /// a skipped question left out; nothing until every question is answered or skipped.
    func testClaudeAnswersCarryTheOwnAnswerAndLeaveSkippedQuestionsOut() throws {
        let request = Self.claudeRequest([Self.scope, Self.audience, Self.tone])
        let submit = try XCTUnwrap(request.responses.first)
        let steps = try XCTUnwrap(request.form).questionSteps
        var input = ConversationRequestFormInput()
        input.preselect(steps)
        XCTAssertNil(request.route(for: submit, input: input), "The first question still waits")
        input.toggle("Question card", for: steps[0])
        input.toggle("Composer", for: steps[0])
        input.setCustomAnswer("Keyboard shortcuts", for: steps[0])
        input.setCustomAnswer("Reviewers", for: steps[1])
        input.skip(steps[2])
        XCTAssertEqual(request.route(for: submit, input: input), .answer(.questions([
            PermissionQuestionAnswer(question: Self.scope.question, selectedLabels: ["Composer", "Question card"],
                                     customAnswer: "Keyboard shortcuts"),
            PermissionQuestionAnswer(question: Self.audience.question, selectedLabels: [], customAnswer: "Reviewers")
        ])))

        // Muse takes only its options, for every question: no own answer, no skip.
        let muse = PermissionQuestion(question: "Which target?", options: [PermissionQuestionOption(label: "Unit")],
                                      requiresAnswer: true)
        let museStep = ConversationQuestionStep(muse)
        XCTAssertFalse(museStep.canSkip)
        XCTAssertFalse(museStep.allowsCustomAnswer)
        var museInput = ConversationRequestFormInput()
        museInput.skip(museStep)
        XCTAssertFalse(museInput.isSettled(museStep))
    }

    // MARK: - Codex

    /// A Codex `requestUserInput` question with options takes one of them or, where it says
    /// `isOther`, the person's own words; one without options only words; a secret one hides them.
    /// The answer goes under each question's ID, a skipped one left out, and the response the
    /// thread keeps reads back as each question's answer.
    func testCodexQuestionsTakeTheirOptionsOrOwnWordsAndReadBackFromTheResponse() throws {
        let params: JSONValue = .object(["questions": .array([
            .object(["id": .string("branch"), "header": .string("Branch"), "question": .string("Which branch?"),
                     "isOther": .bool(true), "isSecret": .bool(false),
                     "options": .array([.object(["label": .string("main"), "description": .string("Default")]),
                                        .object(["label": .string("release")])])]),
            .object(["id": .string("why"), "question": .string("Why?"), "isOther": .bool(false), "isSecret": .bool(false),
                     "options": .null]),
            .object(["id": .string("token"), "question": .string("Token?"), "isOther": .bool(false),
                     "isSecret": .bool(true), "options": .null]),
            .object(["id": .string("mode"), "question": .string("Which mode?"), "isOther": .bool(false),
                     "options": .array([.object(["label": .string("fast")]), .object(["label": .string("safe")])])])
        ])])
        var server = CodexServerRequestState(id: "7", method: "item/tool/requestUserInput", kind: .toolUserInput,
                                             threadID: "thread", turnID: "t1", itemID: "i1", params: params,
                                             resolution: .pending)
        let request = CodexRequestResponseProjection.request(server)
        let steps = try XCTUnwrap(request.form).questionSteps
        XCTAssertEqual(steps.map(\.id), ["branch", "why", "token", "mode"])
        XCTAssertEqual(steps.map(\.header), ["Branch", nil, nil, nil])
        XCTAssertEqual(steps.map(\.allowsCustomAnswer), [true, true, true, false])
        XCTAssertEqual(steps.map(\.isFreeTextOnly), [false, true, true, false])
        XCTAssertEqual(steps.map(\.isSecret), [false, false, true, false])
        XCTAssertEqual(steps[0].options.first, PermissionQuestionOption(label: "main", description: "Default"))

        let send = try XCTUnwrap(request.responses.first)
        var input = ConversationRequestFormInput()
        input.preselect(steps)
        XCTAssertNil(request.route(for: send, input: input), "The free-text questions still wait")
        input.setCustomAnswer("feature/question-steps", for: steps[0])
        input.setCustomAnswer("To ship it", for: steps[1])
        input.skip(steps[2])
        XCTAssertEqual(request.route(for: send, input: input), .codex(.toolUserInput(answers: [
            "branch": ["feature/question-steps"], "why": ["To ship it"], "mode": ["fast"]
        ])))

        let response = try XCTUnwrap(CodexServerRequestResponse.toolUserInput(answers: [
            "branch": ["feature/question-steps"], "why": ["To ship it"], "mode": ["fast"]
        ]).result(for: server.method))
        server.resolution = .resolved(response)
        let answered = CodexRequestResponseProjection.request(server)
        XCTAssertTrue(answered.isAnsweredQuestion)
        XCTAssertEqual(answered.recordedAnswers, [
            "branch": ConversationQuestionAnswer(custom: "feature/question-steps"),
            "why": ConversationQuestionAnswer(custom: "To ship it"),
            "mode": ConversationQuestionAnswer(options: ["fast"])
        ])
    }

    // MARK: - Claude: live and read back

    /// Answered live, the card reads as the answers the call's result recorded; opened again, the
    /// conversation is read back from Claude's saved transcript and the card reads the same, with
    /// nothing to press, and stays in view when the turn's work folds.
    /// What Claude wrote before asking reads as said to the person, beside the answered card when the
    /// work folds, though the API sent it as thinking: Claude Opus 5.5 sends a note before a tool call
    /// as a progress-update thinking block, its text a summary (2026-10-23: a question about "the
    /// wording above" that showed only in the thought process). Its reasoning stays reasoning.
    func testAnAnsweredClaudeQuestionReadsTheSameLiveAndWhenOpenedAgain() throws {
        let input: JSONValue = .object(["questions": .array([
            .object(["question": .string(Self.scope.question), "header": .string("Scope"), "multiSelect": .bool(true),
                     "options": .array(Self.scope.options.map { .object(["label": .string($0.label),
                                                                         "description": .string($0.description ?? "")]) })]),
            .object(["question": .string(Self.audience.question), "header": .string("Audience"), "multiSelect": .bool(false),
                     "options": .array(Self.audience.options.map { .object(["label": .string($0.label),
                                                                            "description": .string($0.description ?? "")]) })])
        ])])
        let toolUse: JSONValue = .object(["type": .string("tool_use"), "id": .string("toolu_ask"),
                                          "name": .string("AskUserQuestion"), "input": input])
        let note = "I would cover the composer and streaming, for engineers, in the wording below."
        let reasoning: JSONValue = .object(["type": .string("thinking"), "thinking": .string("Weighing what readers need."),
                                            "signature": .string(Self.thinkingSignature("thinking"))])
        let progressUpdate: JSONValue = .object(["type": .string("thinking"), "thinking": .string(note),
                                                 "signature": .string(Self.thinkingSignature("narration"))])
        let toolResult: JSONValue = .object(["type": .string("tool_result"), "tool_use_id": .string("toolu_ask"),
                                             "content": .string("User has answered your questions.")])
        let recorded: JSONValue = .object([
            "questions": input["questions"] ?? .null,
            "answers": .object([Self.scope.question: .string("Composer, Keyboard shortcuts"),
                                Self.audience.question: .string("Reviewers outside the team")])
        ])

        // Live: the call, the request the CLI holds, its answer, the result.
        var projection = ClaudeSessionProjection()
        var builder = TranscriptBuilder()
        builder.appendUser("Write the release notes")
        let noteStreams: JSONValue = .object(["type": .string("stream_event"), "event": .object([
            "type": .string("content_block_delta"),
            "delta": .object(["type": .string("thinking_delta"), "thinking": .string("I would cover the composer")])
        ])])
        for frame in [.object(["type": .string("assistant"), "message": .object(["content": .array([reasoning])])]),
                      noteStreams,
                      .object(["type": .string("assistant"), "message": .object(["content": .array([progressUpdate])])]),
                      .object(["type": .string("assistant"), "message": .object(["content": .array([toolUse])])])] as [JSONValue] {
            projection.payloads(from: frame).forEach { builder.apply($0) }
        }
        let structure = try XCTUnwrap(ClaudeProtocol.structure(toolName: "AskUserQuestion", input: input))
        builder.apply(.permissionRequested(PermissionRequest(id: "question-1", title: "Claude has questions", detail: nil,
                                                             command: nil, structured: structure, toolCallID: "toolu_ask")))
        builder.resolvePermission(id: "question-1", decision: .allow)
        for payload in projection.payloads(from: .object([
            "type": .string("user"), "message": .object(["role": .string("user"), "content": .array([toolResult])]),
            "tool_use_result": recorded
        ])) {
            builder.apply(payload)
        }
        builder.apply(.assistantMessageCompleted("Done."))
        builder.apply(.turnCompleted)
        let live = try answeredCard(in: builder.entries)
        XCTAssertEqual(try work(in: builder.entries), .init(
            work: ["reasoning", "answer, summary: \(note)", "card"], keptWhenFolded: ["answer, summary: \(note)", "card"]))
        XCTAssertEqual(live.recordedAnswers, [
            Self.scope.question: ConversationQuestionAnswer(options: ["Composer"], custom: "Keyboard shortcuts"),
            Self.audience.question: ConversationQuestionAnswer(custom: "Reviewers outside the team")
        ])
        XCTAssertEqual(live.title, "Claude has questions")

        // Opened again: Claude's saved transcript, the result's answers under `toolUseResult`.
        let root = try temporaryFolder()
        let sessionID = "11111111-2222-4333-8444-666666666666"
        let folder = root.appending(path: "projects/-tmp-project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var records: [[String: Any]] = []
        func add(_ type: String, _ content: Any, extra: [String: Any] = [:]) {
            var record: [String: Any] = ["type": type, "uuid": UUID().uuidString.lowercased(), "sessionId": sessionID,
                                         "parentUuid": records.last?["uuid"] ?? NSNull(),
                                         "timestamp": "2026-10-23T01:00:0\(records.count).000Z",
                                         "message": ["role": type, "content": content]]
            record.merge(extra) { $1 }
            records.append(record)
        }
        func object(_ value: JSONValue) throws -> Any {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
        }
        let reasoningObject = try object(reasoning)
        let progressUpdateObject = try object(progressUpdate)
        let useObject = try object(toolUse)
        let resultObject = try object(toolResult)
        let recordedObject = try object(recorded)
        add("user", "Write the release notes")
        add("assistant", [reasoningObject])
        add("assistant", [progressUpdateObject])
        add("assistant", [useObject])
        add("user", [resultObject], extra: ["toolUseResult": recordedObject])
        add("assistant", [["type": "text", "text": "Done."]])
        let lines = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: folder.appending(path: "\(sessionID).jsonl"))
        let saved = try XCTUnwrap(try ClaudeSubagentTranscriptReader(configDirectory: root).readConversation(sessionID: sessionID))
        let reopened = try answeredCard(in: saved.entries)

        XCTAssertEqual(reopened.form, live.form)
        XCTAssertEqual(reopened.state, live.state)
        XCTAssertEqual(reopened.recordedAnswers, live.recordedAnswers)
        XCTAssertTrue(reopened.responses.isEmpty, "An answered card offers nothing to press")
        XCTAssertEqual(try work(in: saved.entries), try work(in: builder.entries))
    }

    /// A thinking block's signature naming its kind as the API writes it: a version, then the kind in
    /// field 8 of field 1 of field 2 of the envelope (`ClaudeProgressUpdate`).
    static func thinkingSignature(_ kind: String) -> String {
        func field(_ number: UInt8, _ bytes: [UInt8]) -> [UInt8] { [number << 3 | 2, UInt8(bytes.count)] + bytes }
        return Data([0x08, 0x01] + field(2, field(1, [0x10, 0x05] + field(8, Array(kind.utf8))))).base64EncodedString()
    }

    private struct WorkRead: Equatable {
        let work: [String]
        let keptWhenFolded: [String]
    }

    /// The finished conversation's last turn: its work, and what of it stays in view when it folds.
    private func work(in entries: [TranscriptEntry]) throws -> WorkRead {
        let turn = try XCTUnwrap(TranscriptConversationProjection.presentation(
            from: entries, harness: .claudeCode, status: .ready, latestTurnIsComplete: true).turns.last)
        func read(_ item: ConversationItem) -> String {
            switch item.kind {
            case let .answer(text, _): "answer\(item.isSummary ? ", summary" : ""): \(text)"
            case let .commentary(text, _): "commentary\(item.isSummary ? ", summary" : ""): \(text)"
            case .reasoning: "reasoning"
            case .request: "card"
            default: "\(item.kind)"
            }
        }
        return WorkRead(work: turn.work.map(read), keptWhenFolded: turn.workKeptWhenFolded.map(read))
    }

    /// The one answered question card of `entries`' conversation, which stays in view when the turn
    /// folds; the call's tool row and the live request are that card.
    private func answeredCard(in entries: [TranscriptEntry], file: StaticString = #filePath, line: UInt = #line)
        throws -> ConversationRequest {
        let turn = try XCTUnwrap(TranscriptConversationProjection.presentation(
            from: entries, harness: .claudeCode, status: .ready, latestTurnIsComplete: true).turns.last,
            file: file, line: line)
        let cards = turn.work.compactMap { item -> ConversationRequest? in
            if case let .request(request) = item.kind { return request } else { return nil }
        }
        XCTAssertEqual(cards.count, 1, "one card for the call: \(turn.work.map(\.kind))", file: file, line: line)
        XCTAssertFalse(turn.work.contains { if case .tool = $0.kind { true } else { false } },
                       "the call's tool row is the card", file: file, line: line)
        XCTAssertTrue(turn.workKeptWhenFolded.contains { item in
            if case .request = item.kind { true } else { false }
        }, "the answered card stays in view when the work folds", file: file, line: line)
        let card = try XCTUnwrap(cards.first, file: file, line: line)
        XCTAssertTrue(card.isAnsweredQuestion, file: file, line: line)
        return card
    }

    // MARK: - Rendering

    /// The card at the conversation's width and at the session rail's, in light and dark: a first
    /// question of three with nothing picked, the second with its own answer typed, the last with
    /// its answer button, a Codex form with a free-text question, and the answered summaries.
    func testTheQuestionStepsReadInBothAppearancesAndAtTheRailsWidth() throws {
        let directory = try WindowlessRender.directory("question-steps-qa")
        let questions = [Self.scope, Self.audience, Self.tone]
        var typed = ConversationRequestFormInput()
        typed.selections[Self.scope.question] = ["Composer", "Question card"]
        typed.text[Self.audience.question] = "Reviewers outside the team"
        typed.selections[Self.audience.question] = []
        let codexParams: JSONValue = .object(["questions": .array([
            .object(["id": .string("why"), "header": .string("Reason"), "question": .string("Why switch the branch now?"),
                     "isOther": .bool(false), "options": .null])
        ])])
        let codex = CodexRequestResponseProjection.request(CodexServerRequestState(
            id: "7", method: "item/tool/requestUserInput", kind: .toolUserInput, threadID: "thread",
            turnID: "t1", itemID: "i1", params: codexParams, resolution: .pending))
        let recorded: [String: ConversationQuestionAnswer] = [
            Self.scope.question: ConversationQuestionAnswer(options: ["Composer", "Question card"], custom: "Keyboard shortcuts"),
            Self.audience.question: ConversationQuestionAnswer(custom: "Reviewers outside the team")
        ]
        let states: [(String, ConversationRequest, ConversationRequestFormInput, Int, CGFloat)] = [
            ("first", Self.claudeRequest(questions), .init(), 0, 640),
            ("own-answer", Self.claudeRequest(questions), typed, 1, 640),
            ("last", Self.claudeRequest(questions), typed, 2, 640),
            ("codex-free-text", codex, .init(), 0, 640),
            ("answered", Self.claudeRequest(questions, state: .answered, recorded: recorded), .init(), 0, 640),
            ("rail-first", Self.claudeRequest(questions), typed, 1, 320),
            ("rail-answered", Self.claudeRequest(questions, state: .answered, recorded: recorded), .init(), 0, 320)
        ]
        for (name, request, input, index, width) in states {
            try WindowlessRender.hostedInBothAppearances("question-steps-\(name)", in: directory,
                                                         size: NSSize(width: width, height: 640)) { appearance in
                ConversationRequestCard(request: request, actions: ConversationActions(answer: { _, _ in }),
                                        input: input, questionIndex: index)
                    .padding(20)
                    .frame(width: width)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: width, height: 640, alignment: .top)
                    .background(ParityTheme.canvas)
                    .tint(Color.primary)
                    .environment(\.controlActiveState, .key)
                    .environment(\.colorScheme, appearance.colorScheme)
            }
        }
    }

    // MARK: - In a window

    /// In a real window, as a person answers: pick options on the first question, go on, type an own
    /// answer on the second, skip the third, and send. The answer that goes is the provider's shape;
    /// the card then reads as each question and its answer, with nothing left to press; and it reads
    /// the same once the provider's record replaces what it sent. Number keys and ← → work once the
    /// person has clicked into the form.
    func testAPersonStepsThroughTheQuestionsTypesAnOwnAnswerAndSends() throws {
        let box = QuestionAnswerBox(request: Self.claudeRequest([Self.scope, Self.audience, Self.tone]))
        let window = QuestionKeyWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 640, height: 720),
                               styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: QuestionCardHost(box: box))
        window.contentView = hosting
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        settle(hosting)

        func labels() -> [String] { hosting.accessibilityLabels() }
        func press(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
            guard let element = hosting.accessibilityElement(labelled: label) else {
                return XCTFail("no “\(label)” in \(labels())", file: file, line: line)
            }
            XCTAssertTrue(element.accessibilityPerformPress?() ?? false, "“\(label)” did not press", file: file, line: line)
            settle(hosting)
        }

        // The first question alone, its place among three, Next waiting for a pick.
        XCTAssertTrue(labels().contains("Composer"))
        XCTAssertFalse(labels().contains("The team"), "One question at a time: \(labels())")
        XCTAssertTrue(labels().contains(L10n.string("Next")))
        press("Composer")
        // Keys, once the person has clicked into the form: 3 picks the third option, → goes on.
        key(window, "3", code: 20)
        settle(hosting)
        key(window, "\u{F703}", code: 124)
        settle(hosting)
        XCTAssertTrue(labels().contains("The team"), "→ shows the second question: \(labels())")
        key(window, "\u{F702}", code: 123)
        settle(hosting)
        XCTAssertTrue(labels().contains("Composer"), "← shows the first again")
        press(L10n.string("Next"))

        // The second: its first option already picked; typing an own answer chooses it instead.
        XCTAssertTrue(labels().contains("Everyone"))
        let field = try XCTUnwrap(hosting.editableTextViews().first, "no field for an own answer")
        XCTAssertTrue(window.makeFirstResponder(field))
        settle(hosting)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "the field took no typing")
        editor.insertText("Reviewers outside the team", replacementRange: NSRange(location: NSNotFound, length: 0))
        settle(hosting)
        press(L10n.string("Next"))

        // The third: skipped, which on the last question sends every answer at once.
        XCTAssertTrue(labels().contains("Friendly"))
        XCTAssertTrue(labels().contains(L10n.string("Submit answers")))
        press(L10n.string("Skip"))
        XCTAssertEqual(box.answers, [.questions([
            PermissionQuestionAnswer(question: Self.scope.question, selectedLabels: ["Composer", "Question card"]),
            PermissionQuestionAnswer(question: Self.audience.question, selectedLabels: [],
                                     customAnswer: "Reviewers outside the team")
        ])])

        // Answered: each question with its answer, nothing to press.
        let answered = WindowlessRender.accessibilityElements(in: hosting)
        let rows = answered.filter { [Self.scope.question, Self.audience.question, Self.tone.question].contains($0.label) }
            .map { "\($0.label) = \($0.value)" }
        XCTAssertEqual(rows, [
            "\(Self.scope.question) = Composer, Question card",
            "\(Self.audience.question) = Reviewers outside the team",
            "\(Self.tone.question) = \(L10n.string("Not answered"))"
        ], "\(answered)")
        XCTAssertFalse(answered.contains { $0.role == "AXButton" || $0.role == "AXTextField" || $0.role == "AXTextArea" },
                       "Nothing on the answered card can be pressed or typed in: \(answered)")

        // The provider's record replaces what the card sent, and reads the same.
        box.request.recordedAnswers = [
            Self.scope.question: ConversationQuestionAnswer(options: ["Composer", "Question card"]),
            Self.audience.question: ConversationQuestionAnswer(custom: "Reviewers outside the team")
        ]
        settle(hosting)
        XCTAssertEqual(WindowlessRender.accessibilityElements(in: hosting), answered)
        let capture = try WindowlessRender.capture(hosting)
        try WindowlessRender.writePNG(capture, to: try WindowlessRender.directory("question-steps-qa")
            .appending(path: "question-steps-window-answered.png"))
    }

    // MARK: - Helpers

    private func settle(_ view: NSView, passes: Int = 8) {
        for _ in 0..<passes {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    private func key(_ window: NSWindow, _ characters: String, code: UInt16) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
            else { continue }
            window.sendEvent(event)
        }
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "question-steps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
}

/// The request a card in the window draws, answered as the conversation answers it: the request
/// turns answered once the answer is sent.
@MainActor
private final class QuestionAnswerBox: ObservableObject {
    @Published var request: ConversationRequest
    private(set) var answers: [PermissionStructuredAnswer] = []

    init(request: ConversationRequest) { self.request = request }

    func answer(_ answer: PermissionStructuredAnswer) {
        answers.append(answer)
        request.state = .answered
        request.responses = []
    }
}

private struct QuestionCardHost: View {
    @ObservedObject var box: QuestionAnswerBox

    var body: some View {
        ConversationRequestCard(request: box.request, actions: ConversationActions(answer: { _, answer in
            box.answer(answer)
        }))
        .padding(20)
        .frame(width: 640, height: 720, alignment: .top)
    }
}

/// A window that takes keys, off screen, as the task window does.
private final class QuestionKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private extension NSView {
    /// What the accessibility tree under the view is labelled, in order, as an assistive app reads it.
    func accessibilityLabels() -> [String] {
        var labels: [String] = []
        WindowlessRender.withAccessibilityTree {
            func visit(_ node: AnyObject) {
                for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                    if let label = child.accessibilityLabel?() ?? nil, !label.isEmpty { labels.append(label) }
                    let value: Any? = (child.accessibilityValue?() as Any??) ?? nil
                    if let value = value as? String, !value.isEmpty { labels.append(value) }
                    visit(child)
                }
            }
            visit(self)
        }
        return labels
    }

    func accessibilityElement(labelled label: String) -> AnyObject? {
        find { ($0.accessibilityLabel?() ?? nil) == label }
    }

    func accessibilityButton(labelled label: String) -> AnyObject? {
        find { ($0.accessibilityLabel?() ?? nil) == label && ($0.accessibilityRole?() ?? nil) == .button
            && ($0.isAccessibilityEnabled?() ?? true) }
    }

    func editableTextViews() -> [NSView] {
        var found: [NSView] = []
        func visit(_ view: NSView) {
            if let field = view as? NSTextField, field.isEditable { found.append(field) }
            if let text = view as? NSTextView, text.isEditable { found.append(text) }
            view.subviews.forEach(visit)
        }
        visit(self)
        return found
    }

    private func find(_ matches: (AnyObject) -> Bool) -> AnyObject? {
        var result: AnyObject?
        WindowlessRender.withAccessibilityTree {
            func visit(_ node: AnyObject) -> AnyObject? {
                for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                    if matches(child) { return child }
                    if let found = visit(child) { return found }
                }
                return nil
            }
            result = visit(self)
        }
        return result
    }
}
