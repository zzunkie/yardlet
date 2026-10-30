import Foundation

/// An input request a dot's message carries (`content.elicitation`): the provider's own request,
/// kept as it was sent, and what Yardlet can do with it.
///
/// This is not the coding runtime's MCP request. Its identity is the message's request, thread and
/// optional turn, it is answered through the room message it came in, and the answer is bound to a
/// fingerprint read just before sending (`DotsService.respond`). The classification follows the
/// provider's own order of checks: a request is a form, an approval, or something Yardlet shows but
/// cannot answer. Nothing that needs setup, verification or a capability Yardlet lacks becomes an
/// approval, and no approval kind Yardlet does not know is answered as an empty form.
struct DotsInputRequest: Equatable, Sendable {
    let requestID: String
    let threadID: String
    let turnID: String?
    /// The status the message carries; the request's live status comes from its inspection.
    let status: String?
    let params: JSONValue
    let kind: Kind

    enum Kind: Equatable, Sendable {
        case form(CodexMCPElicitationForm, variant: FormVariant)
        case approval(DotsApproval)
        case unsupported(DotsUnsupportedRequest)
    }

    /// Which mode named the form. The OpenAI forms are taken only where their schema is the strict
    /// subset the ordinary form validator reads, with no extensions or confirmation.
    enum FormVariant: Equatable, Sendable { case ordinary, openAIForm, legacyOpenAIForm }

    /// Whether the message's own status already closes the request.
    var isClosedByMessage: Bool { status == "resolved" || status == "expired" }

    /// The request in `value`, or nil when its identity is incomplete or inconsistent.
    init?(_ value: JSONValue) {
        guard let request = value["request_id"]?.stringValue, !request.trimmed.isEmpty,
              let thread = value["thread_id"]?.stringValue, !thread.trimmed.isEmpty,
              let params = value["params"], case .object = params else { return nil }
        let turn: String?
        switch value["turn_id"] {
        case nil, .null?: turn = nil
        case let .string(text)? where !text.trimmed.isEmpty: turn = text
        default: return nil
        }
        guard params["threadId"]?.stringValue == thread else { return nil }
        switch params["turnId"] {
        case nil, .null?: break
        case let .string(text)? where text == turn: break
        default: return nil
        }
        requestID = request
        threadID = thread
        turnID = turn
        status = value["status"]?.stringValue
        self.params = params
        kind = Self.classify(params)
    }

    /// The journal's identity for this request in a room, for an account and user.
    func key(accountID: String, userID: String, roomID: String) -> DotsResponseKey {
        .init(accountID: accountID, userID: userID, roomID: roomID, threadID: threadID, turnID: turnID, requestID: requestID)
    }

    // MARK: - Classification

