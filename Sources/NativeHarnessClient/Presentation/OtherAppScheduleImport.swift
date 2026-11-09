import Foundation

/// A schedule the Claude app or the Codex app keeps, read for importing. The
/// files are the apps' own and undocumented, so they are only read, and any key may be missing.
/// Importing copies a schedule into Yardlet; the original stays as it is in its app, which runs it
/// while that app is open.
struct ImportableSchedule: Identifiable, Equatable, Sendable {
    /// What a run of the original goes on with.
    enum Link: Equatable, Sendable {
        case none
        /// The Claude app session the task reports to (`notifySessionId`, `local_…`).
        case claudeAppSession(String)
        /// The Codex thread a heartbeat sends to (`target_thread_id`).
        case codexThread(String)
    }

    let origin: ScheduleOrigin
    let name: String
    /// Nil when the prompt could not be read; such a row cannot be imported.
    let prompt: String?
    /// Nil when Yardlet has no trigger for the original's repeat rule (`rule`).
    let trigger: ScheduleTrigger?
    /// The original's cron expression or RRULE, as written.
    let rule: String?
    /// On in its app.
    let isEnabled: Bool
    let harness: HarnessKind
    let workspacePath: String?
    let model: String?
    let effort: String?
    let permissionMode: String?
    let startsInNewWorktree: Bool
    let link: Link

    var id: String { "\(origin.app.rawValue):\(origin.sourceID)" }

    /// Whether it can come into Yardlet at all.
    var canImport: Bool { prompt != nil && trigger != nil }

    /// On in its app and still ahead: a repeating schedule, or a one-off whose moment has not passed.
    func isUpcoming(now: Date) -> Bool {
        guard isEnabled, let trigger else { return false }
        if case let .once(moment) = trigger { return moment > now }
        return true
    }
}

/// Reads the two apps' schedule files and turns each into a Yardlet schedule.
enum OtherAppScheduleImport {
    static let maximumFileBytes = 4 * 1_048_576
    static let maximumPromptBytes = 1_048_576

    // MARK: - Claude app

    /// One `scheduled-tasks.json` (`claude-code-sessions/<account>/<organization>/`). `prompt` reads a
    /// task's prompt file (`filePath`, a `SKILL.md`). Unknown or malformed entries are left out.
    static func claudeSchedules(from data: Data, prompt: (_ filePath: String?, _ id: String) -> String?) -> [ImportableSchedule] {
        guard data.count <= maximumFileBytes,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tasks = root["scheduledTasks"] as? [[String: Any]] else { return [] }
        return tasks.compactMap { task -> ImportableSchedule? in
            guard let id = text(task["id"]) else { return nil }
            let rule = text(task["cronExpression"])
            let trigger: ScheduleTrigger?
            if let fireAt = milliseconds(task["fireAt"]) {
                trigger = .once(fireAt)
            } else if let rule {
                trigger = cronTrigger(rule)
            } else {
                return nil
            }
            let body = prompt(text(task["filePath"]), id).map(skillPrompt)
            let cwd = text(task["cwd"]).flatMap { PathRules.current.isAbsolute($0) ? $0 : nil }
            return ImportableSchedule(
                origin: ScheduleOrigin(app: .claudeApp, sourceID: id),
                name: text(task["displayName"]) ?? body?.name ?? id,
                prompt: body.flatMap { $0.prompt.isEmpty ? nil : $0.prompt },
                trigger: trigger, rule: rule,
                isEnabled: (task["enabled"] as? Bool) == true,
                harness: .claudeCode, workspacePath: cwd,
                model: text(task["model"]) ?? body?.model, effort: nil,
                permissionMode: claudePermissionMode(text(task["permissionMode"])),
                startsInNewWorktree: (task["useWorktree"] as? Bool) == true,
                link: text(task["notifySessionId"]).map { .claudeAppSession($0) } ?? .none)
        }
    }

