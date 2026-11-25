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
// - In a task that asks the person, a connector's reads ask once per service for the task, and so do the reads of
//   the person's personal agents, once for all three tools; every connector
//   write, scheduled-task change and saved sign-in fill asks each time, unless Claude Code's CLI just asked on
//   its own card for that direct call. A browser batch that clicks, types, runs script or goes to a site not
//   allowed yet asks once, on one card listing those actions, and a script's browser action asks as the harness
//   would for a direct one.
// - Reading the task's own tabs, scrolling, resizing and opening a blank tab ask nothing (`AgentToolCatalog
//   .unaskedTools`). Where a tab goes is weighed by its site, wherever the call came from (`allowsNavigation`): a
//   blank page, a file in the task's folders and a server the task itself listens on go freely, and any other site
//   asks once, or once for the task; a download the agent's act starts from a site asks once for the task.
// - A task that runs without asking (Bypass permissions, Full access) is not asked.

extension AgentToolBroker {
    /// The browser tools a batch or a script asks about: every one not marked read-only, so a new one is asked
    /// about too, less the ones asked about by nobody (`AgentToolCatalog.unaskedTools`), the handoff, which gives the
    /// tab to the person, the batch itself, whose actions are weighed one by one, and `browser_navigate`, weighed by
    /// where it goes (`allowsNavigation`).
    nonisolated static let changingBrowserTools: Set<String> = Set(AgentToolCatalog.browserTools.filter {
        !$0.readOnly && !AgentToolCatalog.unaskedTools.contains($0.name) && $0.name != AgentToolCatalog.handoff
            && $0.name != AgentToolCatalog.batch && $0.name != AgentToolCatalog.navigate
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
        var pass: Set<String> = []
        return await approvalRefusal(tool: tool, arguments: arguments, sessionID: sessionID, origin: origin,
                                     navigationPass: &pass)
    }

    /// The same, and for a `browser_batch` the addresses its card let its navigations go to (`BrowserNavigationPass`).
    func approvalRefusal(tool: String, arguments: ToolJSON, sessionID: UUID, origin: AgentToolCallOrigin,
                         navigationPass: inout Set<String>) async -> AgentToolResult? {
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
            return await batchRefusal(actions, sessionID: sessionID, approvals: approvals, policy: policy,
                                      navigationPass: &navigationPass)
        } else if origin == .wrapped, Self.changingBrowserTools.contains(tool) {
            request = (L10n.string("Allow this task to run this browser action?"),
                       Self.browserActionLine(tool, arguments))
        } else if Self.personalAgentTools.contains(tool) {
            // Claude Code's CLI never asks about these (`claudeAllowedTools`), so Yardlet's card is the only one.
            let title = SessionToolCatalog.definition(named: tool)?.title ?? tool
            return await firstReadRefusal(
                Self.personalAgentReads, tool: tool, sessionID: sessionID, host: policy.hostTaskID, harnessAsked: false,
                title: L10n.string("Allow this task to read your personal agents?"),
                detail: L10n.format("First read: %@. Its later reads of your personal agents go without asking.",
                                    title))
        } else {
            request = nil
        }
        guard let request else { return nil }
        let allowed = await approvals.askPerson(title: request.title, detail: request.detail, callerID: sessionID)
        // A call cancelled while it waited (a script out of time) does nothing, whatever the answer.
        return allowed && !Task.isCancelled ? nil : Self.declined(tool)
    }