    private static func classify(_ params: JSONValue) -> Kind {
        let meta = params["_meta"]
        let message = params["message"]?.stringValue
        let unrecognized = Kind.unsupported(.init(reason: .unrecognized, message: message))
        if meta?["openai/location"] != nil { return .unsupported(.init(reason: .location, message: message)) }
        let mode = params["mode"]?.stringValue
        let approvalKind: String? = if case let .string(kind)? = meta?["codex_approval_kind"] { kind } else { nil }
        if mode == "openai/userVerification" {
            return .unsupported(.init(reason: .userVerification, message: params["title"]?.stringValue,
                                      detail: params["description"]?.stringValue))
        }
        // A browser sign-in is read before any other mode, and only a form can be one.
        if approvalKind == "browser_auth" {
            return mode == nil || mode == "form" ? .unsupported(.init(reason: .browserSignIn, message: message)) : unrecognized
        }
        switch mode {
        case "url":
            return .unsupported(.init(reason: .link, message: message))
        case "openaiForm", "openai/form":
            // An approval kind is never answered as a plain form, in any form mode.
            if approvalKind != nil { return .unsupported(.init(reason: .unknownApproval, message: message)) }
            guard params["serverName"]?.stringValue != nil, message != nil,
                  meta?["openai/confirmation"] == nil, let schema = params["requestedSchema"],
                  case let .success(form) = CodexMCPElicitationForm.parse(schema) else {
                return .unsupported(.init(reason: .openAIForm, message: message))
            }
            return .form(form, variant: mode == "openaiForm" ? .openAIForm : .legacyOpenAIForm)
        case nil, "form":
            break
        default:
            return unrecognized
        }
        guard let text = message, params["serverName"]?.stringValue != nil,
              let schema = params["requestedSchema"], schema["type"]?.stringValue == "object",
              case let .object(properties)? = schema["properties"] else { return unrecognized }
        let isEmpty = properties.isEmpty && (schema["required"]?.arrayValue ?? []).isEmpty
        switch approvalKind {
        case "wallet_enrollment": return .unsupported(.init(reason: .wallet, message: message))
        case "tool_suggestion", "mcp_tool_call": if !isEmpty { return unrecognized }
        case "browser_email_otp": return .unsupported(.init(reason: .emailCode, message: message))
        default: break
        }
        let presentation = DotsApproval.Presentation(meta)
        let sites = DotsSitesDatabaseApproval.recognize(params)
        if let approval = DotsApproval.tool(params: params, message: text, sites: sites, presentation: presentation) {
            return .approval(approval)
        }
        switch approvalKind {
        case "tool_suggestion":
            return .unsupported(.init(reason: .toolSetup, message: meta?["tool_name"]?.stringValue ?? message,
                                      detail: meta?["suggest_reason"]?.stringValue))
        case "mcp_tool_call":
            // Metadata the tool-approval schema does not take is not downgraded to a plain approval.
            return .unsupported(.init(reason: .unknownApproval, message: message))
        case .some:
            return .unsupported(.init(reason: .unknownApproval, message: message))
        case nil:
            break
        }
        if let approval = DotsApproval.browser(params: params, message: text, isEmpty: isEmpty, presentation: presentation) {
            return .approval(approval)
        }
        if meta?["openai/elicitation"] != nil { return .unsupported(.init(reason: .openAIForm, message: message)) }
        if meta?["openai/confirmation"] != nil { return .unsupported(.init(reason: .form, message: message)) }
        if isEmpty {
            // An empty form is an approval only when it says what it asks.
            guard !text.trimmed.isEmpty else { return unrecognized }
            return .approval(.init(family: .generic, message: text, presentation: presentation))
        }
        switch CodexMCPElicitationForm.parse(schema) {
        case let .success(form): return .form(form, variant: .ordinary)
        case .failure: return .unsupported(.init(reason: .form, message: message))
        }
    }
}

/// A request Yardlet shows, with the provider's own words, but cannot answer: answering it needs a
/// setup, a verification or a capability that only the provider's own surfaces have.
struct DotsUnsupportedRequest: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case location, userVerification, link, openAIForm, form, wallet, browserSignIn, emailCode, toolSetup
        case unknownApproval, unrecognized
    }
    let reason: Reason
    var message: String?
    var detail: String?
}

/// An approval to allow or deny: a plain one, or a tool call a connector asks to make.
struct DotsApproval: Equatable, Sendable {
    enum Family: Equatable, Sendable { case generic, tool }
    enum Persist: String, Equatable, Sendable, CaseIterable { case session, always }

    struct Detail: Equatable, Sendable {
        let name: String
        let value: String
    }

    /// The provider's own presentation hints, which are not part of any answer.
    struct Presentation: Equatable, Sendable {
        var isHighRisk = false
        var subtitle: String?

        /// Both hints, or neither when either is malformed, as the provider reads them.
        init(_ meta: JSONValue? = nil) {
            let risk = meta?["riskLevel"], subtitle = meta?["subtitle"]
            guard [nil, .null, .string("low"), .string("high")].contains(risk),
                  subtitle == nil || subtitle == .null || subtitle?.stringValue != nil else { return }
            isHighRisk = risk == .string("high")
            self.subtitle = subtitle?.stringValue
        }
    }

    let family: Family
    let message: String
    var presentation = Presentation()
    /// The scopes an allow can be remembered for, only as the request offered them.
    var persist: [Persist] = []
    var connectorName: String?
    var toolName: String?
    var origin: String?
    var details: [Detail] = []
    /// The tool's complete parameters, for the person to read in full.
    var parameters: JSONValue?
    /// One operation that must be allowed alone, never remembered.
    var isExecutionBound = false
    /// Allowing is off: the request does not carry what allowing it would bind to.
    var approveDisabled = false

