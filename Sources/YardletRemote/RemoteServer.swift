import Foundation

/// One open connection, as the transport gives it to the server: text out, and closing.
public protocol RemoteChannel: AnyObject, Sendable {
    func send(_ text: String)
    /// Closes after everything sent so far.
    func close(_ code: RemoteCloseCode)
}

public enum RemoteBridgeChange: Equatable, Sendable {
    /// Something a snapshot reads changed.
    case tasks
    /// A task's conversation changed.
    case conversation(String)
    /// Something `scheduledTasks` reads may have changed: a schedule, a run, or the task of its latest run (§15.21).
    case schedules
}

/// What a command asks of the Mac.
public enum RemoteCommand: Equatable, Sendable {
    case sendMessage(taskID: String, text: String, images: [RemoteImage] = [], followUp: RemoteFollowUpMode? = nil,
                     files: [RemoteFile] = [])
    case answerApproval(taskID: String, requestID: String, answer: RemoteApprovalAnswer, note: String? = nil)
    case stopTurn(taskID: String)
    case markRead(taskID: String)
    case answerQuestion(taskID: String, requestID: String, answers: [RemoteQuestionAnswer])
    case reviewPlan(taskID: String, requestID: String, decision: RemotePlanDecision, reason: String?)
    case actOnSuggestion(taskID: String, suggestionID: String, action: RemoteSuggestionAction)
    case setPinned(taskID: String, pinned: Bool)
    case archiveTask(taskID: String)
    case continueWithAccount(taskID: String, accountID: String)
    case setAutoContinue(taskID: String, enabled: Bool)
    case actOnQueued(taskID: String, itemID: String, action: RemoteQueuedAction)
    case answerHandoff(taskID: String, requestID: String, answer: RemoteHandoffAnswer)
    case chooseAnswer(taskID: String, requestID: String, choice: String, note: String? = nil,
                      values: [String: RemoteFormValue] = [:])
    /// Run now, Pause and Resume of a schedule (§15.21).
    case runScheduledTask(scheduleID: String)
    case setScheduledTaskEnabled(scheduleID: String, enabled: Bool)
}

/// The path a connection came over (§11.1), for Settings.
public enum RemotePath: String, Equatable, Sendable {
    /// The same network.
    case local
    case tailscale
    case relay
    case loopback
}

/// A push the server asks the app to send through the relay (§14.2, §16).
public struct RemotePushRequest: Equatable, Sendable {
    public var provider: String
    public var token: String
    public var keyID: String
    public var sealed: String
    public var urgent: Bool
    public var collapse: String
}

public enum RemotePushResult: Equatable, Sendable {
    case sent
    /// The push service no longer knows the token.
    case unregistered
    case failed
}

/// A link request waiting for an answer (§12.1).
public struct RemoteLinkRequest: Equatable, Sendable {
    public var id: String
    public var name: String
    public var platform: String?
    public var code: String
    public var expiresAt: Date
}

/// What a v2 handshake ends in (§13.1).
public enum RemoteHandshakeOutcome: Sendable {
    /// Authenticated as a device: send the reply, then serve the connection.
    case accepted(UUID, RemoteHandshakeReply)
    /// A link request: send the reply; the connection waits for approval.
    case pending(UUID, RemoteHandshakeReply)
    /// Send the reply, then close with the code.
    case refused(RemoteHandshakeReply, RemoteCloseCode)
}

/// What the server reads from and asks of the app (Yardlet's `AppModel`, or the fixture). The server
/// calls it from its own actor; an app-side bridge hops to its main actor to read or act.
public protocol RemoteBridge: AnyObject, Sendable {
    /// Told whenever a snapshot or a watched conversation may have changed.
    func setChangeHandler(_ handler: @escaping @Sendable (RemoteBridgeChange) -> Void) async
    func snapshot() async -> RemoteSnapshot
    /// A listed task's conversation as loaded now; nil for a task not listed.
    func conversation(of taskID: String) async -> RemoteConversation?
    /// Reads the task's latest saved history, as opening it on the Mac does (no model turn).
    func prepareConversation(of taskID: String) async
    /// Asks the provider for turns before the loaded ones.
    func loadEarlierConversation(of taskID: String) async
    /// Carries out a command through the app's own paths. Nil when it was accepted.
    func perform(_ command: RemoteCommand) async -> RemoteError?
    /// The tasks some phone reads the conversation of.
    func setWatchedTasks(_ taskIDs: Set<String>) async
    /// Starts a task as the Mac's new-task composer would (§15.5, §15.16); the new task's ID.
    func createTask(_ start: RemoteTaskStart) async -> Result<String, RemoteError>
    /// What a line holds beyond its title (§15.8).
    func itemDetail(taskID: String, itemID: String) async -> Result<RemoteItemDetail, RemoteError>
    /// What a task started in the project may run on (§15.16).
    func newTaskOptions(projectID: String?, harness: String?, settings: [String: String]) async -> Result<RemoteNewTaskOptions, RemoteError>
    /// The accounts a task a plan limit stopped may continue under (§15.17).
    func limitAccounts(taskID: String) async -> Result<[RemoteAccount], RemoteError>
    /// The Mac's Scheduled tasks list (§15.21). A bridge that answers it says so in its snapshot (`scheduledTasks`).
    func scheduledTasks() async -> Result<[RemoteSchedule], RemoteError>
}

extension RemoteBridge {
    public func newTaskOptions(projectID: String?, harness: String?, settings: [String: String]) async -> Result<RemoteNewTaskOptions, RemoteError> {
        .failure(RemoteError(.unavailable))
    }

    public func limitAccounts(taskID: String) async -> Result<[RemoteAccount], RemoteError> {
        .failure(RemoteError(.unavailable))
    }

    public func scheduledTasks() async -> Result<[RemoteSchedule], RemoteError> {
        .failure(RemoteError(.unavailable))
    }
}

