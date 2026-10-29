import Foundation

/// A link in a conversation that names a task rather than a page or a file, in the forms agents
/// write them: a Yardlet task ID as an anchor (`[title](#<UUID>)`, as Claude Code writes the Claude
/// app's session links), the Claude app's own session anchor (`#local_<id>`, `#cloud_<id>`), the Codex app's
/// thread link (`codex://threads/<id>`), and cloud session URLs (`https://claude.ai/code/<id>`). Clicking one opens that task in Yardlet or in the provider's app/page.
enum TaskLink: Equatable, Sendable {
    /// A Yardlet task ID, or a harness session ID that is a UUID (a Claude Code session, a Codex
    /// thread).
    case task(UUID)
    /// The Claude app's ID for a Code session (`local_…`, `cloud_…`), which names the Claude Code session in
    /// its own file.
    case claudeDesktopSession(String)
    /// A Codex thread by its ID.
    case codexThread(String)
    /// A cloud-hosted session URL.
    case cloudSession(URL)

    init?(_ url: URL) {
        if url.scheme == nil {
            // An anchor alone: `#<UUID>` or `#local_<id>`.
            guard url.path(percentEncoded: false).isEmpty, url.query == nil, let fragment = url.fragment(percentEncoded: false)
            else { return nil }
            if let id = UUID(uuidString: fragment) {
                self = .task(id)
            } else if fragment.wholeMatch(of: /(local|cloud|remote)_[A-Za-z0-9-]{1,64}/) != nil {
                self = .claudeDesktopSession(fragment)
            } else {
                return nil
            }
            return
        }
        if let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
           let host = url.host()?.lowercased(), host == "claude.ai",
           url.path(percentEncoded: false).hasPrefix("/code/") {
            self = .cloudSession(url)
            return
        }
        // The Codex app opens `codex://threads/<id>` in its own window (`codex-dev:` is its
        // development build's).
        guard url.scheme?.lowercased() == "codex", url.host()?.lowercased() == "threads",
              url.user == nil, url.password == nil, url.port == nil else { return nil }
        let parts = url.path(percentEncoded: false).split(separator: "/")
        guard parts.count == 1, let id = parts.first.map(String.init),
              id.wholeMatch(of: /[A-Za-z0-9_-]{1,128}/) != nil else { return nil }
        self = .codexThread(id)
    }

    /// Whether another app opens the link when Yardlet has no such task: the Codex app opens its
    /// threads, and cloud sessions open in the browser. An anchor names nothing outside the conversation.
    var opensElsewhere: Bool {
        switch self {
        case .codexThread, .cloudSession:
            return true
        case .task, .claudeDesktopSession:
            return false
        }
    }
}