    /// Whether a browser batch may run, having asked the person on one card about its acting steps and the places it
    /// goes that are not allowed yet; the places that card let through go in `navigationPass`.
    private func batchRefusal(_ actions: [(name: String, input: ToolJSON)], sessionID: UUID,
                              approvals: any AgentToolApprovalHandling, policy: AgentToolCallerPolicy,
                              navigationPass: inout Set<String>) async -> AgentToolResult? {
        var lines: [String] = []
        var asked: [BrowserNavigationTarget] = []
        for action in actions {
            if action.name == AgentToolCatalog.navigate {
                guard let address = action.input["url"]?.stringValue,
                      let url = try? BrowserURLPolicy.resolve(address) else { continue }
                let target = BrowserNavigationTarget(url)
                guard await !navigationGoesUnasked(target, sessionID: sessionID, policy: policy) else { continue }
                if !asked.contains(target) { asked.append(target) }
                lines.append(Self.browserActionLine(action.name, action.input))
            } else if Self.changingBrowserTools.contains(action.name) {
                lines.append(Self.browserActionLine(action.name, action.input))
            }
        }
        guard !lines.isEmpty else { return nil }
        var detail = lines.joined(separator: "\n")
        if !asked.isEmpty {
            detail += "\n\n" + L10n.format("Not allowed in this task yet: %@", asked.map(\.cardText).joined(separator: ", "))
        }
        let sites = asked.compactMap { if case let .site(site) = $0 { site } else { nil } }
        // The sites' answer only where every place it goes is a site: a data: address is allowed once.
        let offersSites = !sites.isEmpty && sites.count == asked.count
        let answer = await approvals.askPerson(
            title: L10n.string("Allow this task to run these browser actions?"), detail: detail,
            actions: BrowserNavigationAnswer.actions(site: offersSites ? sites.map(\.text).joined(separator: ", ") : nil),
            callerID: sessionID)
        guard answer != nil, !Task.isCancelled else { return Self.declined(AgentToolCatalog.batch) }
        if BrowserNavigationAnswer(actionID: answer) == .site {
            allowedSites[policy.hostTaskID, default: []].formUnion(sites)
        }
        navigationPass = Set(asked.map(\.passKey))
        return nil
    }

    /// Whether the task's browser may go to `address`, having asked the person where that is the rule: a blank page and a
    /// file go (files outside the task's folders ask on their own card, `BrowserAgentTools.allowFile`), as do a site the
    /// person allowed for the task, a server the task itself listens on, and a place a batch's card let through; any
    /// other site, a local port no process of the task listens on, an address on the local network and a `data:`
    /// address ask. A read-only task never gets here: its navigations are refused before they run.
    func allowsNavigation(to address: String, redirectedFrom: String?, sessionID: UUID) async -> Bool {
        guard let approvals, let policy = approvals.agentToolPolicy(callerID: sessionID) else { return true }
        let target = BrowserNavigationTarget(address)
        if await navigationGoesUnasked(target, sessionID: sessionID, policy: policy) { return true }
        let site: BrowserSite? = if case let .site(site) = target { site } else { nil }
        let title = redirectedFrom == nil
            ? L10n.format("Allow this task to open %@?", target.cardText)
            : L10n.format("The page went on to %@. Allow this task to open it?", target.cardText)
        var detail = address.count > 300 ? String(address.prefix(300)) + "…" : address
        if let redirectedFrom { detail += "\n" + L10n.format("Redirected from %@", redirectedFrom) }
        let answer = await approvals.askPerson(title: title, detail: detail,
                                               actions: BrowserNavigationAnswer.actions(site: site?.text),
                                               callerID: sessionID)
        guard answer != nil, !Task.isCancelled else { return false }
        if BrowserNavigationAnswer(actionID: answer) == .site, let site {
            allowedSites[policy.hostTaskID, default: []].insert(site)
        }
        return true
    }

    /// Whether going to `target` needs no card for this caller.
    private func navigationGoesUnasked(_ target: BrowserNavigationTarget, sessionID: UUID,
                                       policy: AgentToolCallerPolicy) async -> Bool {
        guard policy.asksPerson else { return true }
        if BrowserNavigationPass.allowed.contains(target.passKey) { return true }
        switch target {
        case .blank, .file:
            return true
        case let .site(site):
            if allowedSites[policy.hostTaskID]?.contains(site) == true { return true }
            return site.isLoopbackName ? await approvals?.taskListens(on: site.port, callerID: sessionID) == true : false
        case .other:
            return false
        }
    }

