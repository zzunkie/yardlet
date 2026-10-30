import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Codex command approvals offer the decisions the runtime listed (`availableDecisions`) with
/// their exact command and host rules, and an MCP elicitation form is filled in and checked
/// before its `content` is sent; an MCP request Yardlet cannot fill in is only declined or
/// cancelled (audit F03, F04 of 2026-10-22, Codex 0.163 schema).
@MainActor
final class CodexRequestFormRestorationTests: XCTestCase {
    static let commandMethod = "item/commandExecution/requestApproval"
    static let mcpMethod = "mcpServer/elicitation/request"

    static func state(_ kind: CodexServerRequestKind, method: String, params: JSONValue,
                      id: String = "s:1", resolution: CodexServerRequestResolution = .pending) -> CodexServerRequestState {
        CodexServerRequestState(id: id, method: method, kind: kind, threadID: "thread", turnID: "turn",
                                itemID: "item", params: params, resolution: resolution)
    }

    static func command(_ decisions: [JSONValue]?) -> ConversationRequest {
        var params: [String: JSONValue] = ["threadId": .string("thread"), "turnId": .string("turn"),
                                           "itemId": .string("item"), "command": .string("git status")]
        if let decisions { params["availableDecisions"] = .array(decisions) }
        return CodexRequestResponseProjection.request(state(.commandExecutionApproval, method: commandMethod,
                                                            params: .object(params)))
    }

    static func mcp(_ params: [String: JSONValue]) -> ConversationRequest {
        var params = params
        params["threadId"] = .string("thread")
        params["serverName"] = .string("fixture")
        return CodexRequestResponseProjection.request(state(.mcpElicitation, method: mcpMethod, params: .object(params)))
    }

    static func form(_ properties: [String: JSONValue], required: [String] = [], message: String = "Book a trip",
                     mode: String = "form") -> ConversationRequest {
        mcp(["mode": .string(mode), "message": .string(message),
             "requestedSchema": .object(["type": .string("object"), "properties": .object(properties),
                                         "required": .array(required.map(JSONValue.string))])])
    }

    static func decisions(_ request: ConversationRequest) -> [JSONValue?] {
        request.responses.map { response in
            guard case let .codex(value) = response.route else { return nil }
            return value.result(for: commandMethod)?["decision"]
        }
    }

    static let execpolicy: JSONValue = .object(["acceptWithExecpolicyAmendment": .object([
        "execpolicy_amendment": .array([.string("git"), .string("status")])])])
    static func network(_ host: String, _ action: String) -> JSONValue {
        .object(["applyNetworkPolicyAmendment": .object([
            "network_policy_amendment": .object(["host": .string(host), "action": .string(action)])])])
    }

    // MARK: - F03 command decisions

    func testACommandApprovalOffersOnlyTheDecisionsTheRuntimeListed() {
        let request = Self.command([.string("accept"), .string("decline")])
        XCTAssertEqual(Self.decisions(request), [.string("decline"), .string("accept")])
        XCTAssertEqual(request.responses.map(\.title), [L10n.string("Deny"), L10n.string("Allow")])
        XCTAssertEqual(request.responses.map(\.role), [.destructive, .primary])
        // A notification's "Allow once" is one of the card's answers, so it follows the list too.
        let declineOnly = Self.state(.commandExecutionApproval, method: Self.commandMethod, params: .object([
            "command": .string("rm -rf build"), "availableDecisions": .array([.string("decline"), .string("cancel")])]))
        XCTAssertNil(NotificationApprovalProjection.allowOnce(for: declineOnly))
        let declined = CodexRequestResponseProjection.request(declineOnly)
        XCTAssertEqual(Self.decisions(declined), [.string("decline"), .string("cancel")])
        XCTAssertEqual(declined.responses.map(\.title), [L10n.string("Deny"), L10n.string("Deny and stop")])
    }

