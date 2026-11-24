import AppKit
import SwiftUI

/// Send Feedback: a note the person writes to the Yardlet team, sent privately to the relay's feedback
/// endpoint (`POST /v1/feedback`, relay/README.md), which mails it to the team. Nothing is sent until the
/// person presses Send, and nothing is collected in the background. What goes with the note is shown
/// before it is sent: the app's version and the kind of screen, and from an error card also the macOS
/// version, the agent and the error's kind and code. Conversations, titles, file paths, accounts, logs,
/// screenshots and secrets are never attached; an error's message stays on this Mac.
struct PrivateFeedbackContext: Equatable, Sendable {
    enum Kind: String, Sendable { case feedback, problem }

    /// The kind of screen the note was written from.
    enum Surface: String, Sendable {
        case home, localTask, remoteHost, remoteTask, settings, other

        var title: String {
            switch self {
            case .home: L10n.string("Home")
            case .localTask: L10n.string("Task")
            case .remoteHost: L10n.string("Remote Mac")
            case .remoteTask: L10n.string("Remote task")
            case .settings: L10n.string("Settings")
            case .other: L10n.string("Other")
            }
        }
    }

    /// An error card's kind of failure and, when the provider named one, its code.
    struct Failure: Equatable, Sendable {
        /// "signIn", "actionFailed", "sessionFailed", "taskStart", "accountCheck", "yardletSignIn",
        /// "remoteConnection".
        var kind: String
        var code: String?
    }

    var kind: Kind
    var surface: Surface
    /// "0.11.16 (38)".
    var app: String
    var macOS: String?
    var harness: String?
    var failure: Failure?

    /// A note from the sidebar, the Help menu or a remote window: the app's version and the screen.
    static func feedback(surface: Surface, app: String = currentApp) -> Self {
        Self(kind: .feedback, surface: surface, app: app)
    }

    /// A report from an error card: also the macOS version, the agent and the error's kind and code.
    static func problem(surface: Surface, harness: HarnessKind?, failure: Failure,
                        app: String = currentApp, macOS: String = currentMacOS) -> Self {
        Self(kind: .problem, surface: surface, app: app, macOS: macOS, harness: harness?.displayName,
             failure: Failure(kind: failure.kind, code: failure.code.flatMap(safeCode)))
    }

    /// What the sheet lists under "Included", in the order sent.
    var includedLines: [(label: String, value: String)] {
        var lines = [(L10n.string("App version"), app)]
        if let macOS { lines.append(("macOS", macOS)) }
        if let harness { lines.append((L10n.string("Agent"), harness)) }
        lines.append((L10n.string("Screen"), surface.title))
        if let failure {
            lines.append((L10n.string("Error"), [failure.kind, failure.code].compactMap { $0 }.joined(separator: " · ")))
        }
        return lines
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.surface == rhs.surface && lhs.app == rhs.app && lhs.macOS == rhs.macOS
            && lhs.harness == rhs.harness && lhs.failure == rhs.failure
    }

    // MARK: This Mac

    static var currentApp: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = [info["CFBundleShortVersionString"] as? String,
                       (info["CFBundleVersion"] as? String).map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        return version.isEmpty ? "development build" : version
    }

    static var currentMacOS: String {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(system.majorVersion).\(system.minorVersion)" + (system.patchVersion > 0 ? ".\(system.patchVersion)" : "")
    }

    // MARK: Error codes

