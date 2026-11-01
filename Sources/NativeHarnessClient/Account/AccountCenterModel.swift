import Foundation
import Observation

/// The sign-in and sign-out console of an accounts presentation. Account readings belong to the
/// `ProviderConnectionStore` it was given: the console only runs a harness's own sign-in command
/// and, for Pi, reports what its read-only probe found to that store.
@MainActor
@Observable
final class AccountCenterModel {
    private(set) var activeHarness: HarnessKind?
    private(set) var activeConnection: ProviderConnection?
    let loginController = AccountLoginController()
    @ObservationIgnored let connections: ProviderConnectionStore

    @ObservationIgnored private let broker: HarnessAccountBroker
    @ObservationIgnored private var connectionVerificationTask: Task<Void, Never>?
    @ObservationIgnored private var connectionVerificationID: UUID?
    @ObservationIgnored private var hasClaimedInitialLoad = false

    init(connections: ProviderConnectionStore, codexEnvironmentManager: CodexEnvironmentManager? = nil) {
        self.connections = connections
        broker = HarnessAccountBroker(codexEnvironmentManager: codexEnvironmentManager)
    }

    /// True the first time it is asked, so a presentation starts its checks once even when its
    /// accounts and harnesses pages appear more than once.
    func claimInitialLoad() -> Bool {
        defer { hasClaimedInitialLoad = true }
        return !hasClaimedInitialLoad
    }

    /// Starts a DEBUG-owned presentation command without account discovery or a
    /// provider runtime. Production callers enter through `login` and `logout`.
    func seedConnectionFlow(
        harness: HarnessKind,
        command: AccountInteractiveCommand
    ) {
        stopConnectionVerification()
        activeHarness = harness
        loginController.start(command)
    }

    func login(
        descriptor: HarnessDescriptor,
        connection: ProviderConnection? = nil,
        runtimeSelections: RuntimeSelectionStore
    ) async {
        var connection = connection
        if descriptor.id == .pi, connection?.providerID == nil,
           let provider = HarnessAccountBroker.piConfiguredProvider(homePath: connection?.homePath) {
            connection = ProviderConnection(id: connection?.id ?? "pi-configured", name: connection?.name ?? "Pi",
                harness: .pi, providerID: provider, homePath: connection?.homePath, credentialSelector: nil)
        }
        guard let executableURL = runtimeSelections.selectedURL(for: descriptor.id),
              let command = await (connection.map { HarnessAccountBroker(connection: $0) } ?? broker).loginCommand(
                for: descriptor.id,
                executableURL: executableURL
              ) else { return }
        stopConnectionVerification()
        activeConnection = connection
        activeHarness = descriptor.id
        loginController.start(command)
        // Pi returns to its editor after OAuth instead of exiting.
        if descriptor.id == .pi {
            follow(descriptor: descriptor, executableURL: executableURL, runtimeSelections: runtimeSelections,
                   probes: true, until: { [weak self] in
                       $0.state == .signedIn && self?.activeConnection?.providerID != nil
                   })
        }
    }

    /// Signs the default login out with the harness's own command. With `signsInAfter`, the
    /// harness's sign-in opens in the same console once the sign-out has finished, so a login the
    /// harness keeps in one place (Antigravity's keychain item) can change to another account.
    func logout(
        descriptor: HarnessDescriptor,
        signsInAfter: Bool = false,
        runtimeSelections: RuntimeSelectionStore
    ) async {
        guard let executableURL = runtimeSelections.selectedURL(for: descriptor.id),
              let command = await broker.logoutCommand(
                for: descriptor.id,
                executableURL: executableURL
              ) else { return }
        stopConnectionVerification()
        activeConnection = nil
        activeHarness = descriptor.id
        loginController.start(command)
        var signIn: (@MainActor () async -> Void)?
        if signsInAfter {
            signIn = { [weak self] in await self?.login(descriptor: descriptor, runtimeSelections: runtimeSelections) }
        }
        // A CLI whose sign-out is a command in its own terminal (`/logout`) stays open after it.
        follow(descriptor: descriptor, executableURL: executableURL, runtimeSelections: runtimeSelections,
               probes: command.interaction == .terminalRequired, until: { $0.state == .signedOut }, then: signIn)
    }

    func closeConsole() {
        stopConnectionVerification()
        loginController.stop()
        activeHarness = nil
        activeConnection = nil
    }

    private func stopConnectionVerification() {
        connectionVerificationTask?.cancel()
        connectionVerificationTask = nil
        connectionVerificationID = nil
    }

    /// Follows the console's command until it ends. A CLI that stays open after doing its job is
    /// finished once its credential-free, no-refresh probe reads `isDone`, without inventing a
    /// successful exit or relying on terminal text; the probe of the default login is that login's
    /// reading. `next` runs when the command has completed, by exiting or by the probe.
    private func follow(
        descriptor: HarnessDescriptor,
        executableURL: URL,
        runtimeSelections: RuntimeSelectionStore,
        probes: Bool,
        until isDone: @escaping @MainActor (HarnessAccountSnapshot) -> Bool = { _ in false },
        then next: (@MainActor () async -> Void)? = nil
    ) {
        guard probes || next != nil else { return }
        let verificationID = UUID()
        connectionVerificationID = verificationID
        connectionVerificationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.isFollowing(verificationID, descriptor.id, executableURL, runtimeSelections)
                else { return }
                if self.loginController.isRunning {
                    guard probes else { continue }
                    // A probe of the default login is that login's reading; a saved account's probe
                    // only tells the console when to finish.
                    let readsDefault = self.activeConnection?.homePath == nil
                    let read = readsDefault ? self.connections.beginRead(ofDefault: descriptor.id) : nil
                    let snapshot = await self.connections.readDefault(descriptor, executableURL: executableURL,
                        connection: self.activeConnection)
                    guard !Task.isCancelled, self.isFollowing(verificationID, descriptor.id, executableURL,
                        runtimeSelections), self.loginController.isRunning else { return }
                    // A check can supersede this read while the same console is still open. Discard
                    // only this result and keep following.
                    if let read, !self.connections.finishRead(read, with: snapshot) { continue }
                    guard isDone(snapshot) else { continue }
                    self.loginController.completeVerifiedConnection()
                }
                if self.loginController.phase == .completed, let next { await next() }
                return
            }
        }
    }

    private func isFollowing(_ verificationID: UUID, _ harness: HarnessKind, _ executableURL: URL,
                             _ runtimeSelections: RuntimeSelectionStore) -> Bool {
        connectionVerificationID == verificationID && activeHarness == harness
            && runtimeSelections.selectedURL(for: harness) == executableURL
    }
}
