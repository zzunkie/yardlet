import Foundation
import YardletAgentTools

// Yardlet's own approvals for agent tool calls (docs/AGENT_BROWSER_TOOLS.md, "Approvals"). They are weighed
// where a tool actually runs, here, rather than by the name the harness saw, so a call made inside
// `run_yardlet_script`, `call_connector_tool`, `call_simulator_tool` or `browser_batch` is weighed as a direct
// one would be, and a harness's own card is not followed by a second one:
//
// - A read-only task (Plan, Codex's read-only) runs only what changes nothing: the read-only tools, scrolling
//   and resizing its own tab, a child task or subagent (which inherit read-only), and the wrappers, whose calls
//   are weighed one by one. Anything else is refused.
// - In a task that asks the person, a connector's reads ask once per service for the task, and every connector
//   write, scheduled-task change and saved sign-in fill asks each time, unless Claude Code's CLI just asked on
//   its own card for that direct call. A browser batch that clicks, types, navigates or runs script asks once,
//   on one card listing those actions, and a script's browser action asks as the harness would for a direct one.
// - A task that runs without asking (Bypass permissions, Full access) is not asked.

extension AgentToolBroker {
    /// The browser tools a batch or a script asks about: every one not marked read-only, so a new one is asked
    /// about too, less scrolling and resizing the tab (`readOnlyTaskAlsoRuns`), the handoff, which gives the tab
    /// to the person, and the batch itself, whose actions are weighed one by one.
    static let changingBrowserTools: Set<String> = Set(AgentToolCatalog.browserTools.filter {
        !$0.readOnly && !readOnlyTaskAlsoRuns.contains($0.name) && $0.name != AgentToolCatalog.handoff
            && $0.name != AgentToolCatalog.batch
    }.map(\.name))

    /// Tools a read-only task may run beside the read-only ones: scrolling and resizing its own tab change only
    /// what it sees, and a child task or subagent runs read-only too (`SessionToolCaller.permission`).
    static let readOnlyTaskAlsoRuns: Set<String> = [
        AgentToolCatalog.scroll, AgentToolCatalog.resize, SessionToolCatalog.runAgent, SessionToolCatalog.createTask
    ]

    /// Why one of Yardlet's own tools may not run for this caller, or nil to run it, having asked the person
    /// where that is the rule.
    func approvalRefusal(tool: String, arguments: ToolJSON, sessionID: UUID,
                         origin: AgentToolCallOrigin) async -> AgentToolResult? {
        guard let approvals, let policy = approvals.agentToolPolicy(callerID: sessionID) else { return nil }
        let actions = tool == AgentToolCatalog.batch ? Self.batchActions(arguments) : []
        if policy.readOnly {
            if tool == AgentToolCatalog.batch {
                if let action = actions.first(where: { !Self.readOnlyTaskRuns($0.name) }) {
                    return Self.readOnlyRefusal(action.name)
                }
            } else if !Self.readOnlyTaskRuns(tool) {
                return Self.readOnlyRefusal(tool)
            }
        }
        guard policy.asksPerson else { return nil }
        let harnessAsked = origin == .direct && policy.harnessAsksBeforeDirectCalls
        let request: (title: String, detail: String)?
        if ScheduleToolCatalog.changingTools.contains(tool) {
            guard !harnessAsked else { return nil }
            request = ScheduleToolApproval.request(toolName: Self.claudeName(tool), input: JSONValue(arguments),
                                                   asking: .task)
        } else if tool == VaultToolCatalog.fillCredential {
            guard !harnessAsked else { return nil }
            let item = arguments["item"]?.stringValue ?? ""
            request = (L10n.string("Allow this task to fill a saved sign-in?"),
                       item.isEmpty ? "" : L10n.format("Item: %@", item))
        } else if tool == AgentToolCatalog.batch {
            let changing = actions.filter { Self.changingBrowserTools.contains($0.name) }
            guard !changing.isEmpty else { return nil }
            request = (L10n.string("Allow this task to run these browser actions?"),
                       changing.map { Self.browserActionLine($0.name, $0.input) }.joined(separator: "\n"))
        } else if origin == .wrapped, Self.changingBrowserTools.contains(tool) {
            request = (L10n.string("Allow this task to run this browser action?"),
                       Self.browserActionLine(tool, arguments))
        } else {
            request = nil
        }
        guard let request else { return nil }
        let allowed = await approvals.askPerson(title: request.title, detail: request.detail, callerID: sessionID)
        // A call cancelled while it waited (a script out of time) does nothing, whatever the answer.
        return allowed && !Task.isCancelled ? nil : Self.declined(tool)
    }

