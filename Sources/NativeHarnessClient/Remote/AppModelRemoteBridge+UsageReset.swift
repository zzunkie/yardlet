import Foundation
import YardletRemote

struct RemoteResetOffer {
    let token: String
    let account: String
    let createdAt: Date
    let count: Int
    let resetID: String?
    var attempted = false
    var answer: RemoteUsageReset?
}

extension AppModelRemoteBridge {
    /// Reading prepares the same confirmation as a local limit card. A token stays bound to the account
    /// shown, and an answered use is never repeated when its network response was lost.
    func usageReset(taskID: String, token: String?, confirmed: Bool) async -> Result<RemoteUsageReset, RemoteError> {
        guard let model, let session = session(taskID), session.harness == .codex || session.harness == .claudeCode else {
            return .failure(RemoteError(.notFound))
        }
        let choice = model.connections.choice(for: session.harness, connection: session.connection)
        if let token {
            guard confirmed, var offer = resetOffers[session.id], offer.token == token,
                  offer.account == choice.id, Date().timeIntervalSince(offer.createdAt) < 3600 else {
                return .failure(RemoteError(.notAllowed, "Read and confirm this account's reset first"))
            }
            if let answer = offer.answer { return .success(answer) }
            if offer.attempted {
                switch model.connections.usageResetStates[choice.id] {
                case .answered?:
                    let result = Self.resetPresentation(choice: choice, token: token,
                        state: model.connections.usageResetStates[choice.id])
                    resetOffers[session.id]?.answer = result
                    return .success(result)
                case .failed?, .using?: break
                case nil: return .failure(RemoteError(.notAllowed, "Read the reset again"))
                }
            }
            guard model.connections.usageResetStates[choice.id] != .using else { return .failure(RemoteError(.busy)) }
            guard session.status != .running, session.status != .waitingForApproval,
                  !model.switchingAccounts.contains(session.id), !model.sessionMutations.contains(session.id) else {
                return .failure(RemoteError(.busy))
            }
            let current = model.connections.choice(for: session.harness, connection: session.connection)
            guard offer.attempted || (current.snapshot?.usageResets?.availableCount == offer.count
                && current.snapshot?.usageResets?.next?.id == offer.resetID) else {
                return .failure(RemoteError(.notAllowed, "The available resets changed; read them again"))
            }
            guard hasResetLimitCard(session, in: model) else { return .failure(RemoteError(.notAllowed)) }
            // A failed attempt keeps the account store's attempt ID; a new offer cannot replace it.
            offer.attempted = true
            resetOffers[session.id] = offer
            await model.connections.useUsageReset(choice, runtimeSelections: model.runtimeSelections)
            let result = Self.resetPresentation(choice: model.connections.choice(for: session.harness, connection: session.connection),
                token: token, state: model.connections.usageResetStates[choice.id])
            if case .answered? = model.connections.usageResetStates[choice.id] {
                resetOffers[session.id]?.answer = result
            }
            return .success(result)
        }
        // A limit card, not general account administration: only offer what a current card offers.
        guard session.status != .running, session.status != .waitingForApproval,
              !model.switchingAccounts.contains(session.id), !model.sessionMutations.contains(session.id) else {
            return .failure(RemoteError(.busy))
        }
        guard hasResetLimitCard(session, in: model) else { return .failure(RemoteError(.notAllowed)) }
        guard model.connections.usageResetStates[choice.id] != .using else { return .failure(RemoteError(.busy)) }
        await model.connections.check(choice, runtimeSelections: model.runtimeSelections)
        guard self.session(taskID)?.connection == session.connection else { return .failure(RemoteError(.busy)) }
        let current = model.connections.choice(for: session.harness, connection: session.connection)
        guard let resets = current.snapshot?.usageResets, resets.availableCount > 0 else { return .failure(RemoteError(.notAllowed)) }
        resetOffers = resetOffers.filter { Date().timeIntervalSince($0.value.createdAt) < 3600 }
        guard resetOffers.count < 128 || resetOffers[session.id] != nil else { return .failure(RemoteError(.busy)) }
        let offer = RemoteResetOffer(token: UUID().uuidString, account: choice.id, createdAt: Date(), count: resets.availableCount, resetID: resets.next?.id)
        resetOffers[session.id] = offer
        return .success(Self.resetPresentation(choice: current, token: offer.token, state: nil))
    }

    private func hasResetLimitCard(_ session: SessionRecord, in model: AppModel) -> Bool {
        if session.harness == .claudeCode {
            return UsageLimitContinuation.card(in: model.transcriptBySessionID[session.id] ?? []) != nil
        }
        return presentation(of: session, in: model).turns.last.map { turn in
            if case .usageLimit? = turn.outcome { return true }; return false
        } == true
    }

    private static func resetPresentation(choice: AccountChoice, token: String, state: UsageResetState?) -> RemoteUsageReset {
        let resets = choice.snapshot?.usageResets
        let restored = (resets?.restores.isEmpty ?? true) ? choice.quotas : choice.quotas.filter { resets!.restores.contains($0.id) }
        let status: String?
        var left: Int?
        switch state {
        case .using?: status = "using"
        case let .answered(outcome, count)?:
            left = count
            switch outcome { case .reset: status = "reset"; case .nothingToReset: status = "nothingToReset"; case .noResets: status = "noResets" }
        case .failed?: status = "failed"
        case nil: status = nil
        }
        return RemoteUsageReset(token: token, title: choice.title + " · " + choice.harness.displayName,
            availableCount: resets?.availableCount ?? 0, resetTitle: resets?.next?.title, expiresAt: resets?.next?.expiresAt.map(RemoteJSON.milliseconds),
            metrics: restored.prefix(32).map { .init(id: $0.id, label: $0.label, usedFraction: $0.usedFraction, detail: $0.detail,
                resetsAt: $0.resetsAt.map(RemoteJSON.milliseconds), windowMinutes: $0.windowMinutes, model: $0.model) }, state: status, left: left)
    }
}