    /// The code a provider put in its error, without the message around it: an error body's `type` or
    /// `code` (`overloaded_error`, `rate_limit_exceeded`), else an HTTP status the message names
    /// (`API Error: 529`, `status 401`). Nil when there is none; the message itself is never sent.
    static func errorCode(in message: String?) -> String? {
        guard let message = message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else { return nil }
        if let start = message.firstIndex(of: "{"),
           let value = try? JSONDecoder().decode(JSONValue.self, from: Data(message[start...].utf8)) {
            let candidates = [value["error"]?["type"], value["error"]?["code"], value["type"], value["code"],
                              value["status"]].compactMap { $0 }
            for candidate in candidates {
                if let text = candidate.stringValue, let code = safeCode(text), code != "error" { return code }
                if case let .integer(number) = candidate, let code = safeCode(String(number)) { return code }
            }
        }
        let pattern = #"(?i)\b(?:api error|status(?: code)?|http)\W{0,3}([1-5][0-9]{2})\b"#
        guard let match = message.range(of: pattern, options: .regularExpression) else { return nil }
        return message[match].range(of: #"[1-5][0-9]{2}$"#, options: .regularExpression).map { String(message[match][$0]) }
    }

    /// A code as it is sent: letters, digits, `_`, `-` and `.`, at most 60 of them; anything else is not
    /// a code and is left out.
    static func safeCode(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespaces)
        return text.range(of: #"^[A-Za-z0-9_.\-]{1,60}$"#, options: .regularExpression) != nil ? text : nil
    }
}

/// The note as the endpoint takes it (relay/README.md, "Feedback").
struct PrivateFeedbackSubmission: Encodable, Equatable {
    struct Context: Encodable, Equatable {
        struct Failure: Encodable, Equatable {
            var kind: String
            var code: String?
        }
        var app: String
        var surface: String
        var macOS: String?
        var harness: String?
        var error: Failure?
    }

    /// The same for every retry of one note, so the endpoint mails it once.
    var id: String
    var kind: String
    var message: String
    var replyTo: String?
    var context: Context

    /// The longest note the endpoint takes.
    static let maximumMessageLength = 4000

    init(id: UUID, context: PrivateFeedbackContext, message: String, replyTo: String?) {
        self.id = id.uuidString.lowercased()
        kind = context.kind.rawValue
        self.message = message
        self.replyTo = replyTo
        self.context = Context(app: context.app, surface: context.surface.rawValue, macOS: context.macOS,
                               harness: context.harness,
                               error: context.failure.map { Context.Failure(kind: $0.kind, code: $0.code) })
    }
}

/// Sends a note to the endpoint. The endpoint is the relay this build carries (`YardletRelayURL`), or
/// `YARDLET_FEEDBACK_URL` for a local relay; a build with neither cannot send and says so.
struct PrivateFeedbackClient: Sendable {
    enum Outcome: Equatable {
        case accepted
        /// The note was not taken; the person may send it again, which sends the same note.
        case failed(String)
        /// The send was stopped here, as the sheet closed; nothing is said about it.
        case cancelled
    }

    var endpoint: URL?
    var post: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let live = PrivateFeedbackClient(endpoint: defaultEndpoint) { request in
        try await URLSession.shared.data(for: request)
    }

    static var defaultEndpoint: URL? {
        if let override = ProcessInfo.processInfo.environment["YARDLET_FEEDBACK_URL"] {
            return webURL(override)
        }
        let relay = Bundle.main.object(forInfoDictionaryKey: RemoteControlService.builtInRelayURLKey) as? String
        return relay.flatMap(endpoint(forRelay:))
    }

    /// `wss://relay.example/` → `https://relay.example/v1/feedback`.
    static func endpoint(forRelay relay: String) -> URL? {
        guard var components = URLComponents(string: relay.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), components.host?.isEmpty == false else { return nil }
        switch scheme {
        case "wss", "https": components.scheme = "https"
        case "ws", "http": components.scheme = "http"
        default: return nil
        }
        components.path = "/v1/feedback"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// An http or https address with a host, else nil.
    static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else { return nil }
        return url
    }

