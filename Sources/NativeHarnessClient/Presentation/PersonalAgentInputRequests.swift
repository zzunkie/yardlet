import Foundation
import Observation

/// An input request a dot's message carries, as one window shows it: what the provider says of it
/// now, the shared journal's record of it, and what the person entered.
///
/// Answering follows one order (`PersonalAgentCenter.respond`): the journal must hold nothing for
/// the request, a fresh inspection must show exactly this request still pending with a fingerprint,
/// the journal claims it, and only then is the answer sent, once. A claim stays unless the answer is
/// known not to have left; a request whose answer may have arrived is never answered again here. It
/// reads as unconfirmed until the provider says it is applied, resolved or expired, and checking its
/// status only reads.
@MainActor @Observable
final class PersonalAgentInputRequest {
    enum History: Equatable { case unknown, none, claimed, acknowledged(DotsResponseAcknowledgement), unreadable }

    enum Phase: Equatable {
        case loading, answerable, unavailable, sending, unconfirmed
        case closed(Closure)
    }

    enum Closure: Equatable { case allowed, denied, answered, resolved, expired }

    /// What the last attempt left to say: an answer that was certainly not sent, or that may have been.
    enum Attempt: Equatable { case notSent(PersonalAgentFailure), storage, uncertain }

    let messageID: String
    let request: DotsInputRequest
    let key: DotsResponseKey
    var formInput: [String: CodexMCPElicitationFieldValue] = [:]
    var inspection: DotsRequestInspection?
    var inspectionFailed = false
    var history: History = .unknown
    var isSending = false
    var isChecking = false
    var attempt: Attempt?
    /// The answer this window saw applied.
    var applied: DotsInputResult.Action?
    @ObservationIgnored var inspectID: UUID?
    @ObservationIgnored var needsInspect = false

    init(messageID: String, request: DotsInputRequest, key: DotsResponseKey) {
        self.messageID = messageID
        self.request = request
        self.key = key
    }

    /// The inspection, only while it still describes the request the message showed.
    private var current: DotsRequestInspection? {
        inspection.flatMap { $0.matches(request) ? $0 : nil }
    }

    private var matchingAcknowledgement: DotsResponseAcknowledgement? {
        guard case let .acknowledged(ack) = history, let fingerprint = current?.fingerprint, ack.fingerprint == fingerprint
        else { return nil }
        return ack
    }

    var phase: Phase {
        if let applied { return .closed(Self.closure(applied.rawValue)) }
        if let ack = matchingAcknowledgement { return .closed(Self.closure(ack.action)) }
        if request.status == "expired" || current?.runtimeStatus == "expired" { return .closed(.expired) }
        if request.status == "resolved" || current?.runtimeStatus == "resolved" { return .closed(.resolved) }
        if isSending { return .sending }
        if attempt == .uncertain || inspectionFailed || history == .unreadable || history == .claimed { return .unconfirmed }
        if case .acknowledged = history { return .unconfirmed }
        if inspection != nil, current == nil || current?.runtimeStatus == nil { return .unconfirmed }
        guard history == .none, let current else { return .loading }
        return current.isAnswerable ? .answerable : .unavailable
    }

    private static func closure(_ action: String) -> Closure {
        switch action {
        case "accept": .allowed
        case "decline", "cancel": .denied
        default: .resolved
        }
    }

    /// Whether `result` is one of the answers this request offers, as it now stands.
    func offers(_ result: DotsInputResult) -> Bool {
        switch request.kind {
        case let .approval(approval):
            let allows = ([nil] + approval.persist.map(Optional.some)).compactMap { approval.allow($0) }
            return allows.contains(result) || result == approval.deny || result == approval.cancel
        case let .form(form, _):
            return result == .decline || result == .cancel || result == DotsInputResult.submit(form, formInput)
        case .unsupported:
            return false
        }
    }
}

/// An option question's answer waiting to be confirmed: its request identity and exact payload, kept
/// apart from the ordinary draft and any attachments, under the same account home, account, user, dot
/// and room. While it waits, only the same request can be sent again, and only when the person asks.
@MainActor @Observable
final class PersonalAgentOptionReply {
    enum Problem: Equatable {
        case failure(PersonalAgentFailure)
        /// The question could not be read again just before sending.
        case unchecked
        /// The question changed, was deleted or was already answered.
        case changed
    }

    private(set) var pending: PersonalAgentSubmission?
    private(set) var storageFailed = false
    var isSending = false
    var problem: Problem?
    /// The question the last choice was made on, which the problem is shown under.
    var question: String?
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private var unreadable = false

    private struct Record: Codable {
        var version = 1
        let pending: PersonalAgentSubmission?
    }

