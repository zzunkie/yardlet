import Foundation
import Observation

/// The sign-in and sign-out console of an accounts presentation. Account readings belong to the
/// `ProviderConnectionStore` it was given: the console only runs a harness's own sign-in or sign-out
/// command and, for a CLI that stays open after it, reports what its read-only probe found to that store.
@MainActor
@Observable
final class AccountCenterModel {
    private(set) var activeHarness: HarnessKind?
    private(set) var activeConnection: ProviderConnection?
    let loginController = AccountLoginController()
    var showsLoginDetails = false
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
        showsLoginDetails = command.interaction == .terminalRequired
        loginController.start(command)
    }

    func login(
        descriptor: HarnessDescriptor,
        connection: ProviderConnection? = nil,
        runtimeSelections: RuntimeSelectionStore
    ) async {
        guard let executableURL = runtimeSelections.selectedURL(for: descriptor.id),
              let login = await prepareLogin(descriptor: descriptor, connection: connection, executableURL: executableURL),
              runtimeSelections.selectedURL(for: descriptor.id) == executableURL else { return }
        startLogin(descriptor: descriptor, connection: login.connection, command: login.command,
                   executableURL: executableURL, runtimeSelections: runtimeSelections)
    }

    private func prepareLogin(
        descriptor: HarnessDescriptor, connection: ProviderConnection?, executableURL: URL
    ) async -> (command: AccountInteractiveCommand, connection: ProviderConnection?)? {
        var connection = connection
        if descriptor.id == .pi, connection?.providerID == nil,
           let provider = HarnessAccountBroker.piConfiguredProvider(homePath: connection?.homePath) {
            connection = ProviderConnection(id: connection?.id ?? "pi-configured", name: connection?.name ?? "Pi",
                harness: .pi, providerID: provider, homePath: connection?.homePath, credentialSelector: nil)
        }
        guard let command = await (connection.map { HarnessAccountBroker(connection: $0) } ?? broker)
            .loginCommand(for: descriptor.id, executableURL: executableURL) else { return nil }
        return (command, connection)
    }

    private func startLogin(descriptor: HarnessDescriptor, connection: ProviderConnection?,
                            command: AccountInteractiveCommand, executableURL: URL, runtimeSelections: RuntimeSelectionStore) {
        stopConnectionVerification()
        showsLoginDetails = command.interaction == .terminalRequired
        activeConnection = connection
        activeHarness = descriptor.id
        if descriptor.id == .antigravityCLI {
            loginController.start(command) { [weak self] in
                guard let self else { return false }
                self.stopConnectionVerification()
                return await self.connections.verifyAntigravityLogin(descriptor, executableURL: executableURL,
                                                                    runtimeSelections: runtimeSelections)
            }
        } else {
            loginController.start(command)
        }
        // Pi and older Antigravity versions stay in their editor after signing in.
        if descriptor.id == .pi || (descriptor.id == .antigravityCLI && command.initialInput != nil) {
            follow(descriptor: descriptor, executableURL: executableURL, runtimeSelections: runtimeSelections,
                   until: { [weak self] in
                       // A Pi login completes for the provider it was opened for.
                       $0.state == .signedIn && (descriptor.id != .pi || self?.activeConnection?.providerID != nil)
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
        let next = signsInAfter
            ? await prepareLogin(descriptor: descriptor, connection: nil, executableURL: executableURL) : nil
        guard (!signsInAfter || next != nil), runtimeSelections.selectedURL(for: descriptor.id) == executableURL
        else { return }
        stopConnectionVerification()
        activeConnection = nil
        activeHarness = descriptor.id
        showsLoginDetails = command.interaction == .terminalRequired
        loginController.start(command)
        if let next {
            loginController.onSuccessfulCompletion = { [weak self] in
                guard runtimeSelections.selectedURL(for: descriptor.id) == executableURL else { return }
                self?.startLogin(descriptor: descriptor, connection: next.connection, command: next.command,
                                 executableURL: executableURL, runtimeSelections: runtimeSelections)
            }
        }
        // A CLI with an in-terminal /logout command stays open after signing out.
        if command.initialInput != nil {
            follow(descriptor: descriptor, executableURL: executableURL, runtimeSelections: runtimeSelections,
                   until: { $0.state == .signedOut })
        }
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

    /// A CLI that stays open after changing the account finishes when its read-only probe confirms
    /// the change. A reading of the default account is also published to the accounts store.
    private func follow(
        descriptor: HarnessDescriptor,
        executableURL: URL,
        runtimeSelections: RuntimeSelectionStore,
        until isDone: @escaping @MainActor (HarnessAccountSnapshot) -> Bool
    ) {
        let verificationID = UUID()
        connectionVerificationID = verificationID
        connectionVerificationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.isFollowing(verificationID, descriptor.id, executableURL, runtimeSelections)
                else { return }
                guard self.loginController.isRunning else { return }
                // A probe of the default login is that login's reading; a saved account's probe
                // only tells the console when to finish.
                let readsDefault = self.activeConnection?.homePath == nil
                let read = readsDefault ? self.connections.beginRead(ofDefault: descriptor.id) : nil
                let snapshot = await self.connections.readDefault(descriptor, executableURL: executableURL,
                    connection: self.activeConnection, authOnly: true)
                guard !Task.isCancelled, self.isFollowing(verificationID, descriptor.id, executableURL,
                    runtimeSelections), self.loginController.isRunning else { return }
                // A check can supersede this read while the same console is still open. Discard
                // only this result and keep following.
                if let read, !self.connections.finishRead(read, with: snapshot) { continue }
                guard isDone(snapshot) else { continue }
                if descriptor.id == .antigravityCLI, snapshot.state == .signedIn {
                    self.connections.refreshAntigravityUsage(snapshot, executableURL: executableURL,
                                                           runtimeSelections: runtimeSelections)
                }
                self.loginController.completeVerifiedConnection()
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
