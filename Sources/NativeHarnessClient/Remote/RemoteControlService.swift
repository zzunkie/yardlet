import Foundation
import Observation
import YardletRemote

/// The phone remote on this computer (docs/REMOTE_PROTOCOL.md): off until the person turns it on in
/// Settings › Remote. While on, it serves protocol v2 (§11–§17) on every path the platform has: a
/// listener on every interface advertised with Bonjour (the same network and Tailscale; the Mac's and Windows'), and
/// an outgoing socket to the Yardlet relay when one is configured and allowed. It keeps the paired
/// devices (`devices.json` in the remote's folder: the phones' public keys and push registrations), the
/// audit log (`audit.log` beside it, no message text) and the computer's keys in the platform's secure
/// store. The server, listeners and relay run off the main actor; this object holds what Settings shows.
/// What it takes from the platform is in `RemoteHostPlatform`.
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
    /// The signed-in relay account's id, provider and name, kept so Settings names it while remote
    /// connections are off; removed on sign-out. The token stays in the Keychain.
    static let accountKey = "Yardlet.remote.account"
    static let relayURLEnvironmentKey = "YARDLET_REMOTE_RELAY_URL"
    /// The Yardlet relay a build carries (`RemoteHostPlatform.builtInRelay`): `YardletRelayURL` in the Mac's
    /// Info.plist, or a file of that name beside the Windows app's executable, written from Packaging/RelayURL,
    /// which stays out of git (relay/README.md).
    nonisolated static let builtInRelayURLKey = "YardletRelayURL"
    /// A second address of the same relay, which the Mac's room socket races against the first (§14.2): the
    /// environment's beside the environment's relay, the default beside the default, and `YardletRelayAlternateURL`
    /// (written from Packaging/RelayAlternateURL, as `YardletRelayURL` is) beside the built-in one.
    static let relayAlternateURLKey = "Yardlet.remote.relayAlternateURL"
    static let relayAlternateURLEnvironmentKey = "YARDLET_REMOTE_RELAY_ALTERNATE_URL"
    nonisolated static let builtInRelayAlternateURLKey = "YardletRelayAlternateURL"

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
    var secureState: RemoteDirectListenerState = .stopped
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
    /// The sign-in providers the relay offers; empty where it has none (a relay without OAuth
    /// credentials has no accounts, and the phone remote still goes through it).
    private(set) var accountProviders: [String] = []
    /// Whether the providers were read: nil until Settings › Yardlet Account or the remote first asks,
    /// false when the relay could not be reached and none were read before.
    private(set) var accountProvidersRead: Bool?
    private(set) var isSigningIn = false
    private(set) var accountError: String?

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
    @ObservationIgnored private let platform: RemoteHostPlatform
    /// The relay this build carries and a second address of it, read once.
    @ObservationIgnored private let builtInRelay: (url: String, alternate: String?)?
    @ObservationIgnored private var secureListener: (any RemoteDirectListening)?
    @ObservationIgnored private var relayClient: RemoteRelayClient?
    @ObservationIgnored private let accountToken: any RemoteSecretStoring
    @ObservationIgnored private let webSignIn: @MainActor (URL, String) async throws -> URL
    @ObservationIgnored private var stopWatchingNetwork: (() -> Void)?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var startup: Task<Void, Never>?
    @ObservationIgnored private var activation: Task<Void, Never>?
    @ObservationIgnored private var pairingRequestID: UUID?
    @ObservationIgnored private var nameLookup: Task<Void, Never>?
    /// The Tailscale address last looked up, so an address without a MagicDNS name is asked once.
    @ObservationIgnored private var lookedUpAddress: String?
    /// Whether the Mac runs on power now (no battery, or charging); read again every minute while it matters.
    @ObservationIgnored private let isOnPower: @MainActor () -> Bool
    @ObservationIgnored private var releaseAwake: (() -> Void)?
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
        platform: RemoteHostPlatform = .current,
        interfaces: (@Sendable () -> [RemoteInterfaceAddress])? = nil,
        resolveName: (@Sendable (String) -> String?)? = nil,
        listens: Bool = true,
        isOnPower: (@MainActor () -> Bool)? = nil,
        macName: String? = nil,
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    ) {
        let macName = macName ?? platform.computerName()
        self.platform = platform
        builtInRelay = platform.builtInRelay()
        self.defaults = defaults
        self.environment = environment
        self.interfaces = interfaces ?? platform.interfaces
        self.resolveName = resolveName ?? platform.resolveName
        self.macName = macName
        self.deviceStore = deviceStore
        self.identityStore = RemoteIdentityLoader(store: identityStore)
        self.accountToken = accountToken
        self.webSignIn = webSignIn
        self.listens = listens
        self.isOnPower = isOnPower ?? platform.isOnPower
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        isRelayEnabled = defaults.object(forKey: Self.relayEnabledKey) as? Bool ?? true
        keepsAwakeOnPower = defaults.bool(forKey: Self.keepAwakeKey)
        account = defaults.data(forKey: Self.accountKey)
            .flatMap { try? JSONDecoder().decode(RemoteAccountClient.Account.self, from: $0) }
        server = RemoteServer(
            configuration: RemoteServer.Configuration(server: RemoteServerInfo(name: macName, appVersion: appVersion),
                                                      macKey: nil),
            bridge: bridge, devices: deviceStore, audit: audit)
    }

    // MARK: - Account (§14.4)

    private var accountClient: RemoteAccountClient? {
        relayURL.map { RemoteAccountClient(baseURL: $0) }
    }

    /// Reads the providers, and with a saved token puts this Mac on the account again (its name may
    /// have changed) and takes link requests. A token the relay no longer knows is dropped.
    func refreshAccount() async {
        guard isEnabled, let client = accountClient else { return }
        await readAccountProviders(client)
        guard let token = await withAccountToken({ $0.load() }) else { return keep(account: nil) }
        guard let identity = await ensureIdentity() else { return }
        do {
            let current = try await client.account(token: token)
            try await client.registerMac(token: token, identity: identity, name: macName, accountID: current.id)
            keep(account: current)
            await server.setAcceptsLinks(true)
        } catch let failure as RemoteAccountClient.Failure where failure.isUnauthorized {
            await withAccountToken { $0.delete() }
            keep(account: nil)
            await server.setAcceptsLinks(false)
        } catch {
            accountError = error.localizedDescription
        }
    }

    /// Settings › Yardlet Account as it opens: with remote connections on, the account as
    /// `refreshAccount` reads it; with them off, only the sign-in providers, so the person can sign in
    /// before turning them on, and whether a token is still kept. Nothing reads them on a schedule.
    func refreshAccountPage() async {
        if isEnabled { return await refreshAccount() }
        guard let client = accountClient else { return }
        await readAccountProviders(client)
        if account != nil, await withAccountToken({ $0.load() }) == nil { keep(account: nil) }
    }

    private func readAccountProviders(_ client: RemoteAccountClient) async {
        if let providers = try? await client.providers() {
            accountProviders = providers
            accountProvidersRead = true
        } else {
            accountProvidersRead = !accountProviders.isEmpty
        }
    }

    /// The account Settings names, kept for the next launch without its list of Macs.
    private func keep(account: RemoteAccountClient.Account?) {
        self.account = account
        if var kept = account {
            kept.macs = nil
            defaults.set(try? JSONEncoder().encode(kept), forKey: Self.accountKey)
        } else {
            defaults.removeObject(forKey: Self.accountKey)
        }
    }

    /// Signs in with a provider in the browser sheet and puts this Mac on the account. It works with remote
    /// connections off; the account finds this Mac once they are on.
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
            keep(account: signedIn)
            await server.setAcceptsLinks(true)
        } catch is CancellationError {
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
        keep(account: nil)
        await server.setAcceptsLinks(false)
    }

    /// Runs an account-token operation off the main actor: the keychain can wait on a system prompt.
    private func withAccountToken<T: Sendable>(_ operation: @escaping @Sendable (any RemoteSecretStoring) -> T) async -> T {
        let accountToken = accountToken
        return await Task.detached { operation(accountToken) }.value
    }

    /// The relay this Mac uses: the developer's or self-hosted one, else the built-in one. The account and
    /// every request but the room's socket go here.
    var relayURL: URL? {
        configuredRelay.flatMap { Self.relayAddress($0.url) }
    }

    /// Another address of the same relay, raced against `relayURL` for the room's socket. It comes from where
    /// `relayURL` came from, so a relay set by hand never gets the built-in one's.
    var relayAlternateURL: URL? {
        guard relayURL != nil else { return nil }
        return configuredRelay?.alternate.flatMap(Self.relayAddress)
    }

    private var configuredRelay: (url: String, alternate: String?)? {
        if let url = environment[Self.relayURLEnvironmentKey] { return (url, environment[Self.relayAlternateURLEnvironmentKey]) }
        if let url = defaults.string(forKey: Self.relayURLKey) { return (url, defaults.string(forKey: Self.relayAlternateURLKey)) }
        return builtInRelay
    }

    private static func relayAddress(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme, ["wss", "https", "ws", "http"].contains(scheme) else { return nil }
        return url
    }

    /// Connects the server and, when the remote is on, starts serving.
    func start() async {
        guard !started else { return }
        started = true
        startup = Task { [self] in
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
    var isKeepingAwake: Bool { releaseAwake != nil }

    private func refreshAwake() {
        let wanted = started && isEnabled && keepsAwakeOnPower
        let holds = wanted && isOnPower()
        if holds, releaseAwake == nil {
            releaseAwake = platform.holdAwake("Remote connections are allowed and this Mac stays awake on power")
        } else if !holds, let releaseAwake {
            releaseAwake()
            self.releaseAwake = nil
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
            relayURL: relay?.url, room: relay?.room, alternateRelayURL: relay?.alternate).url)
        lookUpMagicDNSName()
    }

    func cancelPairing() {
        pairingRequestID = nil
        pairing = nil
        Task { await server.cancelPairing() }
    }

    private var permissionSaveError: String?
    var permissionError: String? {
        if !unsafeDeniedPermissions.isEmpty {
            return L10n.string("Permission is off for now. Recovery could not be saved; retry before restarting Yardlet.")
        }
        if !unsavedDeniedPermissions.isEmpty {
            return L10n.string("Permission stays off after restarting. Retry saving the settings.")
        }
        return permissionSaveError
    }
    private(set) var removalError: String?
    private(set) var removingDeviceIDs: Set<String> = []
    private var permissionEdits: [RemotePermissionKey: UUID] = [:]
    private(set) var pendingPermissionValues: [RemotePermissionKey: Bool] = [:]
    private var deactivation: Task<Void, Never>?
    private(set) var updatingDevicePermissions: [String: Set<RemoteDevicePermission>] = [:]
    private(set) var unsavedDeniedPermissions: Set<RemotePermissionKey> = []
    private(set) var unsafeDeniedPermissions: Set<RemotePermissionKey> = []
    var canRetryPermissionChange: Bool { !unsavedDeniedPermissions.isEmpty }

    func retryPermissionChange() async {
        do {
            try await server.retryPermissionRecovery()
            permissionSaveError = nil
        } catch {
            permissionSaveError = L10n.string("Could not save device permissions. Try again.")
        }
        await reloadDevices()
    }

    func setPermission(_ permission: RemoteDevicePermission, allowed: Bool, for device: RemoteDevice) async {
        let key = RemotePermissionKey(deviceID: device.id, permission: permission)
        let edit = UUID()
        permissionEdits[key] = edit
        pendingPermissionValues[key] = allowed
        updatingDevicePermissions[device.id, default: []].insert(permission)
        do {
            try await server.setPermission(permission, allowed: allowed, for: device.id)
            if permissionEdits[key] == edit { permissionSaveError = nil }
        } catch {
            if permissionEdits[key] == edit { permissionSaveError = L10n.string("Could not save device permissions. Try again.") }
        }
        await reloadDevices()
        if permissionEdits[key] == edit {
            permissionEdits[key] = nil
            pendingPermissionValues[key] = nil
            updatingDevicePermissions[device.id]?.remove(permission)
            if updatingDevicePermissions[device.id]?.isEmpty == true { updatingDevicePermissions[device.id] = nil }
        }
    }

    func remove(_ device: RemoteDevice) async {
        guard removingDeviceIDs.insert(device.id).inserted else { return }
        defer { removingDeviceIDs.remove(device.id) }
        do {
            try await server.revoke(device.id)
            removalError = nil
        } catch {
            removalError = L10n.string("Could not remove this device. It is still paired. Try again.")
        }
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
        let previousActivation = activation
        activation?.cancel()
        activation = nil
        pairingRequestID = nil
        refreshAwake()
        await previousActivation?.value
        await deactivation?.value
        await server.shutdown(reason: "quitting")
        secureListener?.stop()
        relayClient?.stop()
    }

    func reloadDevices() async {
        devices = await server.devicesForSettings().sorted { $0.createdAt < $1.createdAt }
        let recovery = await server.permissionRecoveryState()
        unsavedDeniedPermissions = recovery.unsavedDeniedPermissions
        unsafeDeniedPermissions = recovery.unsafeDeniedPermissions
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
        let previousShutdown = deactivation
        activation = Task {
            await activateWhenReady(after: previousShutdown)
            // A failed keychain read can be retried by the next activation request.
            if !Task.isCancelled, identity == nil { activation = nil }
        }
    }

    private func activateWhenReady(after previousShutdown: Task<Void, Never>?) async {
        await startup?.value
        await previousShutdown?.value
        guard !Task.isCancelled, isEnabled else { return }
        await server.start()
        guard !Task.isCancelled, isEnabled else { return }
        let prepared = await ensureIdentity()
        guard !Task.isCancelled, isEnabled else { return }
        if let identity = prepared {
            if listens, secureListener == nil, let listener = platform.makeListener(server, identity) {
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
        guard stopWatchingNetwork == nil else { return }
        stopWatchingNetwork = platform.watchNetwork { [weak self] in
            Task { @MainActor in
                self?.refreshAddresses()
                self?.relayClient?.reconnectSoon()
            }
        }
    }

    private func deactivate(reason: String) {
        let previousActivation = activation
        activation?.cancel()
        activation = nil
        pairingRequestID = nil
        stopWatchingNetwork?()
        stopWatchingNetwork = nil
        pairing = nil
        secureListener?.stop()
        secureListener = nil
        secureState = .stopped
        stopRelay()
        let previous = deactivation
        deactivation = Task {
            await previous?.value
            await previousActivation?.value
            await server.shutdown(reason: reason)
        }
    }

    private func startRelay() {
        guard listens, isEnabled, isRelayEnabled, relayClient == nil, let url = relayURL else { return }
        guard let identity else {
            activate()
            return
        }
        let client = RemoteRelayClient(server: server, identity: identity, baseURL: url, alternateURL: relayAlternateURL)
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
        let publicAddresses = platform.advertisesPublicAddresses
            ? interfaceAddresses.filter { RemoteAddressSelection.isPublic($0.address) } : []
        let public4 = publicAddresses.filter { $0.family == .ipv4 }.map(\.address)
        let public6 = publicAddresses.filter { $0.family == .ipv6 }.map { "[\($0.address)]" }
        var hosts = Array(NSOrderedSet(array: local + tailscale4 + public4)) as? [String] ?? []
        if let magicDNSName { hosts.append(magicDNSName) }
        hosts += tailscale6 + public6
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

/// What the remote takes from the computer it runs on: the Mac's in Platform/macOS, Windows' in Platform/Windows, and
/// elsewhere the relay alone (Platform/Portable).
struct RemoteHostPlatform {
    /// The listener for the direct paths (§11.1), or nil where the platform has none yet.
    var makeListener: (RemoteServer, RemoteIdentity) -> (any RemoteDirectListening)?
    /// Calls back on each change of the computer's networks until the returned stop is called; nil where
    /// changes are not watched.
    var watchNetwork: (@escaping @Sendable () -> Void) -> (() -> Void)?
    var interfaces: @Sendable () -> [RemoteInterfaceAddress]
    var resolveName: @Sendable (String) -> String?
    /// Whether the computer runs on power now (no battery, or charging).
    var isOnPower: @MainActor () -> Bool
    /// Keeps the computer from sleeping on its own, for the reason given, until the returned release is
    /// called; nil where it cannot.
    var holdAwake: (String) -> (() -> Void)?
    /// The name phones and other computers see, asked only when the remote is given none: the Mac's can wait on
    /// a name lookup.
    var computerName: () -> String
    /// The relay the build carries and a second address of it, nil in a build without one.
    var builtInRelay: () -> (url: String, alternate: String?)?
    /// Whether its listener takes connections on public addresses too, which devices are then told after the private
    /// and Tailscale ones: a Linux host the person chose that for. The Mac's and Windows' name only the latter.
    var advertisesPublicAddresses = false
}

extension RemoteHostPlatform {
    /// The relay a build carries in files beside its executable, as the Windows app's packaging writes them
    /// (Windows/scripts/place-relay.ps1): the first line of `YardletRelayURL` and of `YardletRelayAlternateURL`.
    static func relay(besides executable: URL?) -> (url: String, alternate: String?)? {
        guard let folder = executable?.deletingLastPathComponent() else { return nil }
        func firstLine(_ name: String) -> String? {
            guard let text = try? String(contentsOf: folder.appending(path: name), encoding: .utf8),
                  let line = text.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces),
                  !line.isEmpty else { return nil }
            return line
        }
        return firstLine(RemoteControlService.builtInRelayURLKey).map {
            ($0, firstLine(RemoteControlService.builtInRelayAlternateURLKey))
        }
    }
}

/// A secret the remote keeps in the platform's secure store: the relay account's token (§14.4).
protocol RemoteSecretStoring: Sendable {
    func load() -> String?
    func save(_ value: String)
    func delete()
}

final class RemoteMemorySecret: RemoteSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(_ value: String? = nil) {
        self.value = value
    }

    func load() -> String? { lock.withLock { value } }
    func save(_ value: String) { lock.withLock { self.value = value } }
    func delete() { lock.withLock { value = nil } }
}