    init(file: URL? = nil) {
        self.file = file
        guard let file else { return }
        do {
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
            guard record.version == 1 else { throw CocoaError(.coderReadCorrupt) }
            pending = record.pending
            if pending != nil { problem = .failure(.deliveryUnknown) }
        } catch CocoaError.fileReadNoSuchFile {
        } catch { unreadable = true; storageFailed = true }
    }

    /// Keeps the answer before it is sent; false when it cannot be kept, and then it is not sent.
    func prepare(_ submission: PersonalAgentSubmission) -> Bool {
        guard pending == nil, !unreadable else { return false }
        pending = submission
        guard save() else { pending = nil; return false }
        return true
    }

    func accepted(_ requestID: String) {
        guard pending?.requestID == requestID else { return }
        pending = nil
        problem = nil
        _ = save()
    }

    func failed(_ failure: PersonalAgentFailure, retry: Bool) {
        problem = .failure(failure)
        // These answers explicitly reject this first attempt; a rejected retry says nothing of the first.
        if !retry, failure == .sendRejected || failure == .verificationRequired { pending = nil }
        _ = save()
    }

    /// Stops waiting for the uncertain answer `requestID`, after the person accepts that it may have
    /// arrived. A confirmation given for an answer that has since been settled lets no later one go.
    func discard(requestID: String) {
        guard !isSending, pending?.requestID == requestID else { return }
        let previous = pending
        pending = nil
        guard save() else { pending = previous; return }
        problem = nil
    }

    /// The saved answer could not be read; nothing is answered until it is kept as a backup.
    var needsRecovery: Bool { unreadable }

    /// Saves again after a failure, sending nothing: a waiting answer keeps its request and payload.
    @discardableResult
    func retrySave() -> Bool {
        guard !isSending else { return false }
        return save()
    }

    /// Keeps the unreadable file's bytes in a private backup beside it, then starts with no waiting
    /// answer. A backup or save that fails leaves the original and the lock as they were.
    @discardableResult
    func recoverStorage() -> Bool {
        guard !isSending, unreadable, let file else { return false }
        do {
            let backup = file.appendingPathExtension("backup-" + UUID().uuidString)
            try FileManager.default.copyItem(at: file, to: backup)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        } catch { storageFailed = true; return false }
        unreadable = false
        guard save() else { unreadable = true; return false }
        problem = nil
        return true
    }

    @discardableResult
    private func save() -> Bool {
        guard !unreadable else { storageFailed = true; return false }
        guard let file else { storageFailed = false; return true }
        do {
            let manager = FileManager.default
            let directory = file.deletingLastPathComponent()
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let pending {
                try JSONEncoder().encode(Record(pending: pending)).write(to: file, options: .atomic)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } else if manager.fileExists(atPath: file.path) {
                try manager.removeItem(at: file)
            }
            storageFailed = false
            return true
        } catch { storageFailed = true; return false }
    }
}

extension PersonalAgentCenter {
    /// One state per input request the conversation shows, read again after each successful read of
    /// the conversation. A request whose message closes it, or that is being read, is not read again.
    func syncInputRequests(_ state: PersonalAgentConversation, agent: PersonalAgent) {
        var next: [String: PersonalAgentInputRequest] = [:]
        for message in state.messages where message.author == .agent && !message.isDeleted {
            guard let value = message.inputRequest, let request = DotsInputRequest(value) else { continue }
            if let existing = state.requests[message.id], existing.request == request {
                next[message.id] = existing
            } else {
                next[message.id] = PersonalAgentInputRequest(messageID: message.id, request: request,
                    key: request.key(accountID: agent.id.accountID, userID: agent.id.userID, roomID: agent.id.roomID))
            }
        }
        state.requests = next
        if let reply = state.optionReply.pending,
           state.messages.contains(where: { $0.author == .person && $0.requestID == reply.requestID }) {
            state.optionReply.accepted(reply.requestID)
        }
        for item in next.values {
            readHistory(item)
            if case .unsupported = item.request.kind { continue }
            if item.request.isClosedByMessage { continue }
            if case .closed = item.phase { continue }
            Task { await inspectInputRequest(item) }
        }
    }

    private func readHistory(_ item: PersonalAgentInputRequest) {
        do {
            item.history = switch try responses.record(for: item.key) {
            case nil: .none
            case .claimed: .claimed
            case let .acknowledged(ack): .acknowledged(ack)
            }
        } catch { item.history = .unreadable }
    }

    /// Reads the request and its local history again; it never answers and never clears a claim.
    func checkInputRequest(_ item: PersonalAgentInputRequest) async {
        item.attempt = nil
        readHistory(item)
        await inspectInputRequest(item)
    }

