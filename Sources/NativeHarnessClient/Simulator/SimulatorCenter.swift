import Foundation
import Observation

/// Who asks for a device: the person in the simulator panel, or a task's agent through its tools. A person picks
/// with the cost in view, so only an agent is held to the limit on started devices and refused a device another
/// task claims.
enum SimulatorRequester: Sendable {
    case person
    case agent
}

/// The time the idle rules count, and their waits; a fake one in tests.
protocol SimulatorClock: Sendable {
    var now: Date { get }
    func sleep(until deadline: Date) async throws
}

struct LiveSimulatorClock: SimulatorClock {
    var now: Date { Date() }

    func sleep(until deadline: Date) async throws {
        let seconds = deadline.timeIntervalSinceNow
        guard seconds > 0 else { return }
        try await Task.sleep(for: .milliseconds(Int64((seconds * 1000).rounded(.up))))
    }
}

/// Where a task's attached device is kept: its workspace snapshot, so the attachment outlives a restart and goes
/// with the task when it is archived or deleted.
@MainActor
protocol SimulatorAttachmentStore: AnyObject {
    func simulatorAttachment(of task: UUID) -> SimulatorDeviceIdentity?
    func setSimulatorAttachment(_ device: SimulatorDeviceIdentity?, of task: UUID)
    /// The tasks whose saved workspace attaches the device. Asked only when Yardlet starts a device or finds one it
    /// started before, so it may read every task's snapshot.
    func tasksAttaching(_ device: SimulatorDeviceIdentity) -> Set<UUID>
}

/// Attachments kept in memory: tests, and a model without task workspaces.
@MainActor
final class InMemorySimulatorAttachments: SimulatorAttachmentStore {
    var attachments: [UUID: SimulatorDeviceIdentity] = [:]

    func simulatorAttachment(of task: UUID) -> SimulatorDeviceIdentity? { attachments[task] }
    func setSimulatorAttachment(_ device: SimulatorDeviceIdentity?, of task: UUID) { attachments[task] = device }
    func tasksAttaching(_ device: SimulatorDeviceIdentity) -> Set<UUID> {
        Set(attachments.filter { $0.value == device }.map(\.key))
    }
}

/// A device as one task sees it, with what the agent's `simulator_list` reports.
struct SimulatorListEntry: Equatable, Sendable {
    /// With its state as Yardlet knows it: booting while Yardlet waits for it to be ready.
    var device: SimulatorDevice
    var isAttachedHere: Bool
    /// The task that may send it input, this one or another; nil when none claims it.
    var claimingTask: UUID?
    /// Yardlet started it, and stops it once it is unused.
    var isStartedByYardlet: Bool
    /// A simulator panel shows it.
    var isShown: Bool
}

/// A task's attachment, as an attach left it.
struct SimulatorAttachment: Equatable, Sendable {
    var device: SimulatorDevice
    /// This task may send the device input.
    var isClaimed: Bool
    /// The other task that may, when this one may not.
    var claimingTask: UUID?
    /// Yardlet started the device for this attach.
    var startedNow: Bool
    /// Yardlet started the device, now or before, and stops it once it is unused.
    var isStartedByYardlet: Bool
}

/// Why an attach was refused, with the devices that are on and free to offer instead.
struct SimulatorRefusal: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// The Simulator feature is off.
        case disabled
        /// No listed device has this ID or name.
        case unknownDevice(String)
        /// More than one listed device has this name.
        case ambiguousDevice(String, matches: [SimulatorDevice])
        case unavailable(SimulatorPlatform, SimulatorAvailability)
        /// Another task's agent has the device's input.
        case claimedByAnotherTask(UUID)
        /// Yardlet already runs this many devices it started; an agent starts no more.
        case startLimit(Int)
        /// The task has no attached device.
        case notAttached
    }

    var reason: Reason
    var freeRunningDevices: [SimulatorDevice]
}

enum SimulatorAttachResult: Equatable, Sendable {
    case attached(SimulatorAttachment)
    case refused(SimulatorRefusal)
    /// The device is attached, but it did not start or did not become ready.
    case failed(SimulatorDevice, message: String)
}

