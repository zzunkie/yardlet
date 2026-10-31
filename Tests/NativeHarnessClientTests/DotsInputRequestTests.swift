import XCTest
@testable import NativeHarnessClient

/// Input requests in a dot's messages: which answers each kind offers, and the inspect, claim and
/// single-dispatch order every answer follows. All requests here are synthetic.
@MainActor
final class DotsInputRequestTests: XCTestCase {
    func testEachKindOffersOnlyItsOwnAnswers() throws {
        // An ordinary form is submitted only with every field valid.
        let form = try kind(params(schema: #"{"type":"object","properties":{"name":{"type":"string","minLength":1},"count":{"type":"integer","minimum":1,"maximum":5}},"required":["name","count"]}"#))
        guard case let .form(fields, .ordinary) = form else { return XCTFail("An ordinary form: \(form)") }
        XCTAssertNil(DotsInputResult.submit(fields, ["name": .text("Example")]))
        XCTAssertEqual(DotsInputResult.submit(fields, ["name": .text("Example"), "count": .text("2")])?.json,
                       try value(#"{"action":"accept","content":{"name":"Example","count":2},"_meta":null}"#))

        // An empty form that says what it asks is a plain approval, with nothing to remember it by.
        guard case let .approval(generic) = try kind(params(message: "Confirm this operation")) else { return XCTFail() }
        XCTAssertEqual(generic.allow()?.json, try value(#"{"action":"accept","content":{},"_meta":null}"#))
        XCTAssertNil(generic.allow(.session), "A scope the request did not offer is never sent")
        XCTAssertEqual(generic.deny, .decline)
        XCTAssertEqual(generic.cancel, .cancel)
        // A blank one, an approval kind Yardlet does not know and tool metadata the schema does not
        // take are shown but not answered as an empty form.
        for (params, reason) in [
            (try params(message: "  "), DotsUnsupportedRequest.Reason.unrecognized),
            (try params(meta: #"{"codex_approval_kind":"new_kind"}"#), .unknownApproval),
            (try params(meta: #"{"codex_approval_kind":"mcp_tool_call","connector_id":"c"}"#), .unknownApproval),
            (try params(schema: #"{"type":"object","properties":{"x":{"type":"string"}}}"#,
                        meta: #"{"codex_approval_kind":"mcp_tool_call","connector_id":"c","tool_params":{}}"#), .unrecognized),
            (try params(meta: #"{"codex_approval_kind":"tool_suggestion","suggest_type":"install","suggest_reason":"Connect it","tool_type":"connector","tool_id":"t","tool_name":"Example","install_url":"https://example.com"}"#), .toolSetup),
            (try params(meta: #"{"openai/location":{}}"#), .location),
            (try params(mode: "openaiForm", schema: #"{"type":"object","properties":{"photo":{"type":"string","x-openai-input":"image"}}}"#), .openAIForm),
            (try params(schema: #"{"type":"object","properties":{"name":{"type":"string"}}}"#, meta: #"{"openai/confirmation":{}}"#), .form),
            // A special kind is read before the form modes: neither OpenAI form takes one as a plain form.
            (try params(mode: "openaiForm", schema: #"{"type":"object","properties":{"name":{"type":"string"}}}"#,
                        meta: #"{"codex_approval_kind":"browser_auth"}"#), .unrecognized),
            (try params(mode: "openai/form", schema: #"{"type":"object","properties":{"name":{"type":"string"}}}"#,
                        meta: #"{"codex_approval_kind":"browser_auth"}"#), .unrecognized),
            (try params(meta: #"{"codex_approval_kind":"browser_auth"}"#), .browserSignIn),
            (try params(mode: "openai/form", schema: #"{"type":"object","properties":{"name":{"type":"string"}}}"#,
                        meta: #"{"codex_approval_kind":"mcp_tool_call","connector_id":"c","tool_params":{}}"#), .unknownApproval)
        ] {
            let expected = reason == .toolSetup
                ? DotsUnsupportedRequest(reason: reason, message: "Example", detail: "Connect it")
                : DotsUnsupportedRequest(reason: reason, message: params["message"]?.stringValue)
            XCTAssertEqual(try kind(params), .unsupported(expected), "\(params)")
        }
        guard case let .form(_, .openAIForm) = try kind(params(mode: "openaiForm",
            schema: #"{"type":"object","properties":{"name":{"type":"string"}}}"#)) else { return XCTFail("The strict subset") }
        guard case let .form(_, .legacyOpenAIForm) = try kind(params(mode: "openai/form",
            schema: #"{"type":"object","properties":{"name":{"type":"string"}}}"#)) else { return XCTFail("The strict subset") }

        // A tool call the person denies is cancelled, saying the person chose it; only offered scopes are kept.
        guard case let .approval(tool) = try kind(params(meta: #"{"codex_approval_kind":"mcp_tool_call","connector_id":"connector_example","tool_name":"send_item","tool_params":{"item":"example"},"persist":["session","always"]}"#))
        else { return XCTFail() }
        XCTAssertEqual(tool.deny.json, try value(#"{"action":"cancel","content":null,"_meta":{"codex_approval_cancellation_reason":"user"}}"#))
        XCTAssertNil(tool.cancel)
        XCTAssertEqual(tool.allow(.always)?.json, try value(#"{"action":"accept","content":{},"_meta":{"persist":"always"}}"#))

        // A database change runs once: allowed only with a canonical, bound summary, and never remembered.
        let summary = #"{"approval_version":1,"binding_name":"db","column":"status","deployment_id":"dep","new_value":"done","old_value":"open","primary_key_column":"id","primary_key_value":"7","project_id":"proj","table_name":"tasks"}"#
        guard case let .approval(change) = try kind(sites("sites.execute_database_update", summary)) else { return XCTFail() }
        XCTAssertTrue(change.isExecutionBound)
        XCTAssertTrue(change.persist.isEmpty, "An offered scope is removed")
        XCTAssertNil(change.allow(.session))
        XCTAssertNotNil(change.allow())
        XCTAssertTrue(change.presentation.isHighRisk)
        for (tool, text) in [
            ("sites.execute_database_update", summary.replacingOccurrences(of: ",", with: ", ")),
            ("sites.execute_database_delete", summary),
            // Numbers beyond the safe range, down to the smallest 64-bit integer, are refused, not trapped on.
            ("sites.execute_database_delete", #"{"approval_version":1,"binding_name":"db","deployment_id":"dep","operation":"delete","primary_key_column":"id","primary_key_value":"-9223372036854775808","project_id":"proj","table_name":"tasks","values":{"id":-9223372036854775808}}"#),
            ("sites.execute_database_update", summary.replacingOccurrences(of: #""approval_version":1"#, with: #""approval_version":-9223372036854775808"#)),
            ("sites.execute_database_insert", #"{"approval_version":1,"binding_name":"db","deployment_id":"dep","operation":"insert","primary_key_column":"id","primary_key_value":"7","project_id":"proj","table_name":"tasks","values":{"id":"7","name":"Café"}}"#)
        ] {
            guard case let .approval(unbound) = try kind(sites(tool, text)) else { return XCTFail() }
            XCTAssertTrue(unbound.approveDisabled, "\(tool) \(text)")
            XCTAssertNil(unbound.allow())
        }
        for (tool, text) in [
            ("sites.execute_database_insert", #"{"approval_version":1,"binding_name":"db","deployment_id":"dep","operation":"insert","primary_key_column":"id","primary_key_value":"7","project_id":"proj","table_name":"tasks","values":{"id":"7","name":"Caf\u00e9"}}"#),
            ("sites.execute_database_delete", #"{"approval_version":1,"binding_name":"db","deployment_id":"dep","operation":"delete","primary_key_column":"id","primary_key_value":"7","project_id":"proj","table_name":"tasks","values":{"id":7}}"#)
        ] {
            guard case let .approval(bound) = try kind(sites(tool, text)) else { return XCTFail() }
            XCTAssertFalse(bound.approveDisabled, "\(tool) \(text)")
        }

        // The message's request identity must agree with its parameters.
        XCTAssertNil(DotsInputRequest(try value(#"{"request_id":"r","thread_id":"t","params":{"threadId":"other","message":"x"}}"#)))
        XCTAssertNil(DotsInputRequest(try value(#"{"request_id":"r","thread_id":"t","turn_id":" ","params":{"threadId":"t"}}"#)))

        // Option questions: nonblank options, a recorded choice inside them, a reply's nonnegative choice.
        XCTAssertEqual(DotsOptionPicker(metadata: try value(#"{"option_picker":{"options":["A","B"],"selected":1}}"#))?.selected, 1)
        XCTAssertNil(DotsOptionPicker(metadata: try value(#"{"option_picker":{"options":["A"," "]}}"#)))
        XCTAssertNil(DotsOptionPicker(metadata: try value(#"{"option_picker":{"options":["A"],"selected":1}}"#)))
        XCTAssertNil(DotsOptionPicker.selection(try value(#"{"option_picker":{"selection":-1}}"#)))
    }

    func testTheFileJournalClaimsARequestOnceForEveryWindowAndHome() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "dots-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = DotsResponseJournalFiles(directory: directory)
        let second = DotsResponseJournalFiles(directory: directory)
        let key = DotsResponseKey(accountID: "a", userID: "u", roomID: "r", threadID: "t", turnID: nil, requestID: "q")
        XCTAssertEqual(key.serialized, #"["a","u","r","t",null,"q"]"#)
        XCTAssertTrue(try first.claim(key))
        XCTAssertFalse(try second.claim(key), "Another window or home cannot claim the same request")
        try second.release(key)
        XCTAssertNil(try first.record(for: key))
        XCTAssertTrue(try second.claim(key))
        let ack = DotsResponseAcknowledgement(fingerprint: "f", action: "accept", persist: nil)
        try first.acknowledge(key, ack)
        try second.acknowledge(key, .init(fingerprint: "g", action: "decline", persist: nil))
        XCTAssertEqual(try first.record(for: key), .acknowledged(ack), "An acknowledgement is kept")
        XCTAssertThrowsError(try first.release(key), "Only an unsent claim is released")
        let stored = try String(contentsOf: try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).first { $0.pathExtension == "json" }), encoding: .utf8)
        XCTAssertFalse(stored.contains("\"q\""), "The record holds no request identity or answer content")
        // A store that cannot be written refuses, and the answer is then never sent.
        let blocked = directory.appending(path: "blocked")
        try Data().write(to: blocked)
        XCTAssertThrowsError(try DotsResponseJournalFiles(directory: blocked).claim(key))
    }

    func testAnAnswerIsInspectedClaimedAndSentOnceAndAnUncertainOneIsNeverSentAgain() async throws {
        let journal = DotsMemoryResponseJournal()
        let reader = InputRequestReader(messages: [message("tool", try toolRequest())])
        let center = PersonalAgentCenter(responses: journal)
        await center.connect(sourceKey: "home") { reader }
        let item = try await answerable(center, "tool")

        // A request whose parameters changed since the message, or with no fingerprint, is not answered.
        await reader.inspect("tool", params: try value(#"{"threadId":"thread","mode":"form","message":"Changed"}"#))
        await center.respond(to: item, with: deny(item))
        await reader.inspect("tool", fingerprint: nil)
        await center.checkInputRequest(item)
        await center.respond(to: item, with: deny(item))
        var answers = await reader.answers
        XCTAssertTrue(answers.isEmpty)
        XCTAssertNil(try journal.record(for: item.key))

        // Known not sent: the claim is released and the request can be answered.
        await reader.inspect("tool")
        await reader.failNextAnswer(.notDispatched(.network))
        await center.checkInputRequest(item)
        await center.respond(to: item, with: deny(item))
        XCTAssertNil(try journal.record(for: item.key))
        XCTAssertEqual(item.attempt, .notSent(.network))
        XCTAssertEqual(item.phase, .answerable)
        // Perhaps sent: the claim stays, and neither checking nor a restart sends it again.
        await reader.failNextAnswer(.uncertain(.deliveryUnknown))
        await center.respond(to: item, with: deny(item))
        answers = await reader.answers
        XCTAssertEqual(answers.map(\.result), [deny(item)])
        XCTAssertEqual(answers.first?.result.json, try value(#"{"action":"cancel","content":null,"_meta":{"codex_approval_cancellation_reason":"user"}}"#))
        XCTAssertEqual(try journal.record(for: item.key), .claimed)
        XCTAssertEqual(item.phase, .unconfirmed)
        await center.checkInputRequest(item)
        await center.respond(to: item, with: deny(item))
        let restarted = PersonalAgentCenter(responses: journal)
        await restarted.connect(sourceKey: "other-home") { reader }
        let reopened = try XCTUnwrap(restarted.conversation?.requests["tool"])
        try await waitUntil { reopened.inspection != nil }
        XCTAssertEqual(reopened.phase, .unconfirmed)
        await restarted.respond(to: reopened, with: deny(reopened))
        answers = await reader.answers
        XCTAssertEqual(answers.count, 1)
        // The provider closing it closes the card; the claim stays.
        await reader.inspect("tool", status: "resolved")
        await restarted.checkInputRequest(reopened)
        XCTAssertEqual(reopened.phase, .closed(.resolved))
        XCTAssertEqual(try journal.record(for: item.key), .claimed)
        await center.disconnect()
        await restarted.disconnect()
    }

    func testTwoWindowsAnswerOnceAndAStoreThatFailsSendsNothing() async throws {
        let journal = DotsMemoryResponseJournal()
        let reader = InputRequestReader(messages: [message("approval", try request(params(message: "Confirm this operation")))])
        let first = PersonalAgentCenter(responses: journal)
        let second = PersonalAgentCenter(responses: journal)
        await first.connect(sourceKey: "home") { reader }
        await second.connect(sourceKey: "home") { reader }
        let shown = try await answerable(first, "approval")
        let other = try await answerable(second, "approval")
        journal.fails = true
        await first.respond(to: shown, with: .decline)
        XCTAssertEqual(shown.attempt, .storage)
        journal.fails = false
        await first.checkInputRequest(shown)
        await first.respond(to: shown, with: try XCTUnwrap(approval(shown).allow()))
        XCTAssertEqual(shown.phase, .closed(.allowed))
        // The other window still shows it waiting; its answer finds the claim and is not sent.
        await second.respond(to: other, with: .decline)
        let answers = await reader.answers
        XCTAssertEqual(answers.map(\.result.action), [.accept])
        XCTAssertEqual(answers.first?.fingerprint, "fingerprint")
        XCTAssertEqual(try journal.record(for: shown.key), .acknowledged(.init(fingerprint: "fingerprint", action: "accept", persist: nil)))
        XCTAssertNotEqual(other.phase, .answerable)
        await first.disconnect()
        await second.disconnect()
    }

    func testAnOptionAnswerRereadsTheQuestionKeepsTheDraftAndRetriesOnlyTheSameRequest() async throws {
        let picker = try value(#"{"option_picker":{"options":["Keep it","Publish it"]}}"#)
        var question = PersonalAgentMessage(id: "question", author: .agent, text: "What next?", createdAt: nil,
                                            isDeleted: false, attachments: [])
        question.metadata = picker
        let reader = InputRequestReader(messages: [question])
        let center = PersonalAgentCenter()
        await center.connect(sourceKey: "home") { reader }
        let state = try XCTUnwrap(center.conversation)
        state.draft.editor.text = "An unrelated draft"

        // A read of the displayed range that fails is no check of the question.
        await reader.failReads(true)
        await center.chooseOption(1, in: "question")
        XCTAssertEqual(state.optionReply.problem, .unchecked)
        await reader.failReads(false)
        await reader.loseNextSend()
        await center.chooseOption(1, in: "question")
        let pending = try XCTUnwrap(state.optionReply.pending)
        XCTAssertEqual([pending.text, pending.replyToMessageID], ["Publish it", "question"])
        XCTAssertEqual(pending.optionSelection, 1)
        XCTAssertEqual(state.draft.editor.text, "An unrelated draft")
        // Another choice waits for the first; only the same request is sent again.
        await center.chooseOption(0, in: "question")
        await center.retryOptionReply()
        let sends = await reader.sends
        XCTAssertEqual(sends.map(\.requestID), [pending.requestID, pending.requestID])
        XCTAssertEqual(sends.map(\.text), ["Publish it", "Publish it"])
        XCTAssertNil(state.optionReply.pending)
        XCTAssertEqual(state.draft.editor.text, "An unrelated draft")
        XCTAssertTrue(center.isAnswered(question, in: state))

        // A question answered or changed meanwhile is not answered again.
        var answered = question
        answered.metadata = try value(#"{"option_picker":{"options":["Keep it","Publish it"],"selected":0}}"#)
        await reader.setMessages([answered])
        state.sentMessages = []
        await center.chooseOption(0, in: "question")
        XCTAssertEqual(state.optionReply.problem, .changed)
        let after = await reader.sends
        XCTAssertEqual(after.count, 2)
        await center.disconnect()
    }

    /// A read that comes back after the person moved to another dot ends with it, so the request is not
    /// left checking when they return; what it read is not shown on the other dot.
    func testAReadThatOutlivesNavigationEndsAndTheRequestCanBeReadAgain() async throws {
        let reader = InputRequestReader(messages: [message("tool", try toolRequest())])
        let center = PersonalAgentCenter()
        await reader.holdNextInspect()
        await center.connect(sourceKey: "home") { reader }
        let item = try XCTUnwrap(center.conversation?.requests["tool"])
        try await waitUntil { await reader.hasHeldInspect() }
        await center.select(reader.other.id)
        await reader.releaseInspect()
        try await waitUntil { !item.isChecking }
        XCTAssertNil(item.inspection, "A late read is not applied while another dot is shown")
        await center.select(reader.agent.id)
        XCTAssertTrue(center.conversation?.requests["tool"] === item)
        try await waitUntil { item.phase == .answerable }
        // A lost login read while another dot of the same connection is shown still ends that login.
        await reader.holdNextInspect()
        await reader.failInspect(.signInRequired)
        let checking = Task { await center.checkInputRequest(item) }
        try await waitUntil { await reader.hasHeldInspect() }
        await center.select(reader.other.id)
        await reader.releaseInspect()
        await checking.value
        XCTAssertEqual(center.failure, .signInRequired)
        XCTAssertNil(center.selected)
        await center.disconnect()
    }

    /// An answer that ends after the window moved to another account keeps or releases its own claim,
    /// and its login failure does not clear the account now shown.
    func testALateAnswerFailureDoesNotEndTheNextAccountsLogin() async throws {
        for (failure, keepsClaim) in [(DotsResponseFailure.uncertain(.accountChanged), true),
                                      (.notDispatched(.signInRequired), false)] {
            let journal = DotsMemoryResponseJournal()
            let first = InputRequestReader(messages: [message("tool", try toolRequest())])
            let next = InputRequestReader(messages: [], account: "another")
            let center = PersonalAgentCenter(responses: journal)
            await center.connect(sourceKey: "home-a") { first }
            let item = try await answerable(center, "tool")
            await first.holdNextAnswer()
            await first.failNextAnswer(failure)
            let answering = Task { await center.respond(to: item, with: deny(item)) }
            try await waitUntil { await first.hasHeldAnswer() }
            await center.connect(sourceKey: "home-b") { next }
            await first.releaseAnswer()
            await answering.value
            XCTAssertNil(center.failure, "\(failure)")
            XCTAssertEqual(center.selected?.id.accountID, "another")
            XCTAssertEqual(try journal.record(for: item.key), keepsClaim ? .claimed : nil, "\(failure)")
            await center.disconnect()
        }
    }

    /// Sending the waiting answer again checks the question as choosing did, and settles by reading
    /// when the first attempt already arrived.
    func testRetryingAnOptionAnswerChecksTheQuestionAndSettlesByReading() async throws {
        var question = PersonalAgentMessage(id: "question", author: .agent, text: "What next?", createdAt: nil,
                                            isDeleted: false, attachments: [])
        question.metadata = try value(#"{"option_picker":{"options":["Keep it","Publish it"]}}"#)
        let reader = InputRequestReader(messages: [question])
        let center = PersonalAgentCenter()
        await center.connect(sourceKey: "home") { reader }
        let state = try XCTUnwrap(center.conversation)
        await reader.loseNextSend()
        await center.chooseOption(1, in: "question")
        let pending = try XCTUnwrap(state.optionReply.pending)
        for changed in [#"{"option_picker":{"options":["Keep it","Publish it"],"selected":0}}"#,
                        #"{"option_picker":{"options":["Keep it","Publish a revision"]}}"#] {
            var edited = question
            edited.metadata = try value(changed)
            await reader.setMessages([edited])
            await center.retryOptionReply()
            XCTAssertEqual(state.optionReply.pending, pending, "The waiting answer and its request stay")
            XCTAssertEqual(state.optionReply.problem, .changed)
        }
        await reader.setMessages([PersonalAgentMessage(id: "question", author: .agent, text: "", createdAt: nil,
                                                       isDeleted: true, attachments: [])])
        await center.retryOptionReply()
        XCTAssertEqual(state.optionReply.problem, .changed)
        var sends = await reader.sends
        XCTAssertEqual(sends.count, 1, "A changed, answered or deleted question is never answered again")

        // An answer that arrived though its reply was lost is settled by the read before any resend.
        await reader.setMessages([question])
        await center.refreshConversation()
        state.optionReply.discard(requestID: pending.requestID)
        await reader.loseNextSendAfterArrival()
        await center.chooseOption(0, in: "question")
        let arrived = try XCTUnwrap(state.optionReply.pending)
        await center.retryOptionReply()
        XCTAssertNil(state.optionReply.pending)
        sends = await reader.sends
        XCTAssertEqual(sends.map(\.requestID), [pending.requestID, arrived.requestID])
        await center.disconnect()

        // An answer that cannot be saved is not sent, and saving again, which sends nothing, lets the
        // question take one.
        let folder = FileManager.default.temporaryDirectory.appending(path: "option-answers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let stored = PersonalAgentCenter(drafts: PersonalAgentDrafts(directory: folder))
        let storedReader = InputRequestReader(messages: [question])
        await stored.connect(sourceKey: "home") { storedReader }
        let storedState = try XCTUnwrap(stored.conversation)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        await stored.chooseOption(0, in: "question")
        XCTAssertTrue(storedState.optionReply.storageFailed)
        XCTAssertNil(storedState.optionReply.pending)
        await stored.chooseOption(0, in: "question")
        var storedSends = await storedReader.sends
        XCTAssertTrue(storedSends.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        XCTAssertTrue(storedState.optionReply.retrySave())
        storedSends = await storedReader.sends
        XCTAssertTrue(storedSends.isEmpty, "Saving again sends nothing")
        await stored.chooseOption(0, in: "question")
        storedSends = await storedReader.sends
        XCTAssertEqual(storedSends.map(\.text), ["Keep it"])
        await stored.disconnect()
    }

    // MARK: - Fixtures

    private func value(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private func params(mode: String = "form", message: String = "Check this", schema: String = #"{"type":"object","properties":{},"required":[]}"#,
                        meta: String = "null", server: String = "example_service") throws -> JSONValue {
        try value(#"{"threadId":"thread","turnId":"turn","serverName":"\#(server)","mode":"\#(mode)","message":"\#(message)","requestedSchema":\#(schema),"_meta":\#(meta)}"#)
    }

    private func sites(_ tool: String, _ summary: String) throws -> JSONValue {
        let toolParams: JSONValue = .object(["confirmation_summary": .string(summary), "plan_token": .string("plan")])
        guard case var .object(meta) = try value(#"{"codex_approval_kind":"mcp_tool_call","connector_id":"\#(DotsSitesDatabaseApproval.connectorID)","tool_name":"\#(tool)","persist":"always"}"#),
              case var .object(object) = try params(server: "codex_apps") else { throw PersonalAgentFailure.invalidResponse }
        meta["tool_params"] = toolParams
        object["_meta"] = .object(meta)
        return .object(object)
    }

    private func kind(_ params: JSONValue) throws -> DotsInputRequest.Kind {
        try XCTUnwrap(DotsInputRequest(request(params))).kind
    }

    private func request(_ params: JSONValue) throws -> JSONValue {
        .object(["request_id": .string("request"), "thread_id": .string("thread"), "turn_id": .string("turn"),
                 "status": .string("pending"), "params": params])
    }

    private func toolRequest() throws -> JSONValue {
        try request(params(message: "Send the prepared item",
            meta: #"{"codex_approval_kind":"mcp_tool_call","connector_id":"connector_example","tool_name":"send_item","tool_params":{"item":"example"}}"#))
    }

    private func message(_ id: String, _ request: JSONValue) -> PersonalAgentMessage {
        var message = PersonalAgentMessage(id: id, author: .agent, text: "", createdAt: nil, isDeleted: false, attachments: [])
        message.inputRequest = request
        return message
    }

    private func answerable(_ center: PersonalAgentCenter, _ id: String) async throws -> PersonalAgentInputRequest {
        let item = try XCTUnwrap(center.conversation?.requests[id])
        try await waitUntil { item.phase == .answerable }
        return item
    }

    private func approval(_ item: PersonalAgentInputRequest) throws -> DotsApproval {
        guard case let .approval(approval) = item.request.kind else { throw PersonalAgentFailure.invalidResponse }
        return approval
    }

    private func deny(_ item: PersonalAgentInputRequest) -> DotsInputResult { (try? approval(item))?.deny ?? .decline }
}

/// One dot whose messages carry input requests; inspections answer from the message unless told
/// otherwise, and answers are recorded, never applied anywhere.
private actor InputRequestReader: PersonalAgentClient {
    struct Answer { let result: DotsInputResult; let fingerprint: String; let messageID: String }
    let agent: PersonalAgent
    /// A second dot of the same account, with no messages.
    let other: PersonalAgent
    private var history: [PersonalAgentMessage]
    private var holdsInspect = false
    private var heldInspect: CheckedContinuation<Void, Never>?
    private var holdsAnswer = false
    private var heldAnswer: CheckedContinuation<Void, Never>?
    private var sendArrivesButIsLost = false
    private var overrides: [String: (params: JSONValue?, status: String, fingerprint: String?)] = [:]
    private var nextFailure: DotsResponseFailure?
    private var readsFail = false
    private var losesSend = false
    private(set) var answers: [Answer] = []
    private(set) var sends: [PersonalAgentSubmission] = []

    init(messages: [PersonalAgentMessage], account: String = "account") {
        history = messages
        agent = .init(id: .init(accountID: account, userID: "person", agentID: "dot", roomID: "room"),
                      name: "Atlas", rootThreadID: nil, isPaused: false, isPrimary: true)
        other = .init(id: .init(accountID: account, userID: "person", agentID: "dot-2", roomID: "room-2"),
                      name: "Juniper", rootThreadID: nil, isPaused: false, isPrimary: false)
    }

    private var inspectFailure: PersonalAgentFailure?
    func failInspect(_ failure: PersonalAgentFailure) { inspectFailure = failure }
    func holdNextInspect() { holdsInspect = true }
    func hasHeldInspect() -> Bool { heldInspect != nil }
    func releaseInspect() { heldInspect?.resume(); heldInspect = nil }
    func holdNextAnswer() { holdsAnswer = true }
    func hasHeldAnswer() -> Bool { heldAnswer != nil }
    func releaseAnswer() { heldAnswer?.resume(); heldAnswer = nil }
    /// The next send reaches the room but its reply is lost.
    func loseNextSendAfterArrival() { sendArrivesButIsLost = true }

    func inspect(_ id: String, params: JSONValue? = nil, status: String = "pending", fingerprint: String? = "fingerprint") {
        overrides[id] = (params, status, fingerprint)
    }
    func failNextAnswer(_ failure: DotsResponseFailure) { nextFailure = failure }
    func failReads(_ value: Bool) { readsFail = value }
    func loseNextSend() { losesSend = true }
    func setMessages(_ messages: [PersonalAgentMessage]) { history = messages }

    func agents() async throws -> [PersonalAgent] { [agent, other] }
    func messages(for agent: PersonalAgent, before: String?) async throws -> PersonalAgentPage {
        if readsFail { throw PersonalAgentFailure.network }
        return .init(messages: agent.id == self.agent.id ? history : [], before: nil)
    }
    func updates(for agent: PersonalAgent) async -> AsyncStream<PersonalAgentUpdate> { AsyncStream { $0.finish() } }
    func send(_ submission: PersonalAgentSubmission, to agent: PersonalAgent) async throws -> PersonalAgentMessage {
        sends.append(submission)
        if losesSend { losesSend = false; throw PersonalAgentFailure.deliveryUnknown }
        var message = PersonalAgentMessage(id: "sent-" + submission.requestID, author: .person, text: submission.text,
                                           createdAt: nil, isDeleted: false, attachments: [], requestID: submission.requestID)
        message.replyToMessageID = submission.replyToMessageID
        message.metadata = submission.optionSelection.map { .object(["option_picker": .object(["selection": .integer(Int64($0))])]) }
        history.append(message)
        if sendArrivesButIsLost { sendArrivesButIsLost = false; throw PersonalAgentFailure.deliveryUnknown }
        return message
    }
    func inspectRequest(in messageID: String, for agent: PersonalAgent) async throws -> DotsRequestInspection {
        if holdsInspect { holdsInspect = false; await withCheckedContinuation { heldInspect = $0 } }
        if let inspectFailure { throw inspectFailure }
        guard case var .object(request)? = history.first(where: { $0.id == messageID })?.inputRequest else {
            throw PersonalAgentFailure.invalidResponse
        }
        let override = overrides[messageID]
        if let params = override?.params { request["params"] = params }
        var value: [String: JSONValue] = ["elicitation": .object(request), "can_respond": .bool(override?.status ?? "pending" == "pending"),
                                          "runtime_status": .string(override?.status ?? "pending")]
        if let fingerprint = override == nil ? "fingerprint" : override!.fingerprint { value["request_fingerprint"] = .string(fingerprint) }
        return try DotsRequestInspection(.object(value))
    }
    func respond(_ result: DotsInputResult, fingerprint: String, in messageID: String,
                 for agent: PersonalAgent) async throws -> DotsResponseOutcome {
        if holdsAnswer { holdsAnswer = false; await withCheckedContinuation { heldAnswer = $0 } }
        defer { nextFailure = nil }
        if case .notDispatched? = nextFailure { throw nextFailure! }
        answers.append(.init(result: result, fingerprint: fingerprint, messageID: messageID))
        if let nextFailure { throw nextFailure }
        return .applied
    }
    func upload(_ file: PersonalAgentPreparedFile, to agent: PersonalAgent) async throws -> PersonalAgentUploadedFile {
        throw PersonalAgentFailure.uploadFailed
    }
    func download(_ attachment: PersonalAgentAttachment, for agent: PersonalAgent) async throws -> PersonalAgentDownload {
        throw PersonalAgentFailure.attachmentUnavailable
    }
    func avatar(for agent: PersonalAgent) async throws -> Data { throw PersonalAgentFailure.attachmentUnavailable }
    func pet(_ id: String, for agent: PersonalAgent) async throws -> PersonalAgentPet? { nil }
    func spriteSheet(_ pet: PersonalAgentPet, for agent: PersonalAgent) async throws -> Data { Data() }
    func activity(for agent: PersonalAgent, cursor: String?) async throws -> PersonalAgentActivityPage { .init(items: [], cursor: nil) }
    func schedules(for agent: PersonalAgent) async throws -> [PersonalAgentSchedule] { [] }
    func computers(for agent: PersonalAgent) async throws -> [PersonalAgentComputer] { [] }
    // These renders open no Activity task.
    func activityThread(_ threadID: String, for agent: PersonalAgent) async throws -> CodexThreadState {
        throw PersonalAgentFailure.accessDenied
    }
    func activityTurns(_ threadID: String, cursor: String?, for agent: PersonalAgent) async throws -> CodexTurnPage {
        throw PersonalAgentFailure.accessDenied
    }
    func activityItems(_ threadID: String, turnID: String, cursor: String?,
                       for agent: PersonalAgent) async throws -> CodexItemPage {
        throw PersonalAgentFailure.accessDenied
    }
    func stop() {}
}
