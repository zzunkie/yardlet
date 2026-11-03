import AuthenticationServices
import Foundation
import Network
import Observation
import YardletLidSleep
import YardletRemote

/// The phone remote on this Mac (docs/REMOTE_PROTOCOL.md): off until the person turns it on in
/// Settings › Remote. While on, it serves protocol v2 (§11–§17) on every path: a listener on every
/// interface advertised with Bonjour (the same network and Tailscale), and an outgoing socket to the
/// Yardlet relay when one is configured and allowed. It keeps the paired devices
/// (`~/.yardlet/remote/devices.json`: the phones' public keys and push registrations), the audit log (`~/.yardlet/remote/audit.log`, no message text) and the Mac's keys in the
/// Keychain. The server, listeners and relay run off the main actor; this object holds what
/// Settings shows.
@MainActor
@Observable
final class RemoteControlService {
    static let enabledKey = "Yardlet.remote.enabled"
    /// Outside connections through the relay; on unless the person turned it off.
    static let relayEnabledKey = "Yardlet.remote.relay"
    /// A relay other than the built-in one (development, self-hosting).
    static let relayURLKey = "Yardlet.remote.relayURL"
    /// Keeps this Mac from sleeping on its own while remote connections are allowed and it is on power,
    /// so a device elsewhere can still reach it; off unless the person turned it on.
    static let keepAwakeKey = "Yardlet.remote.keepAwakeOnPower"
    static let relayURLEnvironmentKey = "YARDLET_REMOTE_RELAY_URL"
    /// The Yardlet relay a build carries, from `YardletRelayURL` in Info.plist (scripts/build-app.sh
    /// writes it from Packaging/RelayURL, which stays out of git; REMOTE_V2_DESIGN.md §12).
    static let builtInRelayURLKey = "YardletRelayURL"
    static let builtInRelayURL = Bundle.main.object(forInfoDictionaryKey: builtInRelayURLKey) as? String

    struct Pairing: Equatable {
        var expiresAt: Date
        /// What the QR code holds.
        var url: URL?
    }

    /// Which paths a phone can take now, for Settings.
    struct Reach: Equatable {
        /// The v2 listener is up: the same network, and Tailscale when the Mac has a Tailscale address.
        var direct: Bool
        var tailscale: Bool
        var relay: RemoteRelayClient.State?
        var directFailure: String?
    }

    private(set) var isEnabled: Bool
    private(set) var isRelayEnabled: Bool
    private(set) var keepsAwakeOnPower: Bool
    /// The v2 listener's state; a rendering test sets it where nothing listens.
    var secureState: RemoteSecureListener.State = .stopped
    /// The relay client's state; a rendering test sets it where nothing connects.
    var relayState: RemoteRelayClient.State = .off
    private(set) var devices: [RemoteDevice] = []
    private(set) var connectedDeviceIDs: Set<String> = []
    private(set) var connectedPaths: [String: RemotePath] = [:]
    private(set) var linkRequest: RemoteLinkRequest?
    private(set) var pairing: Pairing?
    /// The device the last pairing added, shown until the next pairing.
    private(set) var pairedDeviceName: String?
    private(set) var magicDNSName: String?
    private(set) var interfaceAddresses: [RemoteInterfaceAddress] = []
    /// The relay account this Mac is on, when signed in (§14.4).
    private(set) var account: RemoteAccountClient.Account?
    /// The sign-in providers the relay offers; empty hides the account row.
    private(set) var accountProviders: [String] = []
    private(set) var isSigningIn = false
    private(set) var accountError: String?

    /// Settings shows the account row while signed in, or when the relay offers a sign-in provider: a relay
    /// without OAuth credentials has no accounts, and the phone remote still goes through it.
    var showsAccount: Bool { account != nil || !accountProviders.isEmpty }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private let interfaces: @Sendable () -> [RemoteInterfaceAddress]
    @ObservationIgnored private let resolveName: @Sendable (String) -> String?
    @ObservationIgnored private let macName: String
    @ObservationIgnored let server: RemoteServer
    @ObservationIgnored private let deviceStore: RemoteDeviceStore
    @ObservationIgnored private let identityStore: RemoteIdentityLoader
    @ObservationIgnored private(set) var identity: RemoteIdentity?
    /// False where nothing may listen (tests that drive the server directly, visual fixtures).
    @ObservationIgnored private let listens: Bool
    @ObservationIgnored private var secureListener: RemoteSecureListener?
    @ObservationIgnored private var relayClient: RemoteRelayClient?
    @ObservationIgnored private let accountToken: any RemoteSecretStoring
    @ObservationIgnored private let webSignIn: @MainActor (URL, String) async throws -> URL
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var startup: Task<Void, Never>?
    @ObservationIgnored private var activation: Task<Void, Never>?
    @ObservationIgnored private var pairingRequestID: UUID?
    @ObservationIgnored private var nameLookup: Task<Void, Never>?
    /// The Tailscale address last looked up, so an address without a MagicDNS name is asked once.
    @ObservationIgnored private var lookedUpAddress: String?
    /// Whether the Mac runs on power now (no battery, or charging); read again every minute while it matters.
    @ObservationIgnored private let isOnPower: @MainActor () -> Bool
    @ObservationIgnored private var awakeActivity: NSObjectProtocol?
    @ObservationIgnored private var powerCheck: Timer?