/// The devices of every platform, which task attaches and which claims each, and the devices Yardlet started and
/// stops.
///
/// - An attachment is the device a task chose: at most one per task, kept in the task's workspace snapshot.
/// - A claim is the right of a task's agent to send a device input: one task per device, in memory only. Attaching a
///   device no task claims claims it; a device another task claims is attached for viewing, or refused to an agent.
///   Detaching, choosing another device and removing the task release both.
/// - Yardlet writes down each device it starts with its boot (`SimulatorBootIdentity`) and stops only that boot:
///   ten minutes after no task attaches it and no panel shows it, thirty minutes after the last turn, tool call or
///   panel of the tasks that attach it, never while one of their turns runs, and when Yardlet quits. A Yardlet that
///   ended without stopping them stops, at its next start, those still on in the same boot that no task attaches.
///
/// Nothing runs until the feature is turned on (`setEnabled(_:)`): no command, no file. Devices are read when asked
/// (`refreshDevices()`), never on a timer, and the published state changes only when a device's does.
@MainActor @Observable
final class SimulatorCenter {
    /// Devices Yardlet started that an agent may have running at once: an Android emulator alone holds about 5 GB.
    static let agentStartLimit = 2
    static let unattachedStopDelay: TimeInterval = 10 * 60
    static let idleStopDelay: TimeInterval = 30 * 60

    private(set) var isEnabled = false
    /// What each platform's check found, once checked.
    private(set) var checks: [SimulatorPlatform: SimulatorPlatformCheck] = [:]
    /// Every platform's devices: those on first, then iOS simulators by runtime, then Android.
    private(set) var devices: [SimulatorDevice] = []
    /// The task whose agent may send each device input.
    private(set) var claims: [SimulatorDeviceIdentity: UUID] = [:]
    /// The devices Yardlet started, by the boot it started.
    private(set) var startedByYardlet: [SimulatorDeviceIdentity: SimulatorBootRecordEntry] = [:]
    /// Devices Yardlet is starting or stopping.
    private(set) var transitions: [SimulatorDeviceIdentity: SimulatorDeviceState] = [:]

    /// Whether a task's turn runs, which keeps the devices it attaches on.
    @ObservationIgnored var isTurnRunning: @MainActor (UUID) -> Bool = { _ in false }
    @ObservationIgnored var attachmentStore: any SimulatorAttachmentStore

    @ObservationIgnored private let backends: [SimulatorPlatform: any SimulatorBackend]
    @ObservationIgnored private let record: any SimulatorBootRecordStore
    @ObservationIgnored private let clock: any SimulatorClock
    /// The attachments read or made in this run, complete for every device Yardlet started.
    @ObservationIgnored private var attachments: [UUID: SimulatorDeviceIdentity] = [:]
    @ObservationIgnored private var attachmentsRead: Set<UUID> = []
    @ObservationIgnored private var shownPanels: [UUID: Int] = [:]
    /// When each device Yardlet started was last used: attached or let go, shown or hidden, by a tool or a turn.
    @ObservationIgnored private var lastUse: [SimulatorDeviceIdentity: Date] = [:]
    @ObservationIgnored private var boots: [SimulatorDeviceIdentity: Task<Result<Bool, SimulatorCommandError>, Never>] = [:]
    /// Devices whose stop is under way, from the reading of their boot on.
    @ObservationIgnored private var stopping: Set<SimulatorDeviceIdentity> = []
    @ObservationIgnored private var idleCheck: Task<Void, Never>?
    /// The Xcode whose screens the simulator host said it cannot show.
    @ObservationIgnored private var unsupportedToolchain: SimulatorToolchain?
    /// When the person last pressed, typed or scrolled on each device in a simulator panel. Not published: it
    /// changes with every touch, and only the agent's tools read it, to say a person is using the device.
    @ObservationIgnored private var personInput: [SimulatorDeviceIdentity: Date] = [:]

