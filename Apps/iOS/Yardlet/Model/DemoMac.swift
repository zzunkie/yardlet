import Foundation
import YardletRemote
import YardletRemoteFixtureSupport

/// "Try without a Mac": the fixture Mac the protocol's tests use (docs/REMOTE_PROTOCOL.md §17), served inside the
/// app on loopback and reached through the same connection, pairing and screens as a real Mac. Its tasks, answers
/// and files are the fixture's; nothing leaves the phone, and nothing of it is kept once the demo ends.
actor DemoMac {
    struct Failure: Error {}

    private var server: RemoteServer?
    private var listener: RemoteSecureListener?
    private var folder: URL?
    private var bridge: DemoBridge?

    /// Starts the fixture Mac and returns its pairing link.
    func start() async throws -> RemoteSecurePairingURL {
        let identity = RemoteIdentity.generate()
        let folder = FileManager.default.temporaryDirectory.appending(path: "demo-mac-\(UUID().uuidString)",
                                                                    directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.folder = folder
        let bridge = DemoBridge(RemoteFixtureBridge(filesFolder: folder.appending(path: "files", directoryHint: .isDirectory)))
        self.bridge = bridge
        var configuration = RemoteServer.Configuration(server: RemoteServerInfo(name: "Demo Mac", appVersion: "demo"),
                                                       macKey: identity.noise.publicKey)
        configuration.uploadDirectory = folder.appending(path: "uploads", directoryHint: .isDirectory)
        let server = RemoteServer(configuration: configuration, bridge: bridge, devices: RemoteDeviceStore(fileURL: nil))
        await server.start()
        let secret = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        _ = await server.openPairing(secret: secret, lifetime: 24 * 3600, isSingleUse: false)
        self.server = server

        let listener = RemoteSecureListener(server: server, staticKey: identity.noise, port: 0, advertisement: nil,
                                            loopbackOnly: true)
        let (states, continuation) = AsyncStream<RemoteSecureListener.State>.makeStream()
        listener.onStateChange = { continuation.yield($0) }
        listener.start()
        self.listener = listener
        for await state in states {
            switch state {
            case let .ready(port):
                let host = "127.0.0.1:\(port)"
                await server.setDirectory(direct: [host], relay: nil)
                return RemoteSecurePairingURL(macKey: identity.noise.publicKey, secret: secret, name: "Demo Mac",
                                              hosts: [host])
            case .failed:
                throw Failure()
            default:
                continue
            }
        }
        throw Failure()
    }

    /// The ordinary approval a demo task waits on, as the `attention` change a Mac pushes for it (§5.2, §16), for the
    /// notification the demo shows once the person leaves the app. Nil when none waits.
    func waitingApproval() async -> RemoteEvent? {
        guard let snapshot = await bridge?.snapshot(),
              let task = snapshot.tasks.first(where: {
                  $0.attention == .waiting && $0.pendingRequest == .approval && ($0.pendingKind ?? "approval") == "approval"
              }),
              let requestID = snapshot.newestRequestIDs[task.id] else { return nil }
        var event = RemoteEvent(.attention)
        event.taskId = task.id
        event.title = task.title
        event.projectName = snapshot.projects.first { $0.id == task.projectId }?.name
        event.harnessName = task.harnessName
        event.state = .waiting
        event.previousState = .active
        event.indicator = task.indicator
        event.pendingRequest = .approval
        event.pendingKind = task.pendingKind
        event.requestId = requestID
        event.summary = snapshot.requestSummaries[task.id] ?? task.pendingSummary
        event.macName = "Demo Mac"
        return event
    }

    func stop() {
        listener?.stop()
        listener = nil
        server = nil
        bridge = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }
}

/// The fixture Mac as the demo shows it: what a Mac words itself (its composer's settings and their choices, what it
/// asks before one, and its cards' answers) comes in the app's language, as a real Mac sends them in its own. Every
/// call goes to the fixture; only those words change, through the Demo table (the Mac's own translations).
final class DemoBridge: RemoteBridge {
    private let fixture: RemoteFixtureBridge

    init(_ fixture: RemoteFixtureBridge) {
        self.fixture = fixture
    }

    func setChangeHandler(_ handler: @escaping @Sendable (RemoteBridgeChange) -> Void) async {
        await fixture.setChangeHandler(handler)
    }

    func snapshot() async -> RemoteSnapshot { await fixture.snapshot() }

    func conversation(of taskID: String) async -> RemoteConversation? {
        (await fixture.conversation(of: taskID)).map(Self.local)
    }

    func conversation(of taskID: String, detail: RemoteConversationDetail) async -> RemoteConversation? {
        (await fixture.conversation(of: taskID, detail: detail)).map(Self.local)
    }

    func prepareConversation(of taskID: String) async { await fixture.prepareConversation(of: taskID) }
    func loadEarlierConversation(of taskID: String) async { await fixture.loadEarlierConversation(of: taskID) }
    func perform(_ command: RemoteCommand) async -> RemoteError? { await fixture.perform(command) }
    func setWatchedTasks(_ taskIDs: Set<String>) async { await fixture.setWatchedTasks(taskIDs) }
    func createTask(_ start: RemoteTaskStart) async -> Result<String, RemoteError> { await fixture.createTask(start) }

    func itemDetail(taskID: String, itemID: String) async -> Result<RemoteItemDetail, RemoteError> {
        await fixture.itemDetail(taskID: taskID, itemID: itemID)
    }

    func newTaskOptions(projectID: String?, harness: String?,
                        settings: [String: String]) async -> Result<RemoteNewTaskOptions, RemoteError> {
        (await fixture.newTaskOptions(projectID: projectID, harness: harness, settings: settings)).map { options in
            var options = options
            options.settings = options.settings.map(Self.local)
            return options
        }
    }

    func suggestionOptions(taskID: String, suggestionID: String, harness: String?, settings: [String: String],
                           projectID: String?, accountID: String?,
                           composer: Bool) async -> Result<RemoteNewTaskOptions, RemoteError> {
        (await fixture.suggestionOptions(taskID: taskID, suggestionID: suggestionID, harness: harness, settings: settings,
                                         projectID: projectID, accountID: accountID, composer: composer)).map { options in
            var options = options
            options.settings = options.settings.map(Self.local)
            return options
        }
    }

    func limitAccounts(taskID: String) async -> Result<[RemoteAccount], RemoteError> {
        await fixture.limitAccounts(taskID: taskID)
    }

    func scheduledTasks() async -> Result<[RemoteSchedule], RemoteError> { await fixture.scheduledTasks() }
    func taskOutputs(taskID: String) async -> Result<[RemoteOutput], RemoteError> { await fixture.taskOutputs(taskID: taskID) }
    func fileScope(taskID: String) async -> Result<RemoteFileScope, RemoteError> { await fixture.fileScope(taskID: taskID) }

    func taskSettings(taskID: String, prepare: Bool) async -> Result<[RemoteSetting], RemoteError> {
        (await fixture.taskSettings(taskID: taskID, prepare: prepare)).map { $0.map(Self.local) }
    }

    func setTaskSetting(taskID: String, setting: String, value: String,
                        confirmed: Bool) async -> Result<[RemoteSetting], RemoteError> {
        (await fixture.setTaskSetting(taskID: taskID, setting: setting, value: value, confirmed: confirmed))
            .map { $0.map(Self.local) }
    }

    func composerCommands(taskID: String) async -> Result<[RemoteComposerCommand], RemoteError> {
        (await fixture.composerCommands(taskID: taskID)).map { $0.map(Self.local) }
    }

    func runComposerCommand(taskID: String, command: String, arguments: String?) async -> Result<String?, RemoteError> {
        await fixture.runComposerCommand(taskID: taskID, command: command, arguments: arguments)
    }

    func forkTask(taskID: String, turnID: String?) async -> Result<String, RemoteError> {
        await fixture.forkTask(taskID: taskID, turnID: turnID)
    }

    func composerState(taskID: String) async -> Result<RemoteComposerState, RemoteError> {
        await fixture.composerState(taskID: taskID)
    }

    func composerAction(taskID: String, action: String, itemID: String?,
                        value: String?) async -> Result<RemoteComposerState, RemoteError> {
        await fixture.composerAction(taskID: taskID, action: action, itemID: itemID, value: value)
    }

    // MARK: - The Mac's words

    static func local(_ setting: RemoteSetting) -> RemoteSetting {
        var setting = setting
        setting.name = word(setting.name)
        setting.title = setting.title.map(word)
        setting.note = setting.note.map(word)
        setting.choices = setting.choices.map { choice in
            var choice = choice
            choice.name = word(choice.name)
            choice.description = choice.description.map(word)
            choice.confirm = choice.confirm.map {
                RemoteSetting.Confirmation(title: word($0.title), message: word($0.message), button: word($0.button))
            }
            return choice
        }
        return setting
    }

    static func local(_ command: RemoteComposerCommand) -> RemoteComposerCommand {
        var command = command
        command.title = command.title.map(word)
        command.description = command.description.map(word)
        return command
    }

    static func local(_ conversation: RemoteConversation) -> RemoteConversation {
        var conversation = conversation
        conversation.turns = conversation.turns.map { turn in
            var turn = turn
            turn.items = turn.items.map { item in
                guard item.choices != nil || item.optionTitles != nil else { return item }
                var item = item
                item.choices = item.choices?.map { choice in
                    var choice = choice
                    choice.title = word(choice.title)
                    return choice
                }
                item.optionTitles = item.optionTitles?.mapValues(word)
                return item
            }
            return turn
        }
        return conversation
    }

    /// The Mac's words in the app's language, when its catalog has them; as they are otherwise.
    static func word(_ text: String) -> String {
        let saved = "Always allow in this project (saved to "
        if text.hasPrefix(saved), text.hasSuffix(")") {
            let path = String(text.dropFirst(saved.count).dropLast())
            let format = NSLocalizedString("Always allow in this project (saved to %@)", tableName: "Demo", comment: "")
            return String(format: format, path)
        }
        return NSLocalizedString(text, tableName: "Demo", comment: "")
    }
}
