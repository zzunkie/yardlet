import Foundation
import YardletAgentTools

/// What Claude Code's request card says for a Yardlet scheduled-task call that changes something,
/// as the Claude app's card says it ("Allow Claude to create the routine {title}?" over its prompt
/// and schedule): the action and the schedule's name, then its schedule, where each run goes, and
/// its prompt. Claude Code asks before each such call (`ScheduleToolCatalog.changingTools`); without
/// this the card would name only the tool.
enum ScheduleToolApproval {
    /// `mcp__yardlet__create_scheduled_task` and the other changing calls; nil for any other tool.
    static func tool(named claudeToolName: String?) -> String? {
        let prefix = "mcp__\(AgentToolEnvironment.serverName)__"
        guard let claudeToolName, claudeToolName.hasPrefix(prefix) else { return nil }
        let tool = String(claudeToolName.dropFirst(prefix.count))
        return ScheduleToolCatalog.changingTools.contains(tool) ? tool : nil
    }

    /// Whose card it is: Claude Code's, or Yardlet's own for a task whose harness did not ask
    /// (`AgentToolBroker+Approvals`), which names the task rather than Claude.
    enum Asker { case claude, task }

    static func request(toolName: String?, input: JSONValue, asking asker: Asker = .claude,
                        calendar: Calendar = .autoupdatingCurrent, now: Date = Date(),
                        name lookup: (UUID) -> String? = { ScheduleNameDirectory.shared.name(of: $0) },
                        mode modeLookup: (UUID) -> String? = { ScheduleNameDirectory.shared.mode(of: $0) })
        -> (title: String, detail: String)? {
        typealias Key = ScheduleToolCatalog.Key
        guard let tool = tool(named: toolName) else { return nil }
        let id = input[Key.scheduleID]?.stringValue.flatMap(UUID.init(uuidString:))
        let existing = id.flatMap(lookup)
        let given = input[Key.name]?.stringValue.map(ScheduleToolCatalog.oneLine)?
            .trimmingCharacters(in: .whitespaces)
        let prompt = input[Key.prompt]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = []
        if let schedule = scheduleLine(input, calendar: calendar, now: now) { lines.append(schedule) }
        let title: String
        switch tool {
        case ScheduleToolCatalog.create:
            let name = given.flatMap { $0.isEmpty ? nil : $0 }
                ?? prompt.map(SessionTitleProjection.provisionalTitle(from:)) ?? ""
            title = asker == .claude ? L10n.format("Allow Claude to create the scheduled task “%@”?", name)
                : L10n.format("Allow this task to create the scheduled task “%@”?", name)
            lines.append(input[Key.continueTaskID] == nil
                         ? L10n.string("Each run starts a new task.") : L10n.string("Each run continues a task."))
            lines += placeLines(input)
        case ScheduleToolCatalog.update:
            title = asker == .claude
                ? existing.map { L10n.format("Allow Claude to update the scheduled task “%@”?", $0) }
                    ?? L10n.string("Allow Claude to update a scheduled task?")
                : existing.map { L10n.format("Allow this task to update the scheduled task “%@”?", $0) }
                    ?? L10n.string("Allow this task to update a scheduled task?")
            if let given, !given.isEmpty, given != existing { lines.append(L10n.format("New name: %@", given)) }
            if case let .bool(enabled)? = input[Key.enabled] {
                lines.append(enabled ? L10n.string("Resumes its runs.") : L10n.string("Pauses its runs."))
            }
            if Key.destination.contains(where: { input[$0] != nil }) {
                lines.append(L10n.string("Changes where each run goes."))
                lines += placeLines(input)
            }
        case ScheduleToolCatalog.delete:
            title = asker == .claude
                ? existing.map { L10n.format("Allow Claude to delete the scheduled task “%@”?", $0) }
                    ?? L10n.string("Allow Claude to delete a scheduled task?")
                : existing.map { L10n.format("Allow this task to delete the scheduled task “%@”?", $0) }
                    ?? L10n.string("Allow this task to delete a scheduled task?")
            lines.append(L10n.string("It will not run again. The tasks its runs started stay in the sidebar."))
        default:
            title = asker == .claude
                ? existing.map { L10n.format("Allow Claude to run the scheduled task “%@” now?", $0) }
                    ?? L10n.string("Allow Claude to run a scheduled task now?")
                : existing.map { L10n.format("Allow this task to run the scheduled task “%@” now?", $0) }
                    ?? L10n.string("Allow this task to run a scheduled task now?")
            lines.append(L10n.string("It starts now with the schedule's own settings."))
        }
        if let mode = input[Key.permissionMode]?.stringValue, !mode.isEmpty {
            // In the words of the harness the runs start on: the caller's (Claude Code's) unless the call names another.
            let harness = input[Key.harness]?.stringValue.flatMap(HarnessCatalog.harness(named:)) ?? .claudeCode
            let name = NewTaskModelChoice.permission(fromTool: mode, harness: harness)
                .map { $0.permissionName(for: harness) ?? L10n.string("Default") }
            lines.append(L10n.format("Its runs will use %@ mode.", name ?? mode))
        } else if let mode = id.flatMap(modeLookup) {
            // A schedule that stands: the mode its runs keep, which may do more without asking than the caller may.
            lines.append(L10n.format("Its runs will use %@ mode.", mode))
        }
        var detail = lines.joined(separator: "\n")
        if let prompt, !prompt.isEmpty {
            let preview = prompt.count > 1_200 ? String(prompt.prefix(1_200)) + "…" : prompt
            let lead = tool == ScheduleToolCatalog.update ? L10n.string("New prompt:") + "\n" : ""
            detail += (detail.isEmpty ? "" : "\n\n") + lead + preview
        }
        return (title, detail)
    }