    /// Allowing, remembered for `persist` when one was offered; nil when allowing is not available.
    func allow(_ persist: Persist? = nil) -> DotsInputResult? {
        guard !approveDisabled else { return nil }
        if let persist {
            guard !isExecutionBound, self.persist.contains(persist) else { return nil }
        }
        return .init(action: .accept, content: .object([:]),
                     meta: persist.map { .object(["persist": .string($0.rawValue)]) } ?? .null)
    }

    /// Denying. A dot cancels a tool call the person denies, saying the person chose it, rather
    /// than declining it as a coding session does.
    var deny: DotsInputResult {
        switch family {
        case .generic: .init(action: .decline, content: .null, meta: .null)
        case .tool: .init(action: .cancel, content: .null,
                          meta: .object(["codex_approval_cancellation_reason": .string("user")]))
        }
    }

    /// Dismissing without deciding; a tool approval offers its full parameters instead.
    var cancel: DotsInputResult? {
        family == .generic ? .init(action: .cancel, content: .null, meta: .null) : nil
    }

    // MARK: Recognition

    static func tool(params: JSONValue, message: String, sites: DotsSitesDatabaseApproval.Recognition?,
                     presentation: Presentation) -> DotsApproval? {
        let meta = params["_meta"]
        guard let valid = toolMetadata(meta) else {
            // A recognized database change with metadata the schema does not take stays visible, not allowable.
            guard let sites else { return nil }
            return .init(family: .tool, message: message, presentation: presentation, toolName: sites.toolName,
                         details: sites.details, isExecutionBound: true, approveDisabled: true)
        }
        var approval = DotsApproval(family: .tool, message: message, presentation: presentation)
        approval.connectorName = meta?["connector_name"]?.stringValue ?? valid.connectorID
        approval.toolName = meta?["tool_title"]?.stringValue ?? meta?["tool_name"]?.stringValue
        approval.parameters = valid.parameters
        approval.details = displayList(meta?["tool_params_display"]) ?? valid.parameters.objectValue.map(details) ?? []
        if let sites {
            approval.isExecutionBound = true
            approval.approveDisabled = sites.summary == nil
            if sites.summary != nil {
                approval.details = sites.details
                approval.presentation.isHighRisk = true
            }
        } else {
            approval.persist = valid.persist
        }
        return approval
    }

    /// A browser approval the provider gives without a form: an origin and the scopes it can be kept for.
    static func browser(params: JSONValue, message: String, isEmpty: Bool, presentation: Presentation) -> DotsApproval? {
        let meta = params["_meta"]
        guard ["browser", "browser-use"].contains(params["serverName"]?.stringValue ?? ""), isEmpty,
              let persist = persistOffer(meta?["persist"]), !persist.isEmpty,
              let origin = meta?["origin"]?.stringValue, !origin.trimmed.isEmpty else { return nil }
        var approval = DotsApproval(family: .generic, message: message, presentation: presentation)
        approval.persist = persist
        approval.origin = origin
        approval.details = displayList(meta?["tool_params_display"]) ?? []
        return approval
    }

    private struct ToolMetadata { let connectorID: String; let parameters: JSONValue; let persist: [Persist] }

    /// The tool-approval metadata, all of whose named fields have the types the provider's schema gives them.
    private static func toolMetadata(_ meta: JSONValue?) -> ToolMetadata? {
        guard meta?["codex_approval_kind"]?.stringValue == "mcp_tool_call",
              let connector = meta?["connector_id"]?.stringValue,
              let parameters = meta?["tool_params"], case .object = parameters,
              let persist = persistOffer(meta?["persist"]) else { return nil }
        switch meta?["codex_request_type"] {
        case nil, .string("approval_request")?: break
        default: return nil
        }
        for name in ["connector_name", "tool_name", "tool_title"] {
            if let value = meta?[name], value.stringValue == nil { return nil }
        }
        return .init(connectorID: connector, parameters: parameters, persist: persist)
    }

    /// The offered scopes: absent, one scope, or a list of one or two. Nil when malformed.
    static func persistOffer(_ value: JSONValue?) -> [Persist]? {
        switch value {
        case nil: return []
        case let .string(raw)?: return Persist(rawValue: raw).map { [$0] }
        case let .array(items)? where (1...2).contains(items.count):
            let scopes = items.compactMap { $0.stringValue.flatMap(Persist.init(rawValue:)) }
            guard scopes.count == items.count else { return nil }
            return Persist.allCases.filter(scopes.contains)
        default: return nil
        }
    }