    /// Why a connector's tool may not run for this caller, or nil to run it (also when no connector has a tool
    /// of this name), having asked the person where that is the rule.
    func connectorApprovalRefusal(tool: String, sessionID: UUID, origin: AgentToolCallOrigin,
                                  arguments: ToolJSON) async -> AgentToolResult? {
        guard let approvals, let policy = approvals.agentToolPolicy(callerID: sessionID),
              let facts = connectors?.connectorToolFacts(named: tool, for: connectorContext(sessionID)) else { return nil }
        if policy.readOnly, !facts.readOnly { return Self.readOnlyRefusal(tool) }
        guard policy.asksPerson else { return nil }
        let harnessAsked = origin == .direct && policy.harnessAsksBeforeDirectCalls
        guard facts.readOnly else {
            guard !harnessAsked else { return nil }
            let claudeName = Self.claudeName(tool)
            let input = JSONValue(arguments)
            let draft = GmailToolApproval.readsDraft(toolName: claudeName)
                ? await GmailToolApproval.draft(toolName: claudeName, input: input) : nil
            let detail = GoogleToolApproval.request(toolName: claudeName, input: input, mailDraft: draft)?.detail
                ?? Self.argumentPreview(arguments)
            // The account it acts in leads the card: the one the call names, for a tool the accounts share.
            let named = arguments[ConnectorToolNaming.accountArgument]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let account = named?.isEmpty == false ? named : facts.account
            let allowed = await approvals.askPerson(
                title: L10n.format("Allow this task to use %@ in %@?", facts.title, facts.service),
                detail: account.map { L10n.format("Account: %@", $0) + (detail.isEmpty ? "" : "\n\n" + detail) } ?? detail,
                callerID: sessionID)
            return allowed && !Task.isCancelled ? nil : Self.declined(tool)
        }
        let host = policy.hostTaskID
        if approvedReadServices[host]?.contains(facts.service) == true { return nil }
        if harnessAsked {
            // The person just allowed this read on the CLI's card: the task's other reads there need no other.
            approvedReadServices[host, default: []].insert(facts.service)
            return nil
        }
        let key = "\(host.uuidString)|\(facts.service)"
        let question: PendingReadApproval
        // A question just withdrawn is not joined: it answers no.
        if let pending = pendingReadApprovals[key], !pending.answer.isCancelled {
            question = pending
        } else {
            let title = L10n.format("Allow this task to read from %@?", facts.service)
            let detail = L10n.format("First read: %@. Its later reads from %@ go without asking.", facts.title,
                                     facts.service)
            question = PendingReadApproval(Task { await approvals.askPerson(title: title, detail: detail,
                                                                            callerID: sessionID) })
            pendingReadApprovals[key] = question
        }
        question.waiters += 1
        // The card goes once every call waiting on it was cancelled.
        let allowed = await withTaskCancellationHandler {
            await question.answer.value
        } onCancel: {
            Task { @MainActor in question.leave() }
        }
        // Only the question this call waited on is cleared: a later one may stand in its place already.
        if pendingReadApprovals[key] === question { pendingReadApprovals[key] = nil }
        if allowed { approvedReadServices[host, default: []].insert(facts.service) }
        return allowed && !Task.isCancelled ? nil : Self.declined(tool)
    }

    /// Whether a read-only task may run one of Yardlet's own tools. A wrapper runs, and each call it makes is
    /// weighed as it comes; a name of no tool of Yardlet's is a connector's, weighed by its own annotation.
    static func readOnlyTaskRuns(_ tool: String) -> Bool {
        guard let definition = ownDefinition(named: tool) else { return true }
        return definition.readOnly || readOnlyTaskAlsoRuns.contains(tool)
    }

    static func readOnlyRefusal(_ tool: String) -> AgentToolResult {
        .failure("This task is read-only (Plan or read-only mode), so Yardlet did not run \(tool), which changes "
            + "something. Read and report instead, or ask the person to switch the task's mode.",
            .refused, retry: .no, details: ["tool": .string(tool)])
    }