    /// The project or folder, or the task, each run goes to, as the call names them.
    private static func placeLines(_ input: JSONValue) -> [String] {
        typealias Key = ScheduleToolCatalog.Key
        var lines: [String] = []
        if let task = input[Key.continueTaskID]?.stringValue, !task.isEmpty, task != SessionToolCatalog.selfReference {
            lines.append(L10n.format("Task: %@", task))
        }
        if let place = input[Key.project]?.stringValue, !place.isEmpty {
            lines.append(L10n.format("Project or folder: %@", place))
        }
        return lines
    }

    /// "Every day at 9:00 AM", "Once, Tomorrow at 9:00 AM", or the cron text Yardlet cannot repeat.
    private static func scheduleLine(_ input: JSONValue, calendar: Calendar, now: Date) -> String? {
        if let cron = input[ScheduleToolCatalog.Key.cronExpression]?.stringValue, !cron.isEmpty {
            guard let trigger = OtherAppScheduleImport.cronTrigger(cron, calendar: calendar) else { return cron }
            return ScheduleText.summary(trigger, calendar: calendar, now: now)
        }
        if let text = input[ScheduleToolCatalog.Key.fireAt]?.stringValue, !text.isEmpty {
            guard let moment = ScheduleToolText.moment(text, calendar: calendar) else { return text }
            return ScheduleText.summary(.once(moment), calendar: calendar, now: now)
        }
        return nil
    }
}

/// The schedules' names, and the mode a new task's runs start in, which an adapter's request card reads off the main
/// actor. The scheduler writes it whenever its schedules change.
final class ScheduleNameDirectory: @unchecked Sendable {
    static let shared = ScheduleNameDirectory()

    private let lock = NSLock()
    private var names: [UUID: String] = [:]
    private var modes: [UUID: String] = [:]

    func update(_ schedules: [ScheduledTask]) {
        let next = Dictionary(schedules.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let nextModes = Dictionary(schedules.compactMap { schedule in
            schedule.destination.mode == .newTask ? (schedule.id, Self.runModeName(of: schedule.destination)) : nil
        }, uniquingKeysWith: { first, _ in first })
        lock.withLock {
            names = next
            modes = nextModes
        }
    }

    func name(of id: UUID) -> String? {
        lock.withLock { names[id] }
    }

    /// The mode a new task's runs start in, in its harness's words; nil for a schedule whose runs continue a task.
    func mode(of id: UUID) -> String? {
        lock.withLock { modes[id] }
    }

    /// The permission a new task's runs start with, in its harness's words.
    static func runModeName(of destination: ScheduleDestination) -> String {
        (destination.modelChoice ?? NewTaskModelChoice(model: nil)).permissionName(for: destination.harness)
            ?? (destination.harness == .claudeCode ? L10n.string("Manual") : L10n.string("Default"))
    }
}
