import Foundation

/// Names shared by the app, which injects the Yardlet MCP server into a harness session, and the
/// server, which reads them from its environment.
package enum AgentToolEnvironment {
    /// The server's name in every harness's MCP configuration; tools appear as `yardlet` tools.
    package static let serverName = "yardlet"
    package static let executableName = "yardlet-mcp"
    /// The app's local endpoint (a Unix domain socket path on macOS).
    package static let endpoint = "YARDLET_TOOLS_SOCKET"
    /// The random token Yardlet issued for one task.
    package static let token = "YARDLET_TOOLS_TOKEN"
    /// The Yardlet task (local session) the token belongs to.
    package static let session = "YARDLET_TOOLS_SESSION"
    /// The process ID of the app run that started the server, so that a server whose endpoint does not answer
    /// can tell whether that run ended or only the connection went.
    package static let appProcess = "YARDLET_TOOLS_APP_PID"
}

/// How long the app runs one call to a connector's tool at most: renewing its sign-in, initializing its
/// server, a second try and the call itself together. The MCP server waits longer for any call's answer
/// (`UnixSocketToolInvoker.timeout`), so the app's answer, with what it knows of the call, comes first.
package enum AgentToolTimeLimits {
    package static let connectorCall: Duration = .seconds(150)
}

/// One request the MCP server forwards to the running app: a tool call, the task's tool list, or
/// a wait for that list to change.
package struct AgentToolCall: Codable, Equatable, Sendable {
    /// `tools/list` asks for the tools this task may call; nil is a tool call.
    package static let listMethod = "tools/list"
    /// `tools/watch` waits until the task's list differs from the one the server last gave its
    /// client, whose fingerprint is `arguments.fingerprint` (`AgentToolListWatching`).
    package static let watchMethod = "tools/watch"

    package var token: String
    package var session: String
    package var tool: String
    package var arguments: ToolJSON
    package var method: String?

    package init(token: String, session: String, tool: String, arguments: ToolJSON, method: String? = nil) {
        self.token = token
        self.session = session
        self.tool = tool
        self.arguments = arguments
        self.method = method
    }
}

/// The app's answer to `tools/list`: MCP tool entries, the browser tools and connected connectors' tools.
package struct AgentToolList: Codable, Equatable, Sendable {
    package var tools: [ToolJSON]
    /// The app's fingerprint of `tools`, which the server sends back with `tools/watch`. Only the
    /// app computes it, so a list that crossed the socket is never compared with itself re-encoded.
    package var fingerprint: String?

    package init(tools: [ToolJSON], fingerprint: String? = nil) {
        self.tools = tools
        self.fingerprint = fingerprint
    }
}

/// How the Yardlet MCP server learns that a task's tools changed, so it can send its client
/// `notifications/tools/list_changed`: it asks the app (`tools/watch`) to wait until the task's
/// list differs from the one its client last listed. The app answers at once when it already
/// does and the task is between turns, or holds the request until then or until `hold` passes.
package enum AgentToolListWatching {
    /// The longest the app holds one `tools/watch`; the server asks again after an unchanged answer.
    package static let hold: Duration = .seconds(60)
    /// The server waits this long after its client first lists before it watches. A harness that
    /// only probes the server (Codex's `mcpServerStatus/list` starts a fresh one each time) has
    /// ended it by then, so the app holds nothing for it.
    package static let firstWatchDelay: Duration = .seconds(3)

    /// FNV-1a over the list's JSON with sorted keys: equal lists, equal fingerprints.
    package static func fingerprint(of tools: [ToolJSON]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(tools)) ?? Data()
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex + "-\(tools.count)"
    }
}

/// The app's answer to `tools/watch`.
package struct AgentToolListWatchReply: Codable, Equatable, Sendable {
    /// The task's list differs from the one the server's client last listed; false when the
    /// app's hold ran out first.
    package var changed: Bool

    package init(changed: Bool) {
        self.changed = changed
    }
}

package enum AgentToolContent: Codable, Equatable, Sendable {
    case text(String)
    /// Base64-encoded image bytes.
    case image(data: String, mimeType: String)
    /// An MCP content item passed through as a connector's server sent it (audio, resources, links).
    case json(ToolJSON)
}

/// A tool's answer. Failures the agent can act on (a stale reference, a page that did not load)
/// are results with `isError`, as MCP asks, rather than protocol errors.
package struct AgentToolResult: Codable, Equatable, Sendable {
    package var content: [AgentToolContent]
    package var isError: Bool
    /// A connector tool's structured result, passed through.
    package var structuredContent: ToolJSON?

    package init(content: [AgentToolContent], isError: Bool = false, structuredContent: ToolJSON? = nil) {
        self.content = content
        self.isError = isError
        self.structuredContent = structuredContent
    }

    package static func text(_ text: String) -> AgentToolResult {
        AgentToolResult(content: [.text(text)])
    }

    package static func error(_ message: String) -> AgentToolResult {
        AgentToolResult(content: [.text(message)], isError: true)
    }

    /// The text parts joined, for logs and tests.
    package var text: String {
        content.compactMap { content -> String? in
            switch content {
            case .text(let text): text
            case .json(let item): item["type"]?.stringValue == "text" ? item["text"]?.stringValue : nil
            case .image: nil
            }
        }.joined(separator: "\n")
    }
}

/// Stream framing between the server and the app: a 4-byte big-endian length, then that many
/// bytes of UTF-8 JSON. One connection carries one call and its result.
package enum AgentToolFraming {
    /// A call carries arguments only.
    package static let maximumCallLength = 4 * 1024 * 1024
    /// A result may carry a full-page screenshot.
    package static let maximumResultLength = 64 * 1024 * 1024

    package static func frame<T: Encodable>(_ message: T) throws -> Data {
        frame(body: try JSONEncoder().encode(message))
    }

    package static func frame(body: Data) -> Data {
        var length = UInt32(body.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(body)
        return data
    }

    package static func length(ofHeader header: Data) -> Int {
        header.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
    }
}
