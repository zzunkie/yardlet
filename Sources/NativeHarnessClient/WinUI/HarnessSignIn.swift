import Foundation
import Observation
import UWP
import WinUI

/// Signing in to a harness from the Windows app, where the Mac signs in from a terminal inside Yardlet. Each harness
/// keeps its own login, and Yardlet runs only the harness's own sign-in and reads the result: Codex's browser
/// sign-in through its App Server, as the Codex app starts it (`CodexBrowserSignIn`), and every other harness's
/// sign-in command, or Codex's `codex login` where its App Server starts none, in a console window of its own
/// (`WindowsSignInConsole`). The login is read again as the Mac's console reads it: once the window closes, and
/// while it is open for a CLI that stays open after signing in (Antigravity, Pi).
@MainActor
@Observable
final class HarnessSignIn {
    enum Phase: Equatable {
        /// Codex's browser sign-in waits for the browser.
        case browser
        /// The harness's sign-in command runs in a console window.
        case console
        case signedIn
        /// The sign-in ended without a login, with why when it is known.
        case notSignedIn(String?)
    }

    private(set) var phases: [HarnessKind: Phase] = [:]
    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private var running: Set<HarnessKind> = []
    @ObservationIgnored private var codex: CodexBrowserSignIn?
    @ObservationIgnored private let log = QAEventLog.shared

    init(model: AppModel) {
        self.model = model
    }

    /// The account a new task with `harness` starts on, as the Mac's new task reads it.
    func account(_ harness: HarnessKind) -> AccountChoice? {
        let connections = model.connections
        return connections.choices(for: [harness]).first { $0.connection?.id == connections.selection[harness] }
    }

    /// The account's last reading says it needs a sign-in, which the Mac's new task offers then.
    func needsSignIn(_ harness: HarnessKind) -> Bool {
        guard let choice = account(harness) else { return false }
        return choice.snapshot?.state == .signedOut && AccountListProjection.offersConnect(choice, mode: .newTask(harness))
    }

    /// Reads the account unless its reading is fresh.
    func check(_ harness: HarnessKind) async {
        guard let choice = account(harness) else { return }
        await model.connections.check(choice, runtimeSelections: model.runtimeSelections)
    }

    func start(_ harness: HarnessKind) {
        guard running.insert(harness).inserted else { return }
        Task {
            await run(harness)
            running.remove(harness)
        }
    }

    /// Ends Codex's browser sign-in while it waits for the browser.
    func cancel(_ harness: HarnessKind) {
        guard harness == .codex, let codex else { return }
        Task { await codex.cancel() }
    }

    private func run(_ harness: HarnessKind) async {
        guard let executable = model.runtimeSelections.selectedURL(for: harness) else {
            phases[harness] = .notSignedIn(L10n.format("%@ is not available in Yardlet.", harness.displayName))
            return
        }
        log.write("sign-in: \(harness.rawValue)")
        let connection = account(harness)?.connection
        if harness == .codex, connection == nil {
            let signIn = CodexBrowserSignIn(executableURL: executable, environmentManager: model.codexEnvironmentManager)
            codex = signIn
            phases[harness] = .browser
            let outcome = await signIn.run { url in
                await MainActor.run { _ = WindowsBrowser.open(url) }
            }
            codex = nil
            switch outcome {
            case .signedIn:
                return await finish(harness)
            case .cancelled:
                phases[harness] = nil
                return
            case let .failed(reason):
                log.write("sign-in failed: \(reason ?? "")")
                phases[harness] = .notSignedIn(reason)
                return
            case let .unavailable(reason):
                // An App Server that starts no browser sign-in: `codex login` in a window, as below.
                log.write("browser sign-in unavailable: \(reason ?? "")")
            }
        }
        let broker = connection.map { HarnessAccountBroker(connection: $0) }
            ?? HarnessAccountBroker(codexEnvironmentManager: model.codexEnvironmentManager)
        guard let command = await broker.loginCommand(for: harness, executableURL: executable) else {
            phases[harness] = .notSignedIn(nil)
            return
        }
        let console: WindowsSignInConsole
        do {
            console = try WindowsSignInConsole.open(command)
        } catch {
            log.write("sign-in window failed: \(error.localizedDescription)")
            phases[harness] = .notSignedIn(L10n.format("The sign-in window could not open: %@", error.localizedDescription))
            return
        }
        phases[harness] = .console
        log.write("sign-in window opened")
        let staysOpen = [HarnessKind.pi, .antigravityCLI].contains(harness)
        while true {
            try? await Task.sleep(for: .seconds(2))
            let ended = console.hasEnded
            guard ended || staysOpen else { continue }
            if let choice = account(harness) {
                await model.connections.check(choice, policy: .restart, runtimeSelections: model.runtimeSelections)
            }
            if account(harness)?.snapshot?.state == .signedIn { return await finish(harness) }
            if ended {
                phases[harness] = .notSignedIn(nil)
                return
            }
        }
    }