    /// The provider's display list for the parameters, when every row of it is readable.
    private static func displayList(_ value: JSONValue?) -> [Detail]? {
        guard let rows = value?.arrayValue else { return nil }
        var details: [Detail] = []
        for row in rows {
            guard let name = row["name"]?.stringValue?.trimmed, !name.isEmpty, let value = row["value"] else { return nil }
            var label = name
            if let display = row["display_name"] {
                guard let text = display.stringValue?.trimmed, !text.isEmpty else { return nil }
                label = text
            }
            details.append(.init(name: label, value: DotsJSONText.plain(value)))
        }
        return details
    }

    private static func details(_ object: [String: JSONValue]) -> [Detail] {
        object.keys.sorted().map { .init(name: $0, value: DotsJSONText.plain(object[$0]!)) }
    }
}

/// The answer to an input request: `{action, content, _meta}`, sent as the provider's result.
struct DotsInputResult: Equatable, Sendable {
    enum Action: String, Equatable, Sendable { case accept, decline, cancel }
    let action: Action
    let content: JSONValue
    let meta: JSONValue

    var json: JSONValue { .object(["action": .string(action.rawValue), "content": content, "_meta": meta]) }

    /// The scope an accepted answer was kept for, as its acknowledgement records it.
    var persist: DotsApproval.Persist? { meta["persist"]?.stringValue.flatMap(DotsApproval.Persist.init(rawValue:)) }

    /// A form's answer: what its fields hold, only while every field is valid.
    static func submit(_ form: CodexMCPElicitationForm, _ input: [String: CodexMCPElicitationFieldValue]) -> DotsInputResult? {
        form.content(input).map { .init(action: .accept, content: $0, meta: .null) }
    }

    static let decline = DotsInputResult(action: .decline, content: .null, meta: .null)
    static let cancel = DotsInputResult(action: .cancel, content: .null, meta: .null)
}

/// What the provider says of a request when asked just before an answer is sent.
struct DotsRequestInspection: Equatable, Sendable {
    let request: JSONValue
    let canRespond: Bool
    let runtimeStatus: String?
    let fingerprint: String?