    func testCommandAndHostRulesAreSentWithTheExactScopeTheyWereOffered() throws {
        let request = Self.command([.string("accept"), Self.execpolicy, .string("acceptForSession"),
                                    Self.network("api.example.com", "allow"), Self.network("ads.example.com", "deny"),
                                    .string("cancel")])
        XCTAssertEqual(Self.decisions(request), [
            Self.network("ads.example.com", "deny"), .string("cancel"),
            .string("acceptForSession"), Self.execpolicy, Self.network("api.example.com", "allow"),
            .string("accept")
        ])
        XCTAssertEqual(request.responses.map(\.title), [
            L10n.format("Always block %@", "ads.example.com"), L10n.string("Deny and stop"),
            L10n.string("Allow for session"), L10n.format("Always allow commands starting with “%@”", "git status"),
            L10n.format("Always allow %@", "api.example.com"), L10n.string("Allow")
        ])
        XCTAssertEqual(request.responses.map(\.role),
                       [.destructive, .destructive, .secondary, .secondary, .secondary, .primary])
        // Without a plain allow, the narrowest allow offered is the prominent one.
        let ruleOnly = Self.command([.string("decline"), Self.execpolicy])
        XCTAssertEqual(ruleOnly.responses.last?.role, .primary)
        XCTAssertEqual(Self.decisions(ruleOnly).last, Self.execpolicy)
        // The rule offered is sent, not `proposedExecpolicyAmendment` or a broader one.
        XCTAssertFalse(Self.decisions(ruleOnly).contains(.string("acceptForSession")))
    }

    func testACommandWithoutAListKeepsTheCompatibleDecisionsAndAnUnknownListFailsClosed() {
        let legacy = Self.command(nil)
        XCTAssertEqual(Self.decisions(legacy), [.string("decline"), .string("acceptForSession"), .string("accept")])
        let unknown = Self.command([.string("acceptForever"), .object(["acceptWithExecpolicyAmendment": .object([:])]),
                                    Self.network("", "allow")])
        XCTAssertTrue(unknown.responses.isEmpty)
        XCTAssertNotNil(unknown.unanswerableReason)
        // A sent list offers only what it lists: empty, or not a list, offers nothing.
        XCTAssertTrue(Self.command([]).responses.isEmpty)
        for malformed: JSONValue in [.string("accept"), .object(["accept": .bool(true)]), .integer(1), .bool(true)] {
            let request = CodexRequestResponseProjection.request(Self.state(
                .commandExecutionApproval, method: Self.commandMethod,
                params: .object(["command": .string("git status"), "availableDecisions": malformed])))
            XCTAssertTrue(request.responses.isEmpty, "\(malformed)")
            XCTAssertNotNil(request.unanswerableReason)
            XCTAssertNil(NotificationApprovalProjection.allowOnce(for: Self.state(
                .commandExecutionApproval, method: Self.commandMethod,
                params: .object(["availableDecisions": malformed]))))
        }
        // An explicit null is no list: the compatible decisions stay.
        let null = CodexRequestResponseProjection.request(Self.state(
            .commandExecutionApproval, method: Self.commandMethod,
            params: .object(["command": .string("git status"), "availableDecisions": .null])))
        XCTAssertEqual(Self.decisions(null), [.string("decline"), .string("acceptForSession"), .string("accept")])
    }

    // MARK: - F04 MCP forms

    func testARequiredMCPFieldHasAnInputAndSubmitWaitsForIt() throws {
        let request = Self.form(["destination": .object(["type": .string("string"), "title": .string("Destination")])],
                                required: ["destination"])
        guard case let .mcpForm(form)? = request.form else { return XCTFail("no form: \(String(describing: request.form))") }
        XCTAssertEqual(form.fields.map(\.id), ["destination"])
        XCTAssertEqual(request.responses.map(\.title),
                       [L10n.string("Decline"), L10n.string("Cancel"), L10n.string("Submit")])
        let submit = try XCTUnwrap(request.responses.last)
        // No empty Accept: nothing is sent while the required field is empty or blank.
        XCTAssertNil(request.route(for: submit, input: .init()))
        var input = ConversationRequestFormInput()
        input.fields["destination"] = .text("   ")
        XCTAssertNil(request.route(for: submit, input: input))
        input.fields["destination"] = .text("Busan")
        let route = try XCTUnwrap(request.route(for: submit, input: input))
        guard case let .codex(response) = route else { return XCTFail("\(route)") }
        XCTAssertEqual(response.result(for: Self.mcpMethod),
                       .object(["action": .string("accept"), "content": .object(["destination": .string("Busan")])]))
        // Decline and Cancel carry no content.
        XCTAssertEqual(request.responses.first?.route, .codex(.mcpElicitation(action: .decline)))
        XCTAssertEqual(request.responses[1].route, .codex(.mcpElicitation(action: .cancel)))
        XCTAssertFalse(request.offeredResponses(canChooseOption: false, canAnswer: false).isEmpty)
        XCTAssertEqual(request.offeredResponses(canChooseOption: false, canAnswer: false), request.responses)
    }

