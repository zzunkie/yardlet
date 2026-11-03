import Foundation
import YardletRemote

/// A host task's controls (docs/REMOTE_PROTOCOL.md §15.23): the settings its composer's bottom row shows, its slash
/// commands that may run from here, and the edit and fork of its turns, each carried out on the host as its own menus
/// carry them out. A host from before them offers none, and the window shows none.
extension RemoteHostModel {
    /// Reads a task's settings; `prepare` reads the choices first, as opening the host's menu does.
    func readTaskSettings(_ taskID: String, prepare: Bool = false) async {
        guard taskControls, isConnected else { return }
        let response = await response(to: .taskSettings(taskID: taskID, prepare: prepare))
        if response.ok, conversations[taskID] != nil { taskSettings[taskID] = response.settings ?? [] }
    }

    /// A menu's choice, applied on the host; `confirmed` once this Mac asked as the host's menu asks.
    func setTaskSetting(_ taskID: String, id: String, value: String, confirmed: Bool) {
        request(.setTaskSetting(taskID: taskID, setting: id, value: value, confirmed: confirmed)) { [weak self] response in
            guard let self else { return }
            if response.ok {
                if conversations[taskID] != nil { taskSettings[taskID] = response.settings ?? [] }
            } else {
                commandError = Self.message(for: response.error, host: name)
            }
        }
    }

    /// A composer or rail menu's choice for the task, applied on the host; one the host's menu asks about first was asked
    /// about here too (`ComposerPermissionControl`).
    func chooseTaskSetting(_ taskID: String, _ choice: ComposerSessionChoice) {
        guard case let .providerOption(id, value) = choice,
              let setting = taskSettings[taskID]?.first(where: { $0.id == id }) else { return }
        let confirmed = setting.role == "permission" && setting.choices.first { $0.value == value }?.confirm != nil
        setTaskSetting(taskID, id: id, value: value, confirmed: confirmed)
    }

    /// The task's slash commands that may run from here, or nil when the host could not say.
    func composerCommands(_ taskID: String) async -> [RemoteComposerCommand]? {
        guard taskControls, isConnected else { return nil }
        let response = await response(to: .composerCommands(taskID: taskID))
        return response.ok ? response.commands ?? [] : nil
    }

    /// Runs a command on the host; a task it starts (a new chat, a fork) opens here, as the host's own window opens it.
    func runComposerCommand(_ taskID: String, name: String, arguments: String?) async -> Bool {
        let response = await response(to: .runComposerCommand(taskID: taskID, command: name, arguments: arguments))
        guard response.ok else {
            commandError = Self.message(for: response.error, host: self.name)
            return false
        }
        commandError = nil
        if let started = response.taskId { select(.task(started)) }
        return true
    }

    /// Edit message and Send: the turn's latest message, in `text`, as the host's composer sends an edit.
    func editMessage(_ taskID: String, turnID: String, text: String) async -> Bool {
        await perform(.editMessage(taskID: taskID, turnID: turnID, text: text))
    }

    /// Fork from here on a turn; the fork opens here, as the host's window opens it.
    func fork(_ taskID: String, turnID: String?) {
        request(.forkTask(taskID: taskID, turnID: turnID)) { [weak self] response in
            guard let self else { return }
            if response.ok, let forked = response.taskId {
                select(.task(forked))
            } else if !response.ok {
                commandError = Self.message(for: response.error, host: name)
            }
        }
    }
}
