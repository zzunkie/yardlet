import Foundation

// A Codex inline visualization as Yardlet draws it: the HTML fragment the model wrote, wrapped the way the
// `visualize` skill's own `scripts/render.py` wraps it into a page (its stylesheet, its widget kit and its host
// bridge), under the Content Security Policy the Codex app gives it. The kit is read from the skill the Codex CLI
// installed on this Mac; Yardlet does not ship it. Without it the fragment is drawn with no kit, its text and charts
// in the system's plain styles.

/// The page of one visualization, ready for the sandboxed web view (`MCPAppViewController.startVisualization`).
struct CodexVisualizationPage: Equatable, Sendable {
    /// As much as the Codex app reads of a visualization file (the skill asks the model for under 1 MB).
    static let maximumLength = 5 * 1024 * 1024
    /// A widget's saved state, as the skill's bridge allows it.
    static let maximumStateLength = 16 * 1024

    let html: String
    let policy: String

    enum Problem: Error, Equatable {
        /// The path is not an HTML file in the task's folder or in a Codex home's visualizations.
        case notAllowed
        /// No such file, a link, a folder, too large or not text.
        case unreadable
    }

    /// The scripts, styles, fonts, pictures and sounds a visualization may load, as the Codex app allows them: a
    /// few public CDNs and the skill's own components. Nothing may be fetched (`connect-src`), no frame opened.
    static let policy: String = {
        let sources = ["blob:", "data:", "https://cdnjs.cloudflare.com", "https://cdn.jsdelivr.net", "https://esm.sh",
                       "https://fonts.bunny.net", "https://fonts.googleapis.com", "https://fonts.gstatic.com",
                       "https://unpkg.com"].joined(separator: " ")
        let components = "https://persistent.oaistatic.com/plugins/visualize/"
        return [
            "default-src 'none'",
            "script-src 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval' \(sources) \(components)",
            "style-src 'unsafe-inline' \(sources) \(components)charts/",
            "img-src \(sources)", "font-src \(sources)", "media-src \(sources)",
            "worker-src blob:", "connect-src blob: data:", "frame-src 'none'", "object-src 'none'",
            "base-uri 'none'", "form-action 'none'"
        ].joined(separator: "; ")
    }()

    /// Reads the visualization `file` names (absolute, `~/…` or relative to `workspace`) off the main thread and
    /// makes its page, with `state` as the widget's saved state.
    static func load(file: String, workspace: URL?, state: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser)
        async throws -> CodexVisualizationPage {
        try await Task.detached(priority: .userInitiated) {
            let url = try allowedFile(file, workspace: workspace, home: home)
            let fragment = try read(url)
            return CodexVisualizationPage(html: page(fragment, kit: CodexVisualizationKit.installed(home: home), state: state),
                                          policy: policy)
        }.value
    }

    /// The file `file` names when Yardlet may draw it: an HTML file in the task's folder, or in a Codex home's
    /// `visualizations` (`~/.codex`, or another home the Codex CLI writes, which holds its `config.toml` or
    /// `sessions`), as the Codex app reads only its thread's writable folders.
    static func allowedFile(_ file: String, workspace: URL?, home: URL) throws -> URL {
        let path = file.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL
        if path.hasPrefix("/") {
            url = URL(filePath: path)
        } else if path.hasPrefix("~/") {
            url = home.appending(path: String(path.dropFirst(2)))
        } else if let workspace, !path.isEmpty {
            url = workspace.appending(path: path)
        } else {
            throw Problem.notAllowed
        }
        let standardized = url.standardizedFileURL
        guard standardized.pathExtension.lowercased() == "html" else { throw Problem.notAllowed }
        if let workspace, isInside(standardized, workspace.standardizedFileURL) { return standardized }
        // Under `<home>/visualizations/YYYY/MM/DD/<thread>/`, the folder the Codex app gives a thread.
        let components = standardized.pathComponents
        let manager = FileManager.default
        for index in components.indices where components[index] == "visualizations" && index + 5 < components.count {
            let date = components[(index + 1)...(index + 3)]
            guard zip(date, [4, 2, 2]).allSatisfy({ part, length in
                part.count == length && part.allSatisfy { $0.isASCII && $0.isNumber }
            }) else { continue }
            let codexHome = URL(filePath: "/" + components[1..<index].joined(separator: "/"), directoryHint: .isDirectory)
            if manager.fileExists(atPath: codexHome.appending(path: "config.toml").path(percentEncoded: false))
                || manager.fileExists(atPath: codexHome.appending(path: "sessions").path(percentEncoded: false)) {
                return standardized
            }
        }
        throw Problem.notAllowed
    }

