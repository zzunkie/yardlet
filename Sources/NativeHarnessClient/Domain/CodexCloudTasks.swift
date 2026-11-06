import Foundation

/// A task in Codex Cloud, as `codex cloud list --json` lists it: the Codex CLI's own listing of the
/// person's cloud tasks, which the Codex app shows in its sidebar's cloud group
/// (docs/NATIVE_SESSION_STORAGE.md, "Cloud tasks"). A cloud task runs on OpenAI's machines and has no
/// local session, so it is not a task in Yardlet's index: it is listed beside the tasks and opens on
/// its own page.
struct CodexCloudTask: Identifiable, Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case pending, ready, applied, error
    }

    let id: String
    let title: String
    /// Nil for a status this version of Yardlet does not know.
    let status: Status?
    let updatedAt: Date?
    /// The environment's name, as the CLI labels it.
    let environment: String?
    /// The task's page, which the CLI prints for it.
    let url: URL
}

enum CodexCloudTasks {
    /// The CLI lists at most 20 tasks a page; Yardlet reads the newest five pages.
    static let pageSize = 20
    static let pageLimit = 5
    /// The key the sidebar remembers the Cloud section's "Show more" under, beside Chats' and the projects'.
    static let disclosureKey = "cloud"

    /// The arguments of one page's listing.
    static func arguments(cursor: String?) -> [String] {
        ["cloud", "list", "--json", "--limit", String(pageSize)] + (cursor.map { ["--cursor", $0] } ?? [])
    }

    /// One page of `codex cloud list --json` (`{"tasks": [...], "cursor": ...}`). Nil when the output is
    /// not such a page; a task without an ID or a title is left out.
    static func page(from output: String) -> (tasks: [CodexCloudTask], cursor: String?)? {
        guard let data = output.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let tasks = value["tasks"]?.arrayValue else { return nil }
        let cursor = value["cursor"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        return (tasks.compactMap(task), cursor)
    }

    private static func task(_ value: JSONValue) -> CodexCloudTask? {
        guard let id = value["id"]?.stringValue, isTaskID(id),
              let title = value["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        let environment = value["environment_label"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CodexCloudTask(
            id: id,
            title: SessionTitleProjection.normalizedProviderTitle(title) ?? title,
            status: value["status"]?.stringValue.flatMap(CodexCloudTask.Status.init(rawValue:)),
            updatedAt: value["updated_at"]?.stringValue.flatMap(date),
            environment: environment?.isEmpty == false ? environment : nil,
            url: pageURL(value["url"]?.stringValue, id: id))
    }

    /// Task IDs are short tokens (`task_e_…`); anything else is not taken into a URL.
    private static func isTaskID(_ id: String) -> Bool {
        id.wholeMatch(of: /[A-Za-z0-9_-]{1,128}/) != nil
    }

    /// The page the CLI gives for the task when it is the task's page on ChatGPT, and that page
    /// otherwise: a listing never opens another site or another task.
    static func pageURL(_ listed: String?, id: String) -> URL {
        if let listed, let url = URL(string: listed), url.scheme == "https",
           url.host() == "chatgpt.com", url.user == nil, url.password == nil, url.port == nil,
           url.path(percentEncoded: false) == "/codex/tasks/" + id {
            return url
        }
        return URL(string: "https://chatgpt.com/codex/tasks/" + id)!
    }

    /// RFC 3339, as the CLI writes it, with or without fractions of a second.
    static func date(_ text: String) -> Date? {
        let whole = text.replacing(/\.\d+/, with: "", maxReplacements: 1)
        return try? Date(whole, strategy: .iso8601)
    }

    /// The tasks a sidebar search keeps: those whose title or environment holds the search text.
    static func matching(_ tasks: [CodexCloudTask], search: String) -> [CodexCloudTask] {
        let search = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return tasks }
        return tasks.filter {
            $0.title.localizedStandardContains(search) || $0.environment?.localizedStandardContains(search) == true
        }
    }
}