    private func isShown(_ item: PersonalAgentInputRequest, agent: PersonalAgent, generation current: Int) -> Bool {
        current == generation && selectedID == agent.id && conversation?.requests[item.messageID] === item
    }

    func inspectInputRequest(_ item: PersonalAgentInputRequest) async {
        guard let agent = selected, let reader = client, isShown(item, agent: agent, generation: generation) else { return }
        // Reads of one request coalesce: one runs, and one more follows if asked for meanwhile.
        guard item.inspectID == nil else { item.needsInspect = true; return }
        let current = generation
        let id = UUID()
        item.inspectID = id
        item.isChecking = true
        let result: Result<DotsRequestInspection, Error>
        do { result = .success(try await reader.inspectRequest(in: item.messageID, for: agent)) }
        catch { result = .failure(error) }
        // The read ends here wherever the window is now; only what it read waits for the request to be shown.
        guard item.inspectID == id else { return }
        item.inspectID = nil
        item.isChecking = false
        let again = item.needsInspect
        item.needsInspect = false
        // A lost login ends the connection that read it, whichever dot is shown now.
        if case let .failure(error) = result { endsLogin(error, generation: current) }
        guard isShown(item, agent: agent, generation: current) else { return }
        switch result {
        case let .success(value):
            item.inspection = value
            item.inspectionFailed = false
        case .failure:
            item.inspectionFailed = true
        }
        if again { await inspectInputRequest(item) }
    }

    /// Sends one answer to `item`, in the order its type describes.
    func respond(to item: PersonalAgentInputRequest, with result: DotsInputResult) async {
        guard let agent = selected, let reader = client, isShown(item, agent: agent, generation: generation),
              item.phase == .answerable, item.offers(result) else { return }
        let current = generation
        item.isSending = true
        item.attempt = nil
        defer { item.isSending = false }
        do {
            if try responses.record(for: item.key) != nil { readHistory(item); return }
        } catch { item.history = .unreadable; item.attempt = .storage; return }
        let inspection: DotsRequestInspection
        do { inspection = try await reader.inspectRequest(in: item.messageID, for: agent) }
        catch {
            endsLogin(error, generation: current)
            guard isShown(item, agent: agent, generation: current) else { return }
            item.attempt = .notSent(error as? PersonalAgentFailure ?? .network)
            return
        }
        guard isShown(item, agent: agent, generation: current) else { return }
        item.inspection = inspection
        guard inspection.matches(item.request), inspection.isAnswerable, let fingerprint = inspection.fingerprint else { return }
        do {
            guard try responses.claim(item.key) else { readHistory(item); return }
        } catch { item.attempt = .storage; return }
        item.history = .claimed
        // A change of account, dot or request since the read releases the claim it had not used.
        guard isShown(item, agent: agent, generation: current), !Task.isCancelled else {
            if (try? responses.release(item.key)) != nil { item.history = .none }
            return
        }
        do {
            let outcome = try await reader.respond(result, fingerprint: fingerprint, in: item.messageID, for: agent)
            guard outcome == .applied else {
                // Another status may still have taken effect: read what the provider says now.
                if isShown(item, agent: agent, generation: current) {
                    item.attempt = .uncertain
                    item.isSending = false
                    await inspectInputRequest(item)
                }
                return
            }
            let ack = DotsResponseAcknowledgement(fingerprint: fingerprint, action: result.action.rawValue,
                                                  persist: result.persist?.rawValue)
            // An acknowledgement that cannot be written leaves the claim, which still blocks a second answer.
            if (try? responses.acknowledge(item.key, ack)) != nil, isShown(item, agent: agent, generation: current) {
                item.history = .acknowledged(ack)
            }
            if isShown(item, agent: agent, generation: current) { item.applied = result.action }
        } catch let DotsResponseFailure.notDispatched(failure) {
            if (try? responses.release(item.key)) != nil, isShown(item, agent: agent, generation: current) { item.history = .none }
            if isShown(item, agent: agent, generation: current) { item.attempt = .notSent(failure) }
            // The claim belongs to this request; ending a login belongs to the connection that sent it.
            endsLogin(failure, generation: current)
        } catch {
            if isShown(item, agent: agent, generation: current) { item.attempt = .uncertain }
            if case let DotsResponseFailure.uncertain(failure) = error { endsLogin(failure, generation: current) }
        }
    }

    // MARK: - Option questions

    /// Whether the person already answered `question`: the provider recorded an option, a reply chose
    /// one, or an answer to it is still waiting.
    func isAnswered(_ question: PersonalAgentMessage, in state: PersonalAgentConversation) -> Bool {
        if DotsOptionPicker(metadata: question.metadata)?.selected != nil { return true }
        if state.optionReply.pending?.replyToMessageID == question.id { return true }
        return state.visibleMessages.contains {
            !$0.isDeleted && $0.replyToMessageID == question.id && DotsOptionPicker.selection($0.metadata) != nil
        }
    }