    init(_ value: JSONValue) throws {
        guard let request = value["elicitation"], case .object = request else { throw PersonalAgentFailure.invalidResponse }
        self.request = request
        canRespond = value["can_respond"] == .bool(true)
        runtimeStatus = value["runtime_status"]?.stringValue
        fingerprint = value["request_fingerprint"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Whether this is still exactly the request the message showed: the same identity and parameters.
    func matches(_ shown: DotsInputRequest) -> Bool {
        guard request["request_id"]?.stringValue == shown.requestID,
              request["thread_id"]?.stringValue == shown.threadID else { return false }
        let turn: String?? = switch request["turn_id"] {
        case nil, .null?: .some(nil)
        case let .string(text)?: .some(text)
        default: nil
        }
        return turn == .some(shown.turnID) && request["params"] == shown.params
    }

    var isAnswerable: Bool { canRespond && runtimeStatus == "pending" && fingerprint != nil }
    var isClosed: Bool { runtimeStatus == "resolved" || runtimeStatus == "expired" }
}

/// A question a dot asks with options (`message_metadata.option_picker`). It is answered by an
/// ordinary reply carrying the chosen option's exact text, not through the input-request endpoint.
struct DotsOptionPicker: Equatable, Sendable {
    let options: [String]
    /// The option the provider records as chosen; -1 is a question closed without one.
    let selected: Int?

    init?(metadata: JSONValue?) {
        guard let picker = metadata?["option_picker"], let items = picker["options"]?.arrayValue, !items.isEmpty else {
            return nil
        }
        let options = items.compactMap(\.stringValue)
        guard options.count == items.count, options.allSatisfy({ !$0.trimmed.isEmpty }) else { return nil }
        switch picker["selected"] {
        case nil: selected = nil
        case let value?:
            guard let index = Self.integer(value), index >= -1, index < options.count else { return nil }
            selected = index
        }
        self.options = options
    }

    /// The option a reply chose, from its own metadata.
    static func selection(_ metadata: JSONValue?) -> Int? {
        guard let value = metadata?["option_picker"]?["selection"], let index = integer(value), index >= 0 else { return nil }
        return index
    }

    private static func integer(_ value: JSONValue) -> Int? {
        switch value {
        case let .integer(number): Int(exactly: number)
        case let .number(number) where number.rounded() == number && abs(number) < 9.0e15: Int(number)
        default: nil
        }
    }
}

/// The journal's identity of one provider request: the same account, user, room, thread, turn and
/// request in every window and account home, so one request can be claimed only once.
struct DotsResponseKey: Hashable, Sendable {
    let accountID: String
    let userID: String
    let roomID: String
    let threadID: String
    let turnID: String?
    let requestID: String

    /// The identity as the provider's own history keys it, with an absent turn as null.
    var serialized: String {
        let parts: [JSONValue] = [.string(accountID), .string(userID), .string(roomID), .string(threadID),
                                  turnID.map(JSONValue.string) ?? .null, .string(requestID)]
        return String(decoding: try! JSONEncoder().encode(JSONValue.array(parts)), as: UTF8.self)
    }
}

/// What an applied answer was: the fingerprint it answered, its action and remembered scope.
struct DotsResponseAcknowledgement: Codable, Equatable, Sendable {
    let fingerprint: String
    let action: String
    let persist: String?
}

/// A request's local history: claimed before its answer was sent, then acknowledged once applied.
/// A claim without an acknowledgement may already have reached the provider; it is never resent.
enum DotsResponseRecord: Equatable, Sendable {
    case claimed
    case acknowledged(DotsResponseAcknowledgement)

    /// The record as stored: no form values, no message or parameters.
    struct Stored: Codable, Equatable {
        var version = 1
        var acknowledgement: DotsResponseAcknowledgement?
    }

    init?(_ stored: Stored) {
        guard stored.version == 1 else { return nil }
        self = stored.acknowledgement.map { .acknowledged($0) } ?? .claimed
    }
}

/// The durable claim-and-acknowledge journal every window and account home shares. Each call is
/// atomic: a claim succeeds only for a request with no record, and only an unsent claim is
/// released. A storage failure throws, and the answer is then not sent.
protocol DotsResponseJournal: AnyObject, Sendable {
    func record(for key: DotsResponseKey) throws -> DotsResponseRecord?
    /// Records an unsent claim; false when the request already has a record.
    func claim(_ key: DotsResponseKey) throws -> Bool
    /// Removes a claim known not to have been sent; throws for any other record.
    func release(_ key: DotsResponseKey) throws
    /// Turns the claim into an acknowledgement, keeping one already there.
    func acknowledge(_ key: DotsResponseKey, _ acknowledgement: DotsResponseAcknowledgement) throws
}

enum DotsResponseJournalFailure: Error, Equatable { case missingClaim, unreadable }

/// The journal kept in memory, for renders and tests; the app keeps it in files.
final class DotsMemoryResponseJournal: DotsResponseJournal, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [DotsResponseKey: DotsResponseRecord] = [:]
    /// Makes every operation fail, as an unwritable store does.
    var fails = false

    init() {}

    func record(for key: DotsResponseKey) throws -> DotsResponseRecord? {
        try locked { records[key] }
    }

    func claim(_ key: DotsResponseKey) throws -> Bool {
        try locked {
            guard records[key] == nil else { return false }
            records[key] = .claimed
            return true
        }
    }

    func release(_ key: DotsResponseKey) throws {
        try locked {
            guard records[key] == .claimed else { throw DotsResponseJournalFailure.missingClaim }
            records[key] = nil
        }
    }

    func acknowledge(_ key: DotsResponseKey, _ acknowledgement: DotsResponseAcknowledgement) throws {
        try locked {
            guard let record = records[key] else { throw DotsResponseJournalFailure.missingClaim }
            if case .claimed = record { records[key] = .acknowledged(acknowledgement) }
        }
    }

    private func locked<Value>(_ body: () throws -> Value) throws -> Value {
        lock.lock()
        defer { lock.unlock() }
        guard !fails else { throw DotsResponseJournalFailure.unreadable }
        return try body()
    }
}

/// JSON as the card shows a value: text as it is, anything else compact.
enum DotsJSONText {
    static func plain(_ value: JSONValue) -> String {
        if case let .string(text) = value { return text }
        return compact(value)
    }

    static func compact(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    static func pretty(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