    private static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let folderPath = folder.path(percentEncoded: false)
        let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        return url.path(percentEncoded: false).hasPrefix(prefix)
    }

    /// The file's text: a regular file, not a link, no larger than `maximumLength`.
    private static func read(_ url: URL) throws -> String {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isSymbolicLink != true, values.isRegularFile == true, let size = values.fileSize, size <= maximumLength,
              let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            throw Problem.unreadable
        }
        return text
    }

    /// Whether `html` is a whole document rather than the fragment the skill asks for.
    static func isDocument(_ html: String) -> Bool {
        let start = html.drop { $0.isWhitespace }.prefix(15).lowercased()
        return start.hasPrefix("<!doctype") || start.hasPrefix("<html")
    }

    /// The page: the kit's stylesheet, the widget's saved state, the host bridge, then the kit with the fragment in
    /// it, as `render.py` builds the frame. A whole document keeps its own head and styles and gets the state and
    /// the bridge at the top of its body. Without a kit the fragment gets `stylesheet`: the plain fallback for a
    /// Codex visualization, Yardlet's theme (`YardletWidgetTheme`) for a `show_widget` view.
    static func page(_ fragment: String, kit: CodexVisualizationKit?, state: String?,
                     stylesheet: String = CodexVisualizationKit.fallbackStylesheet) -> String {
        let globals = "{\"widgetState\":\(state ?? "null"),\"statePersistence\":\"local\"}"
            .replacingOccurrences(of: "<", with: "\\u003c")
        let bridge = (kit?.bridge ?? CodexVisualizationKit.fallbackBridge).replacingOccurrences(of: "</script", with: "<\\/script")
        let start = """
        <script type="application/json" id="codex-visualization-widget-state">\(globals)</script>
        <script>\(bridge)</script>
        """
        if isDocument(fragment) {
            guard let body = fragment.range(of: "<body[^>]*>", options: [.regularExpression, .caseInsensitive]) else {
                return start + fragment
            }
            return String(fragment[..<body.upperBound]) + start + String(fragment[body.upperBound...])
        }
        let inner = kit.map { $0.widgets.replacingOccurrences(of: CodexVisualizationKit.placeholder, with: fragment) } ?? fragment
        return """
        <!doctype html>
        <html lang="en" data-visualize-standalone>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="referrer" content="no-referrer">
        <style>\(kit?.stylesheet ?? stylesheet)
        html>body{padding:0}</style>
        </head>
        <body>
        \(start)
        \(inner)
        </body>
        </html>
        """
    }
}

/// The `visualize` skill's page kit, read from the newest copy the Codex CLI installed in a Codex home on this Mac.
struct CodexVisualizationKit: Equatable, Sendable {
    static let placeholder = "<!--__INLINE_VISUALIZATION_FRAGMENT__-->"

    let stylesheet: String
    /// `visualize.html`: tooltips and icons around `placeholder`.
    let widgets: String
    /// `standalone-host-bridge.js`: `window.openai` and the messages to the host.
    let bridge: String

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (folder: URL, kit: CodexVisualizationKit)?