    /// Answers an option question with the exact text of option `index`, as a reply to it. The
    /// conversation's displayed range is read again first; the question must still be there, unchanged,
    /// undeleted and unanswered. The ordinary draft is not touched.
    func chooseOption(_ index: Int, in messageID: String) async {
        guard let agent = selected, let state = conversation, state.optionReply.pending == nil,
              !state.optionReply.isSending, !state.optionReply.storageFailed,
              let shown = state.messages.first(where: { $0.id == messageID }),
              let shownPicker = DotsOptionPicker(metadata: shown.metadata), shownPicker.options.indices.contains(index)
        else { return }
        let reply = state.optionReply
        let current = generation
        reply.isSending = true
        reply.problem = nil
        reply.question = messageID
        defer { reply.isSending = false }
        guard await refreshDisplayedRange(), current == generation, selectedID == agent.id else {
            if current == generation { reply.problem = .unchecked }
            return
        }
        guard let picker = openQuestion(messageID, index: index, text: shownPicker.options[index], in: state) else {
            reply.problem = .changed
            return
        }
        var submission = PersonalAgentSubmission(text: picker.options[index])
        submission.replyToMessageID = messageID
        submission.optionSelection = index
        guard reply.prepare(submission) else { reply.problem = .failure(.draftStorage); return }
        await deliverOptionReply(submission, retry: false, agent: agent, state: state)
    }

    /// Sends the waiting answer again with the same request identity and payload, only when asked.
    func retryOptionReply() async {
        guard let agent = selected, let state = conversation, let submission = state.optionReply.pending,
              let messageID = submission.replyToMessageID, let index = submission.optionSelection,
              !state.optionReply.isSending else { return }
        let reply = state.optionReply
        let current = generation
        reply.isSending = true
        defer { reply.isSending = false }
        // The earlier attempt may have arrived: a read that shows it settles the answer without sending.
        guard await refreshDisplayedRange(), current == generation, selectedID == agent.id else {
            if current == generation { reply.problem = .unchecked }
            return
        }
        guard reply.pending == submission else { return }
        // A question deleted, answered or changed since is not answered again; the waiting answer stays.
        guard openQuestion(messageID, index: index, text: submission.text, in: state) != nil else {
            reply.problem = .changed
            return
        }
        await deliverOptionReply(submission, retry: true, agent: agent, state: state)
    }

    /// The question as the displayed range now reads it, when it can still take option `index` with
    /// `text`: there, undeleted, asked by the dot, with no recorded option and no reply that chose one.
    private func openQuestion(_ messageID: String, index: Int, text: String,
                              in state: PersonalAgentConversation) -> DotsOptionPicker? {
        guard let question = state.messages.first(where: { $0.id == messageID }), !question.isDeleted,
              question.author == .agent, let picker = DotsOptionPicker(metadata: question.metadata),
              picker.selected == nil, picker.options.indices.contains(index), picker.options[index] == text,
              !state.visibleMessages.contains(where: {
                  !$0.isDeleted && $0.replyToMessageID == messageID && DotsOptionPicker.selection($0.metadata) != nil
              }) else { return nil }
        return picker
    }

    private func deliverOptionReply(_ submission: PersonalAgentSubmission, retry: Bool, agent: PersonalAgent,
                                    state: PersonalAgentConversation) async {
        guard let reader = client else { return }
        let current = generation
        do {
            let message = try await reader.send(submission, to: agent)
            state.optionReply.accepted(submission.requestID)
            if current == generation {
                state.sentMessages = DotsProjection.merge(state.sentMessages, with: [message], older: false)
                if selectedID == agent.id { await refreshConversation() }
            }
        } catch {
            let failure = error as? PersonalAgentFailure ?? .deliveryUnknown
            if state.optionReply.pending?.requestID == submission.requestID { state.optionReply.failed(failure, retry: retry) }
            endsLogin(failure, generation: current)
        }
    }

    /// One complete read of the displayed range, waiting briefly for a read already running to end;
    /// false unless this read succeeded.
    private func refreshDisplayedRange() async -> Bool {
        for _ in 0..<100 {
            guard conversation?.isLoading == true else { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await refreshConversation()
    }

    /// Ends the login of the connection `generation` names, and only while it is still the current one.
    private func endsLogin(_ error: Error, generation started: Int) {
        let failure = error as? PersonalAgentFailure
        guard started == generation, failure == .accountChanged || failure == .signInRequired else { return }
        accept(failure!)
    }
}