    /// Whether a download the agent's act started may stay in the Downloads folder, having asked the person where that
    /// is the rule: one from a site the task already downloaded from with the person's leave, from a server the task
    /// itself listens on, or from a file goes; the first from any other site asks once for the task, and one from no
    /// site (a `data:` page, an address Yardlet does not read as a site) asks each time. `address` is where it came from
    /// (`BrowserDownload.url`, else `BrowserTab.agentDownloadAddress`); a `blob:` address is its page's site's.
    func allowsAgentDownload(from address: String?, fileName: String, sessionID: UUID) async -> Bool {
        guard let approvals, let policy = approvals.agentToolPolicy(callerID: sessionID), policy.asksPerson else {
            return true
        }
        var address = address ?? ""
        if address.lowercased().hasPrefix("blob:") { address = String(address.dropFirst(5)) }
        let target = BrowserNavigationTarget(address)
        let detail = L10n.format("File: %@", fileName) + "\n" + L10n.string("It is saving to the Downloads folder.")
        let site: BrowserSite
        switch target {
        case .blank, .file:
            return true
        case .other:
            let allowed = await approvals.askPerson(title: L10n.string("Allow this task's download?"), detail: detail,
                                                    callerID: sessionID)
            return allowed && !Task.isCancelled
        case let .site(found):
            site = found
        }
        let host = policy.hostTaskID
        if allowedDownloadSites[host]?.contains(site) == true { return true }
        if site.isLoopbackName, await approvals.taskListens(on: site.port, callerID: sessionID) { return true }
        // The person may have allowed the site meanwhile.
        if allowedDownloadSites[host]?.contains(site) == true { return true }
        let key = "\(host.uuidString)|\(site.text)"
        let question: PendingReadApproval
        // A question just withdrawn is not joined: it answers no.
        if let pending = pendingDownloadApprovals[key], !pending.answer.isCancelled {
            question = pending
        } else {
            let title = L10n.format("Allow downloads from %@ in this task?", site.text)
            question = PendingReadApproval(Task { await approvals.askPerson(title: title, detail: detail,
                                                                            callerID: sessionID) })
            pendingDownloadApprovals[key] = question
        }
        question.waiters += 1
        let allowed = await withTaskCancellationHandler {
            await question.answer.value
        } onCancel: {
            Task { @MainActor in question.leave() }
        }
        // Only the question this call waited on is cleared: a later one may stand in its place already.
        if pendingDownloadApprovals[key] === question { pendingDownloadApprovals[key] = nil }
        if allowed { allowedDownloadSites[host, default: []].insert(site) }
        return allowed && !Task.isCancelled
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
        return await firstReadRefusal(facts.service, tool: tool, sessionID: sessionID, host: policy.hostTaskID,
                                      harnessAsked: harnessAsked,
                                      title: L10n.format("Allow this task to read from %@?", facts.service),
                                      detail: L10n.format("First read: %@. Its later reads from %@ go without asking.",
                                                          facts.title, facts.service))
    }

    /// The tools that read the person's personal agents, asked about together once per task.
    static let personalAgentTools: Set<String> = [
        SessionToolCatalog.listPersonalAgents, SessionToolCatalog.readPersonalAgent,
        SessionToolCatalog.readPersonalAgentThread
    ]

    /// The key the personal agents' reads are allowed under, beside the connectors' services; no service is named so.
    static let personalAgentReads = "\u{1}personal agents"