    static let everyKind: [String: JSONValue] = [
        "name": .object(["type": .string("string"), "minLength": .integer(2), "maxLength": .integer(5)]),
        "email": .object(["type": .string("string"), "format": .string("email")]),
        "site": .object(["type": .string("string"), "format": .string("uri")]),
        "day": .object(["type": .string("string"), "format": .string("date")]),
        "at": .object(["type": .string("string"), "format": .string("date-time")]),
        "ratio": .object(["type": .string("number"), "minimum": .number(0), "maximum": .number(1.5)]),
        "count": .object(["type": .string("integer"), "minimum": .integer(1), "maximum": .integer(10),
                          "default": .integer(3)]),
        "notify": .object(["type": .string("boolean"), "default": .bool(true)]),
        "seat": .object(["type": .string("string"), "enum": .array([.string("w"), .string("a")]),
                         "enumNames": .array([.string("Window"), .string("Aisle")])]),
        "class": .object(["type": .string("string"), "oneOf": .array([
            .object(["const": .string("eco"), "title": .string("Economy")]),
            .object(["const": .string("biz"), "title": .string("Business")])])]),
        "meals": .object(["type": .string("array"), "minItems": .integer(1), "maxItems": .integer(2),
                          "items": .object(["type": .string("string"),
                                            "enum": .array([.string("veg"), .string("fish"), .string("meat")])])]),
        "extras": .object(["type": .string("array"), "items": .object(["anyOf": .array([
            .object(["const": .string("bag"), "title": .string("Checked bag")]),
            .object(["const": .string("wifi"), "title": .string("Wi-Fi")])])])])
    ]

    static var everyKindRequest: ConversationRequest {
        form(everyKind, required: ["name", "count", "seat", "meals", "notify"])
    }

    static var filled: ConversationRequestFormInput {
        var input = ConversationRequestFormInput()
        input.fields = [
            "name": .text("Kim"), "email": .text("kim@example.com"), "site": .text("https://example.com/a"),
            "day": .text("2026-10-23"), "at": .text("2026-10-23T09:30:00+09:00"), "ratio": .text("0.75"),
            "seat": .picked(["w"]), "class": .picked(["biz"]), "meals": .picked(["fish", "veg"]),
            "extras": .picked(["wifi"])
        ]
        return input
    }

    func testEverySupportedFieldIsSentWithItsSchemasType() throws {
        let request = Self.everyKindRequest
        guard case let .mcpForm(form)? = request.form else { return XCTFail("no form") }
        // Required fields in `required`'s order, then the rest by name.
        XCTAssertEqual(form.fields.map(\.id), ["name", "count", "seat", "meals", "notify",
                                               "at", "class", "day", "email", "extras", "ratio", "site"])
        let submit = try XCTUnwrap(request.responses.last)
        let route = try XCTUnwrap(request.route(for: submit, input: Self.filled))
        guard case let .codex(response) = route else { return XCTFail("\(route)") }
        XCTAssertEqual(response.result(for: Self.mcpMethod)?["content"], .object([
            "name": .string("Kim"), "email": .string("kim@example.com"), "site": .string("https://example.com/a"),
            "day": .string("2026-10-23"), "at": .string("2026-10-23T09:30:00+09:00"), "ratio": .number(0.75),
            "count": .integer(3), "notify": .bool(true), "seat": .string("w"), "class": .string("biz"),
            "meals": .array([.string("veg"), .string("fish")]), "extras": .array([.string("wifi")])
        ]))
        // Optional fields left empty stay out; a required boolean is sent as shown.
        var minimal = ConversationRequestFormInput()
        minimal.fields = ["name": .text("Lee"), "seat": .picked(["a"]), "meals": .picked(["meat"]), "notify": .flag(false)]
        guard case let .codex(sparse)? = request.route(for: submit, input: minimal) else { return XCTFail() }
        XCTAssertEqual(sparse.result(for: Self.mcpMethod)?["content"], .object([
            "name": .string("Lee"), "count": .integer(3), "seat": .string("a"),
            "meals": .array([.string("meat")]), "notify": .bool(false)]))
    }