    /// The kit of the newest `visualize` the Codex CLI installed: in `~/.codex`, or in the Codex homes Yardlet keeps
    /// for other accounts, under `plugins/cache/<marketplace>/visualize/<version>/skills/visualize/assets`.
    static func installed(home: URL) -> CodexVisualizationKit? {
        guard let folder = newestAssets(home: home) else { return nil }
        if let cached = lock.withLock({ cached }), cached.folder == folder { return cached.kit }
        func read(_ name: String) -> String? { try? String(contentsOf: folder.appending(path: name), encoding: .utf8) }
        guard let stylesheet = read("visualize.css"), let widgets = read("visualize.html"),
              widgets.contains(placeholder), let bridge = read("standalone-host-bridge.js") else { return nil }
        let kit = CodexVisualizationKit(stylesheet: stylesheet, widgets: widgets, bridge: bridge)
        lock.withLock { cached = (folder, kit) }
        return kit
    }

    private static func newestAssets(home: URL) -> URL? {
        let manager = FileManager.default
        var homes = [home.appending(path: ".codex")]
        for root in [home.appending(path: ".yardlet/connections"), home.appending(path: ".yardlet/harnesses")] {
            for entry in (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                homes.append(entry.appending(path: "codex"))
                homes.append(entry.appending(path: "home"))
            }
        }
        var found: [(version: [Int], folder: URL)] = []
        for codexHome in homes {
            let cache = codexHome.appending(path: "plugins/cache")
            for marketplace in (try? manager.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? [] {
                let skill = marketplace.appending(path: "visualize")
                for version in (try? manager.contentsOfDirectory(at: skill, includingPropertiesForKeys: nil)) ?? [] {
                    let assets = version.appending(path: "skills/visualize/assets")
                    guard manager.fileExists(atPath: assets.appending(path: "visualize.css").path(percentEncoded: false))
                    else { continue }
                    found.append((version.lastPathComponent.split(separator: ".").map { Int($0) ?? 0 }, assets))
                }
            }
        }
        return found.max { $0.version.lexicographicallyPrecedes($1.version) }?.folder
    }

    /// Without the kit, the page still tells its height and follows the appearance.
    static let fallbackStylesheet = """
    :root{color-scheme:light dark;font:13px -apple-system,system-ui,sans-serif}body{margin:0;padding:0}
    """

    /// What a page without the kit has of `window.openai`, on the port Yardlet hands it, as the skill's bridge does: its
    /// height as it changes, its saved state, and a link or a follow-up only while the person is clicking.
    static let fallbackBridge = """
    (() => {
      let port = null;
      const pending = [];
      const post = (message) => { if (port) { port.postMessage(message); } else { pending.push(message); } };
      const clicking = () => navigator.userActivation && navigator.userActivation.isActive === true;
      const element = document.getElementById("codex-visualization-widget-state");
      const initial = JSON.parse((element && element.textContent) || "{}");
      if (element) { element.remove(); }
      let state = initial.widgetState || null;
      let next = 0;
      const dark = matchMedia("(prefers-color-scheme: dark)");
      window.openai = {
        widgetState: state,
        theme: dark.matches ? "dark" : "light",
        setWidgetState: async (value) => {
          state = typeof value === "function" ? value(state) : value;
          window.openai.widgetState = state;
          post({ type: "widget-state-write", id: ++next, state: JSON.stringify(state) });
        },
        openExternal: ({ href }) => { if (clicking()) { post({ type: "open-external", href }); } },
        sendFollowUpMessage: async ({ prompt }) => { if (clicking()) { post({ type: "follow-up", prompt }); } }
      };
      dark.addEventListener("change", () => { window.openai.theme = dark.matches ? "dark" : "light"; });
      const send = () => post({ type: "height", height: Math.ceil(Math.max(
        document.body.scrollHeight, document.body.getBoundingClientRect().height)) });
      addEventListener("message", (event) => {
        if (port || event.source !== parent || !event.data || event.data.type !== "codex-visualization-initialize"
            || !event.ports || event.ports.length !== 1) { return; }
        event.stopImmediatePropagation();
        port = event.ports[0];
        port.start();
        pending.splice(0).forEach((message) => port.postMessage(message));
        send();
      }, { capture: true });
      addEventListener("click", (event) => {
        const link = event.target instanceof Element ? event.target.closest("a[href]") : null;
        if (!link || event.defaultPrevented) { return; }
        event.preventDefault();
        window.openai.openExternal({ href: link.href });
      });
      addEventListener("DOMContentLoaded", () => new ResizeObserver(send).observe(document.body));
    })();
    """
}

/// What a visualization's page says to Yardlet, on the port the outer page hands it (the skill's
/// `standalone-host-bridge.js`): its height, a link the person clicked, a follow-up to ask, a state to keep. A
/// follow-up only goes into the composer, and the state is kept in memory for the app's run and never reaches the
/// model.
@MainActor
final class CodexVisualizationBridge {
    enum Phase: Equatable {
        case loading
        case live
    }

