import Foundation
import Observation

/// Yardlet instructions: text the person writes once in Settings (and, for a project, in its edit sheet)
/// that Yardlet hands to every agent it starts or resumes, through each harness's own per-process
/// or per-session route. Nothing is written to a harness's files (`~/.codex/AGENTS.md`, `CLAUDE.md`,
/// `GEMINI.md`, `APPEND_SYSTEM.md`, an account's settings); turned off, the next launch carries
/// nothing (the user's decision, 2026-10-16). The text is the person's own; Yardlet adds no heading
/// or wording of its own.
struct YardletInstructionsDelivery: Hashable, Sendable {
    /// The text as sent: the global text, then the task's project's text, each without its leading
    /// and trailing blank space and joined by one blank line. The same bytes on every launch and
    /// turn until the person edits one of them.
    let text: String
}

/// The route each harness offers. Read from each CLI's own `--help`, schema or bundled source on
/// 2026-10-16, with no model turn:
/// - Claude Code 2.1.291 — `--append-system-prompt <prompt>` ("Append a system prompt to the
///   default system prompt"; `-file` exists too). CLAUDE.md loading is unaffected.
/// - Codex 0.163.0 — App Server `developerInstructions` on `thread/start`, `thread/resume` and
///   `thread/fork` (`generate-json-schema`). It is a developer message apart from AGENTS.md (user
///   instructions); since it overrides the configuration's own `developer_instructions`, Yardlet
///   reads that first (`config/read`) and sends it ahead of its text.
/// - Grok Build 1.0.30 — `grok agent stdio` has no `--rules` (that is the TUI's flag); its ACP
///   documents `_meta.rules` on `session/new`, "Extra rules appended to the system prompt".
/// - Pi 0.84.1 — `--append-system-prompt <text>` (repeatable) on the `pi --mode rpc` launch. It
///   replaces the APPEND_SYSTEM.md Pi would find, so Yardlet passes the global one ahead of its
///   text and leaves a project that has its own unchanged.
/// - None: OpenCode (`opencode acp` has no option; its per-process `OPENCODE_CONFIG_CONTENT` would
///   do, but one OpenCode process serves the tasks of every folder and reads it once, so it could
///   follow neither a project's text nor its switch), `muse serve` (only an internal evaluation
///   variable), `kimi acp` (no options), `hermes acp` (its ephemeral prompt is read by the TUI and
///   gateway only), `cursor-agent`, and `agy` (print mode has no such flag and its `--add-dir` route
///   was removed on purpose; `agy acp` advertises `_meta.antigravity.systemPrompt` in `initialize`
///   but documents no shape for it).
enum YardletInstructionsRoute: String, CaseIterable, Sendable {
    case claudeAppendSystemPrompt
    case codexDeveloperInstructions
    case grokSessionRules
    case piAppendSystemPrompt

    static func route(for harness: HarnessKind) -> YardletInstructionsRoute? {
        switch harness {
        case .claudeCode: .claudeAppendSystemPrompt
        case .codex: .codexDeveloperInstructions
        case .grokBuild: .grokSessionRules
        case .pi: .piAppendSystemPrompt
        default: nil
        }
    }

    /// The built-in harnesses that receive nothing, in catalog order, for Settings to name.
    static var unsupportedHarnesses: [HarnessKind] {
        HarnessCatalog.builtIns.map(\.id).filter { route(for: $0) == nil }
    }
}

/// An adapter whose harness takes Yardlet instructions per process or per session. It is handed the text
/// before a session starts, resumes or forks; nil leaves that launch as it always was.
protocol HarnessYardletInstructionsConfiguring: Actor {
    func setYardletInstructions(_ instructions: YardletInstructionsDelivery?, for localSessionID: UUID) async
}