/// The remote's protocol, connection by connection (docs/REMOTE_PROTOCOL.md): authentication and
/// pairing, rates, snapshots and their change events, conversation pages and their changes, and
/// commands through the bridge. Transport-free: `RemoteSecureConnection` hands it each connection once
/// its Noise handshake is read (the direct listener and the relay client make those), tests hand it
/// channels of their own.
public actor RemoteServer {
    public struct Configuration: Sendable {
        public var server: RemoteServerInfo
        public var authTimeout: TimeInterval = 10
        /// How long a v2 connection may stay before the phone's first message proves it holds the session keys.
        public var proofTimeout: TimeInterval = 30
        public var idleTimeout: TimeInterval = 75
        /// Connections of paired devices, counted once they are proven.
        public var maxConnections = 8
        /// Connections still proving themselves; a new one past this closes the oldest.
        public var maxWaitingConnections = 8
        public var maxSubscriptions = 8
        public var tasksInterval: Duration = .milliseconds(400)
        public var conversationInterval: Duration = .milliseconds(200)
        /// How long `loadOlder` waits for the provider.
        public var olderWait: TimeInterval = 15
        public var sweepInterval: Duration = .seconds(5)
        public var windowLimits = RemoteConversationWindow.Limits()
        /// The Mac's static public key, for link codes (§12.1).
        public var macKey: Data?
        /// Where files a phone sends are kept (§15.20).
        public var uploadDirectory = RemoteUploadStore.defaultDirectory

        public init(server: RemoteServerInfo, macKey: Data? = nil) {
            self.server = server
            self.macKey = macKey
        }
    }

    /// What Settings shows: the devices connected now and the open pairing.
    public struct Status: Equatable, Sendable {
        public var connectedDeviceIDs: Set<String> = []
        public var pairing: RemotePairingTicket?
        /// The device the last pairing added.
        public var pairedDeviceID: String?
        /// The path each connected device came over (its newest connection).
        public var connectedPaths: [String: RemotePath] = [:]
        public var linkRequest: RemoteLinkRequest?
    }

    private struct Connection {
        let channel: any RemoteChannel
        var deviceID: String?
        var path: RemotePath?
        /// The phone sent a message under this connection's keys (§13.1); until then the connection neither
        /// counts as the device's nor holds back its pushes.
        var isProven = false
        var openedAt: Date
        var lastReceivedAt: Date
        var limiter: RemoteRateLimiter
        var seq = 0
        var receivesTaskEvents = false
        /// It asked for `scheduledTasks`, so it is told when they change (§15.21).
        var receivesScheduleEvents = false
        var subscriptions: [String: Subscription] = [:]
        var queue: [Data] = []
        var isDraining = false

        /// A paired device's connection, counted against `maxConnections`.
        var isEstablished: Bool { deviceID != nil && isProven }
    }

    private struct Subscription {
        var window: RemoteConversationWindow
        /// The fetch the window last showed; an older fetch that returns late is dropped.
        var generation: Int
    }

    /// A link request from message 1 until it is answered (§12.1).
    private struct PendingLink {
        var connection: UUID
        var key: Data
        var name: String
        var platform: String?
        var commitment: Data
        var macNonce: Data
        /// Set once the phone revealed its nonce: the request Settings and phones are shown.
        var request: RemoteLinkRequest?
    }

    private let configuration: Configuration
    private let bridge: any RemoteBridge
    private let devices: RemoteDeviceStore
    private let audit: RemoteAuditLog?
    private let now: @Sendable () -> Date

    private var connections: [UUID: Connection] = [:]
    private var pairing: RemotePairingTicket?
    private var pairedDeviceID: String?
    private var published: RemoteSnapshot?
    private var tasksDirty = true
    private var tasksRefresh: Task<Void, Never>?
    private var tasksTimer: Task<Void, Never>?
    private var conversationTimers: [String: Task<Void, Never>] = [:]
    /// The schedules the connections that follow them were last told of (§15.21), and the read they came from:
    /// a read that returns after a newer one is dropped.
    private var publishedSchedules: [RemoteSchedule]?
    private var publishedScheduleRead = 0
    private var scheduleReads = 0
    private var schedulesTimer: Task<Void, Never>?
    private var fetchGeneration = 0
    private var watched: Set<String> = []
    private var sweeper: Task<Void, Never>?
    private var statusHandler: (@Sendable (Status) -> Void)?
    private var lastStatus = Status()
    /// A v2 pairing just spent, which the same phone key may use again until it expires (§12).
    private var spentPairing: RemotePairingTicket?
    private var directory: (direct: [String], relay: RemoteHandshakeReply.Relay?) = ([], nil)
    /// Link requests are taken while the Mac is signed in to an account (§12.1).
    private var acceptsLinks = false
    private var link: PendingLink?
    /// When link requests were taken, for `linksPerWindow`.
    private var linkTimes: [Date] = []
    /// Devices removed while this server runs: a handshake that read one before it went is refused.
    private var revokedDeviceIDs: Set<String> = []
    private var pushSender: (@Sendable (RemotePushRequest) async -> RemotePushResult)?
    private var hasPushDevices = false
    /// The Mac's static public key, for link codes (§12.1); made the first time the remote is used.
    private var macKey: Data?
    private var uploads: RemoteUploadStore

    public init(
        configuration: Configuration,
        bridge: any RemoteBridge,
        devices: RemoteDeviceStore,
        audit: RemoteAuditLog? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        macKey = configuration.macKey
        uploads = RemoteUploadStore(directory: configuration.uploadDirectory)
        self.bridge = bridge
        self.devices = devices
        self.audit = audit
        self.now = now
    }

    /// Connects the bridge's change signals to the server. Call once before taking connections.
    public func start() async {
        await bridge.setChangeHandler { [weak self] change in
            guard let self else { return }
            Task { await self.bridgeChanged(change) }
        }
        await reloadPushDevices()
    }

    public func setStatusHandler(_ handler: (@Sendable (Status) -> Void)?) {
        statusHandler = handler
        handler?(status)
    }

    public var status: Status {
        var paths: [String: RemotePath] = [:]
        let established = connections.values.filter(\.isEstablished)
        for connection in established.sorted(by: { $0.openedAt < $1.openedAt }) {
            if let device = connection.deviceID, let path = connection.path { paths[device] = path }
        }
        return Status(connectedDeviceIDs: Set(established.compactMap(\.deviceID)), pairing: livePairing,
                      pairedDeviceID: pairedDeviceID, connectedPaths: paths, linkRequest: link?.request)
    }

    /// What message 2 tells a phone to try next time (§13.1).
    public func setDirectory(direct: [String], relay: RemoteHandshakeReply.Relay?) {
        directory = (direct, relay)
    }

    public func setMacKey(_ key: Data?) {
        macKey = key
    }

    public func setAcceptsLinks(_ accepts: Bool) {
        acceptsLinks = accepts
        guard !accepts, let pending = link else { return }
        if let request = pending.request {
            resolveLink(request.id, approve: false, code: .unauthenticated)
        } else {
            close(pending.connection, .unauthenticated)
        }
    }

    /// How pushes leave the Mac; nil turns them off.
    public func setPushSender(_ sender: (@Sendable (RemotePushRequest) async -> RemotePushResult)?) async {
        pushSender = sender
        await reloadPushDevices()
    }

    // MARK: - Transport

    /// A frame the connection received. Frames are handled one at a time, in order.
    public func receive(_ data: Data, on id: UUID) {
        guard let connection = connections[id] else { return }
        // A paired v2 phone's joined chunks can carry images (§13.2, §15.14); a link request still waiting for
        // approval only keeps its connection alive.
        let limit = connection.deviceID != nil ? RemoteProtocol.maxSecureClientMessageBytes : RemoteProtocol.maxClientFrameBytes
        guard data.count <= limit else {
            close(id, .messageTooBig)
            return
        }
        connections[id]?.lastReceivedAt = now()
        if !connection.isProven {
            connections[id]?.isProven = true
            publishStatus()
        }
        connections[id]?.queue.append(data)
        guard connections[id]?.isDraining == false else { return }
        connections[id]?.isDraining = true
        Task { await self.drain(id) }
    }

    /// The transport saw the connection end.
    public func closed(_ id: UUID) {
        guard connections.removeValue(forKey: id) != nil else { return }
        forgetLink(on: id)
        Task { await self.updateWatched() }
        publishStatus()
    }

    // MARK: - v2 handshake (§12, §13.1)

    /// Decides what message 1 of a v2 handshake gets: a device's connection, a link request, or a refusal.
    /// An accepted connection is registered here; the channel must not send before message 2.
    public func acceptHandshake(
        _ hello: RemoteHandshakeHello, publicKey: Data, channel: any RemoteChannel, path: RemotePath
    ) async -> RemoteHandshakeOutcome {
        func refuse(_ code: RemoteErrorCode, _ message: String, _ close: RemoteCloseCode) -> RemoteHandshakeOutcome {
            audit?.record(device: nil, type: "handshake", task: nil, result: code.rawValue, at: now())
            return .refused(RemoteHandshakeReply(ok: false, error: RemoteError(code, message)), close)
        }
        guard hello.v == RemoteProtocol.secureVersion else {
            return refuse(.unsupportedVersion, "This Mac speaks protocol \(RemoteProtocol.secureVersion)", .unsupportedVersion)
        }
        guard establishedCount < configuration.maxConnections else {
            return refuse(.unavailable, "Too many connections", .unavailable)
        }
        let name = String((hello.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        let platform = hello.platform.map { String($0.prefix(32)) }
        var paired = false
        let device: RemoteDevice
        if let typed = hello.pair {
            guard let secret = RemoteEncoding.data(base64url: typed) else { return refuse(.badRequest, "Unreadable secret", .unauthenticated) }
            if let spent = spentPairing, spent.expiresAt > now(), spent.pairedKey == publicKey,
               Self.constantTimeEqual(spent.secret, secret) {
                // The same phone again: it lost the Mac's answer.
            } else {
                guard var ticket = livePairing else {
                    pairing = nil
                    publishStatus()
                    return refuse(.pairingUnavailable, "No pairing is open on the Mac", .unauthenticated)
                }
                // A wrong secret leaves the pairing open: 32 random bytes are not guessed.
                guard Self.constantTimeEqual(ticket.secret, secret) else {
                    return refuse(.pairingInvalid, "Wrong pairing secret", .unauthenticated)
                }
                ticket.pairedKey = publicKey
                var spent = ticket
                spent.expiresAt = min(ticket.expiresAt, now().addingTimeInterval(Self.pairingRetryWindow))
                spentPairing = spent
                if ticket.isSingleUse { pairing = nil }
            }
            device = await devices.addSecure(name: name, publicKey: publicKey, platform: platform, now: now())
            paired = true
            pairedDeviceID = device.id
            audit?.record(device: device.id, type: "pair", task: nil, result: "ok", at: now())
        } else if let known = await devices.authenticate(publicKey: publicKey, name: name, now: now()) {
            device = known
        } else if hello.link == true {
            guard acceptsLinks else { return refuse(.linkUnavailable, "This Mac takes no link requests", .unauthenticated) }
            guard let commitment = hello.linkCommit.flatMap(RemoteEncoding.data(base64url:)), commitment.count == 32 else {
                return refuse(.unsupportedVersion, "Update the app to link through an account", .unsupportedVersion)
            }
            guard link == nil else { return refuse(.busy, "Another link request is waiting", .unavailable) }
            let time = now()
            linkTimes.removeAll { time.timeIntervalSince($0) >= Self.linkWindow }
            guard linkTimes.count < Self.linksPerWindow else {
                return refuse(.rateLimited, "Too many link requests; try again later", .rateLimited)
            }
            linkTimes.append(time)
            makeRoomForWaiting()
            let id = UUID()
            connections[id] = Connection(channel: channel, path: path, openedAt: time, lastReceivedAt: time,
                                         limiter: RemoteRateLimiter(now: time))
            let nonce = Data(RemoteRandom.bytes(RemoteLinkCode.nonceLength))
            link = PendingLink(connection: id, key: publicKey, name: name.isEmpty ? "Phone" : name, platform: platform,
                               commitment: commitment, macNonce: nonce)
            ensureSweeper()
            var reply = RemoteHandshakeReply(ok: false)
            reply.pending = true
            reply.linkNonce = RemoteEncoding.base64url(nonce)
            reply.server = configuration.server
            return .pending(id, reply)
        } else {
            return refuse(.unknownDevice, "This phone is not paired with this Mac", .revoked)
        }
        // Removed while this handshake read the device list.
        guard !revokedDeviceIDs.contains(device.id) else {
            return refuse(.unknownDevice, "This phone is not paired with this Mac", .revoked)
        }
        makeRoomForWaiting()
        let id = UUID()
        let time = now()
        connections[id] = Connection(channel: channel, deviceID: device.id, path: path, openedAt: time, lastReceivedAt: time,
                                     limiter: RemoteRateLimiter(now: time))
        ensureSweeper()
        var reply = RemoteHandshakeReply(ok: true)
        reply.deviceId = device.id
        reply.serverTime = RemoteJSON.milliseconds(time)
        reply.paired = paired ? true : nil
        reply.server = configuration.server
        reply.direct = directory.direct
        reply.relay = directory.relay
        // A phone that connects while a link request waits can answer it too.
        if let request = link?.request { sendLinkRequest(request, to: id) }
        publishStatus()
        return .accepted(id, reply)
    }

    static let linkLifetime: TimeInterval = 120
    /// At most this many link requests are taken in `linkWindow`.
    static let linksPerWindow = 5
    static let linkWindow: TimeInterval = 10 * 60
    /// How long the phone that spent a pairing may use it again after losing the Mac's answer.
    static let pairingRetryWindow: TimeInterval = 60

    /// The phone revealed the nonce message 1 committed to: the request is shown with the code both sides compute.
    private func revealLink(_ nonce: Data, requestID: String, on id: UUID) {
        guard let pending = link, pending.connection == id, pending.request == nil,
              Self.constantTimeEqual(RemoteLinkCode.commitment(phoneKey: pending.key, nonce: nonce), pending.commitment) else {
            respond(.failure(requestID, RemoteError(.badRequest, "The nonce does not match")), to: id)
            close(id, .unauthenticated)
            return
        }
        let time = now()
        let request = RemoteLinkRequest(id: UUID().uuidString, name: pending.name, platform: pending.platform,
                                        code: RemoteLinkCode.code(macKey: macKey ?? Data(), phoneKey: pending.key,
                                                                  macNonce: pending.macNonce, phoneNonce: nonce),
                                        expiresAt: time.addingTimeInterval(Self.linkLifetime))
        link?.request = request
        respond(RemoteResponse(re: requestID), to: id)
        broadcastLinkRequest(request)
        Task { await self.pushLinkRequest(request) }
        audit?.record(device: nil, type: "link", task: nil, result: "pending", at: time)
        publishStatus()
    }

    /// The link request's connection ended.
    private func forgetLink(on id: UUID) {
        guard let pending = link, pending.connection == id else { return }
        link = nil
        if let request = pending.request { broadcastLinkResolved(request.id, approved: false) }
    }

    /// Approves or refuses the waiting link request (Settings, or a phone's `answerLink`).
    @discardableResult
    public func answerLink(_ requestID: String, approve: Bool) async -> Bool {
        guard let pending = link, let request = pending.request, request.id == requestID else { return false }
        if approve {
            guard connections[pending.connection] != nil else {
                link = nil
                publishStatus()
                return false
            }
            let device = await devices.addSecure(name: request.name, publicKey: pending.key,
                                                 platform: request.platform, now: now())
            guard connections[pending.connection] != nil, link?.request?.id == requestID else { return false }
            link = nil
            connections[pending.connection]?.deviceID = device.id
            var linked = RemoteEvent(.linked)
            linked.deviceId = device.id
            send(linked, to: pending.connection)
            broadcastLinkResolved(requestID, approved: true)
            audit?.record(device: device.id, type: "link", task: nil, result: "ok", at: now())
            publishStatus()
        } else {
            resolveLink(requestID, approve: false, code: .revoked)
        }
        return true
    }

    private func resolveLink(_ requestID: String, approve: Bool, code: RemoteCloseCode) {
        guard let pending = link, pending.request?.id == requestID else { return }
        link = nil
        send(RemoteEvent(.linkRefused), to: pending.connection)
        close(pending.connection, code)
        broadcastLinkResolved(requestID, approved: false)
        audit?.record(device: nil, type: "link", task: nil, result: "refused", at: now())
        publishStatus()
    }

    private func broadcastLinkRequest(_ request: RemoteLinkRequest) {
        for (id, connection) in connections where connection.deviceID != nil {
            sendLinkRequest(request, to: id)
        }
    }

    private func sendLinkRequest(_ request: RemoteLinkRequest, to id: UUID) {
        var event = RemoteEvent(.linkRequest)
        event.requestId = request.id
        event.name = request.name
        event.platform = request.platform
        event.code = request.code
        event.expiresAt = RemoteJSON.milliseconds(request.expiresAt)
        send(event, to: id)
    }

    private func broadcastLinkResolved(_ requestID: String, approved: Bool) {
        var event = RemoteEvent(.linkResolved)
        event.requestId = requestID
        event.approved = approved
        for (id, connection) in connections where connection.deviceID != nil {
            send(event, to: id)
        }
    }

    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }

    // MARK: - Control (Settings)

    /// Opens a pairing, replacing any open one.
    @discardableResult
    public func openPairing(
        secret: Data = Data(RemoteRandom.bytes(32)),
        lifetime: TimeInterval = RemotePairingTicket.lifetime,
        isSingleUse: Bool = true
    ) -> RemotePairingTicket {
        let ticket = RemotePairingTicket(secret: secret,
                                         expiresAt: now().addingTimeInterval(lifetime), isSingleUse: isSingleUse)
        pairing = ticket
        spentPairing = nil
        pairedDeviceID = nil
        publishStatus()
        return ticket
    }

    public func cancelPairing() {
        pairing = nil
        spentPairing = nil
        publishStatus()
    }

    /// Removes a device and disconnects it at once. The pairing it may have just spent goes too, so the
    /// same key cannot pair again with it.
    public func revoke(_ deviceID: String) async {
        revokedDeviceIDs.insert(deviceID)
        spentPairing = nil
        await devices.remove(deviceID)
        for (id, connection) in connections where connection.deviceID == deviceID {
            send(RemoteEvent(.revoked), to: id)
            close(id, .revoked)
        }
        audit?.record(device: deviceID, type: "revoke", task: nil, result: "ok", at: now())
        await reloadPushDevices()
    }

    /// Closes every connection: the remote was turned off, or Yardlet quits.
    public func shutdown(reason: String) {
        for id in connections.keys {
            var closing = RemoteEvent(.closing)
            closing.reason = reason
            send(closing, to: id)
            close(id, .unavailable)
        }
        pairing = nil
        spentPairing = nil
        link = nil
        sweeper?.cancel()
        sweeper = nil
        publishStatus()
    }

    // MARK: - Requests

    private func drain(_ id: UUID) async {
        while let data = connections[id]?.queue.first {
            connections[id]?.queue.removeFirst()
            await handle(data, on: id)
        }
        connections[id]?.isDraining = false
    }

    private func handle(_ data: Data, on id: UUID) async {
        guard let connection = connections[id] else { return }
        let envelope: RemoteRequestEnvelope
        switch RemoteRequestEnvelope.decode(data) {
        case let .failure(failure):
            respond(.failure(failure.id ?? "", failure.error), to: id)
            if connection.deviceID == nil { close(id, .unauthenticated) }
            return
        case let .success(value):
            envelope = value
        }
        let request = envelope.request
        guard connections[id]?.limiter.admit(isCommand: request.isCommand, now: now()) == true else {
            respond(.failure(envelope.id, RemoteError(.rateLimited)), to: id)
            if let refused = connections[id]?.limiter.refusedInARow, refused >= RemoteRateLimiter.refusalsBeforeClosing {
                close(id, .rateLimited)
            }
            return
        }
        if connection.deviceID == nil {
            // A link request (§12.1): first the nonce message 1 committed to, then nothing but ping until it is
            // answered.
            if link?.connection == id, link?.request == nil {
                if case let .revealLink(nonce) = request {
                    revealLink(nonce, requestID: envelope.id, on: id)
                } else {
                    respond(.failure(envelope.id, RemoteError(.unauthenticated, "Reveal the link nonce first")), to: id)
                    close(id, .unauthenticated)
                }
            } else if case .ping = request {
                var response = RemoteResponse(re: envelope.id)
                response.pong = true
                response.serverTime = RemoteJSON.milliseconds(now())
                respond(response, to: id)
            } else {
                respond(.failure(envelope.id, RemoteError(.unauthenticated, "Waiting for approval")), to: id)
            }
            return
        }
        if let deviceID = connection.deviceID { await devices.seen(deviceID, now: now()) }
        switch request {
        case .revealLink:
            respond(.failure(envelope.id, RemoteError(.badRequest, "Already authenticated")), to: id)
        case let .answerQuestion(taskID, requestID, answers):
            await command(envelope.id, request: request, on: id) {
                if answers.contains(where: { ($0.text?.count ?? 0) > RemoteProtocol.maxAnswerCharacters }) {
                    return RemoteError(.tooLarge)
                }
                return await self.bridge.perform(.answerQuestion(taskID: taskID, requestID: requestID, answers: answers))
            }
        case let .reviewPlan(taskID, requestID, decision, reason):
            await command(envelope.id, request: request, on: id) {
                if (reason?.count ?? 0) > RemoteProtocol.maxAnswerCharacters { return RemoteError(.tooLarge) }
                return await self.bridge.perform(.reviewPlan(taskID: taskID, requestID: requestID, decision: decision,
                                                             reason: reason))
            }
        case let .createTask(start):
            var created: String?
            await command(envelope.id, request: request, on: id) {
                if let error = Self.validateMessage(start.text) ?? Self.validateImages(start.images) { return error }
                var trimmed = start
                trimmed.text = start.text.trimmingCharacters(in: .whitespacesAndNewlines)
                switch self.uploadedFiles(start.files, on: id) {
                case let .success(files): trimmed.attachedFiles = files
                case let .failure(error): return error
                }
                switch await self.bridge.createTask(trimmed) {
                case let .success(taskID):
                    created = taskID
                    self.uploads.release(start.files)
                    return nil
                case let .failure(error):
                    return error
                }
            } answer: { response in
                response.taskId = created
            }
        case let .registerPush(provider, token):
            guard let deviceID = connection.deviceID,
                  let key = await devices.setPush(deviceID, provider: String(provider.prefix(32)), token: String(token.prefix(4096))) else {
                respond(.failure(envelope.id, RemoteError(.internal)), to: id)
                return
            }
            var response = RemoteResponse(re: envelope.id)
            response.pushKey = RemoteEncoding.base64url(key)
            response.pushKeyId = RemotePushSeal.keyID(key)
            respond(response, to: id)
            await reloadPushDevices()
        case .unregisterPush:
            if let deviceID = connection.deviceID { await devices.clearPush(deviceID) }
            respond(RemoteResponse(re: envelope.id), to: id)
            await reloadPushDevices()
        case .forgetDevice:
            respond(RemoteResponse(re: envelope.id), to: id)
            if let deviceID = connection.deviceID { await revoke(deviceID) }
        case let .itemDetail(taskID, itemID):
            switch await bridge.itemDetail(taskID: taskID, itemID: itemID) {
            case let .success(detail):
                var response = RemoteResponse(re: envelope.id)
                response.taskId = taskID
                response.itemId = itemID
                response.output = detail.output
                response.outputTruncated = detail.outputTruncated ? true : nil
                response.diffs = detail.diffs.isEmpty ? nil : detail.diffs
                respond(response, to: id)
            case let .failure(error):
                respond(.failure(envelope.id, error), to: id)
            }
        case let .actOnSuggestion(taskID, suggestionID, action):
            await command(envelope.id, request: request, on: id) {
                await self.bridge.perform(.actOnSuggestion(taskID: taskID, suggestionID: suggestionID, action: action))
            }
        case let .setPinned(taskID, pinned):
            await command(envelope.id, request: request, on: id) { await self.bridge.perform(.setPinned(taskID: taskID, pinned: pinned)) }
        case let .archiveTask(taskID):
            await command(envelope.id, request: request, on: id) { await self.bridge.perform(.archiveTask(taskID: taskID)) }
        case let .answerLink(requestID, approve):
            await command(envelope.id, request: request, on: id) {
                await self.answerLink(requestID, approve: approve) ? nil : RemoteError(.requestNotFound)
            }
        case let .newTaskOptions(projectID, harness, settings):
            switch await bridge.newTaskOptions(projectID: projectID, harness: harness, settings: settings) {
            case let .success(options):
                var response = RemoteResponse(re: envelope.id)
                response.harness = options.harness.harness
                response.harnessName = options.harness.harnessName
                response.harnesses = options.harnesses
                response.settings = options.settings
                response.worktree = options.worktree
                respond(response, to: id)
            case let .failure(error):
                respond(.failure(envelope.id, error), to: id)
            }
        case let .limitAccounts(taskID):
            switch await bridge.limitAccounts(taskID: taskID) {
            case let .success(accounts):
                var response = RemoteResponse(re: envelope.id)
                response.taskId = taskID
                response.accounts = accounts
                respond(response, to: id)
            case let .failure(error):
                respond(.failure(envelope.id, error), to: id)
            }
        case let .continueWithAccount(taskID, accountID):
            await command(envelope.id, request: request, on: id) {
                await self.bridge.perform(.continueWithAccount(taskID: taskID, accountID: accountID))
            }
        case let .setAutoContinue(taskID, enabled):
            await command(envelope.id, request: request, on: id) {
                await self.bridge.perform(.setAutoContinue(taskID: taskID, enabled: enabled))
            }
        case let .actOnQueued(taskID, itemID, action):
            await command(envelope.id, request: request, on: id) {
                await self.bridge.perform(.actOnQueued(taskID: taskID, itemID: itemID, action: action))
            }
        case let .answerHandoff(taskID, requestID, answer):
            await command(envelope.id, request: request, on: id) {
                await self.bridge.perform(.answerHandoff(taskID: taskID, requestID: requestID, answer: answer))
            }
        case let .chooseAnswer(taskID, requestID, choice, note, values):
            await command(envelope.id, request: request, on: id) {
                if (note?.count ?? 0) > RemoteProtocol.maxAnswerCharacters { return RemoteError(.tooLarge) }
                if let note, Self.isSlashCommand(note) { return RemoteError(.unsupportedCommand, "Slash commands stay on the Mac") }
                return await self.bridge.perform(.chooseAnswer(taskID: taskID, requestID: requestID, choice: choice, note: note,
                                                               values: values))
            }
        case .scheduledTasks:
            let read = await readSchedules()
            switch read.result {
            case let .success(schedules):
                var response = RemoteResponse(re: envelope.id)
                response.schedules = schedules
                respond(response, to: id)
                // The list later changes are told against, unless another connection that follows them has yet
                // to hear of one.
                let othersFollow = connections.contains { $0.key != id && $0.value.receivesScheduleEvents }
                if publishedSchedules == nil || !othersFollow, read.number > publishedScheduleRead {
                    publishedSchedules = schedules
                    publishedScheduleRead = read.number
                }
                connections[id]?.receivesScheduleEvents = true
            case let .failure(error):
                respond(.failure(envelope.id, error), to: id)
            }
        case let .runScheduledTask(scheduleID):
            await command(envelope.id, request: request, on: id) {
                await self.bridge.perform(.runScheduledTask(scheduleID: scheduleID))
            }
        case let .setScheduledTaskEnabled(scheduleID, enabled):
            await command(envelope.id, request: request, on: id) {
                await self.bridge.perform(.setScheduledTaskEnabled(scheduleID: scheduleID, enabled: enabled))
            }
        case let .uploadFile(part):
            guard let deviceID = connection.deviceID else { return }
            switch uploads.receive(part, from: deviceID, now: now()) {
            case let .success(received):
                var response = RemoteResponse(re: envelope.id)
                response.uploadId = part.uploadID
                response.received = received
                respond(response, to: id)
            case let .failure(error):
                respond(.failure(envelope.id, error), to: id)
            }
        case .ping:
            var response = RemoteResponse(re: envelope.id)
            response.pong = true
            response.serverTime = RemoteJSON.milliseconds(now())
            respond(response, to: id)
        case .snapshot:
            await refreshTasks(force: true)
            var response = RemoteResponse(re: envelope.id)
            response.projects = published?.projects ?? []
            response.tasks = published?.tasks ?? []
            response.newTask = published?.newTask
            response.followUp = published?.followUp
            response.scheduledTasks = published?.scheduledTasks == true ? true : nil
            response.serverTime = RemoteJSON.milliseconds(now())
            respond(response, to: id)
            connections[id]?.receivesTaskEvents = true
        case let .subscribeTask(taskID):
            await subscribe(envelope.id, taskID: taskID, on: id)
        case let .loadOlder(taskID, cursor):
            await loadOlder(envelope.id, taskID: taskID, cursor: cursor, on: id)
        case let .unsubscribeTask(taskID):
            connections[id]?.subscriptions[taskID] = nil
            respond(RemoteResponse(re: envelope.id), to: id)
            await updateWatched()
        case let .sendMessage(taskID, text, images, followUp, ids):
            await command(envelope.id, request: request, on: id) {
                if let error = Self.validateMessage(text, images: images, hasFiles: !ids.isEmpty) { return error }
                let files: [RemoteFile]
                switch self.uploadedFiles(ids, on: id) {
                case let .success(found): files = found
                case let .failure(error): return error
                }
                let error = await self.bridge.perform(.sendMessage(taskID: taskID,
                                                                   text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                                                   images: images, followUp: followUp, files: files))
                if error == nil { self.uploads.release(ids) }
                return error
            }
        case let .answerApproval(taskID, requestID, answer, note):
            await command(envelope.id, request: request, on: id) {
                if (note?.count ?? 0) > RemoteProtocol.maxAnswerCharacters { return RemoteError(.tooLarge) }
                // A note may become the task's next message (§15.13), and commands stay on the Mac.
                if let note, Self.isSlashCommand(note) { return RemoteError(.unsupportedCommand, "Slash commands stay on the Mac") }
                return await self.bridge.perform(.answerApproval(taskID: taskID, requestID: requestID, answer: answer,
                                                                 note: note))
            }
        case let .stopTurn(taskID):
            await command(envelope.id, request: request, on: id) { await self.bridge.perform(.stopTurn(taskID: taskID)) }
        case let .markRead(taskID):
            await command(envelope.id, request: request, on: id) { await self.bridge.perform(.markRead(taskID: taskID)) }
        }
    }

    private func command(
        _ requestID: String, request: RemoteRequest, on id: UUID,
        perform: () async -> RemoteError?, answer: (inout RemoteResponse) -> Void = { _ in }
    ) async {
        let error = await perform()
        // A new task is listed (`tasksChanged`) before the answer naming it, so the phone can open it.
        if error == nil, case .createTask = request { tasksDirty = true; await refreshTasks(force: true) }
        var response = RemoteResponse(re: requestID)
        if error == nil { answer(&response) }
        respond(error.map { .failure(requestID, $0) } ?? response, to: id)
        audit?.record(device: connections[id]?.deviceID, type: request.type, task: request.taskID,
                      schedule: request.scheduleID, result: error?.code.rawValue ?? "ok", at: now())
    }

    /// The finished uploads a message names (§15.20), sent by this connection's device.
    private func uploadedFiles(_ ids: [String], on id: UUID) -> Result<[RemoteFile], RemoteError> {
        guard !ids.isEmpty else { return .success([]) }
        guard let deviceID = connections[id]?.deviceID else { return .failure(RemoteError(.unauthenticated)) }
        guard Set(ids.map { $0.uppercased() }).count == ids.count else {
            return .failure(RemoteError(.badRequest, "A file is named twice"))
        }
        return uploads.files(ids, from: deviceID)
    }

    /// `sendMessage` text and images the Mac would not send (§4.4, §15.14). With images or files the
    /// text may be empty.
    static func validateMessage(_ text: String, images: [RemoteImage] = [], hasFiles: Bool = false) -> RemoteError? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, images.isEmpty, !hasFiles { return RemoteError(.emptyMessage) }
        if trimmed.count > RemoteProtocol.maxMessageCharacters { return RemoteError(.tooLarge) }
        if isSlashCommand(trimmed) { return RemoteError(.unsupportedCommand, "Slash commands stay on the Mac") }
        return validateImages(images)
    }

    /// Images the Mac would not attach (§15.14): too many, too large, or not JPEG or PNG.
    static func validateImages(_ images: [RemoteImage]) -> RemoteError? {
        if images.count > RemoteProtocol.maxImages || images.contains(where: { $0.data.count > RemoteProtocol.maxImageBytes }) {
            return RemoteError(.tooLarge, "At most \(RemoteProtocol.maxImages) images of 3 MiB each")
        }
        if images.contains(where: { $0.format == nil }) { return RemoteError(.badRequest, "Images are JPEG or PNG") }
        return nil
    }

    /// The first word is a slash command (`/clear`, `/model`, `/review:pr`), not a path (`/Users/me`).
    static func isSlashCommand(_ text: String) -> Bool {
        guard let first = text.split(whereSeparator: \.isWhitespace).first, first.first == "/" else { return false }
        let name = first.dropFirst()
        guard let initial = name.first, initial.isLetter else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || "-_:.".contains($0) }
    }

    // MARK: - Conversations

    private func subscribe(_ requestID: String, taskID: String, on id: UUID) async {
        guard let connection = connections[id] else { return }
        guard connection.subscriptions[taskID] != nil
                || connection.subscriptions.count < configuration.maxSubscriptions else {
            respond(.failure(requestID, RemoteError(.tooManySubscriptions)), to: id)
            return
        }
        let (generation, conversation) = await fetch(taskID)
        guard connections[id] != nil else { return }
        guard let conversation else {
            respond(.failure(requestID, RemoteError(.notFound, "No task \(taskID)")), to: id)
            return
        }
        var window = RemoteConversationWindow(limits: configuration.windowLimits)
        let page = window.open(conversation)
        connections[id]?.subscriptions[taskID] = Subscription(window: window, generation: generation)
        var response = RemoteResponse(re: requestID)
        response.taskId = taskID
        response.items = page.items
        response.cursor = page.cursor
        response.hasOlder = page.hasOlder
        respond(response, to: id)
        await updateWatched()
        // Opening the task on the Mac reads its latest saved history; what that brings is sent as changes.
        let bridge = self.bridge
        Task { await bridge.prepareConversation(of: taskID) }
    }

    private func loadOlder(_ requestID: String, taskID: String, cursor: String, on id: UUID) async {
        guard connections[id]?.subscriptions[taskID] != nil else {
            respond(.failure(requestID, RemoteError(.notSubscribed)), to: id)
            return
        }
        var askedProvider = false
        while true {
            let (generation, conversation) = await fetch(taskID)
            guard var subscription = connections[id]?.subscriptions[taskID] else {
                respond(.failure(requestID, RemoteError(.notSubscribed)), to: id)
                return
            }
            guard let conversation else {
                respond(.failure(requestID, RemoteError(.notFound)), to: id)
                return
            }
            switch subscription.window.older(cursor, in: conversation) {
            case .invalidCursor:
                respond(.failure(requestID, RemoteError(.invalidCursor, "Subscribe again")), to: id)
                return
            case .needsProvider where !askedProvider:
                askedProvider = true
                let bridge = self.bridge
                await Self.waitAtMost(configuration.olderWait) { await bridge.loadEarlierConversation(of: taskID) }
                continue
            case .needsProvider:
                var response = RemoteResponse(re: requestID)
                response.taskId = taskID
                response.items = []
                response.cursor = cursor
                response.hasOlder = true
                respond(response, to: id)
                return
            case let .page(page):
                // The window now shows this read: what changed in its newer turns since goes out right
                // after the page, so a change read meanwhile and dropped as older is not lost.
                let update = subscription.window.update(conversation)
                subscription.generation = max(subscription.generation, generation)
                connections[id]?.subscriptions[taskID] = subscription
                var response = RemoteResponse(re: requestID)
                response.taskId = taskID
                response.items = page.items
                response.cursor = page.cursor
                response.hasOlder = page.hasOlder
                respond(response, to: id)
                send(update, of: taskID, to: id)
                return
            }
        }
    }

    private func fetch(_ taskID: String) async -> (Int, RemoteConversation?) {
        fetchGeneration += 1
        let generation = fetchGeneration
        return (generation, await bridge.conversation(of: taskID))
    }

    private func refreshConversation(_ taskID: String) async {
        guard connections.values.contains(where: { $0.subscriptions[taskID] != nil }) else { return }
        let (generation, conversation) = await fetch(taskID)
        for (id, connection) in connections {
            guard var subscription = connection.subscriptions[taskID], subscription.generation < generation else { continue }
            guard let conversation else {
                connections[id]?.subscriptions[taskID] = nil
                var ended = RemoteEvent(.conversationEnded)
                ended.taskId = taskID
                ended.reason = "removed"
                send(ended, to: id)
                continue
            }
            subscription.generation = generation
            let update = subscription.window.update(conversation)
            connections[id]?.subscriptions[taskID] = subscription
            send(update, of: taskID, to: id)
        }
        if conversation == nil { await updateWatched() }
    }

    /// A window's update as its event: changes, the window again whole, or nothing.
    private func send(_ update: RemoteConversationWindow.Update, of taskID: String, to id: UUID) {
        switch update {
        case .unchanged:
            break
        case let .changes(changes):
            var event = RemoteEvent(.conversation)
            event.taskId = taskID
            event.changes = changes
            send(event, to: id)
        case let .reset(page):
            var event = RemoteEvent(.conversationReset)
            event.taskId = taskID
            event.items = page.items
            event.cursor = page.cursor
            event.hasOlder = page.hasOlder
            send(event, to: id)
        }
    }

    private func updateWatched() async {
        let tasks = Set(connections.values.flatMap(\.subscriptions.keys))
        guard tasks != watched else { return }
        watched = tasks
        await bridge.setWatchedTasks(tasks)
    }

    // MARK: - Tasks

    private func bridgeChanged(_ change: RemoteBridgeChange) {
        switch change {
        case .tasks:
            tasksDirty = true
            guard tasksTimer == nil, connections.values.contains(where: \.receivesTaskEvents) || pushesAttention else { return }
            let interval = configuration.tasksInterval
            tasksTimer = Task {
                try? await Task.sleep(for: interval)
                self.tasksTimer = nil
                await self.refreshTasks(force: false)
            }
        case let .conversation(taskID):
            guard conversationTimers[taskID] == nil,
                  connections.values.contains(where: { $0.subscriptions[taskID] != nil }) else { return }
            let interval = configuration.conversationInterval
            conversationTimers[taskID] = Task {
                try? await Task.sleep(for: interval)
                self.conversationTimers[taskID] = nil
                await self.refreshConversation(taskID)
            }
        case .schedules:
            guard connections.values.contains(where: \.receivesScheduleEvents) else {
                // Nobody follows them: the next `scheduledTasks` starts over.
                publishedSchedules = nil
                return
            }
            guard schedulesTimer == nil else { return }
            let interval = configuration.tasksInterval
            schedulesTimer = Task {
                try? await Task.sleep(for: interval)
                self.schedulesTimer = nil
                await self.refreshSchedules()
            }
        }
    }

    // MARK: - Schedules (§15.21)

    /// The bridge's schedules, at most `maxSchedules`, numbered by when the read began.
    private func readSchedules() async -> (number: Int, result: Result<[RemoteSchedule], RemoteError>) {
        scheduleReads += 1
        let number = scheduleReads
        let result = await bridge.scheduledTasks().map { Array($0.prefix(RemoteProtocol.maxSchedules)) }
        return (number, result)
    }

    /// Reads the schedules again and tells the connections that follow them, when they changed. The event
    /// carries nothing: a phone asks for `scheduledTasks` again.
    private func refreshSchedules() async {
        let read = await readSchedules()
        guard case let .success(schedules) = read.result, read.number > publishedScheduleRead else { return }
        let changed = schedules != publishedSchedules
        publishedSchedules = schedules
        publishedScheduleRead = read.number
        guard changed else { return }
        for (id, connection) in connections where connection.receivesScheduleEvents {
            send(RemoteEvent(.schedulesChanged), to: id)
        }
    }

    /// Reads the snapshot again when it may have changed (or always, for a `snapshot` request), and
    /// tells the connections that follow tasks what changed. One read at a time.
    private func refreshTasks(force: Bool) async {
        while true {
            if let running = tasksRefresh {
                await running.value
                continue
            }
            guard force || tasksDirty || published == nil else { return }
            tasksDirty = false
            let refresh = Task { await self.readTasks() }
            tasksRefresh = refresh
            await refresh.value
            return
        }
    }

    private func readTasks() async {
        defer { tasksRefresh = nil }
        let snapshot = await bridge.snapshot()
        let previous = published
        published = snapshot
        guard let previous else { return }
        let changes = Self.taskChanges(from: previous, to: snapshot)
        for (id, connection) in connections where connection.receivesTaskEvents {
            if let event = changes.tasks { send(event, to: id) }
            for event in changes.attention { send(event, to: id) }
        }
        if pushesAttention { await push(changes.attention) }
        // A subscribed task no longer listed ends its subscriptions.
        for taskID in changes.tasks?.removedTaskIds ?? [] {
            await refreshConversation(taskID)
        }
    }

    /// The `tasksChanged` event between two snapshots (nil when nothing changed), and an `attention`
    /// event for each task whose attention changed or that waits on a newer request.
    static func taskChanges(from old: RemoteSnapshot, to new: RemoteSnapshot) -> (tasks: RemoteEvent?, attention: [RemoteEvent]) {
        let oldTasks = Dictionary(old.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newIDs = Set(new.tasks.map(\.id))
        let changed = new.tasks.filter { oldTasks[$0.id] != $0 }
        let removed = old.tasks.map(\.id).filter { !newIDs.contains($0) }
        let projectsChanged = old.projects != new.projects
        var tasksEvent: RemoteEvent?
        if !changed.isEmpty || !removed.isEmpty || projectsChanged {
            var event = RemoteEvent(.tasksChanged)
            event.tasks = changed
            event.removedTaskIds = removed
            if projectsChanged { event.projects = new.projects }
            tasksEvent = event
        }
        let projectNames = Dictionary(new.projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var attention: [RemoteEvent] = []
        for task in new.tasks {
            guard let before = oldTasks[task.id] else { continue }
            let request = new.newestRequestIDs[task.id]
            let newRequest = task.attention == .waiting && request != nil && request != old.newestRequestIDs[task.id]
            guard before.attention != task.attention || newRequest else { continue }
            var event = RemoteEvent(.attention)
            event.taskId = task.id
            event.title = task.title
            event.projectName = task.projectId.flatMap { projectNames[$0] }
            event.harnessName = task.harnessName
            event.state = task.attention
            event.previousState = before.attention
            event.indicator = task.indicator
            event.pendingRequest = task.pendingRequest
            event.requestId = task.attention == .waiting ? request : nil
            event.summary = task.attention == .waiting ? new.requestSummaries[task.id] : nil
            event.pendingKind = task.attention == .waiting ? task.pendingKind : nil
            attention.append(event)
        }
        return (tasksEvent, attention)
    }

    // MARK: - Sending and closing

    private func respond(_ response: RemoteResponse, to id: UUID) {
        connections[id]?.channel.send(RemoteJSON.string(response))
    }

    private func send(_ event: RemoteEvent, to id: UUID) {
        guard let connection = connections[id] else { return }
        connections[id]?.seq += 1
        var event = event
        event.seq = connection.seq + 1
        connection.channel.send(RemoteJSON.string(event))
    }

    private func close(_ id: UUID, _ code: RemoteCloseCode) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        forgetLink(on: id)
        connection.channel.close(code)
        Task { await self.updateWatched() }
        publishStatus()
    }

    private var establishedCount: Int {
        connections.values.count(where: \.isEstablished)
    }

    /// Closes the oldest connection still proving itself when there are `maxWaitingConnections` of them, so
    /// connections that never finish cannot keep a phone out. A link request that was shown is not one of them.
    private func makeRoomForWaiting() {
        let waiting = connections.filter { id, connection in
            !connection.isEstablished && !(link?.connection == id && link?.request != nil)
        }
        guard waiting.count >= configuration.maxWaitingConnections,
              let oldest = waiting.min(by: { $0.value.openedAt < $1.value.openedAt }) else { return }
        close(oldest.key, .unavailable)
    }

    private var livePairing: RemotePairingTicket? {
        guard let pairing, pairing.expiresAt > now() else { return nil }
        return pairing
    }

    private func publishStatus() {
        let current = status
        guard current != lastStatus else { return }
        lastStatus = current
        statusHandler?(current)
    }

    // MARK: - Timeouts

    private func ensureSweeper() {
        guard sweeper == nil else { return }
        let interval = configuration.sweepInterval
        sweeper = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self.sweep()
            }
        }
    }

    /// Closes connections that did not authenticate in time or went quiet, and forgets a pairing that
    /// expired.
    func sweep() {
        let time = now()
        for (id, connection) in connections {
            let age = time.timeIntervalSince(connection.openedAt)
            if connection.deviceID == nil {
                // A link request that was shown waits for its answer until it expires, below.
                if link?.connection == id, link?.request != nil { continue }
                if age > configuration.authTimeout { close(id, .idle) }
            } else if !connection.isProven, age > configuration.proofTimeout {
                close(id, .idle)
            } else if time.timeIntervalSince(connection.lastReceivedAt) > configuration.idleTimeout {
                close(id, .idle)
            }
        }
        if pairing != nil, livePairing == nil { pairing = nil }
        if let spent = spentPairing, spent.expiresAt <= time { spentPairing = nil }
        uploads.sweep(now: time)
        if let request = link?.request, request.expiresAt <= time {
            resolveLink(request.id, approve: false, code: .idle)
        }
        publishStatus()
    }

    // MARK: - Push (§16)

    private var pushesAttention: Bool { pushSender != nil && hasPushDevices }

    private func reloadPushDevices() async {
        let had = pushesAttention
        hasPushDevices = await devices.all().contains { $0.push != nil }
        // The first snapshot is the baseline later changes are pushed against.
        if pushesAttention, !had, published == nil { await refreshTasks(force: false) }
    }

    /// Whether an attention change is worth waking a phone for: a request waits, a task finished or
    /// failed, or a request stopped waiting (withdraw its notification).
    static func pushes(_ event: RemoteEvent) -> (push: Bool, urgent: Bool) {
        switch (event.previousState, event.state) {
        case (_, .waiting?): (true, true)
        case (.active?, .unread?), (.waiting?, .unread?): (true, true)
        case (.waiting?, _): (true, false)
        default: (false, false)
        }
    }

    private func push(_ events: [RemoteEvent]) async {
        let worth = events.compactMap { event -> (RemoteEvent, Bool)? in
            let decision = Self.pushes(event)
            return decision.push ? (event, decision.urgent) : nil
        }
        guard !worth.isEmpty else { return }
        for (event, urgent) in worth {
            var payload = event
            payload.seq = nil
            payload.macName = configuration.server.name
            payload.sentAt = RemoteJSON.milliseconds(now())
            if let title = payload.title { payload.title = String(title.prefix(200)) }
            await deliver(payload, urgent: urgent, collapse: RemotePushSeal.collapseKey(taskID: event.taskId ?? ""))
        }
    }

    private func pushLinkRequest(_ request: RemoteLinkRequest) async {
        guard pushesAttention else { return }
        var payload = RemoteEvent(.linkRequest)
        payload.requestId = request.id
        payload.name = request.name
        payload.platform = request.platform
        payload.code = request.code
        payload.expiresAt = RemoteJSON.milliseconds(request.expiresAt)
        payload.macName = configuration.server.name
        payload.sentAt = RemoteJSON.milliseconds(now())
        await deliver(payload, urgent: true, collapse: "link")
    }

    /// Seals the event for each device that registered for pushes and has no v2 connection open.
    private func deliver(_ payload: RemoteEvent, urgent: Bool, collapse: String) async {
        guard let pushSender else { return }
        let connected = Set(connections.values.filter(\.isEstablished).compactMap(\.deviceID))
        let plaintext = Data(RemoteJSON.string(payload).utf8)
        for device in await devices.all() where !connected.contains(device.id) {
            guard let registration = device.push, let key = RemoteEncoding.data(base64url: registration.key),
                  let sealed = try? RemotePushSeal.seal(plaintext, key: key) else { continue }
            let request = RemotePushRequest(provider: registration.provider, token: registration.token,
                                            keyID: RemotePushSeal.keyID(key), sealed: sealed, urgent: urgent, collapse: collapse)
            if await pushSender(request) == .unregistered {
                await devices.dropPushToken(registration.token)
                await reloadPushDevices()
            }
        }
    }

    /// Runs `operation` and returns when it ends or after `seconds`, whichever is first.
    public static func waitAtMost(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = RemoteOnce(continuation)
            Task {
                await operation()
                once.resume()
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                once.resume()
            }
        }
    }
}

final class RemoteOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}
