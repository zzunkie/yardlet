import Foundation
import Observation

/// What Yardlet remembers about one harness's install between launches.
struct CLIUpdateRecord: Codable, Equatable, Sendable {
    /// The installed version that last passed Yardlet's check, and where its runtime was.
    var verifiedVersion: String?
    var verifiedExecutable: String?
    /// A version that failed the check; it is not tried again.
    var failedVersion: String?
    /// The version before the last update, kept to go back to.
    var previous: CLIPreviousVersion?
    var lastCheck: Date?
}

struct CLIPreviousVersion: Codable, Equatable, Sendable {
    var version: String
    var executable: String
    /// A copy in Yardlet's own folder, rather than a version the installer kept.
    var isCopy: Bool
}

/// A notice for the main window: a new version failed Yardlet's check.
struct CLIUpdateNotice: Equatable, Sendable {
    let harness: HarnessKind
    let failedVersion: String
    /// The earlier version Yardlet went back to; nil when there was none.
    let restoredVersion: String?

    var message: String {
        if let restoredVersion {
            return L10n.format("%1$@ %2$@ did not pass Yardlet's check, so Yardlet went back to %3$@.",
                               harness.displayName, failedVersion, restoredVersion)
        }
        return L10n.format("%1$@ %2$@ did not pass Yardlet's check, and no earlier version is available to go back to.",
                           harness.displayName, failedVersion)
    }
}

/// Checks each installed harness CLI for updates at launch and every six hours, and, when CLI
/// automatic updates are on, updates it with its install method's own updater while none of its
/// tasks is running. Before an update the current version must pass Yardlet's check (no model
/// turn); after it the new one must too, or Yardlet goes back to the version before (product
/// document 13.22). Turning automatic updates off drops what Yardlet kept for going back.
@MainActor
@Observable
final class CLIUpdateCenter {
    enum Phase: Equatable, Sendable {
        case idle
        case checking
        case waitingForTasks
        case verifying
        case updating
    }

    enum Outcome: Equatable, Sendable {
        case updated(from: String, to: String)
        case failedWithoutPrevious(String)
        /// The current version failed the check before an update, so the update did not run.
        case couldNotVerifyCurrent(String)
        case updateFailed(String)
    }

    struct Row: Identifiable, Equatable {
        let harness: HarnessKind
        var method: CLIInstallMethod
        var plan: CLIUpdatePlan
        var installed: String?
        var latest: CLILatest?
        var phase: Phase = .idle
        var outcome: Outcome?
        var decision: CLIUpdateDecision?

        var id: HarnessKind { harness }
    }