    /// Asks once per task before its first read of `scope` (a connector's service, or the personal agents), or nil
    /// when the person allowed it already. Calls made while the question waits wait on the same card.
    private func firstReadRefusal(_ scope: String, tool: String, sessionID: UUID, host: UUID, harnessAsked: Bool,
                                  title: String, detail: String) async -> AgentToolResult? {
        guard let approvals else { return nil }
        if approvedReadServices[host]?.contains(scope) == true { return nil }
        if harnessAsked {
            // The person just allowed this read on the CLI's card: the task's other reads there need no other.
            approvedReadServices[host, default: []].insert(scope)
            return nil
        }
        let key = "\(host.uuidString)|\(scope)"
        let question: PendingReadApproval
        // A question just withdrawn is not joined: it answers no.
        if let pending = pendingReadApprovals[key], !pending.answer.isCancelled {
            question = pending
        } else {
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
        // A task released meanwhile (archived, deleted) keeps no allow: its question was withdrawn.
        if allowed, !question.answer.isCancelled, tokens[host] != nil {
            approvedReadServices[host, default: []].insert(scope)
        }
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

/// Which harness cards Yardlet's tools get (docs/AGENT_BROWSER_TOOLS.md, "Approvals"): none where Yardlet weighs the
/// call itself, and otherwise the harness's own card, offering no allow for the conversation or for good for a
/// connector's write, a scheduled-task change, a saved sign-in fill, the wrappers, whose calls Yardlet weighs one by
/// one, and `browser_navigate`, which Yardlet allows by site. A lasting allow on the harness's card would let later
/// such calls go unasked.
enum AgentToolHarnessApproval {
    /// Yardlet's own tools whose calls need no harness card: the ones Claude Code runs without its CLI's card
    /// (`AgentToolServerLaunch.claudeAllowedToolNames`), about which Yardlet asks on its own card where that is the
    /// rule, and the scheduled-task changes and saved sign-in fills, which Yardlet asks about each time unless
    /// Claude Code's CLI just did. Codex (`AgentToolServerLaunch.codexConfig`) and Antigravity (`ACPAdapter`) ask about
    /// none of these, nor about a connector's tools, so each call gets one card, Yardlet's.
    static let weighedByYardlet: Set<String> = Set(AgentToolServerLaunch.claudeAllowedToolNames)
        .union(ScheduleToolCatalog.changingTools).union([VaultToolCatalog.fillCredential])

    /// Yardlet's own tools a harness still asks about by its own rule: those that act in a page or on a device.
    static let askedByHarness: [String] = AgentToolBroker.ownToolNames.filter { !weighedByYardlet.contains($0) }.sorted()

    /// The browser tools that act in a page or on the task's tabs (`AgentToolBroker.changingBrowserTools`): a harness's
    /// card may allow them for the conversation, never for good, as Yardlet allows a site only for the task.
    static func allowsOnlyForSession(tool: String) -> Bool {
        AgentToolBroker.changingBrowserTools.contains(tool)
    }

    /// The same for Claude Code's name of the tool (`mcp__yardlet__…`); false for any other server's.
    static func allowsOnlyForSession(claudeToolName: String?) -> Bool {
        yardletTool(claudeToolName: claudeToolName).map(allowsOnlyForSession(tool:)) ?? false
    }

    private static func yardletTool(claudeToolName: String?) -> String? {
        let prefix = "mcp__\(AgentToolEnvironment.serverName)__"
        guard let claudeToolName, claudeToolName.hasPrefix(prefix) else { return nil }
        return String(claudeToolName.dropFirst(prefix.count))
    }

    /// The Yardlet tool an Antigravity permission request asks about, when it names one Yardlet can be sure of: agy
    /// titles an MCP call "Run mcp_yardlet_<hex>_<tool>" from the tool's own name, with ACP kind `other`, whatever
    /// summary the model gave (`toolSummary`, which goes in its input). The input holds only what that tool takes,
    /// and the summary.
    static func yardletTool(antigravityTitle title: String?, kind: String?, input: JSONValue?) -> String? {
        guard kind == "other", let title, title.hasPrefix("Run mcp_\(AgentToolEnvironment.serverName)_"),
              let tool = ConnectorToolLabels.yardletToolName(fromHarnessTool: title),
              title.hasSuffix("_\(tool)"),
              let definition = AgentToolBroker.ownDefinition(named: tool) else { return nil }
        let takes = Set(definition.inputSchema["properties"]?.objectValue.map { Array($0.keys) } ?? []).union(["toolSummary"])
        switch input {
        case nil, .null?: return tool
        case let .object(fields)?: return Set(fields.keys).isSubset(of: takes) ? tool : nil
        default: return nil
        }
    }

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
            SimulatorGatewayToolCatalog.callTool, AgentToolCatalog.batch, AgentToolCatalog.navigate
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
