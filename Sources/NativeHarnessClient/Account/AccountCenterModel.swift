import Foundation
import Observation

/// The sign-in and sign-out console of an accounts presentation. Account readings belong to the
/// `ProviderConnectionStore` it was given: the console only runs a harness's own sign-in command
/// and, for Pi and Antigravity, reports what its read-only probe found to that store.
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
        if [.pi, .antigravityCLI].contains(descriptor.id) {
            verifyConnection(descriptor: descriptor, executableURL: executableURL, runtimeSelections: runtimeSelections)
        }
    }

    func logout(
        descriptor: HarnessDescriptor,
        runtimeSelections: RuntimeSelectionStore
    ) async {
        guard let executableURL = runtimeSelections.selectedURL(for: descriptor.id),
              let command = await broker.logoutCommand(
                for: descriptor.id,
                executableURL: executableURL
              ) else { return }
        stopConnectionVerification()
        activeHarness = descriptor.id
        loginController.start(command)
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

    /// Pi returns to its editor after OAuth, and Antigravity to its chat, instead of exiting.
    /// While this exact login is open, use the harness's credential-free, no-refresh probe to
    /// detect completion. Other providers retain their own exit/interactive contracts.
    private func verifyConnection(
        descriptor: HarnessDescriptor,
        executableURL: URL,
        runtimeSelections: RuntimeSelectionStore
    ) {
        let harness = descriptor.id
        let verificationID = UUID()
        connectionVerificationID = verificationID
        connectionVerificationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.connectionVerificationID == verificationID,
                      self.activeHarness == harness, self.loginController.isRunning,
                      runtimeSelections.selectedURL(for: harness) == executableURL else { return }
                // A probe of the default login is that login's reading; a saved account's probe
                // only tells the console when to finish.
                let readsDefault = self.activeConnection?.homePath == nil
                let read = readsDefault ? self.connections.beginRead(ofDefault: harness) : nil
                let snapshot = await self.connections.readDefault(descriptor, executableURL: executableURL,
                    connection: self.activeConnection)
                guard !Task.isCancelled, self.connectionVerificationID == verificationID,
                      self.activeHarness == harness, self.loginController.isRunning,
                      runtimeSelections.selectedURL(for: harness) == executableURL else { return }
                // A check can supersede this read while the same login is still open. Discard
                // only this result and keep verifying.
                if let read, !self.connections.finishRead(read, with: snapshot) { continue }
                // A Pi login completes for the provider it was opened for.
                if snapshot.state == .signedIn, harness != .pi || self.activeConnection?.providerID != nil {
                    self.loginController.completeVerifiedConnection()
                    return
                }
            }
        }
    }
}