    init(
        bridge: any RemoteBridge,
        deviceStore: RemoteDeviceStore,
        audit: RemoteAuditLog?,
        identityStore: any RemoteIdentityStoring = RemoteMemoryIdentityStore(),
        accountToken: any RemoteSecretStoring = RemoteMemorySecret(),
        webSignIn: @escaping @MainActor (URL, String) async throws -> URL = { _, _ in throw CancellationError() },
        defaults: UserDefaults = .yardlet,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        interfaces: @escaping @Sendable () -> [RemoteInterfaceAddress] = RemoteAddressSelection.systemInterfaces,
        resolveName: @escaping @Sendable (String) -> String? = RemoteAddressSelection.magicDNSName(for:),
        listens: Bool = true,
        isOnPower: @escaping @MainActor () -> Bool = { !PowerConditions.current().onBattery },
        macName: String = Host.current().localizedName ?? "Mac",
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    ) {
        self.defaults = defaults
        self.environment = environment
        self.interfaces = interfaces
        self.resolveName = resolveName
        self.macName = macName
        self.deviceStore = deviceStore
        self.identityStore = RemoteIdentityLoader(store: identityStore)
        self.accountToken = accountToken
        self.webSignIn = webSignIn
        self.listens = listens
        self.isOnPower = isOnPower
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        isRelayEnabled = defaults.object(forKey: Self.relayEnabledKey) as? Bool ?? true
        keepsAwakeOnPower = defaults.bool(forKey: Self.keepAwakeKey)
        server = RemoteServer(
            configuration: RemoteServer.Configuration(server: RemoteServerInfo(name: macName, appVersion: appVersion),
                                                      macKey: nil),
            bridge: bridge, devices: deviceStore, audit: audit)
    }

