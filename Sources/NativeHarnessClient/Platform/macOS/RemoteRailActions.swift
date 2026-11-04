import AppKit
import Foundation
import YardletRemote

/// Desktop dialogs and opening actions for a host task; its facts remain portable.
extension RemoteHostModel {
    /// Uses the host's existing compact command and its availability, in both context surfaces.
    func railCompact(_ taskID: String) -> ComposerContextUsageDetails.Compact? {
        guard taskControls, let facts = taskRailFacts[taskID], facts.compactOffered else { return nil }
        let running = task(taskID)?.running == true
        return ComposerContextUsageDetails.Compact(
            isAvailable: isConnected && facts.compactAvailable && !running,
            unavailableReason: running
                ? L10n.format("Available when %@ finishes this turn", task(taskID)?.harnessName ?? name)
                : L10n.string("Available when reconnected"),
            run: { [weak self] in Task { _ = await self?.runComposerCommand(taskID, name: "compact", arguments: nil) } })
    }


    private func confirmRailWrite(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: title)
        alert.addButton(withTitle: L10n.string("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func railActions(_ taskID: String, openChanges: @escaping () -> Void, draftFix: @escaping (String) -> Void) -> SessionRailActions {
        var actions = SessionRailActions()
        actions.openChanges = openChanges
        actions.compact = railCompact(taskID)
        actions.openURL = { [weak self] url in
            guard let self, !url.isFileURL else { return }
            if !openHostBrowserLink(url, taskID: taskID) { NSWorkspace.shared.open(url) }
        }
        actions.agents = SessionRailAgentActions(open: { [weak self] agent in
            if case let .childTask(id) = agent.kind { self?.select(.task(id.uuidString)) }
        }, canOpen: { agent in
            if case .childTask = agent.kind { return true }
            return false
        }, stop: { [weak self] agent in
            guard let self, let wire = taskRailFacts[taskID]?.agents.first(where: { $0.id == agent.id }) else { return }
            performRailAction(taskID, action: RemoteRailProjection.stopAction(wire.kind), targetID: wire.targetID)
        }, isStopping: { [weak self] agent in
            guard let self, let wire = taskRailFacts[taskID]?.agents.first(where: { $0.id == agent.id }) else { return false }
            let action = RemoteRailProjection.stopAction(wire.kind)
            return runningRailActions.contains(taskID + ":" + action + ":" + (wire.targetID ?? ""))
        })
        actions.backgroundTasks = HarnessActivityActions(open: { _ in }, stop: { [weak self] activity in
            self?.performRailAction(taskID, action: "stopBackground", targetID: activity.id)
        }, isStopping: { [weak self] id in
            self?.runningRailActions.contains(taskID + ":stopBackground:" + id) == true
        }, error: { _ in nil })
        actions.terminals = SessionRailTerminalActions(canOpen: false, stop: { [weak self] terminal in
            self?.performRailAction(taskID, action: "stopTerminal", targetID: terminal.processID)
        }, stopAll: { [weak self] in
            self?.performRailAction(taskID, action: "stopAllTerminals", confirmed: true)
        }, isStopping: { [weak self] id in
            self?.runningRailActions.contains(taskID + ":stopTerminal:" + id) == true
                || self?.runningRailActions.contains(taskID + ":stopAllTerminals:") == true
        })
        actions.pullRequest = SessionRailPullRequestActions(
            refresh: { [weak self] in self?.performRailAction(taskID, action: "refreshPR") },
            loadLog: { [weak self] check in self?.performRailAction(taskID, action: "loadLog", targetID: check.id) },
            closeLog: { [weak self] check in self?.performRailAction(taskID, action: "closeLog", targetID: check.id) },
            rerunFailed: { [weak self] _ in self?.performRailAction(taskID, action: "rerunFailed") },
            requestMerge: { [weak self] kind in
                self?.performRailAction(taskID, action: "requestMerge", targetID: RemoteRailProjection.mergeKey(kind))
            },
            confirmMerge: { [weak self] in
                guard let self, let facts = taskRailFacts[taskID], let pending = facts.pendingMerge else { return }
                performRailAction(taskID, action: "confirmMerge", targetID: pending + "|" + (facts.pullRequestDetail?.headSHA ?? ""), confirmed: true)
            },
            cancelMerge: { [weak self] in self?.performRailAction(taskID, action: "cancelMerge") },
            setAutoFix: { [weak self] enabled in
                guard let self else { return }
                if enabled, !confirmRailWrite(title: L10n.string("Turn on auto-fix"),
                    message: L10n.string("Fix CI")) { return }
                performRailAction(taskID, action: "setAutoFix", targetID: enabled ? "true" : "false", confirmed: true)
            }, draftFix: { [weak self] _ in
                guard let self, confirmRailWrite(title: L10n.string("Fix CI"),
                    message: L10n.string("Put a request to fix the failing checks in the composer")) else { return }
                Task {
                    let answer = await response(to: .railAction(taskID: taskID, action: "draftFix", targetID: nil, confirmed: true))
                    if answer.ok, let text = answer.output { draftFix(text) }
                    else if !answer.ok { commandError = Self.message(for: answer.error, host: name) }
                }
            })
        return actions
    }
}