    func testEachLimitKeepsSubmitOffAndSaysWhy() throws {
        let request = Self.everyKindRequest
        guard case let .mcpForm(form)? = request.form else { return XCTFail("no form") }
        func issue(_ field: String, _ value: CodexMCPElicitationFieldValue) -> CodexMCPElicitationForm.Issue? {
            var input = Self.filled
            input.fields[field] = value
            let found = form.issue(of: try! XCTUnwrap(form.fields.first { $0.id == field }), in: input.fields)
            if found != nil {
                XCTAssertNil(request.route(for: request.responses.last!, input: input), "\(field) \(value)")
            }
            return found
        }
        XCTAssertEqual(issue("name", .text("K")), .tooShort(2))
        XCTAssertEqual(issue("name", .text("Kimberly")), .tooLong(5))
        XCTAssertEqual(issue("name", .text("가나")), nil)
        XCTAssertEqual(issue("email", .text("kim@")), .format(.email))
        XCTAssertEqual(issue("site", .text("example.com")), .format(.uri))
        XCTAssertEqual(issue("site", .text("https://exa mple.com")), .format(.uri))
        XCTAssertEqual(issue("day", .text("2026-02-30")), .format(.date))
        XCTAssertEqual(issue("day", .text("2026/10/23")), .format(.date))
        XCTAssertEqual(issue("at", .text("2026-10-23T09:30:00")), .format(.dateTime))
        XCTAssertEqual(issue("at", .text("2026-10-23T09:30:00.250Z")), nil)
        for notFinite in ["inf", "nan", "Infinity", "0x10", "1e999", "1,5", ""] where !notFinite.isEmpty {
            XCTAssertEqual(issue("ratio", .text(notFinite)), .notANumber, notFinite)
        }
        XCTAssertEqual(issue("ratio", .text("-0.1")), .belowMinimum(0))
        XCTAssertEqual(issue("ratio", .text("1.6")), .aboveMaximum(1.5))
        XCTAssertEqual(issue("ratio", .text(" 1.5 ")), nil)
        XCTAssertEqual(issue("count", .text("3.5")), .notAnInteger)
        XCTAssertEqual(issue("count", .text("99999999999999999999")), .notANumber)
        XCTAssertEqual(issue("count", .text("0")), .belowMinimum(1))
        XCTAssertEqual(issue("count", .text("11")), .aboveMaximum(10))
        XCTAssertEqual(issue("count", .text("")), .missing)
        XCTAssertEqual(issue("seat", .picked([])), .missing)
        XCTAssertEqual(issue("seat", .picked(["x"])), .unknownChoice)
        XCTAssertEqual(issue("meals", .picked(["veg", "fish", "meat"])), .tooManyChoices(2))
        XCTAssertEqual(issue("meals", .picked([])), .missing)
        XCTAssertEqual(issue("extras", .picked(["lounge"])), .unknownChoice)
        XCTAssertEqual(issue("extras", .picked([])), nil)
    }

    /// `required` asks for presence: an empty string or list the schema allows (`default` `""` or
    /// `[]`, `minItems` 0) is an answer, while nothing entered yet is not; and the card limits an
    /// answer no further than the schema does.
    func testAnEmptyValueTheSchemaAllowsIsAnAnswerAndNothingEnteredIsNot() throws {
        let request = Self.form([
            "note": .object(["type": .string("string"), "default": .string("")]),
            "tags": .object(["type": .string("array"), "default": .array([]),
                             "items": .object(["type": .string("string"), "enum": .array([.string("a")])])]),
            "flags": .object(["type": .string("array"), "minItems": .integer(0),
                              "items": .object(["type": .string("string"), "enum": .array([.string("x")])])]),
            "name": .object(["type": .string("string")]),
            "picks": .object(["type": .string("array"),
                              "items": .object(["type": .string("string"), "enum": .array([.string("p")])])])
        ], required: ["note", "tags", "flags", "name", "picks"])
        let submit = try XCTUnwrap(request.responses.last)
        var input = ConversationRequestFormInput()
        input.fields = ["name": .text("Kim"), "picks": .picked(["p"])]
        // "flags" was never touched and has no default: required, so not yet answered.
        XCTAssertNil(request.route(for: submit, input: input))
        input.fields["flags"] = .picked([])
        guard case let .codex(response)? = request.route(for: submit, input: input) else { return XCTFail() }
        XCTAssertEqual(response.result(for: Self.mcpMethod)?["content"], .object([
            "note": .string(""), "tags": .array([]), "flags": .array([]),
            "name": .string("Kim"), "picks": .array([.string("p")])]))
        // Without a schema that allows it, an emptied field is no answer.
        input.fields["name"] = .text("")
        XCTAssertNil(request.route(for: submit, input: input))
        input.fields["name"] = .text("Kim")
        input.fields["picks"] = .picked([])
        XCTAssertNil(request.route(for: submit, input: input))
    }

