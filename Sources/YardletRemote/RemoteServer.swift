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
    /// A task's composer controls changed since `taskSettings` last read them (§15.23).
    case taskSettings(String)
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
    /// Edit message on the task's latest message, then Send, as the Mac's turn and composer do (§15.23).
    case editMessage(taskID: String, turnID: String, text: String)
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
    /// The same with what the Mac's own cards draw too (§15.24). A bridge that answers it says so in its snapshot
    /// (`fullConversation`); one that does not answers as `conversation(of:)`.
    func conversation(of taskID: String, detail: RemoteConversationDetail) async -> RemoteConversation?
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
    /// The files the Mac's Outputs card lists for a task, in its order (§15.22); the server reads their sizes. A bridge
    /// that answers it and `fileScope` says so in its snapshot (`taskFiles`).
    func taskOutputs(taskID: String) async -> Result<[RemoteOutput], RemoteError>
    /// The task's folders and outputs, which a `readFile` of the task is checked against (§15.22).
    func fileScope(taskID: String) async -> Result<RemoteFileScope, RemoteError>
    /// The controls the task's composer shows for its settings (§15.23); `prepare` reads the choices first, as opening
    /// the Mac's menu does. Told as `.taskSettings` when they change since this read. A bridge that answers this,
    /// `setTaskSetting`, `composerCommands`, `runComposerCommand`, `forkTask` and `editMessage` says so in its snapshot
    /// (`taskControls`).
    func taskSettings(taskID: String, prepare: Bool) async -> Result<[RemoteSetting], RemoteError>
    /// Applies a choice as the Mac's menu does; the controls after it.
    func setTaskSetting(taskID: String, setting: String, value: String, confirmed: Bool) async -> Result<[RemoteSetting], RemoteError>
    /// The slash commands the task's composer offers that may run from another device.
    func composerCommands(taskID: String) async -> Result<[RemoteComposerCommand], RemoteError>
    /// Runs one as the Mac's composer does; the task it started, when it started one.
    func runComposerCommand(taskID: String, command: String, arguments: String?) async -> Result<String?, RemoteError>
    /// Fork from here on a turn, or the task's whole conversation where the Mac forks only that; the new task.
    func forkTask(taskID: String, turnID: String?) async -> Result<String, RemoteError>
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

    public func taskOutputs(taskID: String) async -> Result<[RemoteOutput], RemoteError> {
        .failure(RemoteError(.unavailable))
    }

    public func fileScope(taskID: String) async -> Result<RemoteFileScope, RemoteError> {
        .failure(RemoteError(.unavailable))
    }

    public func taskSettings(taskID: String, prepare: Bool) async -> Result<[RemoteSetting], RemoteError> {
        .failure(RemoteError(.unavailable))
    }

    public func setTaskSetting(taskID: String, setting: String, value: String,
                               confirmed: Bool) async -> Result<[RemoteSetting], RemoteError> {
        .failure(RemoteError(.unavailable))
    }

    public func composerCommands(taskID: String) async -> Result<[RemoteComposerCommand], RemoteError> {
        .failure(RemoteError(.unavailable))
    }

    public func runComposerCommand(taskID: String, command: String, arguments: String?) async -> Result<String?, RemoteError> {
        .failure(RemoteError(.unavailable))
    }

    public func forkTask(taskID: String, turnID: String?) async -> Result<String, RemoteError> {
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
        /// A desktop in use (`presence`, §18): phone pushes wait while one is.
        var isPresent = false
        /// Subscribed tasks whose `taskSettings` it read, so it is told when they change (§15.23).
        var followsSettings: Set<String> = []
        /// The file it read last (the path the Mac read) and where its next part starts (§15.22): a read that goes on
        /// from there is not written to the audit log again.
        var fileRead: FileRead?
        var subscriptions: [String: Subscription] = [:]
        var queue: [Data] = []
        var isDraining = false

        /// A paired device's connection, counted against `maxConnections`.
        var isEstablished: Bool { deviceID != nil && isProven }
    }

    struct FileRead: Equatable {
        var taskID: String
        var path: String
        var next: Int
    }

    private struct Subscription {
        var window: RemoteConversationWindow
        /// The fetch the window last showed; an older fetch that returns late is dropped.
        var generation: Int
        /// What the phone asked to be sent of each item (§15.24).
        var detail: RemoteConversationDetail = .basic
    }

    /// What one `conversation` event carries at most, well within a message (§13.2): a part of a full
    /// conversation's changes can hold long answers and pictures.
    static let maxChangesBytes = 2 * 1024 * 1024

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
    /// Pushes held while a desktop is in use, the latest per task (§18).
    private var heldPushes: [HeldPush] = []
    private var hasPushDevices = false
    /// The Mac's static public key, for link codes (§12.1); made the first time the remote is used.
    private var macKey: Data?
    private var uploads: RemoteUploadStore
    /// What each device's file reads may still carry (§15.22), shared by its connections.
    private var readBudgets: [String: RemoteRateBucket] = [:]
    /// When each `readFile` line was last written, by device, task, file and result: the same line again within
    /// `readAuditWindow` is not written, so repeating a request cannot flood the log.
    private var auditedReads: [String: Date] = [:]
    static let readAuditWindow: TimeInterval = 60

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
            if connection.deviceID != nil { RemoteLog.notice("Remote: \(Self.describe(connection)) connected") }
            publishStatus()
        }
        connections[id]?.queue.append(data)
        guard connections[id]?.isDraining == false else { return }
        connections[id]?.isDraining = true
        Task { await self.drain(id) }
    }

    /// The transport saw the connection end.
    public func closed(_ id: UUID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        RemoteLog.notice("Remote: \(Self.describe(connection)) ended with its transport after \(lifetime(of: connection))")
        forgetLink(on: id)
        if connection.isPresent { Task { await self.releaseHeldPushes() } }
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
                  let key = await devices.setPush(deviceID, provider: provider, token: String(token.prefix(4096))) else {
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
        case let .presence(active):
            connections[id]?.isPresent = active
            respond(RemoteResponse(re: envelope.id), to: id)
            if !active { await releaseHeldPushes() }
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
        case let .taskOutputs(taskID):
            switch await bridge.taskOutputs(taskID: taskID) {
            case let .success(outputs):
                let listed = Array(outputs.prefix(RemoteProtocol.maxOutputs))
                var response = RemoteResponse(re: envelope.id)
                // Off this actor and Swift's threads: a slow disk holds up no other connection.
                response.outputs = await RemoteFileReader.perform { RemoteFileReader.sized(listed) }
                respond(response, to: id)
            case let .failure(error):
                respond(.failure(envelope.id, error), to: id)
            }
        case let .readFile(taskID, path, offset):
            await readFile(envelope.id, taskID: taskID, path: path, offset: offset, on: id)
        case let .taskSettings(taskID, prepare):
            let result = await bridge.taskSettings(taskID: taskID, prepare: prepare)
            respondSettings(envelope.id, taskID: taskID, result, on: id)
        case let .setTaskSetting(taskID, setting, value, confirmed):
            var settings: [RemoteSetting]?
            await command(envelope.id, request: request, on: id) {
                switch await self.bridge.setTaskSetting(taskID: taskID, setting: setting, value: value, confirmed: confirmed) {
                case let .success(after):
                    settings = after
                    return nil
                case let .failure(error):
                    return error
                }
            } answer: { response in
                response.settings = settings
            }
            if settings != nil, connections[id]?.subscriptions[taskID] != nil { connections[id]?.followsSettings.insert(taskID) }
        case let .composerCommands(taskID):
            switch await bridge.composerCommands(taskID: taskID) {
            case let .success(commands):
                var response = RemoteResponse(re: envelope.id)
                response.taskId = taskID
                response.commands = commands
                respond(response, to: id)
            case let .failure(error):
                respond(.failure(envelope.id, error), to: id)
            }
        case let .runComposerCommand(taskID, name, arguments):
            var started: String?
            await command(envelope.id, request: request, on: id) {
                if (arguments?.count ?? 0) > RemoteProtocol.maxAnswerCharacters { return RemoteError(.tooLarge) }
                switch await self.bridge.runComposerCommand(taskID: taskID, command: name, arguments: arguments) {
                case let .success(taskID):
                    started = taskID
                    return nil
                case let .failure(error):
                    return error
                }
            } answer: { response in
                response.taskId = started
            }
        case let .editMessage(taskID, turnID, text):
            await command(envelope.id, request: request, on: id) {
                if let error = Self.validateMessage(text) { return error }
                return await self.bridge.perform(.editMessage(taskID: taskID, turnID: turnID,
                                                              text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        case let .forkTask(taskID, turnID):
            var forked: String?
            await command(envelope.id, request: request, on: id) {
                switch await self.bridge.forkTask(taskID: taskID, turnID: turnID) {
                case let .success(taskID):
                    forked = taskID
                    return nil
                case let .failure(error):
                    return error
                }
            } answer: { response in
                response.taskId = forked
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
            response.taskFiles = published?.taskFiles == true && RemoteFileReader.isSupported ? true : nil
            response.presence = true
            response.taskControls = published?.taskControls == true ? true : nil
            response.fullConversation = published?.fullConversation == true ? true : nil
            response.serverTime = RemoteJSON.milliseconds(now())
            respond(response, to: id)
            connections[id]?.receivesTaskEvents = true
        case let .subscribeTask(taskID, detail):
            await subscribe(envelope.id, taskID: taskID, detail: detail, on: id)
        case let .loadOlder(taskID, cursor):
            await loadOlder(envelope.id, taskID: taskID, cursor: cursor, on: id)
        case let .unsubscribeTask(taskID):
            connections[id]?.subscriptions[taskID] = nil
            connections[id]?.followsSettings.remove(taskID)
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
        var response = RemoteResponse(re: requestID)
        if error == nil { answer(&response) }
        // A new task (`createTask`, a fork, a new chat) is listed (`tasksChanged`) before the answer naming it, so the
        // phone can open it.
        if error == nil, response.taskId != nil { tasksDirty = true; await refreshTasks(force: true) }
        respond(error.map { .failure(requestID, $0) } ?? response, to: id)
        audit?.record(device: connections[id]?.deviceID, type: request.type, task: request.taskID,
                      schedule: request.scheduleID, result: error?.code.rawValue ?? "ok", at: now())
    }

    /// A part of one of the task's files (§15.22), read off this actor and Swift's threads so a large file or a slow disk
    /// holds up no other connection. A device reads at most `readFileBudgetBytes` per `readFileBudgetWindow`. The audit
    /// log gets every read of a listed task that does not go on from the part before it on this connection, and every
    /// refusal, by the file's name, never its path, the same line at most once a minute.
    private func readFile(_ requestID: String, taskID: String, path: String, offset: Int, on id: UUID) async {
        // Kept for the audit line, also when the connection closes during the read.
        let device = connections[id]?.deviceID
        let budgetKey = device ?? id.uuidString
        var budget = readBudgets[budgetKey] ?? RemoteRateBucket(
            capacity: Double(RemoteProtocol.readFileBudgetBytes),
            perSecond: Double(RemoteProtocol.readFileBudgetBytes) / RemoteProtocol.readFileBudgetWindow, now: now())
        let hasRoom = budget.hasTokens(now: now())
        readBudgets[budgetKey] = budget
        guard hasRoom else {
            respond(.failure(requestID, RemoteError(.rateLimited, "Files: at most 32 MiB per 10 s")), to: id)
            return
        }
        let scope: RemoteFileScope
        switch await bridge.fileScope(taskID: taskID) {
        case let .success(found):
            scope = found
        case let .failure(error):
            // No such task: nothing a phone could read, and nothing for the log.
            respond(.failure(requestID, error), to: id)
            return
        }
        let result = await RemoteFileReader.perform { RemoteFileReader.read(path, offset: offset, in: scope) }
        switch result {
        case let .success(part):
            // By the file read, not the path asked for: a link turned to another file between parts is another read.
            let goesOn = connections[id]?.fileRead == FileRead(taskID: taskID, path: part.path, next: offset)
            // Another connection of the device may have spent meanwhile.
            readBudgets[budgetKey]?.spend(Double(part.data.count), now: now())
            var response = RemoteResponse(re: requestID)
            response.path = part.path
            response.name = part.name
            response.mediaType = part.mediaType
            response.size = part.size
            response.offset = part.offset
            response.data = part.data
            response.modifiedAt = part.modifiedAt
            respond(response, to: id)
            connections[id]?.fileRead = FileRead(taskID: taskID, path: part.path, next: offset + part.data.count)
            if !goesOn { auditRead(device: device, task: taskID, file: part.name, result: "ok") }
        case let .failure(error):
            respond(.failure(requestID, error), to: id)
            connections[id]?.fileRead = nil
            auditRead(device: device, task: taskID, file: RemoteFileReader.auditName(path), result: error.code.rawValue)
        }
    }

    private func auditRead(device: String?, task: String, file: String, result: String) {
        let time = now()
        auditedReads = auditedReads.filter { time.timeIntervalSince($0.value) < Self.readAuditWindow }
        let key = [device ?? "", task, file, result].joined(separator: "\u{0}")
        guard auditedReads[key] == nil else { return }
        auditedReads[key] = time
        audit?.record(device: device, type: "readFile", task: task, file: file, result: result, at: time)
    }

    /// A task's settings as `taskSettings` answers them (§15.23). A connection subscribed to the task is told when they
    /// change from now on.
    private func respondSettings(_ requestID: String, taskID: String, _ result: Result<[RemoteSetting], RemoteError>,
                                 on id: UUID) {
        switch result {
        case let .success(settings):
            var response = RemoteResponse(re: requestID)
            response.taskId = taskID
            response.settings = settings
            respond(response, to: id)
            if connections[id]?.subscriptions[taskID] != nil { connections[id]?.followsSettings.insert(taskID) }
        case let .failure(error):
            respond(.failure(requestID, error), to: id)
        }
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

    private func subscribe(_ requestID: String, taskID: String, detail: RemoteConversationDetail, on id: UUID) async {
        guard let connection = connections[id] else { return }
        guard connection.subscriptions[taskID] != nil
                || connection.subscriptions.count < configuration.maxSubscriptions else {
            respond(.failure(requestID, RemoteError(.tooManySubscriptions)), to: id)
            return
        }
        let (generation, conversation) = await fetch(taskID, detail: detail)
        guard connections[id] != nil else { return }
        guard let conversation else {
            respond(.failure(requestID, RemoteError(.notFound, "No task \(taskID)")), to: id)
            return
        }
        var window = RemoteConversationWindow(limits: configuration.windowLimits)
        let page = window.open(conversation)
        connections[id]?.subscriptions[taskID] = Subscription(window: window, generation: generation, detail: detail)
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
            let detail = connections[id]?.subscriptions[taskID]?.detail ?? .basic
            let (generation, conversation) = await fetch(taskID, detail: detail)
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

    private func fetch(_ taskID: String, detail: RemoteConversationDetail) async -> (Int, RemoteConversation?) {
        fetchGeneration += 1
        let generation = fetchGeneration
        return (generation, await bridge.conversation(of: taskID, detail: detail))
    }

    /// Reads the conversation once for each detail its subscriptions asked for, and sends each the changes.
    private func refreshConversation(_ taskID: String) async {
        let details = Set(connections.values.compactMap { $0.subscriptions[taskID]?.detail })
        var ended = false
        for detail in [RemoteConversationDetail.basic, .full] where details.contains(detail) {
            let (generation, conversation) = await fetch(taskID, detail: detail)
            for (id, connection) in connections {
                guard var subscription = connection.subscriptions[taskID], subscription.detail == detail,
                      subscription.generation < generation else { continue }
                guard let conversation else {
                    connections[id]?.subscriptions[taskID] = nil
                    connections[id]?.followsSettings.remove(taskID)
                    var event = RemoteEvent(.conversationEnded)
                    event.taskId = taskID
                    event.reason = "removed"
                    send(event, to: id)
                    continue
                }
                subscription.generation = generation
                let update = subscription.window.update(conversation)
                connections[id]?.subscriptions[taskID] = subscription
                send(update, of: taskID, to: id)
            }
            if conversation == nil { ended = true }
        }
        if ended { await updateWatched() }
    }

    /// A window's update as its event: changes, the window again whole, or nothing.
    private func send(_ update: RemoteConversationWindow.Update, of taskID: String, to id: UUID) {
        switch update {
        case .unchanged:
            break
        case let .changes(changes):
            for part in RemoteConversationWindow.parts(of: changes, maxBytes: Self.maxChangesBytes) {
                var event = RemoteEvent(.conversation)
                event.taskId = taskID
                event.changes = part
                send(event, to: id)
            }
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
        case let .taskSettings(taskID):
            // The bridge tells only of a change since the last read; the phone reads them again.
            var event = RemoteEvent(.taskSettingsChanged)
            event.taskId = taskID
            for (id, connection) in connections where connection.followsSettings.contains(taskID) {
                send(event, to: id)
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
        RemoteLog.notice("Remote: closing \(Self.describe(connection)) with code \(code.rawValue) after \(lifetime(of: connection))")
        forgetLink(on: id)
        connection.channel.close(code)
        Task { await self.updateWatched() }
        publishStatus()
    }

    /// A connection as the log names it: its device and path.
    private static func describe(_ connection: Connection) -> String {
        "device \(RemoteLog.device(connection.deviceID)) over \(connection.path?.rawValue ?? "an unknown path")"
    }

    /// How long a connection was up, and how long since the phone last sent something.
    private func lifetime(of connection: Connection) -> String {
        let time = now()
        return "\(RemoteLog.seconds(time.timeIntervalSince(connection.openedAt))), "
            + "\(RemoteLog.seconds(time.timeIntervalSince(connection.lastReceivedAt))) after the phone's last message"
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
            let collapse = RemotePushSeal.collapseKey(taskID: event.taskId ?? "")
            // While a desktop is in use the person sees it there; the task's latest change waits for when it is not.
            if isDesktopInUse {
                heldPushes.removeAll { $0.collapse == collapse }
                heldPushes.append(HeldPush(payload: payload, urgent: urgent, collapse: collapse))
                continue
            }
            await deliver(payload, urgent: urgent, collapse: collapse)
        }
    }

    private struct HeldPush {
        var payload: RemoteEvent
        var urgent: Bool
        var collapse: String
    }

    /// A paired desktop says it is in use (§18).
    private var isDesktopInUse: Bool {
        connections.values.contains { $0.isEstablished && $0.isPresent }
    }

    /// Once no desktop is in use, each held task's latest change goes to the phones, in the order they came:
    /// a request still waiting rings, one answered there meanwhile withdraws what an earlier push showed.
    private func releaseHeldPushes() async {
        guard !isDesktopInUse, !heldPushes.isEmpty else { return }
        let held = heldPushes
        heldPushes = []
        for push in held { await deliver(push.payload, urgent: push.urgent, collapse: push.collapse) }
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