    init(backends: [any SimulatorBackend] = [],
         record: any SimulatorBootRecordStore = InMemorySimulatorBootRecord(),
         attachments: any SimulatorAttachmentStore = InMemorySimulatorAttachments(),
         clock: any SimulatorClock = LiveSimulatorClock()) {
        self.backends = Dictionary(backends.map { ($0.platform, $0) }, uniquingKeysWith: { first, _ in first })
        self.record = record
        attachmentStore = attachments
        self.clock = clock
    }

    // MARK: - The feature

    /// The Simulator switch. On: checks the platforms, stops what an earlier Yardlet started and left unused, and
    /// lists the devices. Off: stops the devices Yardlet started and lets go of every claim.
    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            await refreshChecks()
            await recoverStartedDevices()
            await refreshDevices()
        } else {
            await stopEveryStartedDevice()
            idleCheck?.cancel()
            idleCheck = nil
            claims = [:]
            shownPanels = [:]
            devices = []
            checks = [:]
        }
    }

    /// Yardlet quits: every device it started stops, attached or not.
    func stopForQuit() async {
        idleCheck?.cancel()
        idleCheck = nil
        await stopEveryStartedDevice()
    }

    // MARK: - Platforms and devices

    /// Checks each platform off the main thread and keeps what it found.
    func refreshChecks() async {
        guard isEnabled else { return }
        var found: [SimulatorPlatform: SimulatorPlatformCheck] = [:]
        for (platform, backend) in backends {
            var check = await backend.check()
            if check.availability == .available, let unsupportedToolchain, check.toolchain == unsupportedToolchain {
                check.availability = .xcodeNotSupportedYet(xcodeVersion: unsupportedToolchain.version)
            }
            found[platform] = check
        }
        guard isEnabled else { return }
        if found != checks { checks = found }
    }

    /// The developer folder or SDK a platform's devices run with, which the simulator host is also handed.
    func toolchain(for platform: SimulatorPlatform) -> SimulatorToolchain? {
        checks[platform].flatMap { $0.availability.listsDevices ? $0.toolchain : nil }
    }

    /// The simulator host cannot show this Xcode's screens: its devices still list and start, and the panel says why
    /// it shows none.
    func markNotSupportedYet(_ toolchain: SimulatorToolchain) {
        unsupportedToolchain = toolchain
        guard var check = checks[.iOS], check.toolchain == toolchain, check.availability == .available else { return }
        check.availability = .xcodeNotSupportedYet(xcodeVersion: toolchain.version)
        checks[.iOS] = check
    }

    /// Reads every platform's devices. A platform whose list fails keeps the devices it listed last.
    func refreshDevices() async {
        guard isEnabled else { return }
        var listed: [SimulatorDevice] = []
        for platform in SimulatorPlatform.allCases {
            guard let backend = backends[platform], let toolchain = toolchain(for: platform) else { continue }
            do {
                listed += try await backend.devices(with: toolchain)
            } catch {
                listed += devices.filter { $0.platform == platform }
            }
        }
        guard isEnabled else { return }
        let ordered = SimulatorDeviceOrder.sorted(listed)
        if ordered != devices { devices = ordered }
        // A device Yardlet started that is now off, or gone, was stopped elsewhere.
        let stoppedElsewhere = startedByYardlet.keys.filter { identity in
            boots[identity] == nil && transitions[identity] == nil && !stopping.contains(identity)
                && device(identity).map { $0.state == .off } ?? true
        }
        if !stoppedElsewhere.isEmpty {
            stoppedElsewhere.forEach(forget)
            saveRecord()
            rescheduleIdleCheck()
        }
    }

    func device(_ identity: SimulatorDeviceIdentity) -> SimulatorDevice? {
        devices.first { $0.identity == identity }
    }

    /// The device's state, with Yardlet's own starting and stopping over the platform's.
    func state(of identity: SimulatorDeviceIdentity) -> SimulatorDeviceState {
        transitions[identity] ?? device(identity)?.state ?? .off
    }

    /// The devices with what one task sees of each.
    func entries(for task: UUID) -> [SimulatorListEntry] {
        let attached = attachment(of: task)
        let shown = Set(shownPanels.compactMap { $0.value > 0 ? attachments[$0.key] : nil })
        return devices.map { device in
            var device = device
            device.state = state(of: device.identity)
            return SimulatorListEntry(device: device, isAttachedHere: attached == device.identity,
                                      claimingTask: claims[device.identity],
                                      isStartedByYardlet: startedByYardlet[device.identity] != nil,
                                      isShown: shown.contains(device.identity))
        }
    }

    /// The listed devices an ID or a name names: the device of that UDID, adb serial or AVD name, else those of that
    /// name, the one that is on when only one of them is.
    func devices(named query: String) -> [SimulatorDevice] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let byID = devices.filter {
            $0.identity.value.caseInsensitiveCompare(query) == .orderedSame || $0.adbSerial == query
        }
        if !byID.isEmpty { return byID }
        let byName = devices.filter { $0.name.caseInsensitiveCompare(query) == .orderedSame }
        let running = byName.filter { state(of: $0.identity).isRunning }
        return byName.count > 1 && running.count == 1 ? running : byName
    }

    // MARK: - Attachments and claims

    /// The device the task attaches, read from its workspace the first time.
    func attachment(of task: UUID) -> SimulatorDeviceIdentity? {
        if attachmentsRead.contains(task) { return attachments[task] }
        attachmentsRead.insert(task)
        let saved = attachmentStore.simulatorAttachment(of: task)
        attachments[task] = saved
        return saved
    }

    /// Attaches the device an ID or name names (`devices(named:)`), after listing the devices again.
    func attach(_ query: String, to task: UUID, by requester: SimulatorRequester) async -> SimulatorAttachResult {
        guard isEnabled else { return refusal(.disabled) }
        await refreshDevices()
        let matches = devices(named: query)
        guard let device = matches.first else { return refusal(.unknownDevice(query)) }
        guard matches.count == 1 else { return refusal(.ambiguousDevice(query, matches: matches)) }
        return await attach(device.identity, to: task, by: requester)
    }

    /// Attaches the device to the task, claims it when no task does, and starts it when it is off.
    func attach(_ identity: SimulatorDeviceIdentity, to task: UUID,
                by requester: SimulatorRequester) async -> SimulatorAttachResult {
        guard isEnabled else { return refusal(.disabled) }
        guard let device = device(identity) else { return refusal(.unknownDevice(identity.value)) }
        let platform = device.platform
        guard let backend = backends[platform], let toolchain = toolchain(for: platform) else {
            let missing: SimulatorAvailability = platform == .iOS ? .xcodeMissing : .sdkMissing
            return refusal(.unavailable(platform, checks[platform]?.availability ?? missing))
        }
        let holder = claims[identity]
        if let holder, holder != task, requester == .agent {
            return refusal(.claimedByAnotherTask(holder), excluding: identity)
        }
        let needsStart = !state(of: identity).isRunning
        if needsStart, requester == .agent, startedCount >= Self.agentStartLimit {
            return refusal(.startLimit(Self.agentStartLimit), excluding: identity)
        }

        if let previous = attachment(of: task), previous != identity { letGo(of: previous, by: task) }
        if attachments[task] != identity {
            attachments[task] = identity
            attachmentStore.setSimulatorAttachment(identity, of: task)
        }
        if holder == nil { claims[identity] = task }
        noteUse(identity)

        var startedNow = false
        if needsStart || boots[identity] != nil {
            switch await start(device, backend: backend, toolchain: toolchain) {
            case let .success(started):
                startedNow = started
            case let .failure(error):
                return .failed(self.device(identity) ?? device, message: error.message)
            }
        }
        rescheduleIdleCheck()
        var current = self.device(identity) ?? device
        current.state = state(of: identity)
        let claimant = claims[identity]
        return .attached(SimulatorAttachment(device: current, isClaimed: claimant == task,
                                             claimingTask: claimant == task ? nil : claimant, startedNow: startedNow,
                                             isStartedByYardlet: startedByYardlet[identity] != nil))
    }

    /// Before an agent's tool acts on the task's device: claims it again when no task does (claims are not kept
    /// across a restart) and starts it again when the idle rules stopped it, under the same rules as an attach.
    func prepareAttachedDevice(for task: UUID) async -> SimulatorAttachResult {
        guard isEnabled else { return refusal(.disabled) }
        guard let identity = attachment(of: task) else { return refusal(.notAttached) }
        await refreshDevices()
        return await attach(identity, to: task, by: .agent)
    }

    /// "Use in this task": the task's agent takes the input of the device it attaches from whichever task had it.
    /// Returns the task that had it.
    @discardableResult
    func claim(for task: UUID) -> UUID? {
        guard let identity = attachment(of: task) else { return nil }
        let previous = claims[identity]
        claims[identity] = task
        noteUse(identity)
        return previous == task ? nil : previous
    }

    /// Detaches the task's device and lets go of its claim.
    func detach(_ task: UUID) {
        guard let identity = attachment(of: task) else { return }
        letGo(of: identity, by: task)
        attachmentStore.setSimulatorAttachment(nil, of: task)
        rescheduleIdleCheck()
    }

    /// The task was archived or deleted, which removes its saved attachment with its workspace.
    func taskRemoved(_ task: UUID) {
        if let identity = attachments[task] { letGo(of: identity, by: task) }
        attachmentsRead.insert(task)
        shownPanels[task] = nil
        rescheduleIdleCheck()
    }

    // MARK: - Use

    /// A simulator panel showing the task's device appeared, which also claims the device again when no task does.
    func panelAppeared(for task: UUID) {
        shownPanels[task, default: 0] += 1
        guard let identity = attachment(of: task) else { return }
        if claims[identity] == nil { claims[identity] = task }
        noteUse(identity)
        rescheduleIdleCheck()
    }

    func panelDisappeared(for task: UUID) {
        guard let count = shownPanels[task] else { return }
        shownPanels[task] = count > 1 ? count - 1 : nil
        guard count == 1, let identity = attachments[task] else { return }
        noteUse(identity)
        rescheduleIdleCheck()
    }

    /// The person pressed, typed or scrolled on the device in a simulator panel, in any task's.
    func notePersonInput(on identity: SimulatorDeviceIdentity) {
        personInput[identity] = clock.now
    }

    /// When the person last pressed, typed or scrolled on the device in a simulator panel; nil when they have not
    /// since Yardlet started.
    func lastPersonInput(on identity: SimulatorDeviceIdentity) -> Date? {
        personInput[identity]
    }

    /// An agent's tool acted on the task's device.
    func noteToolUse(for task: UUID) {
        guard let identity = attachments[task] else { return }
        noteUse(identity)
    }

    /// The task's status changed: a turn started or ended, which holds or lets go of the devices it attaches.
    func taskStatusChanged(_ task: UUID) {
        guard let identity = attachments[task], startedByYardlet[identity] != nil else { return }
        if !isTurnRunning(task) { noteUse(identity) }
        rescheduleIdleCheck()
    }

    // MARK: - Starting and stopping

    /// Stops a device Yardlet started, from its menu. False when Yardlet did not start it, or it runs another boot.
    @discardableResult
    func stopStartedDevice(_ identity: SimulatorDeviceIdentity) async -> Bool {
        let stopped = await stop(identity)
        rescheduleIdleCheck()
        return stopped
    }

    /// When the idle rules stop the device; nil while a panel shows it, a turn of a task attaching it runs, or
    /// Yardlet did not start it.
    func stopDeadline(for identity: SimulatorDeviceIdentity) -> Date? {
        guard let entry = startedByYardlet[identity], boots[identity] == nil, transitions[identity] == nil
        else { return nil }
        let attachers = attachments.compactMap { $0.value == identity ? $0.key : nil }
        if attachers.contains(where: { shownPanels[$0, default: 0] > 0 || isTurnRunning($0) }) { return nil }
        let since = lastUse[identity] ?? entry.bootedAt
        return since.addingTimeInterval(attachers.isEmpty ? Self.unattachedStopDelay : Self.idleStopDelay)
    }

    /// Stops each device Yardlet started whose idle time is up.
    func stopIdleDevices() async {
        idleCheck = nil
        let now = clock.now
        for identity in Array(startedByYardlet.keys) {
            guard let deadline = stopDeadline(for: identity), deadline <= now else { continue }
            await stop(identity) { [weak self] in
                self?.stopDeadline(for: identity).map { $0 <= now } ?? false
            }
        }
        rescheduleIdleCheck()
    }

    // MARK: - Private

    private var startedCount: Int { Set(startedByYardlet.keys).union(boots.keys).count }

    private func refusal(_ reason: SimulatorRefusal.Reason,
                         excluding identity: SimulatorDeviceIdentity? = nil) -> SimulatorAttachResult {
        let free = devices.filter {
            $0.identity != identity && state(of: $0.identity) == .on && claims[$0.identity] == nil
        }
        return .refused(SimulatorRefusal(reason: reason, freeRunningDevices: free))
    }

    private func letGo(of identity: SimulatorDeviceIdentity, by task: UUID) {
        if attachments[task] == identity { attachments[task] = nil }
        attachmentsRead.insert(task)
        if claims[identity] == task { claims[identity] = nil }
        noteUse(identity)
    }

    private func noteUse(_ identity: SimulatorDeviceIdentity) {
        guard startedByYardlet[identity] != nil else { return }
        lastUse[identity] = clock.now
    }

    /// Starts the device, or waits for the start already under way. True when this start turned it on.
    private func start(_ device: SimulatorDevice, backend: any SimulatorBackend,
                       toolchain: SimulatorToolchain) async -> Result<Bool, SimulatorCommandError> {
        let identity = device.identity
        if let boot = boots[identity] { return await boot.value }
        let boot = Task { @MainActor [weak self] () -> Result<Bool, SimulatorCommandError> in
            do {
                let start = try await backend.boot(device, with: toolchain)
                if start == .started {
                    // Written down before the wait, so a quit meanwhile stops it.
                    if let boot = await backend.bootIdentity(of: identity, with: toolchain), let self {
                        self.recordStart(identity, boot: boot)
                    }
                }
                try await backend.waitUntilReady(device, with: toolchain)
                return .success(start == .started)
            } catch let error as SimulatorCommandError {
                return .failure(error)
            } catch {
                return .failure(SimulatorCommandError(message: String(describing: error)))
            }
        }
        boots[identity] = boot
        transitions[identity] = .booting
        let result = await boot.value
        boots[identity] = nil
        transitions[identity] = nil
        await refreshDevices()
        return result
    }

    private func recordStart(_ identity: SimulatorDeviceIdentity, boot: SimulatorBootIdentity) {
        startedByYardlet[identity] = SimulatorBootRecordEntry(device: identity, boot: boot, bootedAt: clock.now)
        lastUse[identity] = clock.now
        adoptSavedAttachments(of: identity)
        saveRecord()
    }

    /// The tasks that attached the device in an earlier run, which count for its idle rules as any other.
    private func adoptSavedAttachments(of identity: SimulatorDeviceIdentity) {
        for task in attachmentStore.tasksAttaching(identity) where !attachmentsRead.contains(task) {
            attachmentsRead.insert(task)
            attachments[task] = identity
        }
    }

    /// Stops a device Yardlet started, when it still runs the boot Yardlet started, also while it is still starting;
    /// another boot is not Yardlet's and only leaves the record. `stillWanted` is asked again once the boot is read,
    /// as the device may have been taken up meanwhile.
    @discardableResult
    private func stop(_ identity: SimulatorDeviceIdentity,
                      stillWanted: @MainActor () -> Bool = { true }) async -> Bool {
        guard let entry = startedByYardlet[identity], !stopping.contains(identity),
              let backend = backends[identity.kind.platform],
              let toolchain = checks[identity.kind.platform]?.toolchain else { return false }
        stopping.insert(identity)
        defer { stopping.remove(identity) }
        let device = device(identity) ?? SimulatorDevice(identity: identity, name: identity.value, state: .on,
                                                         osName: "", osVersion: "")
        let running = await backend.bootIdentity(of: identity, with: toolchain)
        guard running.map(entry.boot.isSameBoot) ?? false else {
            forget(identity)
            saveRecord()
            return false
        }
        guard stillWanted(), startedByYardlet[identity] != nil else { return false }
        transitions[identity] = .shuttingDown
        do {
            try await backend.shutDown(device, with: toolchain)
        } catch {
            // Tried again after a full idle time, not at every check.
            transitions[identity] = nil
            lastUse[identity] = clock.now
            return false
        }
        transitions[identity] = nil
        forget(identity)
        saveRecord()
        await refreshDevices()
        return true
    }

    private func stopEveryStartedDevice() async {
        // At once: each stop waits on its own command.
        let stops = startedByYardlet.keys.map { identity in
            Task { @MainActor [weak self] in _ = await self?.stop(identity) }
        }
        for stop in stops { await stop.value }
    }

    /// At the switch's turning on: the devices an earlier Yardlet started and did not stop. Those that run another
    /// boot now are not Yardlet's; those in the same boot that no task attaches stop; the rest go on under the idle
    /// rules.
    private func recoverStartedDevices() async {
        let entries = record.load()
        guard !entries.isEmpty else { return }
        for entry in entries { startedByYardlet[entry.device] = entry }
        for entry in entries {
            let identity = entry.device
            guard let backend = backends[identity.kind.platform],
                  let toolchain = checks[identity.kind.platform]?.toolchain,
                  let running = await backend.bootIdentity(of: identity, with: toolchain),
                  entry.boot.isSameBoot(as: running) else {
                forget(identity)
                continue
            }
            adoptSavedAttachments(of: identity)
            lastUse[identity] = clock.now
            if !attachments.values.contains(identity) { await stop(identity) }
        }
        saveRecord()
        rescheduleIdleCheck()
    }

    private func forget(_ identity: SimulatorDeviceIdentity) {
        startedByYardlet[identity] = nil
        lastUse[identity] = nil
    }

    private func saveRecord() {
        record.save(startedByYardlet.values.sorted { $0.bootedAt < $1.bootedAt })
    }

    /// One wait, until the first device's idle time is up.
    private func rescheduleIdleCheck() {
        idleCheck?.cancel()
        idleCheck = nil
        guard isEnabled, let next = startedByYardlet.keys.compactMap(stopDeadline(for:)).min() else { return }
        let clock = clock
        idleCheck = Task { @MainActor [weak self] in
            do { try await clock.sleep(until: next) } catch { return }
            await self?.stopIdleDevices()
        }
    }
}