    func testAnImpossibleDateTimeIsNotRolledOver() throws {
        let request = Self.form(["at": .object(["type": .string("string"), "format": .string("date-time")])],
                                required: ["at"])
        guard case let .mcpForm(form)? = request.form, let field = form.fields.first else { return XCTFail() }
        for impossible in ["2026-02-30T12:00:00Z", "2026-13-01T12:00:00Z", "2026-10-23T24:00:00Z",
                           "2026-10-23T12:60:00Z", "2026-10-23T12:00:60Z", "2026-10-23T12:00:00+24:00"] {
            XCTAssertEqual(form.issue(of: field, in: ["at": .text(impossible)]), .format(.dateTime), impossible)
        }
        for valid in ["2028-02-29T23:59:59Z", "2026-10-23t09:30:00.5-07:30"] {
            XCTAssertNil(form.issue(of: field, in: ["at": .text(valid)]), valid)
        }
    }

    func testAFormYardletCannotFillInOrAnotherModeIsOnlyDeclinedOrCancelled() {
        let unsupported: [(String, ConversationRequest)] = [
            ("pattern", Self.form(["code": .object(["type": .string("string"), "pattern": .string("^[A-Z]+$")])])),
            ("format", Self.form(["code": .object(["type": .string("string"), "format": .string("ipv4")])])),
            ("nested", Self.form(["where": .object(["type": .string("object"), "properties": .object([:])])])),
            ("infinite", Self.form(["n": .object(["type": .string("number"), "maximum": .string("inf")])])),
            ("range", Self.form(["n": .object(["type": .string("integer"), "minimum": .integer(5), "maximum": .integer(1)])])),
            ("required", Self.form(["a": .object(["type": .string("string")])], required: ["b"])),
            ("duplicate", Self.form(["c": .object(["type": .string("string"), "enum": .array([.string("x"), .string("x")])])])),
            ("open schema", Self.mcp(["mode": .string("openai/form"), "message": .string("Anything"),
                                      "requestedSchema": .bool(true)])),
            ("url", Self.mcp(["mode": .string("url"), "message": .string("Sign in"), "elicitationId": .string("e"),
                              "url": .string("https://auth.example.com/start")])),
            ("device", Self.mcp(["mode": .string("openai/userVerification"), "title": .string("Verify"),
                                 "description": .string("Confirm"), "challenge": .string("abc")])),
            ("unknown mode", Self.mcp(["mode": .string("openai/somethingNew"), "message": .string("?")]))
        ]
        for (name, request) in unsupported {
            XCTAssertNil(request.form, name)
            XCTAssertEqual(request.responses.map(\.route), [.codex(.mcpElicitation(action: .decline)),
                                                           .codex(.mcpElicitation(action: .cancel))], name)
            XCTAssertNotNil(request.detail, name)
            XCTAssertFalse(request.responses.contains { response in
                guard case let .codex(value) = response.route else { return true }
                return value.result(for: Self.mcpMethod)?["action"] == .string("accept")
            }, name)
        }
        XCTAssertEqual(unsupported[0].1.detail,
                       L10n.format("Yardlet can't fill in the field “%@” of this MCP form. Decline or cancel it.", "code"))
        // The phone denies it without the form; it never accepts it.
        XCTAssertEqual(RemoteApprovalPolicy.answers(for: unsupported[8].1), [.deny])
    }

    func testAFormWithoutFieldsAndTheOpenAIModesAreAnsweredWithTheirContent() throws {
        let confirm = Self.form([:], message: "Continue?")
        XCTAssertNil(confirm.form)
        XCTAssertEqual(confirm.responses.last?.route, .codex(.mcpElicitation(action: .accept, content: .object([:]))))
        for mode in ["openai/form", "openaiForm"] {
            let request = Self.form(["ok": .object(["type": .string("boolean")])], mode: mode)
            guard case .mcpForm? = request.form else { return XCTFail(mode) }
            guard case let .codex(response)? = request.route(for: request.responses.last!, input: .init()) else {
                return XCTFail(mode)
            }
            XCTAssertEqual(response.result(for: Self.mcpMethod)?["content"], .object(["ok": .bool(false)]), mode)
        }
    }

    func testAnMCPToolApprovalKeepsItsPersistAnswers() {
        let computerUse = CodexToolApprovalRenderingTests.request(connector: "computer-use", persist: ["session", "always"])
        XCTAssertNil(computerUse.form)
        XCTAssertNil(computerUse.detail)
        XCTAssertEqual(computerUse.responses.map(\.route), [
            .codex(.mcpElicitation(action: .decline)),
            .codex(.mcpElicitation(action: .accept, content: .object([:]), meta: .object(["persist": .string("always")]))),
            .codex(.mcpElicitation(action: .accept, content: .object([:]), meta: .object(["persist": .string("session")])))
        ])
    }