    private(set) var phase: Phase = .loading
    var onHeight: (@MainActor (Double) -> Void)?
    /// Posts a message to the page, as JSON text.
    var post: (@MainActor (String) -> Void)?
    private let openLink: @MainActor (URL) -> Void
    private let followUp: (@MainActor (String) -> Void)?
    private let saveState: @MainActor (String) -> Void
    private var lastLink = Date.distantPast

    init(openLink: @escaping @MainActor (URL) -> Void, followUp: (@MainActor (String) -> Void)?,
         saveState: @escaping @MainActor (String) -> Void) {
        self.openLink = openLink
        self.followUp = followUp
        self.saveState = saveState
    }

    func receive(_ text: String) {
        guard text.utf8.count <= MCPAppBridge.maximumMessageLength, let data = text.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = message["type"] as? String else { return }
        switch type {
        case "height":
            guard let height = message["height"] as? Double, height.isFinite, height >= 0 else { return }
            phase = .live
            onHeight?(height)
        case "open-external":
            guard let href = message["href"] as? String, let url = URL(string: href),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            open(url)
        case "follow-up":
            guard let prompt = message["prompt"] as? String else { return }
            let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.utf8.count <= CodexVisualizationPage.maximumStateLength else { return }
            followUp?(trimmed)
        case "widget-state-write":
            guard let id = message["id"] as? Int, let state = message["state"] as? String else { return }
            let ok = state.utf8.count <= CodexVisualizationPage.maximumStateLength
                && (try? JSONSerialization.jsonObject(with: Data(state.utf8))) is [String: Any]
            if ok { saveState(state) }
            post?("{\"type\":\"widget-state-result\",\"id\":\(id),\"ok\":\(ok)}")
        default:
            break
        }
    }

    /// A link the person clicked in the page, at most one a second.
    func open(_ url: URL) {
        let now = Date()
        guard now.timeIntervalSince(lastLink) >= 1 else { return }
        lastLink = now
        openLink(url)
    }

    /// Runs in the outer page's isolated world from its start: each time the visualization's frame loads, hands it a
    /// new port, passes on what the page posts on it, and keeps the port for Yardlet's answers
    /// (`window.yardletVisualizationPort`).
    static func outerScript(handler: String) -> String {
        """
        (() => {
          const connect = () => {
            const frame = document.getElementById('view');
            if (!frame) { return; }
            frame.addEventListener('load', () => {
              if (!frame.contentWindow) { return; }
              const channel = new MessageChannel();
              channel.port1.onmessage = (event) => {
                let text;
                try { text = JSON.stringify(event.data); } catch (error) { return; }
                if (typeof text !== 'string' || text.length > \(MCPAppBridge.maximumMessageLength)) { return; }
                window.webkit.messageHandlers.\(handler).postMessage(text);
              };
              window.yardletVisualizationPort = channel.port1;
              frame.contentWindow.postMessage({ type: 'codex-visualization-initialize' }, '*', [channel.port2]);
            });
          };
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', connect, { once: true });
          } else {
            connect();
          }
        })();
        """
    }
}

/// The state each visualization's page saved, by its row, for the app's run.
@MainActor
final class CodexVisualizationStates {
    static let shared = CodexVisualizationStates()
    private var states: [String: String] = [:]

    func state(_ key: String) -> String? { states[key] }

    func save(_ state: String, for key: String) {
        states[key] = state
        if states.count > 200, let first = states.keys.first(where: { $0 != key }) { states.removeValue(forKey: first) }
    }
}