    struct Dependencies {
        /// The selected runtime of each installed harness.
        var runtimes: @MainActor () -> [HarnessKind: URL]
        /// Harnesses with a running task.
        var busyHarnesses: @MainActor () -> Set<HarnessKind>
        var runner: any CLICommandRunning
        var verifier: any CLIVerifying
        var overrides: CLIRuntimeOverrides
        var defaults: UserDefaults
        /// Where Yardlet keeps copies of earlier versions (`~/.yardlet/cli-previous`).
        var previousVersionsDirectory: URL
        var environment: [String: String] = ProcessInfo.processInfo.environment
        var now: @MainActor () -> Date = { Date() }
        var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds), clock: .continuous)
        }
        /// After Yardlet's runtime for a harness changed (updated, or back to an earlier version).
        var runtimeChanged: @MainActor (HarnessKind, URL) async -> Void = { _, _ in }
    }

    static let enabledKey = "cliUpdate.autoUpdate"
    static let recordsKey = "cliUpdate.records"

    private(set) var rows: [Row] = []
    private(set) var notice: CLIUpdateNotice?
    private(set) var isAutoUpdateEnabled: Bool
    private(set) var lastCheckAll: Date?
    @ObservationIgnored private var records: [String: CLIUpdateRecord]
    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private var waiting: Set<HarnessKind> = []
    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var startedAt: Date?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        isAutoUpdateEnabled = dependencies.defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        records = dependencies.defaults.data(forKey: Self.recordsKey)
            .flatMap { try? JSONDecoder().decode([String: CLIUpdateRecord].self, from: $0) } ?? [:]
        forgetRetiredHarnesses()
        refreshRows()
    }

    /// What Yardlet kept for a harness removed from the catalog goes with it: its record, the
    /// earlier version held in place of its install, and Yardlet's copies of that version. The
    /// copies are a backup, so they go to the Trash rather than away for good.
    private func forgetRetiredHarnesses() {
        for harness in HarnessCatalog.retired {
            if dependencies.overrides.entry(for: harness) != nil { dependencies.overrides.set(nil, for: harness) }
            let copies = dependencies.previousVersionsDirectory.appending(path: harness.rawValue, directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: copies.path(percentEncoded: false)) {
                try? Trash.move(copies)
            }
        }
        let kept = records.filter { !HarnessCatalog.retired.contains(HarnessKind(rawValue: $0.key)) }
        if kept.count != records.count {
            records = kept
            saveRecords()
        }
    }

    // MARK: - Public

    func setAutoUpdate(_ enabled: Bool) {
        guard enabled != isAutoUpdateEnabled else { return }
        isAutoUpdateEnabled = enabled
        dependencies.defaults.set(enabled, forKey: Self.enabledKey)
        guard !enabled else { return }
        // Off leaves nothing of Yardlet's: no earlier version in place of an install, no copies.
        let held = HarnessCatalog.builtIns.map(\.id).filter { dependencies.overrides.entry(for: $0) != nil }
        dependencies.overrides.removeAll()
        try? FileManager.default.removeItem(at: dependencies.previousVersionsDirectory)
        records = [:]
        saveRecords()
        waiting = []
        notice = nil
        for index in rows.indices {
            rows[index].outcome = nil
            if rows[index].phase == .waitingForTasks { rows[index].phase = .idle }
            rows[index].decision = .skip(.autoUpdateOff)
        }
        let runtimes = dependencies.runtimes()
        Task { for harness in held { if let url = runtimes[harness] { await dependencies.runtimeChanged(harness, url) } } }
    }

    /// Starts the checks: one now, then every six hours, with a look every ten minutes at updates
    /// that wait for tasks to finish.
    func start(delaysFirstCheck: Bool = true) {
        guard loop == nil else { return }
        startedAt = delaysFirstCheck ? dependencies.now() : nil
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let next = CLIUpdateSchedule.next(lastCheckAll: self.lastCheckAll, hasWaiting: !self.waiting.isEmpty,
                                                  now: self.dependencies.now(), launchedAt: self.startedAt)
                let delay = next.at.timeIntervalSince(self.dependencies.now())
                if delay > 0 {
                    do { try await self.dependencies.sleep(delay) } catch { return }
                }
                guard !Task.isCancelled else { return }
                await self.run(next.pass)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    func run(_ pass: CLIUpdateSchedule.Pass) async {
        switch pass {
        case .checkAll: await checkAll()
        case .retryWaiting: await retryWaiting()
        }
    }

    func checkAll() async {
        lastCheckAll = dependencies.now()
        refreshRows()
        for harness in rows.map(\.harness) {
            await enqueue { await self.evaluate(harness, refreshesLatest: true) }
        }
    }

    /// The Settings button: checks one harness now and, when automatic updates are on, updates it.
    func check(_ harness: HarnessKind) async {
        refreshRows()
        await enqueue { await self.evaluate(harness, refreshesLatest: true) }
    }

    func retryWaiting() async {
        for harness in waiting.sorted(by: { $0.rawValue < $1.rawValue }) {
            await enqueue { await self.evaluate(harness, refreshesLatest: false) }
        }
    }

    func dismissNotice() { notice = nil }

    func row(for harness: HarnessKind) -> Row? { rows.first { $0.harness == harness } }

    func record(for harness: HarnessKind) -> CLIUpdateRecord? { records[harness.rawValue] }

    /// The earlier version Yardlet runs in place of this harness's install, if any.
    func heldVersion(for harness: HarnessKind) -> CLIRuntimeOverrides.Entry? {
        dependencies.overrides.entry(for: harness)
    }

    var isBusy: Bool { rows.contains { $0.phase != .idle && $0.phase != .waitingForTasks } }

    // MARK: - One harness

    private func evaluate(_ harness: HarnessKind, refreshesLatest: Bool) async {
        guard let launcher = dependencies.runtimes()[harness] else {
            rows.removeAll { $0.harness == harness }
            waiting.remove(harness)
            return
        }
        let method = CLIInstallDetector.detect(harness: harness, executable: launcher)
        let plan = CLIUpdatePlan(harness: harness, launcher: launcher, method: method)
        update(harness) {
            $0.method = method
            $0.plan = plan
            $0.phase = .checking
        }
        defer { update(harness) { if $0.phase != .waitingForTasks { $0.phase = .idle } } }
        waiting.remove(harness)

        let installed = await version(of: plan)
        var latest = row(for: harness)?.latest
        if refreshesLatest || latest == nil {
            latest = await self.latest(plan, installed: installed)
            modifyRecord(harness) { $0.lastCheck = dependencies.now() }
        }
        update(harness) {
            $0.installed = installed
            $0.latest = latest
        }

        let isBusy = dependencies.busyHarnesses().contains(harness)
        if isAutoUpdateEnabled, let installed, dependencies.verifier.canVerify(harness) {
            let record = records[harness.rawValue] ?? CLIUpdateRecord()
            if record.verifiedVersion == nil {
                // The version found when Yardlet first looks is the one it works with now.
                modifyRecord(harness) {
                    $0.verifiedVersion = installed
                    $0.verifiedExecutable = Self.resolvedPath(launcher)
                }
            } else if installed != record.verifiedVersion, installed != record.failedVersion {
                // Updated outside Yardlet (by hand, or by the CLI itself): check the new version.
                guard !isBusy else { return wait(harness) }
                await verifyOutsideUpdate(plan, installed: installed, record: record)
            }
        }

        let decision = CLIUpdateDecision.decide(
            autoUpdate: isAutoUpdateEnabled, plan: plan, canVerify: dependencies.verifier.canVerify(harness),
            latest: latest, failedVersion: records[harness.rawValue]?.failedVersion, isBusy: isBusy)
        update(harness) { $0.decision = decision }
        switch decision {
        case .update: await runUpdate(plan, installed: installed)
        case .waitForIdle: wait(harness)
        case .skip: break
        }
    }

    private func wait(_ harness: HarnessKind) {
        waiting.insert(harness)
        update(harness) { $0.phase = .waitingForTasks }
    }

    private func verifyOutsideUpdate(_ plan: CLIUpdatePlan, installed: String, record: CLIUpdateRecord) async {
        let harness = plan.harness
        update(harness) { $0.phase = .verifying }
        if await dependencies.verifier.verify(harness, executable: plan.launcher) == .passed {
            accept(plan, version: installed, previous: record.previous)
            return
        }
        // The version that worked, where its installer kept it, or else the copy Yardlet made
        // before its last update (a CLI such as `agy` updates itself between Yardlet's checks).
        var candidates: [CLIPreviousVersion] = []
        if let verifiedVersion = record.verifiedVersion, let earlier = record.verifiedExecutable {
            candidates.append(CLIPreviousVersion(version: verifiedVersion, executable: earlier, isCopy: false))
        }
        if let previous = record.previous { candidates.append(previous) }
        let current = Self.resolvedPath(plan.launcher)
        for candidate in candidates
        where candidate.executable != current && FileManager.default.isExecutableFile(atPath: candidate.executable) {
            if await dependencies.verifier.verify(harness, executable: URL(filePath: candidate.executable)) == .passed {
                await goBack(plan, failed: installed, to: candidate)
                return
            }
        }
        await goBack(plan, failed: installed, to: nil)
    }

    private func runUpdate(_ plan: CLIUpdatePlan, installed: String?) async {
        let harness = plan.harness
        guard let updateCommand = plan.updateCommand else { return }
        let held = dependencies.overrides.entry(for: harness)
        let running = held.map { URL(filePath: $0.target) } ?? plan.launcher

        // The version Yardlet runs now must pass first, so a failure afterwards is the new version's.
        update(harness) { $0.phase = .verifying }
        if case let .failed(reason) = await dependencies.verifier.verify(harness, executable: running) {
            update(harness) { $0.outcome = .couldNotVerifyCurrent(reason) }
            return
        }

        update(harness) { $0.phase = .updating }
        let previous: CLIPreviousVersion?
        if let held {
            // Already on an earlier version: that one stays the one to go back to.
            previous = records[harness.rawValue]?.previous
                ?? CLIPreviousVersion(version: held.version, executable: held.target, isCopy: false)
        } else if let installed {
            switch plan.retention {
            case .installerKeepsEarlierVersions:
                previous = CLIPreviousVersion(version: installed, executable: Self.resolvedPath(plan.launcher), isCopy: false)
            case let .yardletCopy(root, executable):
                previous = await keepCopy(of: root, executable: executable, version: installed, harness: harness)
                guard let previous else {
                    update(harness) { $0.outcome = .updateFailed(L10n.string("Yardlet could not keep the current version")) }
                    return
                }
                // Kept whatever the updater does: the version that works now is the one to go back to.
                modifyRecord(harness) { $0.previous = previous }
            case .none:
                return
            }
        } else {
            previous = nil
        }

        let result = await dependencies.runner.run(updateCommand)
        guard result.succeeded else {
            update(harness) { $0.outcome = .updateFailed(result.failureSummary) }
            return
        }
        let after = await version(of: plan)
        update(harness) { $0.installed = after }
        guard let after, after != installed else {
            // The updater found nothing newer.
            update(harness) { $0.latest = .upToDate }
            return
        }

        update(harness) { $0.phase = .verifying }
        if await dependencies.verifier.verify(harness, executable: plan.launcher) == .passed {
            accept(plan, version: after, previous: previous)
            update(harness) {
                if let installed { $0.outcome = .updated(from: installed, to: after) }
                $0.latest = .upToDate
            }
            await dependencies.runtimeChanged(harness, plan.launcher)
        } else {
            await goBack(plan, failed: after,
                         to: previous.flatMap { FileManager.default.isExecutableFile(atPath: $0.executable) ? $0 : nil })
        }
    }

    /// The new version works: Yardlet runs the install again and keeps only `previous`.
    private func accept(_ plan: CLIUpdatePlan, version: String, previous: CLIPreviousVersion?) {
        let harness = plan.harness
        let wasHeld = dependencies.overrides.entry(for: harness) != nil
        dependencies.overrides.set(nil, for: harness)
        modifyRecord(harness) {
            $0.verifiedVersion = version
            $0.verifiedExecutable = Self.resolvedPath(plan.launcher)
            $0.failedVersion = nil
            $0.previous = previous
        }
        if isAutoUpdateEnabled {
            pruneCopies(of: harness, keeping: previous)
        } else {
            try? FileManager.default.removeItem(at: dependencies.previousVersionsDirectory)
            records = [:]
            saveRecords()
        }
        update(harness) { $0.outcome = nil }
        if wasHeld { Task { await dependencies.runtimeChanged(harness, plan.launcher) } }
    }

    /// The new version failed: Yardlet runs `previous` in its place, or says none is left.
    private func goBack(_ plan: CLIUpdatePlan, failed: String, to previous: CLIPreviousVersion?) async {
        let harness = plan.harness
        // Turned off while the update ran: the install stays as its updater left it, nothing held.
        guard isAutoUpdateEnabled else {
            dependencies.overrides.set(nil, for: harness)
            try? FileManager.default.removeItem(at: dependencies.previousVersionsDirectory)
            return
        }
        modifyRecord(harness) {
            $0.failedVersion = failed
            if let previous { $0.previous = previous }
        }
        if let previous {
            dependencies.overrides.set(CLIRuntimeOverrides.Entry(
                launcher: plan.launcher.standardizedFileURL.path(percentEncoded: false),
                installed: Self.resolvedPath(plan.launcher), target: previous.executable,
                failedVersion: failed, version: previous.version), for: harness)
            update(harness) { $0.outcome = nil }
        } else {
            dependencies.overrides.set(nil, for: harness)
            update(harness) { $0.outcome = .failedWithoutPrevious(failed) }
        }
        notice = CLIUpdateNotice(harness: harness, failedVersion: failed, restoredVersion: previous?.version)
        await dependencies.runtimeChanged(harness, plan.launcher)
    }

    // MARK: - Commands

    private func version(of plan: CLIUpdatePlan) async -> String? {
        let result = await dependencies.runner.run(plan.versionCommand)
        return result.succeeded ? CLIVersion.parse(result.stdout + "\n" + result.stderr) : nil
    }

    private func latest(_ plan: CLIUpdatePlan, installed: String?) async -> CLILatest {
        let commands = plan.checkCommands(environment: dependencies.environment)
        guard let last = commands.last else { return .unknown }
        // Homebrew's own metadata refresh may fail (offline); the check reads what it has.
        for command in commands.dropLast() { _ = await dependencies.runner.run(command) }
        return plan.latest(from: await dependencies.runner.run(last), installed: installed)
    }

    /// A copy of `root` under `<previous versions>/<harness>/<version>/`, an APFS clone where it can be.
    private func keepCopy(of root: URL, executable: URL, version: String, harness: HarnessKind) async -> CLIPreviousVersion? {
        let folder = dependencies.previousVersionsDirectory
            .appending(path: harness.rawValue, directoryHint: .isDirectory)
            .appending(path: version, directoryHint: .isDirectory)
        let copy = folder.appending(path: root.lastPathComponent)
        let target = CLIInstallDetector.executable(executable, inside: root).pathComponents
            .dropFirst(root.pathComponents.count)
            .reduce(copy) { $0.appending(path: $1) }
        let copied = await Task.detached(priority: .utility) { () -> Bool in
            let manager = FileManager.default
            if manager.isExecutableFile(atPath: target.path(percentEncoded: false)) { return true }
            try? manager.removeItem(at: folder)
            do {
                try manager.createDirectory(at: folder, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                try manager.copyItem(at: root, to: copy)
            } catch {
                try? manager.removeItem(at: folder)
                return false
            }
            return manager.isExecutableFile(atPath: target.path(percentEncoded: false))
        }.value
        return copied ? CLIPreviousVersion(version: version, executable: target.path(percentEncoded: false), isCopy: true) : nil
    }

    private func pruneCopies(of harness: HarnessKind, keeping previous: CLIPreviousVersion?) {
        let folder = dependencies.previousVersionsDirectory.appending(path: harness.rawValue, directoryHint: .isDirectory)
        let kept = previous.flatMap { $0.isCopy ? $0.version : nil }
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        where entry != kept {
            try? FileManager.default.removeItem(at: folder.appending(path: entry))
        }
    }

    // MARK: - State

    private func refreshRows() {
        let runtimes = dependencies.runtimes()
        rows = HarnessCatalog.builtIns.compactMap { descriptor -> Row? in
            guard let launcher = runtimes[descriptor.id] else { return nil }
            if var existing = row(for: descriptor.id) {
                if existing.plan.launcher != launcher {
                    let method = CLIInstallDetector.detect(harness: descriptor.id, executable: launcher)
                    existing.method = method
                    existing.plan = CLIUpdatePlan(harness: descriptor.id, launcher: launcher, method: method)
                    existing.installed = nil
                    existing.latest = nil
                }
                return existing
            }
            let method = CLIInstallDetector.detect(harness: descriptor.id, executable: launcher)
            return Row(harness: descriptor.id, method: method,
                       plan: CLIUpdatePlan(harness: descriptor.id, launcher: launcher, method: method))
        }
    }

    private func update(_ harness: HarnessKind, _ change: (inout Row) -> Void) {
        guard let index = rows.firstIndex(where: { $0.harness == harness }) else { return }
        change(&rows[index])
    }

    private func modifyRecord(_ harness: HarnessKind, _ change: (inout CLIUpdateRecord) -> Void) {
        var record = records[harness.rawValue] ?? CLIUpdateRecord()
        change(&record)
        records[harness.rawValue] = record
        saveRecords()
    }

    private func saveRecords() {
        if records.isEmpty {
            dependencies.defaults.removeObject(forKey: Self.recordsKey)
        } else if let data = try? JSONEncoder().encode(records) {
            dependencies.defaults.set(data, forKey: Self.recordsKey)
        }
    }

    /// One harness at a time, in the order asked: two Homebrew commands at once would wait on its lock.
    private func enqueue(_ work: @escaping @MainActor () async -> Void) async {
        let previous = queue
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        queue = task
        await task.value
    }

    private static func resolvedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
    }
}