    static func declined(_ tool: String) -> AgentToolResult {
        .failure("The person declined \(tool) on Yardlet's card, so it did not run. Do not call it again unless "
            + "they ask for it.", .refused, retry: .no, details: ["tool": .string(tool)])
    }

    /// The actions a `browser_batch` call names, in order.
    static func batchActions(_ arguments: ToolJSON) -> [(name: String, input: ToolJSON)] {
        guard case let .array(items)? = arguments["actions"] else { return [] }
        return items.map { ($0["name"]?.stringValue ?? "", $0["input"] ?? .object([:])) }
    }

    /// One line naming a browser action and what it acts on, for a card.
    static func browserActionLine(_ tool: String, _ input: ToolJSON) -> String {
        let title = AgentToolCatalog.definition(named: tool)?.title ?? tool
        for key in ["url", "text", "key", "function", "expression", "values", "paths", "ref"] {
            guard let value = input[key], value != .null else { continue }
            let text = value.stringValue ?? compactJSON(value)
            return "\(title): \(text.count > 200 ? String(text.prefix(200)) + "…" : text)"
        }
        return title
    }

    static func argumentPreview(_ arguments: ToolJSON) -> String {
        let text = compactJSON(arguments)
        return text.count > 1_200 ? String(text.prefix(1_200)) + "…" : text
    }

    private static func compactJSON(_ value: ToolJSON) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private static func claudeName(_ tool: String) -> String {
        "mcp__\(AgentToolEnvironment.serverName)__\(tool)"
    }
}

/// A first read's question that calls for the same task and service wait on together.
@MainActor
final class PendingReadApproval {
    let answer: Task<Bool, Never>
    var waiters = 0

    init(_ answer: Task<Bool, Never>) { self.answer = answer }

    /// A waiting call was cancelled; once none waits, the question is withdrawn and its card goes.
    func leave() {
        waiters -= 1
        if waiters <= 0 { answer.cancel() }
    }
}

/// The Yardlet tools a harness's own card asks about each time, offering no allow for the conversation or for
/// good: a connector's write, a scheduled-task change, a saved sign-in fill, and the wrappers, whose calls
/// Yardlet weighs one by one. A lasting allow on the harness's card would let later such calls go unasked.
enum AgentToolHarnessApproval {
    /// Yardlet's own tools that a harness's card may offer a lasting allow for.
    private static let ownToolsWithLastingAllow: Set<String> = {
        let catalogs: [[AgentToolDefinition]] = [
            AgentToolCatalog.browserTools, TaskSuggestionToolCatalog.tools, SessionToolCatalog.tools,
            SettingsToolCatalog.tools, ScheduleToolCatalog.tools, SimulatorToolCatalog.tools,
            SimulatorGatewayToolCatalog.tools, ConnectorGatewayToolCatalog.staticTools, CodeModeToolCatalog.tools,
            [VaultToolCatalog.tool, TerminalToolCatalog.tool, WidgetToolCatalog.tool]
        ]
        let asked: Set<String> = ScheduleToolCatalog.changingTools.union([
            VaultToolCatalog.fillCredential, CodeModeToolCatalog.runScript, ConnectorGatewayToolCatalog.callTool,
            SimulatorGatewayToolCatalog.callTool, AgentToolCatalog.batch
        ])
        return Set(catalogs.joined().map(\.name)).subtracting(asked)
    }()

    /// True unless the tool is known to only read: a connector's tool whose label says so, or one of Yardlet's own
    /// tools other than the ones asked each time. A name Yardlet does not know yet (a connector whose labels have
    /// not come) is asked each time.
    static func asksEachTime(tool: String, labels: ConnectorToolLabels = .shared) -> Bool {
        if ownToolsWithLastingAllow.contains(tool) { return false }
        if let label = labels.label(forTool: tool) { return !label.readOnly }
        return true
    }

    /// The same for Claude Code's name of the tool (`mcp__yardlet__…`); false for any other server's.
    static func asksEachTime(claudeToolName: String?, labels: ConnectorToolLabels = .shared) -> Bool {
        let prefix = "mcp__\(AgentToolEnvironment.serverName)__"
        guard let claudeToolName, claudeToolName.hasPrefix(prefix) else { return false }
        return asksEachTime(tool: String(claudeToolName.dropFirst(prefix.count)), labels: labels)
    }
}
