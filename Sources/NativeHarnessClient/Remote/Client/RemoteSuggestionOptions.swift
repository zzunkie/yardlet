import Foundation
import Observation
import YardletRemote

/// A host's suggested task in this Mac's Options popover (docs/REMOTE_PROTOCOL.md §15.9): the host's choices for what
/// the chip's Start starts with, read again after each pick as the host's menus take it, and Start with what it shows.
/// The picks stay here until Start; the host keeps the chip's own choices until a Start with these.
@MainActor
@Observable
final class RemoteSuggestionOptions: TaskSuggestionOptionsSource {
    private let host: RemoteHostModel
    private let taskID: String
    private let suggestionID: String
    /// The agent asked for a worktree (`useWorktree`): a folder outside Git says it starts locally.
    private let asksForWorktree: Bool
    private var answer: RemoteResponse?
    private var harness: String?
    private var projectID: String?
    private var accountID: String?
    private var picks: [String: String] = [:]
    private var worktree: Bool?
    /// Choices the host asks to confirm that the person confirmed here, by setting.
    private var confirmed: [String: String] = [:]
    private var readID: UUID?

    init(host: RemoteHostModel, taskID: String, suggestion: ConversationTaskSuggestion) {
        self.host = host
        self.taskID = taskID
        self.suggestionID = suggestion.id
        self.asksForWorktree = suggestion.startsInNewWorktree
    }

    /// Reads the host's choices after the picks so far. A pick its menus no longer take is let go.
    func read() async {
        guard host.isConnected else { return }
        let id = UUID()
        readID = id
        defer { if readID == id { readID = nil } }
        var response = await host.response(to: request)
        if !response.ok, response.error?.reason == .setting, !picks.isEmpty {
            picks = [:]
            confirmed = [:]
            response = await host.response(to: request)
        }
        guard readID == id else { return }
        guard response.ok else {
            host.commandError = RemoteHostModel.message(for: response.error, host: host.name)
            return
        }
        answer = response
        if response.worktree == nil { worktree = nil }
    }

    private var request: RemoteRequest {
        .suggestionOptions(taskID: taskID, suggestionID: suggestionID, harness: harness, settings: picks,
                           projectID: projectID, accountID: accountID, composer: true)
    }

    private func reread() {
        Task { await read() }
    }

    private var settings: [RemoteSetting] { answer?.settings ?? [] }

    /// A setting whose value now is one the host asks to confirm, not yet confirmed here.
    private var unconfirmed: RemoteSetting? {
        settings.first { setting in
            setting.choices.first { $0.value == setting.value }?.confirm != nil && confirmed[setting.id] != setting.value
        }
    }

    func menus() -> TaskSuggestionOptionsMenus {
        let harnessID = harness ?? answer?.harness ?? host.task(taskID)?.harness ?? HarnessKind.claudeCode.rawValue
        let harnessName = answer?.harnesses?.first { $0.harness == harnessID }?.harnessName ?? HarnessKind(rawValue: harnessID).displayName
        let options = RemoteTaskSettingsProjection.options(settings, task: RemoteTask(
            id: taskID, title: "", harness: harnessID, harnessName: harnessName, projectId: nil, attention: .idle,
            lastActivityAt: 0))
        let projects = host.projects.filter { $0.canCreateTask == true && $0.kind != .chats }
        let place = projectID ?? answer?.projectId
        let startsAsChat = place == RemoteTaskProjection.chatsProjectID
        let placeTitle = startsAsChat ? L10n.string("Chat (no project)")
            : projectID.flatMap { id in projects.first { $0.id == id }?.name } ?? answer?.placeName ?? ""
        var run: TaskSuggestionOptionsMenus.Run?
        if let offered = answer?.worktree {
            run = .choosable(inWorktree: worktree ?? offered)
        } else if asksForWorktree, answer != nil, !startsAsChat {
            run = .localOnly
        }
        let accounts = answer?.accounts ?? []
        let chosenAccount = accounts.first { account in accountID.map { account.id == $0 } ?? (account.current == true) }
        let pending = unconfirmed
        let confirmation = pending.flatMap { setting in setting.choices.first { $0.value == setting.value }?.confirm }
        return TaskSuggestionOptionsMenus(
            harness: HarnessKind(rawValue: harnessID),
            harnesses: (answer?.harnesses ?? []).map { HarnessKind(rawValue: $0.harness) },
            chooseHarness: { [self] harness in
                guard harness.rawValue != harnessID else { return }
                self.harness = harness.rawValue
                picks = [:]
                confirmed = [:]
                accountID = nil
                reread()
            },
            account: accounts.isEmpty ? nil : .init(
                title: chosenAccount?.name ?? L10n.string("Account unavailable"),
                items: accounts.map { .init(id: $0.id, title: $0.name, isChosen: $0.id == chosenAccount?.id,
                                            isEnabled: $0.available == true) }),
            chooseAccount: { [self] id in
                accountID = id
                reread()
            },
            place: .init(title: placeTitle, startsAsChat: startsAsChat,
                         projects: projects.map { .init(id: $0.id, title: $0.name, isChosen: $0.id == place) }),
            choosePlace: { [self] id in
                projectID = id ?? RemoteTaskProjection.chatsProjectID
                worktree = nil
                reread()
            },
            run: run,
            chooseWorktree: { [self] in worktree = $0 },
            options: options,
            pick: { [self] picked in
                guard case let .providerOption(id, value) = picked else { return }
                picks[id] = value
                let asks = settings.first { $0.id == id }?.choices.first { $0.value == value }?.confirm != nil
                confirmed[id] = asks ? value : nil
                reread()
            },
            canStart: host.isConnected && answer != nil && readID == nil,
            startConfirmation: confirmation.map {
                ComposerPermissionSlot.Confirmation(title: $0.title, message: $0.message, confirm: $0.button)
            },
            start: { [self] confirmedNow in
                if confirmedNow, let pending { confirmed[pending.id] = pending.value }
                start(harness: harnessID)
            })
    }

    /// Start with what the popover shows: every setting's value, and the place, worktree and account the person chose.
    /// Confirmed only when each choice shown that asks was confirmed here; the host checks again.
    private func start(harness: String) {
        var values = picks
        for setting in settings where values[setting.id] == nil { values[setting.id] = setting.value }
        let asking = settings.filter { setting in setting.choices.first { $0.value == values[setting.id] }?.confirm != nil }
        let isConfirmed = !asking.isEmpty && asking.allSatisfy { confirmed[$0.id] == values[$0.id] }
        host.send(.actOnSuggestion(taskID: taskID, suggestionID: suggestionID, action: .start, start: RemoteSuggestionStart(
            harness: harness, settings: values, projectID: projectID, worktree: worktree, accountID: accountID,
            confirmed: isConfirmed)))
    }
}