    /// A `SKILL.md`'s frontmatter `name` and `model`, and its body as the prompt.
    static func skillPrompt(_ text: String) -> (name: String?, model: String?, prompt: String) {
        var lines = text.components(separatedBy: "\n")
        var fields: [String: String] = [:]
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            for line in lines[1..<end] {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                    value = String(value.dropFirst().dropLast())
                }
                fields[key] = value
            }
            lines.removeSubrange(0...end)
        }
        let prompt = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (fields["name"].flatMap { $0.isEmpty ? nil : $0 }, fields["model"].flatMap { $0.isEmpty ? nil : $0 }, prompt)
    }

    /// The Claude app's mode in the spelling Yardlet's Claude Code menu keeps (`default` is Manual).
    static func claudePermissionMode(_ mode: String?) -> String? {
        guard let mode else { return nil }
        if mode == "default" { return ClaudePermissionMode.manual }
        return ClaudePermissionMode.selectable.contains(mode) ? mode : nil
    }

    /// A five-field cron expression in local time, where Yardlet has the same trigger: a time every
    /// day or on some weekdays, or every N hours (N dividing a day). Anything else is nil.
    static func cronTrigger(_ expression: String, calendar: Calendar = .autoupdatingCurrent) -> ScheduleTrigger? {
        let fields = expression.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5, fields[2] == "*", fields[3] == "*",
              let minute = Int(fields[0]), (0...59).contains(minute),
              let days = cronDays(fields[4]) else { return nil }
        let hour = fields[1]
        if let hour = Int(hour), (0...23).contains(hour) {
            let time = ScheduleTime(hour: hour, minute: minute)
            return days == ScheduleWeekday.everyDay ? .daily(time) : .weekly(days: days, time: time)
        }
        let step: Int
        if hour == "*" {
            step = 1
        } else if hour.hasPrefix("*/"), let value = Int(hour.dropFirst(2)), value > 0, 24 % value == 0 {
            step = value
        } else {
            return nil
        }
        // Cron's hours divisible by N: counted from a midnight, at the minute.
        let anchor = calendar.date(bySettingHour: 0, minute: minute, second: 0,
                                   of: calendar.startOfDay(for: Date(timeIntervalSince1970: 0))) ?? Date(timeIntervalSince1970: 0)
        return .interval(hours: step, anchor: anchor, days: days == ScheduleWeekday.everyDay ? [] : days)
    }

    /// Cron's day-of-week field: `*`, numbers 0–7 (0 and 7 are Sunday), names, lists and ranges.
    static func cronDays(_ field: String) -> Set<ScheduleWeekday>? {
        if field == "*" { return ScheduleWeekday.everyDay }
        let names = ["sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6]
        func number(_ text: Substring) -> Int? {
            if let value = Int(text), (0...7).contains(value) { return value % 7 }
            return names[text.lowercased()]
        }
        var days = Set<ScheduleWeekday>()
        for part in field.split(separator: ",") {
            let bounds = part.split(separator: "-")
            switch bounds.count {
            case 1:
                guard let day = number(bounds[0]) else { return nil }
                days.insert(ScheduleWeekday(rawValue: day + 1)!)
            case 2:
                // The end may be 7 (Sunday), so "1-7" runs Monday to Sunday.
                guard let start = number(bounds[0]), let end = Int(bounds[1]) ?? names[bounds[1].lowercased()],
                      (0...7).contains(end), start <= end else { return nil }
                for day in start...end { days.insert(ScheduleWeekday(rawValue: day % 7 + 1)!) }
            default:
                return nil
            }
        }
        return days.isEmpty ? nil : days
    }

    // MARK: - Codex app

    /// One `automation.toml` (`$CODEX_HOME/automations/<id>/`). Only version 1 files with a kind the
    /// Codex app itself reads are taken: a `heartbeat` that names its thread, or a `cron` that names
    /// its folders.
    static func codexSchedule(fromTOML text: String) -> ImportableSchedule? {
        guard text.utf8.count <= maximumFileBytes, let values = try? MinimalTOML.parse(text) else { return nil }
        if let version = values["version"]?.integer, version != 1 { return nil }
        guard let id = values["id"]?.string, let name = values["name"]?.string,
              let prompt = values["prompt"]?.string, let status = values["status"]?.string,
              status != "DELETED" else { return nil }
        let rule = values["rrule"]?.string
        let createdAt = values["created_at"]?.integer.map { Date(timeIntervalSince1970: Double($0) / 1_000) }
        let trigger = rule.flatMap { rruleTrigger($0, createdAt: createdAt ?? Date()) }
        let link: ImportableSchedule.Link
        var workspace: String?
        switch values["kind"]?.string ?? "cron" {
        case "heartbeat":
            guard let thread = values["target_thread_id"]?.string?.trimmingCharacters(in: .whitespaces),
                  !thread.isEmpty else { return nil }
            link = .codexThread(thread)
        case "cron":
            guard let cwds = values["cwds"]?.array?.compactMap(\.string) else { return nil }
            workspace = cwds.first { PathRules.current.isAbsolute($0) }
            link = .none
        default:
            return nil
        }
        let model = values["model"]?.string?.trimmingCharacters(in: .whitespaces)
        return ImportableSchedule(
            origin: ScheduleOrigin(app: .codexApp, sourceID: id), name: name,
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : prompt,
            trigger: trigger, rule: rule, isEnabled: status == "ACTIVE", harness: .codex,
            workspacePath: workspace, model: model?.isEmpty == false ? model : nil,
            effort: values["reasoning_effort"]?.string, permissionMode: nil,
            startsInNewWorktree: values["execution_environment"]?.string == "worktree", link: link)
    }

    /// An RRULE the Codex app writes, where Yardlet has the same trigger: `FREQ=DAILY` or `WEEKLY`
    /// at one `BYHOUR`/`BYMINUTE` (with `BYDAY`), or `FREQ=HOURLY;INTERVAL=N` (1–24) at a minute.
    /// An hourly rule counts from the hour it was created, at its minute.
    static func rruleTrigger(_ text: String, createdAt: Date, calendar: Calendar = .autoupdatingCurrent) -> ScheduleTrigger? {
        guard let line = text.components(separatedBy: .newlines)
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { $0.uppercased().hasPrefix("RRULE:") || ($0.contains("FREQ=") && !$0.uppercased().hasPrefix("DTSTART")) })
        else { return nil }
        let body = line.uppercased().hasPrefix("RRULE:") ? String(line.dropFirst(6)) : line
        var parts: [String: String] = [:]
        for pair in body.split(separator: ";") {
            let items = pair.split(separator: "=", maxSplits: 1)
            guard items.count == 2 else { return nil }
            parts[items[0].uppercased()] = String(items[1]).uppercased()
        }
        let known: Set<String> = ["FREQ", "INTERVAL", "BYHOUR", "BYMINUTE", "BYSECOND", "BYDAY", "WKST"]
        guard Set(parts.keys).isSubset(of: known) else { return nil }
        let interval = parts["INTERVAL"].map { Int($0) } ?? 1
        guard let interval, interval > 0 else { return nil }
        var minute = 0
        if let text = parts["BYMINUTE"] {
            guard let value = Int(text), (0...59).contains(value) else { return nil }
            minute = value
        }
        var hour: Int?
        if let text = parts["BYHOUR"] {
            guard let value = Int(text), (0...23).contains(value) else { return nil }
            hour = value
        }
        if let second = parts["BYSECOND"], second != "0" { return nil }
        var days = ScheduleWeekday.everyDay
        if let byDay = parts["BYDAY"] {
            let names = ["SU": ScheduleWeekday.sunday, "MO": .monday, "TU": .tuesday, "WE": .wednesday,
                         "TH": .thursday, "FR": .friday, "SA": .saturday]
            var chosen = Set<ScheduleWeekday>()
            for name in byDay.split(separator: ",") {
                guard let day = names[String(name)] else { return nil }
                chosen.insert(day)
            }
            guard !chosen.isEmpty else { return nil }
            days = chosen
        }
        switch parts["FREQ"] {
        case "DAILY", "WEEKLY":
            guard interval == 1, parts["FREQ"] == "DAILY" || parts["BYDAY"] != nil, let hour else { return nil }
            let time = ScheduleTime(hour: hour, minute: minute)
            return days == ScheduleWeekday.everyDay ? .daily(time) : .weekly(days: days, time: time)
        case "HOURLY":
            guard ScheduleTrigger.intervalHours.contains(interval), hour == nil else { return nil }
            let hourStart = calendar.dateInterval(of: .hour, for: createdAt)?.start ?? createdAt
            let anchor = hourStart.addingTimeInterval(Double(minute) * 60)
            return .interval(hours: interval, anchor: anchor, days: days == ScheduleWeekday.everyDay ? [] : days)
        default:
            return nil
        }
    }

    // MARK: - Into Yardlet

    /// The Yardlet schedule an imported one becomes. `linkedTask` is the Yardlet task the original
    /// goes on with (the Claude session it reports to, the Codex thread a heartbeat sends to), when
    /// that conversation is in Yardlet; `projectID` the project owning its folder.
    static func schedule(from item: ImportableSchedule, linkedTask: UUID?, projectID: UUID?) -> ScheduledTask? {
        guard let prompt = item.prompt, let trigger = item.trigger else { return nil }
        var destination = ScheduleDestination(
            harness: item.harness, workspacePath: item.workspacePath, projectID: item.workspacePath == nil ? nil : projectID,
            startsInNewWorktree: item.startsInNewWorktree)
        if item.model != nil || item.effort != nil || item.permissionMode != nil {
            destination.modelChoice = NewTaskModelChoice(model: item.model, effort: item.effort,
                                                         permissionMode: item.permissionMode)
        }
        switch item.link {
        case .codexThread:
            if let linkedTask {
                destination.mode = .continueTask
                destination.targetTaskID = linkedTask
            }
        case .claudeAppSession:
            destination.parentTaskID = linkedTask
        case .none:
            break
        }
        return ScheduledTask(name: item.name, prompt: prompt, trigger: trigger, destination: destination,
                             isEnabled: item.isEnabled, origin: item.origin)
    }

    /// What the import sheet says under a row.
    static func notes(for item: ImportableSchedule, linkedTask: UUID?, isImported: Bool) -> [String] {
        if isImported { return [L10n.string("Already in Yardlet")] }
        var notes: [String] = []
        if item.prompt == nil { notes.append(L10n.string("Its prompt could not be read.")) }
        if item.trigger == nil {
            notes.append(L10n.string("Yardlet cannot repeat it on this rule."))
        }
        if case .codexThread = item.link, linkedTask == nil {
            notes.append(L10n.string("The Codex task it continues is not in Yardlet, so each run starts a new chat."))
        }
        return notes
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Epoch milliseconds. A JSON boolean reads as a number too; no real moment is that small.
    private static func milliseconds(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber, number.doubleValue > 1_000_000 else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue / 1_000)
    }
}
