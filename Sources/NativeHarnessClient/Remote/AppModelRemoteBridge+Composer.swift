import Foundation
import Observation
import YardletRemote

extension AppModelRemoteBridge {
    func composerState(taskID: String) async -> Result<RemoteComposerState, RemoteError> {
        guard let session = session(taskID), let state = watchComposer(of: session.id) else {
            return .failure(RemoteError(.notFound))
        }
        return .success(state)
    }

    /// Dependencies may invalidate together (for example, a provider's capability dictionary),
    /// but only a changed composer projection asks its clients to read again.
    func watchComposer(of id: UUID) -> RemoteComposerState? {
        guard let model else { return nil }
        let read = { [weak self] in
            self?.listedSession(id).map { Self.readComposerState(session: $0, model: model) }
        }
        let state: RemoteComposerState?
        if watchesComposer.contains(id) {
            state = read()
        } else {
            watchesComposer.insert(id)
            state = withObservationTracking(read) { [weak self] in
                Task { @MainActor in self?.composerMayHaveChanged(id) }
            }
        }
        answeredComposer[id] = state
        return state
    }

    private func composerMayHaveChanged(_ id: UUID) {
        watchesComposer.remove(id)
        guard let answered = answeredComposer[id] else { return }
        guard watched.contains(id) else {
            answeredComposer[id] = nil
            return
        }
        // Rearm even when the projection stayed equal, so a later meaningful change is observed.
        if watchComposer(of: id) != answered { changeHandler?(.composerState(id.uuidString)) }
    }

    private static func readComposerState(session: SessionRecord, model: AppModel) -> RemoteComposerState {
        let center = model.connectorCenter
        let scope = model.connectorScopeBySessionID[session.id] ?? ConnectorTaskScope(harness: session.harness)
        let list = ComposerConnectorList.make(Self.composerOptions(of: session, in: model).connectors,
            connectors: center?.connectors ?? [],
            taskState: { center?.state(of: $0, inTask: session.id, scope: scope) ?? .on },
            standInServerNames: Set(scope.leftOutNativeServers.map(\.name)))
        let rows = list?.rows.map { row in
            RemoteComposerConnector(id: row.id, name: row.name, state: String(describing: row.state),
                toolCount: row.toolCount, source: row.source == .yardlet ? "yardlet" : "session",
                connectorID: row.connectorID?.uuidString, presetID: row.presetID)
        }
        // As mounting the host composer does, retain the empty draft so a suggestion arriving
        // later can invalidate this observation even when no host window has opened the task.
        let draft = model.composerDrafts.tasks.draft(for: session.id)
        let enabled = NextMessageSuggestionPreference.isOn()
        let suggestion = enabled && session.status != .running && session.status != .waitingForApproval
            ? draft.nextMessageSuggestion : nil
        // What the Mac's composer says under its text: a message it kept, a command that failed (`keepUnsent`, its commands).
        return RemoteComposerState(nextMessageSuggestion: RemoteText.short(suggestion, RemoteText.userLimit),
            queuePaused: model.followUps.isPaused(session.id), connectors: rows,
            toolListFollowsNextTurn: list?.toolListFollowsNextTurn ?? false,
            notice: RemoteText.short(draft.notice, RemoteText.errorLimit))
    }

    func composerAction(taskID: String, action: String, itemID: String?, value: String?) async -> Result<RemoteComposerState, RemoteError> {
        guard let model, let session = session(taskID) else { return .failure(RemoteError(.notFound)) }
        guard !model.switchingAccounts.contains(session.id), !model.sessionMutations.contains(session.id) else {
            return .failure(RemoteError(.busy, "The task is changing on the Mac", reason: .changing))
        }
        switch action {
        case "connector":
            guard let itemID, let id = UUID(uuidString: itemID), let center = model.connectorCenter,
                  value == "on" || value == "off",
                  case let .success(state) = await composerState(taskID: taskID),
                  state.connectors?.contains(where: { $0.connectorID == itemID && $0.state != "harnessHasIt" }) == true else {
                return .failure(RemoteError(.notAllowed))
            }
            center.setConnector(id, on: value == "on", inTask: session.id)
        case "pause":
            guard FollowUpPolicy(harness: session.harness) != nil else { return .failure(RemoteError(.notAllowed)) }
            model.followUps.pause(session.id)
        case "resume": model.resumeQueue(for: session)
        case "moveUp", "moveDown", "retry", "edit":
            guard let itemID, itemID.hasPrefix("queued:"),
                  let id = UUID(uuidString: String(itemID.dropFirst("queued:".count))),
                  let item = model.followUps.item(id, in: session.id), !model.followUps.isClaimed(id),
                  let index = model.followUps.queue(for: session.id).firstIndex(where: { $0.id == id }) else {
                return .failure(RemoteError(.notFound))
            }
            guard !item.isFromAnotherTask, item.state != .sent else { return .failure(RemoteError(.notAllowed)) }
            if action == "edit" {
                guard item.draft.text.count <= RemoteText.userLimit, DiffCommentPrompt.parse(item.draft.text) == nil,
                      let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      value.count <= RemoteProtocol.maxMessageCharacters, TaskMessage.parse(value) == nil,
                      model.followUps.editText(id, in: session.id, text: value) else { return .failure(RemoteError(.notAllowed)) }
            }
            else if action == "retry" { model.retryQueued(id, for: session) }
            else { model.moveQueued(id, in: session, to: index + (action == "moveUp" ? -1 : 1)) }
        default: return .failure(RemoteError(.notAllowed))
        }
        return await composerState(taskID: taskID)
    }
}
