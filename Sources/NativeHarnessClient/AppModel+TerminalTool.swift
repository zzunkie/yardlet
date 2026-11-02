import Foundation
import YardletAgentTools

/// Whether the person shares a task's terminal with its agent: the agent may read the task's terminal
/// tabs (`read_terminal`), and a selection in the terminal may be attached to the person's message, as
/// the Claude app and the Codex app give their agents the terminal. On unless turned off; off, the tool
/// leaves every task's tool list at once (`AgentToolBroker.toolsMayHaveChanged`) and the terminal has no
/// attach action, with nothing kept in a harness's settings or files.
enum TerminalSharingPreference {
    static let key = "Yardlet.terminalSharing"

    static func isOn(in defaults: UserDefaults = .yardlet) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}

extension AppModel {
    /// `read_terminal`: the calling task's terminal tabs, and the last lines of one, the shown one unless
    /// `tab` names another. A subagent reads the terminal of the task it runs in. Reads the tabs Yardlet
    /// keeps and starts none.
    func readTerminal(_ arguments: JSONValue, caller: SessionToolCaller) -> AgentToolResult {
        let workspace = taskWorkspaces.loadedState(for: caller.hostTaskID)
        let tabs = workspace?.terminals ?? []
        guard let workspace, !tabs.isEmpty else { return .text("This task has no terminal tab open.") }
        let titles = TerminalTabTitle.titles(for: tabs)
        let shown = tabs.firstIndex { $0 === workspace.shownTerminal } ?? 0
        let index: Int
        if let number = Self.integer(arguments["tab"]) {
            guard tabs.indices.contains(number - 1) else {
                return .error("This task's terminal has \(tabs.count) tab\(tabs.count == 1 ? "" : "s"); tab \(number) "
                    + "is not one of them.")
            }
            index = number - 1
        } else {
            index = shown
        }
        let count = min(max(Self.integer(arguments["lines"]) ?? TerminalToolCatalog.defaultLines, 1),
                        TerminalToolCatalog.maximumLines)
        let list = tabs.enumerated().map { offset, tab in
            let title = titles[ObjectIdentifier(tab)] ?? TerminalTabTitle.defaultTitle(of: tab)
            return "\(offset + 1). \"\(title)\"\(offset == shown ? " (shown)" : ""), in "
                + "\(ShellLaunchEnvironment.directoryPath(tab.workspaceURL)): \(Self.terminalState(of: tab))"
        }
        let tab = tabs[index]
        var lines = tab.bufferText.components(separatedBy: "\n")
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        let title = titles[ObjectIdentifier(tab)] ?? TerminalTabTitle.defaultTitle(of: tab)
        let heading = lines.isEmpty
            ? "Tab \(index + 1) \"\(title)\" shows nothing yet."
            : "The last \(min(count, lines.count)) of \(lines.count) lines of tab \(index + 1) \"\(title)\":"
        return .text((["Terminal tabs (\(tabs.count)):"] + list + ["", heading] + lines.suffix(count))
            .joined(separator: "\n"))
    }

    private static func terminalState(of tab: NativeTerminalSession) -> String {
        if tab.isRunningProgram { return "a command is running" }
        if tab.isRunning { return "at its prompt" }
        if let signal = tab.terminationSignal { return "stopped by signal \(signal)" }
        if let code = tab.exitCode { return "exited (\(code))" }
        return tab.hasShell ? "stopped" : "not started"
    }
}