    func send(_ submission: PrivateFeedbackSubmission) async -> Outcome {
        guard let endpoint else { return .failed(L10n.string("This build of Yardlet cannot send feedback.")) }
        guard let body = try? JSONEncoder().encode(submission) else {
            return .failed(L10n.string("The note could not be read. Shorten it and try again."))
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        do {
            let (_, response) = try await post(request)
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200..<300: return .accepted
            case 429: return .failed(L10n.string("Too many notes were sent just now. Try again in a minute."))
            case 400, 413, 415: return .failed(L10n.string("The note could not be read. Shorten it and try again."))
            default: return .failed(L10n.string("The note could not be sent. Try again later."))
            }
        } catch is CancellationError {
            return .cancelled
        } catch let error as URLError where error.code == .cancelled {
            return .cancelled
        } catch {
            return Task.isCancelled ? .cancelled
                : .failed(L10n.string("The note could not be sent. Check your connection and try again."))
        }
    }
}

/// What the sheet edits and sends. A failed send keeps the note; sending the same note again reuses its
/// id, so the endpoint mails it once even when an earlier try reached it.
@MainActor @Observable
final class PrivateFeedbackForm {
    enum State: Equatable {
        case editing
        case sending
        case sent
        case failed(String)
    }

    let context: PrivateFeedbackContext
    var message = ""
    var addsEmail = false
    var email = ""
    /// Closing asked with an unsent note: the sheet asks whether to discard it.
    var confirmsDiscard = false
    private(set) var state = State.editing
    @ObservationIgnored private let client: PrivateFeedbackClient
    @ObservationIgnored private var lastAttempt: PrivateFeedbackSubmission?
    @ObservationIgnored private var sending: Task<Void, Never>?

    init(context: PrivateFeedbackContext, client: PrivateFeedbackClient = .live) {
        self.context = context
        self.client = client
    }