/// What each route adds to a launch or a session request. Each function returns nothing when
/// there is nothing to send, so a launch without instructions is byte for byte what it was.
enum YardletInstructionsLaunch {
    /// The one block a task receives: the global text, then its project's.
    static func combined(global: String, project: String?) -> String? {
        let parts = [global, project ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Claude Code's flag, in the `=` form so text that starts with a dash stays a value.
    static func claudeArguments(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        return ["--append-system-prompt=\(text)"]
    }

    /// Codex's `developerInstructions`: the configuration's own developer instructions first, so
    /// the thread keeps them, then Yardlet's text.
    static func codexDeveloperInstructions(configured: String?, yardlet: String) -> String {
        guard let configured = configured?.trimmingCharacters(in: .whitespacesAndNewlines),
              !configured.isEmpty else { return yardlet }
        return configured + "\n\n" + yardlet
    }

    /// Grok's ACP `session/new` (and `session/load`) `_meta`.
    static func grokSessionMeta(_ text: String?) -> JSONValue? {
        guard let text, !text.isEmpty else { return nil }
        return .object(["rules": .string(text)])
    }

    static let piAgentDirectoryVariable = "PI_CODING_AGENT_DIR"

    /// Pi's flags. Given `--append-system-prompt`, Pi skips the APPEND_SYSTEM.md it would find (the
    /// project's `.pi/APPEND_SYSTEM.md` when that project is trusted, else the agent folder's), so:
    /// the agent folder's file goes first when the project has none; a project with its own file
    /// launches as it always did, since only Pi knows whether it trusts that project.
    static func piArguments(_ text: String?, workspaceURL: URL, environment: [String: String],
                            homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
                            fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        let project = workspaceURL.standardizedFileURL.appending(path: ".pi/APPEND_SYSTEM.md").path(percentEncoded: false)
        guard !fileExists(project) else { return [] }
        let agentDirectory: URL
        if let configured = environment[piAgentDirectoryVariable], !configured.isEmpty {
            agentDirectory = URL(filePath: NSString(string: configured).expandingTildeInPath, directoryHint: .isDirectory)
        } else {
            agentDirectory = homeURL.appending(path: ".pi/agent", directoryHint: .isDirectory)
        }
        let global = agentDirectory.appending(path: "APPEND_SYSTEM.md").standardizedFileURL.path(percentEncoded: false)
        var arguments: [String] = []
        if fileExists(global) { arguments += ["--append-system-prompt", global] }
        return arguments + ["--append-system-prompt", text]
    }
}

/// Where the setting lives, all in Yardlet's own folder and defaults: the global text in
/// `~/.yardlet/instructions/instructions.md`, each project's text in
/// `~/.yardlet/instructions/projects/<project id>.md`, the switch and the projects turned off in
/// Yardlet's defaults.
@MainActor
@Observable
final class YardletInstructionsStore {
    static let enabledKey = "Yardlet.instructions.enabled"
    static let disabledProjectsKey = "Yardlet.instructions.disabledProjects"
    /// Marked the one-time seed of one person's model-routing guideline (2026-10-16). The seed was
    /// removed on 2026-10-22 because how people route differs; a saved text stays as it is.
    static let retiredSeededKey = "Yardlet.instructions.seeded"

    /// What the Settings editor shows. Saved as it changes.
    var text: String {
        didSet {
            guard text != oldValue else { return }
            Self.write(text, to: sourceURL)
        }
    }

    /// The switch for both levels: on unless the person turns it off. With empty text nothing is
    /// sent either way.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
        }
    }

    /// Each project's own text, keyed by project.
    private(set) var projectTexts: [UUID: String]
    /// The projects whose tasks receive nothing, the global text included.
    private(set) var disabledProjects: Set<UUID>

    @ObservationIgnored let directory: URL
    @ObservationIgnored private let defaults: UserDefaults

    var sourceURL: URL { directory.appending(path: "instructions.md") }
    var projectsDirectory: URL { directory.appending(path: "projects", directoryHint: .isDirectory) }

    func projectFileURL(for projectID: UUID) -> URL {
        projectsDirectory.appending(path: "\(projectID.uuidString.lowercased()).md")
    }

    init(directory: URL, defaults: UserDefaults = .yardlet) {
        self.directory = directory
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        text = (try? String(contentsOf: directory.appending(path: "instructions.md"), encoding: .utf8)) ?? ""
        defaults.removeObject(forKey: Self.retiredSeededKey)
        disabledProjects = Set(((defaults.object(forKey: Self.disabledProjectsKey) as? [String]) ?? []).compactMap(UUID.init(uuidString:)))
        var texts: [UUID: String] = [:]
        let folder = directory.appending(path: "projects", directoryHint: .isDirectory)
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension == "md" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let saved = try? String(contentsOf: file, encoding: .utf8) else { continue }
            texts[id] = saved
        }
        projectTexts = texts
    }

    static func live() -> YardletInstructionsStore {
        YardletInstructionsStore(directory: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: YardletProduct.storageDirectoryName, directoryHint: .isDirectory)
            .appending(path: "instructions", directoryHint: .isDirectory))
    }

    func projectText(for projectID: UUID) -> String { projectTexts[projectID] ?? "" }

    /// Saves a project's text; empty text removes its file.
    func setProjectText(_ value: String, for projectID: UUID) {
        guard projectText(for: projectID) != value else { return }
        let url = projectFileURL(for: projectID)
        if value.isEmpty {
            projectTexts.removeValue(forKey: projectID)
            try? FileManager.default.removeItem(at: url)
        } else {
            projectTexts[projectID] = value
            Self.write(value, to: url)
        }
    }

    func isDisabled(forProject projectID: UUID) -> Bool { disabledProjects.contains(projectID) }

    /// "Turn off in this project": the project's tasks receive neither level.
    func setDisabled(_ disabled: Bool, forProject projectID: UUID) {
        guard isDisabled(forProject: projectID) != disabled else { return }
        if disabled { disabledProjects.insert(projectID) } else { disabledProjects.remove(projectID) }
        defaults.set(disabledProjects.map { $0.uuidString }.sorted(), forKey: Self.disabledProjectsKey)
    }

    /// What a launch in `projectID` (nil for a chat, which has no project) receives now, or nil when
    /// the switch is off, the project turned it off, or there is no text. `routing` is the routing
    /// evaluation's block, after the person's text and apart from it.
    func delivery(forProject projectID: UUID?, routing: String? = nil) -> YardletInstructionsDelivery? {
        guard isEnabled else { return nil }
        if let projectID, isDisabled(forProject: projectID) { return nil }
        guard let text = YardletInstructionsLaunch.combined(
            global: text, project: projectID.map(projectText(for:))) else {
            return routing.flatMap { YardletInstructionsLaunch.combined(global: $0, project: nil) }
                .map(YardletInstructionsDelivery.init(text:))
        }
        return YardletInstructionsDelivery(text: YardletInstructionsLaunch.combined(global: text, project: routing) ?? text)
    }

    private static func write(_ text: String, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url, options: .atomic)
    }
}