    /// The remote for the app: its bridge to the model, its files under `~/.yardlet/remote`, and its
    /// keys in the Keychain.
    static func live(model: AppModel) -> RemoteControlService {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: YardletProduct.storageDirectoryName, directoryHint: .isDirectory)
            .appending(path: "remote", directoryHint: .isDirectory)
        return RemoteControlService(
            bridge: AppModelRemoteBridge(model: model, makePreview: RemoteImagePreviewMaker.make, browser: RemoteTabBridge.Environment(
                client: AppModel.macBrowserClient, usesMacEditingCommands: true,
                marksTypedSecrets: {
                    let vault = MacAgentToolService.shared.vault
                    return vault.isAllowedBuild && (vault.isEnabled || vault.isWalletEnabled)
                })),
            deviceStore: RemoteDeviceStore(fileURL: folder.appending(path: "devices.json")),
            audit: RemoteAuditLog(fileURL: folder.appending(path: "audit.log")),
            identityStore: KeychainRemoteIdentityStore.live(),
            accountToken: KeychainRemoteSecret.accountToken(),
            webSignIn: { url, scheme in try await RemoteAccountSignIn().signIn(at: url, callbackScheme: scheme) })
    }

    // MARK: - Account (§14.4)

    private var accountClient: RemoteAccountClient? {
        relayURL.map { RemoteAccountClient(baseURL: $0) }
    }

    /// Reads the providers, and with a saved token puts this Mac on the account again (its name may
    /// have changed) and takes link requests. A token the relay no longer knows is dropped.
    func refreshAccount() async {
        guard isEnabled, let client = accountClient else { return }
        accountProviders = (try? await client.providers()) ?? accountProviders
        guard let token = await withAccountToken({ $0.load() }), let identity = await ensureIdentity() else { return }
        do {
            let current = try await client.account(token: token)
            try await client.registerMac(token: token, identity: identity, name: macName, accountID: current.id)
            account = current
            await server.setAcceptsLinks(true)
        } catch let failure as RemoteAccountClient.Failure where failure.isUnauthorized {
            await withAccountToken { $0.delete() }
            account = nil
            await server.setAcceptsLinks(false)
        } catch {
            accountError = error.localizedDescription
        }
    }

    /// Signs in with a provider in the browser sheet and puts this Mac on the account.
    func signIn(with provider: String) async {
        guard let client = accountClient, !isSigningIn else { return }
        isSigningIn = true
        accountError = nil
        defer { isSigningIn = false }
        guard let identity = await ensureIdentity() else { return }
        let pkce = RemoteAccountClient.PKCE()
        let state = RemoteEncoding.base64url(Data(RemoteRandom.bytes(16)))
        do {
            guard let url = client.startURL(provider: provider, pkce: pkce, state: state) else { return }
            let callback = try await webSignIn(url, RemoteAccountClient.callbackScheme)
            guard let code = RemoteAccountClient.code(from: callback, state: state) else {
                accountError = L10n.string("The sign-in did not finish.")
                return
            }
            let (token, signedIn) = try await client.exchange(code: code, pkce: pkce, deviceName: macName)
            await withAccountToken { $0.save(token) }
            try await client.registerMac(token: token, identity: identity, name: macName, accountID: signedIn.id)
            account = signedIn
            await server.setAcceptsLinks(true)
        } catch is CancellationError {
            return
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        } catch {
            accountError = error.localizedDescription
        }
    }

    /// Takes this Mac off the account and forgets the token; link requests stop.
    func signOut() async {
        if let client = accountClient, let token = await withAccountToken({ $0.load() }) {
            if let identity = await loadIdentity(create: false) { try? await client.removeMac(token: token, room: identity.room) }
            try? await client.logout(token: token)
        }
        await withAccountToken { $0.delete() }
        account = nil
        await server.setAcceptsLinks(false)
    }

    /// Runs an account-token operation off the main actor: the keychain can wait on a system prompt.
    private func withAccountToken<T: Sendable>(_ operation: @escaping @Sendable (any RemoteSecretStoring) -> T) async -> T {
        let accountToken = accountToken
        return await Task.detached { operation(accountToken) }.value
    }

    /// The relay this Mac uses: the developer's or self-hosted one, else the built-in one.
    var relayURL: URL? {
        let configured = environment[Self.relayURLEnvironmentKey] ?? defaults.string(forKey: Self.relayURLKey) ?? Self.builtInRelayURL
        guard let configured, let url = URL(string: configured), let scheme = url.scheme,
              ["wss", "https", "ws", "http"].contains(scheme) else { return nil }
        return url
    }

    /// Connects the server and, when the remote is on, starts serving.
    func start() async {
        guard !started else { return }
        started = true
        startup = Task {
            _ = await loadIdentity(create: false)
            guard started, !Task.isCancelled else { return }
            await server.start()
            guard started, !Task.isCancelled else { return }
            await server.setStatusHandler { [weak self] status in
                Task { @MainActor in await self?.apply(status) }
            }
            guard started, !Task.isCancelled else { return }
            await reloadDevices()
        }
        await startup?.value
        guard started, !Task.isCancelled else { return }
        if isEnabled {
            activate()
            await activation?.value
        }
        refreshAwake()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            activate()
        } else {
            deactivate(reason: "disabled")
        }
        refreshAwake()
    }

    func setKeepsAwakeOnPower(_ keepsAwake: Bool) {
        guard keepsAwake != keepsAwakeOnPower else { return }
        keepsAwakeOnPower = keepsAwake
        defaults.set(keepsAwake, forKey: Self.keepAwakeKey)
        refreshAwake()
    }

    /// The Mac is kept from sleeping on its own now, as Codex's "Keep this Mac awake" does: the remote is
    /// on, the setting is on and the Mac is on power. The display may still sleep, and the hold ends with
    /// Yardlet.
    var isKeepingAwake: Bool { awakeActivity != nil }

    private func refreshAwake() {
        let wanted = started && isEnabled && keepsAwakeOnPower
        let holds = wanted && isOnPower()
        if holds, awakeActivity == nil {
            awakeActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled], reason: "Remote connections are allowed and this Mac stays awake on power")
        } else if !holds, let awakeActivity {
            ProcessInfo.processInfo.endActivity(awakeActivity)
            self.awakeActivity = nil
        }
        // Plugged in or not is read again every minute while the setting wants it.
        if wanted, powerCheck == nil {
            powerCheck = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshAwake() }
            }
        } else if !wanted {
            powerCheck?.invalidate()
            powerCheck = nil
        }
    }

    func setRelayEnabled(_ enabled: Bool) {
        guard enabled != isRelayEnabled else { return }
        isRelayEnabled = enabled
        defaults.set(enabled, forKey: Self.relayEnabledKey)
        guard isEnabled else { return }
        if enabled { startRelay() } else { stopRelay() }
        publishDirectory()
    }

    /// The paths a phone can take now (§11.1).
    var reach: Reach {
        let direct: Bool
        var failure: String?
        switch secureState {
        case .ready: direct = true
        case let .failed(message):
            direct = false
            failure = message
        case .starting, .stopped: direct = false
        }
        let relay: RemoteRelayClient.State? = isRelayEnabled && relayURL != nil ? relayState : nil
        return Reach(direct: direct, tailscale: interfaceAddresses.contains { RemoteAddressSelection.isTailscale($0.address) },
                     relay: relay, directFailure: failure)
    }

    /// Opens a pairing for five minutes and shows its QR code.
    func startPairing() async {
        let requestID = UUID()
        pairingRequestID = requestID
        await startup?.value
        guard pairingRequestID == requestID, !Task.isCancelled else { return }
        if isEnabled {
            activate()
            await activation?.value
        }
        guard pairingRequestID == requestID, !Task.isCancelled else { return }
        guard let identity = await ensureIdentity(), pairingRequestID == requestID, !Task.isCancelled else { return }
        let ticket = await server.openPairing()
        guard pairingRequestID == requestID, !Task.isCancelled else { return }
        pairedDeviceName = nil
        let relay = relayClient?.relayInfo
        pairing = Pairing(expiresAt: ticket.expiresAt, url: RemoteSecurePairingURL(
            macKey: identity.noise.publicKey, secret: ticket.secret, name: macName, hosts: directHosts,
            relayURL: relay?.url, room: relay?.room).url)
        lookUpMagicDNSName()
    }

    func cancelPairing() {
        pairingRequestID = nil
        pairing = nil
        Task { await server.cancelPairing() }
    }

    /// Removes a paired device; it is disconnected at once and its key or token stops working.
    func remove(_ device: RemoteDevice) async {
        await server.revoke(device.id)
        await reloadDevices()
    }

    /// Approves or refuses a phone that asked to link through the account (§12.1).
    func answerLink(approve: Bool) async {
        guard let linkRequest else { return }
        await server.answerLink(linkRequest.id, approve: approve)
    }

    /// Closes every phone connection: Yardlet is quitting.
    func shutdown() async {
        guard started else { return }
        started = false
        startup?.cancel()
        activation?.cancel()
        activation = nil
        pairingRequestID = nil
        refreshAwake()
        await server.shutdown(reason: "quitting")
        secureListener?.stop()
        relayClient?.stop()
    }

    func reloadDevices() async {
        devices = await deviceStore.all().sorted { $0.createdAt < $1.createdAt }
        refreshAddresses()
    }

    // MARK: - Serving

    /// The Mac's keys, made the first time the remote is used. All callers share the loader,
    /// whose actor serializes keychain reads and creation away from the main actor.
    private func ensureIdentity() async -> RemoteIdentity? {
        await loadIdentity(create: true)
    }

    private func loadIdentity(create: Bool) async -> RemoteIdentity? {
        if let identity { return identity }
        guard let loaded = try? await identityStore.load(create: create) else { return nil }
        await server.setMacKey(loaded.noise.publicKey)
        identity = loaded
        return loaded
    }

    private func activate() {
        refreshAddresses()
        guard activation == nil else { return }
        activation = Task {
            await activateWhenReady()
            // A failed keychain read can be retried by the next activation request.
            if !Task.isCancelled, identity == nil { activation = nil }
        }
    }

    private func activateWhenReady() async {
        await startup?.value
        guard !Task.isCancelled, isEnabled else { return }
        let prepared = await ensureIdentity()
        guard !Task.isCancelled, isEnabled else { return }
        if let identity = prepared {
            if listens, secureListener == nil {
                let listener = RemoteSecureListener(server: server, staticKey: identity.noise,
                                                    advertisement: .of(identity))
                listener.onStateChange = { [weak self] state in
                    Task { @MainActor in
                        self?.secureState = state
                        self?.publishDirectory()
                    }
                }
                secureListener = listener
                listener.start()
            }
            if isRelayEnabled { startRelay() }
            Task { await refreshAccount() }
        }
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                self?.refreshAddresses()
                self?.relayClient?.reconnectSoon()
            }
        }
        monitor.start(queue: DispatchQueue(label: "yardlet.remote.paths"))
        self.monitor = monitor
    }

    private func deactivate(reason: String) {
        activation?.cancel()
        activation = nil
        pairingRequestID = nil
        monitor?.cancel()
        monitor = nil
        pairing = nil
        secureListener?.stop()
        secureListener = nil
        secureState = .stopped
        stopRelay()
        Task { await server.shutdown(reason: reason) }
    }

    private func startRelay() {
        guard listens, isEnabled, isRelayEnabled, relayClient == nil, let url = relayURL else { return }
        guard let identity else {
            activate()
            return
        }
        let client = RemoteRelayClient(server: server, identity: identity, baseURL: url)
        client.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.relayState = state
                self?.publishDirectory()
            }
        }
        relayClient = client
        client.start()
        Task { await server.setPushSender { await client.push($0) } }
    }

    private func stopRelay() {
        relayClient?.stop()
        relayClient = nil
        relayState = .off
        Task { await server.setPushSender(nil) }
    }

    /// Reads the interfaces again: phones are told the addresses to try directly.
    func refreshAddresses() {
        guard isEnabled else { return }
        interfaceAddresses = interfaces()
        publishDirectory()
        if magicDNSName == nil { lookUpMagicDNSName() }
    }

    /// The v2 addresses a phone tries directly, `host:port`, in order: the same network, then
    /// Tailscale (its IPv4, the MagicDNS name, its IPv6).
    var directHosts: [String] {
        guard case let .ready(securePort) = secureState else { return [] }
        let local = interfaceAddresses.filter { $0.family == .ipv4 && RemoteAddressSelection.isPrivateLAN($0.address) }.map(\.address)
        let tailscale4 = interfaceAddresses.filter { $0.family == .ipv4 && RemoteAddressSelection.isTailscale($0.address) }.map(\.address)
        let tailscale6 = interfaceAddresses.filter { $0.family == .ipv6 && RemoteAddressSelection.isTailscale($0.address) }
            .map { "[\($0.address)]" }
        var hosts = Array(NSOrderedSet(array: local + tailscale4)) as? [String] ?? []
        if let magicDNSName { hosts.append(magicDNSName) }
        hosts += tailscale6
        return hosts.map { "\($0):\(securePort)" }
    }

    private func publishDirectory() {
        let direct = directHosts
        let relay = relayClient?.relayInfo
        Task { await server.setDirectory(direct: direct, relay: relay) }
    }

    /// The MagicDNS name, read once by a reverse lookup off the main thread; nothing is changed.
    private func lookUpMagicDNSName() {
        guard magicDNSName == nil, nameLookup == nil,
              let ipv4 = interfaceAddresses.first(where: { $0.family == .ipv4 && RemoteAddressSelection.isTailscale($0.address) })?.address,
              ipv4 != lookedUpAddress
        else { return }
        lookedUpAddress = ipv4
        let resolveName = self.resolveName
        nameLookup = Task {
            let name = await Task.detached(priority: .utility) { resolveName(ipv4) }.value
            nameLookup = nil
            guard let name else { return }
            magicDNSName = name
            publishDirectory()
        }
    }

    private func apply(_ status: RemoteServer.Status) async {
        connectedDeviceIDs = status.connectedDeviceIDs
        connectedPaths = status.connectedPaths
        linkRequest = status.linkRequest
        if status.pairing == nil, pairing != nil { pairing = nil }
        await reloadDevices()
        if let id = status.pairedDeviceID {
            pairedDeviceName = devices.first { $0.id == id }?.name
        }
    }
}

/// A single off-main queue for the stored identity prevents concurrent first requests from
/// generating different keys while the keychain is still answering.
private actor RemoteIdentityLoader {
    let store: any RemoteIdentityStoring
    private var identity: RemoteIdentity?
    private var hasLoaded = false

    init(store: any RemoteIdentityStoring) { self.store = store }

    func load(create: Bool) throws -> RemoteIdentity? {
        if let identity { return identity }
        if create {
            identity = try store.loadOrCreate()
        } else if !hasLoaded {
            identity = try store.load()
        }
        hasLoaded = true
        return identity
    }
}