extension SimulatorBootIdentity {
    /// The same boot: the same process, started at the same time where both know it.
    func isSameBoot(as other: SimulatorBootIdentity) -> Bool {
        guard processID == other.processID, avdName == other.avdName else { return false }
        guard let start = processStartMicroseconds, let otherStart = other.processStartMicroseconds else { return true }
        return start == otherStart
    }
}

/// The order a device list shows: devices that are on first, then iOS simulators by runtime, newest first, then
/// Android; each platform keeps its own order within.
enum SimulatorDeviceOrder {
    static func sorted(_ devices: [SimulatorDevice]) -> [SimulatorDevice] {
        let indexed = Array(devices.enumerated())
        return indexed.sorted { left, right in
            let (a, b) = (left.element, right.element)
            let (aOn, bOn) = (a.state.isRunning, b.state.isRunning)
            if aOn != bOn { return aOn }
            if a.platform != b.platform { return a.platform == .iOS }
            if !aOn, a.platform == .iOS, a.osVersion != b.osVersion {
                return isNewer(a.osVersion, than: b.osVersion)
            }
            return left.offset < right.offset
        }.map(\.element)
    }

    static func isNewer(_ version: String, than other: String) -> Bool {
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        let otherParts = other.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(parts.count, otherParts.count) {
            let (a, b) = (index < parts.count ? parts[index] : 0, index < otherParts.count ? otherParts[index] : 0)
            if a != b { return a > b }
        }
        return false
    }
}