    private func finish(_ harness: HarnessKind) async {
        if let choice = account(harness), choice.snapshot?.state != .signedIn {
            await model.connections.check(choice, policy: .restart, runtimeSelections: model.runtimeSelections)
        }
        phases[harness] = .signedIn
        log.write("signed in: \(harness.rawValue)")
    }
}

/// A harness's sign-in where a task starts or failed for it: what the harness needs and Sign in while its login
/// reads signed out, then how the sign-in goes. It shows nothing while the login needs nothing, except where a turn
/// already failed for its sign-in (`offersAlways`), which the login's reading may not know yet.
@MainActor
final class SignInRow {
    let view = StackPanel()
    private let words = TextBlock()
    private let button = Button()
    private let signIn: HarnessSignIn
    private let offersAlways: Bool
    private var harness: HarnessKind?
    /// Ends the following of a harness no longer shown.
    private var generation = 0
    private var action: (() -> Void)?
    /// The panel the row was placed in, which it leaves when it is placed again.
    private var host: StackPanel?

    init(signIn: HarnessSignIn, offersAlways: Bool = false) {
        self.signIn = signIn
        self.offersAlways = offersAlways
        view.spacing = 8
        view.visibility = .collapsed
        words.textWrapping = .wrap
        words.opacity = 0.75
        view.children.append(words)
        button.click.addHandler { [weak self] _, _ in self?.action?() }
        view.children.append(button)
    }

    /// Puts the row at the end of `panel`, out of the panel it was in, as a turn that redraws places it again.
    func place(in panel: StackPanel) {
        if let host {
            var index: UInt32 = 0
            if host.children.indexOf(view, &index) { host.children.removeAt(index) }
        }
        panel.children.append(view)
        host = panel
    }

    /// Follows `harness`'s sign-in, reading its login unless the reading is fresh.
    func show(_ harness: HarnessKind?) {
        guard harness != self.harness else { return }
        self.harness = harness
        follow()
        if let harness { Task { await signIn.check(harness) } }
    }

    private func follow() {
        generation += 1
        let current = generation
        guard let harness else {
            view.visibility = .collapsed
            return
        }
        let (phase, needsSignIn) = withObservationTracking {
            (signIn.phases[harness], signIn.needsSignIn(harness))
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.follow()
            }
        }
        let name = harness.displayName
        switch phase {
        case nil:
            guard needsSignIn || offersAlways else {
                view.visibility = .collapsed
                return
            }
            present(ProviderSignIn.neededHere(harness), button: L10n.string("Sign in")) { [weak self] in
                self?.signIn.start(harness)
            }
        case .browser?:
            present(L10n.format("Finish signing in to %@ in your browser.", name), button: L10n.string("Cancel")) {
                [weak self] in self?.signIn.cancel(harness)
            }
        case .console?:
            present(L10n.format("Finish signing in to %@ in the window that opened.", name), button: nil, action: nil)
        case .signedIn?:
            present(L10n.format("Signed in to %@.", name), button: nil, action: nil)
        case let .notSignedIn(reason)?:
            present(reason ?? L10n.format("%@ is still not signed in.", name), button: L10n.string("Sign in")) {
                [weak self] in self?.signIn.start(harness)
            }
        }
    }

    private func present(_ text: String, button title: String?, action: (() -> Void)?) {
        words.text = text
        button.content = title ?? ""
        button.visibility = title == nil ? .collapsed : .visible
        try? AutomationProperties.setName(button, title ?? "")
        self.action = action
        view.visibility = .visible
    }
}