    // MARK: - YHP

    func testTypedAnswersCrossTheHarnessProtocolUnchanged() throws {
        let responses: [CodexServerRequestResponse] = [
            .command(.acceptWithExecpolicyAmendment(["git", "status"])),
            .command(.applyNetworkPolicyAmendment(host: "api.example.com", action: .allow)),
            .command(.applyNetworkPolicyAmendment(host: "ads.example.com", action: .deny)),
            .mcpElicitation(action: .accept, content: .object([
                "name": .string("Kim"), "count": .integer(3), "ratio": .number(0.75), "notify": .bool(true),
                "meals": .array([.string("veg")])]))
        ]
        let codec = HarnessProtocolPayloadCodec()
        for response in responses {
            let wire = CodexYHPProjection.serverResponse(response)
            let decoded = try codec.decode(HarnessProtocolCodexServerResponse.self, from: try codec.encode(wire))
            XCTAssertEqual(decoded, wire)
        }
    }

    func testTheBridgeSendsTheFormsContentAndTheOfferedRuleToCodex() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [.object(["thread": .object(["id": .string("codex-thread-1")])])]
        ])
        let adapter = CodexAdapter(executableURL: URL(filePath: "/tmp/fake-codex"), transport: transport)
        let bridge = LegacyHarnessProtocolBridge(adapter: adapter, manifest: HarnessProtocolCompatibilityManifest.codex())
        let localSessionID = UUID()
        _ = try await bridge.handle(HarnessProtocolRequest(
            id: "create", method: .sessionCreate,
            typedParams: HarnessProtocolCreateSessionParams(
                localSessionID: localSessionID,
                config: HarnessProtocolSessionConfig(workspacePath: "/tmp/codex-yhp-workspace", modelID: nil, modeID: nil,
                                                     featureValues: [:], extensionValues: [:]),
                initialPrompt: [])))

        let sends: [(Int64, String, JSONValue, CodexServerRequestResponse, JSONValue)] = [
            (91, Self.mcpMethod,
             .object(["threadId": .string("codex-thread-1"), "serverName": .string("fixture"), "mode": .string("form"),
                      "message": .string("Book"), "requestedSchema": .object([
                        "type": .string("object"), "required": .array([.string("count")]),
                        "properties": .object(["count": .object(["type": .string("integer")])])])]),
             .mcpElicitation(action: .accept, content: .object(["count": .integer(2)])),
             .object(["action": .string("accept"), "content": .object(["count": .integer(2)])])),
            (92, Self.commandMethod,
             .object(["threadId": .string("codex-thread-1"), "turnId": .string("t"), "itemId": .string("c"),
                      "command": .string("git status"), "availableDecisions": .array([.string("decline"), Self.execpolicy])]),
             .command(.acceptWithExecpolicyAmendment(["git", "status"])),
             .object(["decision": Self.execpolicy]))
        ]
        for (id, method, params, response, expected) in sends {
            await transport.emitServerRequest(id: .integer(id), method: method, params: params)
            let requestID = "i:\(id)"
            try await waitUntil {
                let read = try? await bridge.handle(HarnessProtocolRequest(
                    id: "read-\(id)", method: .codexPresentationRead,
                    typedParams: HarnessProtocolCodexPresentationReadParams(localSessionID: localSessionID, refresh: false)))
                guard let result = read?.result,
                      let snapshot = try? HarnessProtocolPayloadCodec().decode(
                        HarnessProtocolCodexPresentationSnapshot.self, from: result) else { return false }
                return snapshot.serverRequests.contains { $0.id == requestID && $0.resolution == "pending" }
            }
            let answer = try await bridge.handle(HarnessProtocolRequest(
                id: "respond-\(id)", method: .codexServerRequestRespond,
                typedParams: HarnessProtocolCodexServerRequestRespondParams(
                    localSessionID: localSessionID, requestID: requestID,
                    response: CodexYHPProjection.serverResponse(response))))
            XCTAssertNil(answer.error)
            let sent = await transport.sentResponses
            XCTAssertEqual(sent.last?.result, expected)
        }
    }


    // MARK: - Rendering and input

    static func card(_ request: ConversationRequest, input: ConversationRequestFormInput = .init(),
                     actions: ConversationActions = ConversationActions(),
                     appearance: WindowlessRender.Appearance, height: CGFloat) -> some View {
        ConversationRequestCard(request: request, actions: actions, input: input)
            .padding(20)
            .frame(width: 640)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 640, height: height, alignment: .top)
            .background(ParityTheme.canvas)
            .tint(Color.primary)
            .environment(\.controlActiveState, .key)
            .environment(\.colorScheme, appearance.colorScheme)
    }

    func testTheFormsAndRuleChoicesReadInBothAppearances() throws {
        let directory = try WindowlessRender.directory("codex-restore-forms-qa")
        var invalid = Self.filled
        invalid.fields["name"] = .text("K")
        invalid.fields["ratio"] = .text("inf")
        invalid.fields["email"] = .text("kim@")
        let renders: [(String, ConversationRequest, ConversationRequestFormInput, CGFloat)] = [
            ("mcp-form-empty", Self.everyKindRequest, .init(), 1500),
            ("mcp-form-filled", Self.everyKindRequest, Self.filled, 1500),
            ("mcp-form-invalid", Self.everyKindRequest, invalid, 1500),
            ("mcp-url-unsupported", Self.mcp(["mode": .string("url"), "message": .string("Sign in to Fixture"),
                                              "elicitationId": .string("e"), "url": .string("https://auth.example.com")]),
             .init(), 260),
            ("command-rules", Self.command([.string("accept"), Self.execpolicy, Self.network("api.example.com", "allow"),
                                            .string("decline")]), .init(), 300)
        ]
        for (name, request, input, height) in renders {
            let captures = try WindowlessRender.hostedInBothAppearances(name, in: directory,
                                                                        size: NSSize(width: 640, height: height)) {
                Self.card(request, input: input, appearance: $0, height: height)
            }
            XCTAssertEqual(captures.count, 2)
        }

        let host = WindowlessRender.Host(Self.card(Self.everyKindRequest, input: invalid, appearance: .light, height: 1500),
                                         size: NSSize(width: 640, height: 1500))
        defer { host.close() }
        host.settle()
        let elements = host.accessibilityElements()
        let labels = elements.map(\.label) + elements.map(\.value)
        for expected in ["name", "email", "Window", "Aisle", "Economy", "Checked bag", "Wi-Fi", "notify",
                         CodexMCPElicitationForm.Issue.tooShort(2).message, CodexMCPElicitationForm.Issue.notANumber.message,
                         CodexMCPElicitationForm.Issue.format(.email).message, L10n.string("Submit")] {
            XCTAssertTrue(labels.contains(expected), "missing \(expected) in \(labels)")
        }
    }

    static func answeredForm(_ resolution: CodexServerRequestResolution) -> ConversationRequest {
        CodexRequestResponseProjection.request(state(.mcpElicitation, method: mcpMethod, params: .object([
            "threadId": .string("thread"), "serverName": .string("fixture"), "mode": .string("form"),
            "message": .string("Book a trip"),
            "requestedSchema": .object(["type": .string("object"), "required": .array([.string("destination")]),
                "properties": .object([
                    "destination": .object(["type": .string("string"), "title": .string("Destination"),
                                            "default": .string("Seoul")]),
                    "travellers": .object(["type": .string("integer"), "title": .string("Travellers"),
                                           "default": .integer(4)]),
                    "meals": .object(["type": .string("array"), "title": .string("Meals"),
                                      "items": .object(["anyOf": .array([
                                        .object(["const": .string("veg"), "title": .string("Vegetarian")]),
                                        .object(["const": .string("fish"), "title": .string("Fish")])])])]),
                    "insurance": .object(["type": .string("boolean"), "title": .string("Insurance"),
                                          "default": .bool(true)])])])]),
            resolution: resolution))
    }

    /// An answered form reads as what was sent to Codex, from the recorded response, however the
    /// card is drawn again (a new view, a relaunch): never the schema's defaults or an empty field.
    func testAnAnsweredFormShowsTheContentItSentNotTheDefaults() throws {
        let accepted = Self.answeredForm(.resolved(.object(["action": .string("accept"), "content": .object([
            "destination": .string("Busan"), "travellers": .integer(2), "meals": .array([.string("fish")]),
            "insurance": .bool(false)])])))
        let declined = Self.answeredForm(.resolved(.object(["action": .string("decline")])))
        let rejected = Self.answeredForm(.rejected(code: -1, message: "Request expired"))
        let directory = try WindowlessRender.directory("codex-restore-forms-qa")
        for (name, request) in [("accepted", accepted), ("declined", declined), ("rejected", rejected)] {
            XCTAssertTrue(request.responses.isEmpty, name)
            XCTAssertEqual(request.state, name == "accepted" ? .answered
                           : name == "declined" ? .denied : .rejected(message: "Request expired"), name)
            try WindowlessRender.hostedInBothAppearances("mcp-form-answered-\(name)", in: directory,
                                                         size: NSSize(width: 640, height: 520)) {
                Self.card(request, appearance: $0, height: 520)
            }
            let host = WindowlessRender.Host(Self.card(request, appearance: .light, height: 520),
                                             size: NSSize(width: 640, height: 520))
            defer { host.close() }
            host.settle()
            let elements = host.accessibilityElements()
            let words = elements.map(\.label) + elements.map(\.value)
            XCTAssertTrue(Self.textFields(in: host.hosting).isEmpty, "\(name) still takes input")
            for shownAsSent in ["Seoul", "4"] {
                XCTAssertFalse(words.contains(shownAsSent), "\(name) shows the default \(shownAsSent): \(words)")
            }
            if name == "accepted" {
                for sent in ["Busan", "2", "Fish", L10n.string("No")] {
                    XCTAssertTrue(words.contains(sent), "missing sent \(sent) in \(words)")
                }
            } else {
                XCTAssertTrue(words.contains(L10n.string("Not answered")), "\(name): \(words)")
            }
        }
    }

    /// Typing into the card's fields and pressing its answers, as the person does: Submit stays off
    /// until the required field holds a valid value, then sends exactly that content.
    func testTypingInTheCardEnablesSubmitAndSendsTheTypedContent() throws {
        let request = Self.form([
            "count": .object(["type": .string("integer"), "title": .string("Travellers"), "minimum": .integer(1)]),
            "note": .object(["type": .string("string"), "title": .string("Note")])
        ], required: ["count"])
        final class Sent { var responses: [CodexServerRequestResponse] = [] }
        let sent = Sent()
        let actions = ConversationActions(respondToCodexRequest: { _, response in sent.responses.append(response) })
        let host = WindowlessRender.Host(Self.card(request, actions: actions, appearance: .light, height: 400),
                                         size: NSSize(width: 640, height: 400))
        defer { host.close() }
        host.settle()

        /// Whether the button took the press: a disabled one does not.
        @discardableResult
        func press(_ label: String) throws -> Bool {
            let button = try XCTUnwrap(Self.element(in: host.hosting, label: label, role: .button), label)
            let pressed = button.accessibilityPerformPress?() ?? false
            host.settle()
            return pressed
        }
        func type(_ text: String, into label: String) throws {
            let field = try XCTUnwrap(Self.textFields(in: host.hosting).first { $0.accessibilityLabel() == label
                || $0.placeholderString == label }, label)
            field.stringValue = text
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            host.settle()
        }

        XCTAssertFalse(try press(L10n.string("Submit")))
        XCTAssertTrue(sent.responses.isEmpty, "Submit sent before the required field was filled: \(sent.responses)")
        let fields = Self.textFields(in: host.hosting)
        XCTAssertEqual(fields.count, 2)
        try type("0", into: fields[0].accessibilityLabel() ?? "")
        XCTAssertFalse(try press(L10n.string("Submit")))
        XCTAssertTrue(sent.responses.isEmpty, "Submit sent below the minimum: \(sent.responses)")
        try type("2", into: fields[0].accessibilityLabel() ?? "")
        try type("Window seats", into: fields[1].accessibilityLabel() ?? "")
        XCTAssertTrue(try press(L10n.string("Submit")))
        XCTAssertEqual(sent.responses, [.mcpElicitation(action: .accept, content: .object([
            "count": .integer(2), "note": .string("Window seats")]))])
    }

    static func textFields(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { subview -> [NSTextField] in
            if let field = subview as? NSTextField, field.isEditable { return [field] }
            return textFields(in: subview)
        }
    }

    /// The accessibility element under `root` with `role` and `label`. SwiftUI builds its tree only
    /// for an assistive app (`AXEnhancedUserInterface`), which the search announces while it reads.
    static func element(in root: NSView, label: String, role: NSAccessibility.Role) -> AnyObject? {
        WindowlessRender.withAccessibilityTree {
            var queue: [AnyObject] = [root]
            var seen: Set<ObjectIdentifier> = []
            while !queue.isEmpty {
                let node = queue.removeFirst()
                guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
                if (node.accessibilityRole?() ?? nil) == role, (node.accessibilityLabel?() ?? nil) == label { return node }
                queue += ((node.accessibilityChildren?() ?? nil) ?? []) as [AnyObject]
            }
            return nil
        }
    }
}