    /// The note as sent: without the control characters the endpoint refuses (tabs and line breaks stay).
    var trimmedMessage: String {
        String(String.UnicodeScalarView(message.unicodeScalars.filter { !Self.isRefusedControl($0) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isRefusedControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0D: false
        case 0x00...0x1F, 0x7F...0x9F: true
        default: false
        }
    }

    var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isTooLong: Bool { trimmedMessage.count > PrivateFeedbackSubmission.maximumMessageLength }
    /// Printable US-ASCII in the shape the endpoint takes for a reply address.
    var emailIsValid: Bool {
        !addsEmail || trimmedEmail.isEmpty
            || (trimmedEmail.count <= 254 && trimmedEmail.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
                && trimmedEmail.range(of: #"^[^@]+@[^@]+\.[^@]+$"#, options: .regularExpression) != nil)
    }
    var canSend: Bool { !trimmedMessage.isEmpty && !isTooLong && emailIsValid && state != .sending && state != .sent }
    /// Closing would lose something the person wrote.
    var hasUnsentNote: Bool { state != .sent && (!trimmedMessage.isEmpty || (addsEmail && !trimmedEmail.isEmpty)) }

    /// Starts sending, kept so closing the sheet can stop it (`cancelSending`).
    func startSending() {
        guard canSend else { return }
        sending = Task { await send() }
    }

    /// Stops a send under way; the note goes back to editing.
    func cancelSending() {
        sending?.cancel()
        sending = nil
    }

    /// Closing, from Cancel, the close button or ⌘W: allowed at once when nothing would be lost; while a
    /// note is going it is not, and with an unsent note the sheet asks first.
    func mayClose() -> Bool {
        if state == .sending { return false }
        if hasUnsentNote {
            confirmsDiscard = true
            return false
        }
        return true
    }

    func send() async {
        guard canSend else { return }
        let replyTo = addsEmail && !trimmedEmail.isEmpty ? trimmedEmail : nil
        var submission = PrivateFeedbackSubmission(id: UUID(), context: context, message: trimmedMessage, replyTo: replyTo)
        if let lastAttempt, lastAttempt.message == submission.message, lastAttempt.replyTo == submission.replyTo {
            submission.id = lastAttempt.id
        }
        lastAttempt = submission
        state = .sending
        switch await client.send(submission) {
        case .accepted: state = .sent
        case let .failed(reason): state = .failed(reason)
        case .cancelled: state = .editing
        }
    }
}

// MARK: - Presenting

/// Opens Send Feedback as a sheet over the window it was asked from, or as a window of its own when there is
/// none or that window already shows a sheet (Settings). One at a time: asked again, the open one comes
/// forward. DEBUG QA replaces `open` so nothing opens on the person's screen.
@MainActor
enum PrivateFeedbackPresenter {
    static var open: @MainActor (_ context: PrivateFeedbackContext, _ window: NSWindow?) -> Void = present
    /// The open one, released as it closes.
    fileprivate(set) static var shown: PrivateFeedbackWindow?

    private static func present(_ context: PrivateFeedbackContext, over window: NSWindow?) {
        if let shown {
            shown.window.makeKeyAndOrderFront(nil)
            return
        }
        let parent = (window ?? NSApp.keyWindow ?? NSApp.mainWindow).flatMap { $0.sheetParent ?? $0 }
        let sheetParent = parent?.attachedSheet == nil ? parent : nil
        shown = PrivateFeedbackWindow(form: PrivateFeedbackForm(context: context), over: sheetParent)
    }
}

/// The sheet's window and its form. Cancel, the close button and ⌘W all go through `mayClose`; once
/// closed, the send is stopped and the window lets go of its content, so neither the window nor the note
/// outlives it.
@MainActor
final class PrivateFeedbackWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let form: PrivateFeedbackForm

    init(form: PrivateFeedbackForm, over parent: NSWindow?) {
        self.form = form
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PrivateFeedbackSheet.width, height: 420),
                          styleMask: parent == nil ? [.titled, .closable] : [.titled], backing: .buffered, defer: true)
        super.init()
        window.title = form.context.kind == .problem ? L10n.string("Send Problem Report") : L10n.string("Send Feedback")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: PrivateFeedbackSheet(form: form) { [weak self] in
            self?.finish()
        })
        if let parent {
            parent.beginSheet(window)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if form.mayClose() { finish() }
        return false
    }

    /// Closes for good: stops a send, takes the window down and breaks its hold on the form.
    func finish() {
        form.cancelSending()
        if let parent = window.sheetParent { parent.endSheet(window) } else { window.orderOut(nil) }
        window.delegate = nil
        window.contentViewController = nil
        if PrivateFeedbackPresenter.shown === self { PrivateFeedbackPresenter.shown = nil }
    }
}

/// Opens Send Feedback from the sidebar, an error card or a remote window. Equal to every other, as
/// `YardletReportProblemAction` is, so the window is not evaluated again for a new closure.
struct YardletSendFeedbackAction: Equatable {
    let open: @MainActor (PrivateFeedbackContext) -> Void

    @MainActor func callAsFunction(_ context: PrivateFeedbackContext) { open(context) }

    static func == (lhs: Self, rhs: Self) -> Bool { true }

    static let presenting = YardletSendFeedbackAction { PrivateFeedbackPresenter.open($0, NSApp.keyWindow) }
}

private struct YardletSendFeedbackKey: EnvironmentKey {
    static let defaultValue: YardletSendFeedbackAction? = nil
}

private struct YardletFeedbackSurfaceKey: EnvironmentKey {
    static let defaultValue = PrivateFeedbackContext.Surface.localTask
}

extension EnvironmentValues {
    /// Send Feedback, for the sidebar's Feedback button and an error card's Send problem report. Nil
    /// where nothing should open, as in a test's window; the button is then left out.
    var yardletSendFeedback: YardletSendFeedbackAction? {
        get { self[YardletSendFeedbackKey.self] }
        set { self[YardletSendFeedbackKey.self] = newValue }
    }

    /// The kind of screen a note sent from here names: a task unless the window says otherwise.
    var yardletFeedbackSurface: PrivateFeedbackContext.Surface {
        get { self[YardletFeedbackSurfaceKey.self] }
        set { self[YardletFeedbackSurfaceKey.self] = newValue }
    }
}
