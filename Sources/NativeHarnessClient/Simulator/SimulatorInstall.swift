import Foundation
import Observation

/// Something Yardlet installed for the simulators, written down so that turning Settings › General › Simulator off
/// can offer to remove it. Only what is written down is ever removed.
enum SimulatorInstalledItem: Codable, Hashable, Sendable {
    /// An iOS simulator runtime, by the identifier `simctl runtime list` gives it.
    case iOSRuntime(identifier: String, name: String, bytes: Int64?)
    /// An Android SDK package, unpacked at `path` (its SDK path, `emulator` or
    /// `system-images/android-36/google_apis_playstore/arm64-v8a`) under `sdkRoot`, at the revision Yardlet wrote in
    /// its `package.xml`.
    case androidPackage(sdkRoot: String, path: String, revision: String, name: String, bytes: Int64?)
    /// An AVD Yardlet made, in its AVD folder.
    case androidAVD(home: String, name: String)
    /// The SDK folder itself, when Yardlet made it: removed once nothing else is in it.
    case androidSDKFolder(path: String)

    /// What the person reads in the question that offers to remove it.
    var displayName: String {
        switch self {
        case let .iOSRuntime(_, name, _), let .androidPackage(_, _, _, name, _): name
        case let .androidAVD(_, name): L10n.format("Android virtual device “%@”", name)
        case let .androidSDKFolder(path): path
        }
    }

    var bytes: Int64? {
        switch self {
        case let .iOSRuntime(_, _, bytes), let .androidPackage(_, _, _, _, bytes): bytes
        case .androidAVD, .androidSDKFolder: nil
        }
    }

    var platform: SimulatorPlatform {
        if case .iOSRuntime = self { return .iOS }
        return .android
    }
}

/// Where what Yardlet installed is written down.
protocol SimulatorInstallRecordStore: Sendable {
    func load() -> [SimulatorInstalledItem]
    /// Writes the items; with none, leaves nothing behind.
    func save(_ items: [SimulatorInstalledItem])
}

/// The record as a small JSON file, removed when it holds nothing.
struct SimulatorInstallRecordFile: SimulatorInstallRecordStore {
    let url: URL

    private struct Contents: Codable {
        var installed: [SimulatorInstalledItem]
    }

    func load() -> [SimulatorInstalledItem] {
        guard let data = try? Data(contentsOf: url),
              let contents = try? JSONDecoder().decode(Contents.self, from: data) else { return [] }
        return contents.installed
    }

    func save(_ items: [SimulatorInstalledItem]) {
        guard !items.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Contents(installed: items)) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {}
    }
}

/// The record kept in memory: tests, and a model whose platform installs nothing.
final class InMemorySimulatorInstallRecord: SimulatorInstallRecordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SimulatorInstalledItem]

    init(_ items: [SimulatorInstalledItem] = []) { self.items = items }

    func load() -> [SimulatorInstalledItem] { lock.withLock { items } }
    func save(_ items: [SimulatorInstalledItem]) { lock.withLock { self.items = items } }
}

/// A license the person accepts before a download: its text, shown in full.
struct SimulatorLicense: Equatable, Sendable {
    var id: String
    var text: String
}

/// What Yardlet can do about a missing part, offered in the Simulator tab.
enum SimulatorInstallOffer: Equatable, Sendable {
    /// Opens a store page where the person gets it themselves (Xcode from the App Store).
    case openStore(URL)
    /// Downloads and installs `name`, `bytes` long when known, once the person accepts the licenses.
    case download(name: String, bytes: Int64?, licenses: [SimulatorLicense])
}

/// How far an install is: `fraction` when the download says, and what it is doing.
struct SimulatorInstallProgress: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        case downloading
        case installing
    }

    var stage: Stage
    var fraction: Double?
}

/// Gets what a platform is missing. Every method runs off the main thread.
protocol SimulatorInstaller: Sendable {
    var platform: SimulatorPlatform { get }
    /// What can be done about the availability a check found; nil when nothing can.
    func offer(for check: SimulatorPlatformCheck) async throws -> SimulatorInstallOffer?
    /// Installs what `offer` named, reporting progress, and returns what it installed. Cancelling the task stops it.
    func install(_ offer: SimulatorInstallOffer, for check: SimulatorPlatformCheck,
                 progress: @escaping @Sendable (SimulatorInstallProgress) -> Void) async throws -> [SimulatorInstalledItem]
    /// Whether the item is still there as Yardlet installed it, so removing it removes nothing else.
    func isStillInstalled(_ item: SimulatorInstalledItem) async -> Bool
    func remove(_ item: SimulatorInstalledItem) async throws
}

struct SimulatorInstallError: Error, Equatable, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// What each platform's Install button is doing, and what Yardlet installed.
///
/// The person starts it: Install reads what the download is and how large (`prepare`), the tab shows that with the
/// licenses to accept, and only Download (`confirm`) starts it. When it ends, the simulator center checks the platform
/// again. Each item installed is written down; turning the Simulator switch off offers to remove those still there
/// as Yardlet left them (`removableItems`, `remove`).
@MainActor @Observable
final class SimulatorInstalls {
    enum State: Equatable {
        case idle
        /// Reading what the download is.
        case preparing
        case offered(SimulatorInstallOffer)
        case installing(name: String, SimulatorInstallProgress)
        case failed(String)
    }

    private(set) var states: [SimulatorPlatform: State] = [:]

    /// The platform's install finished: the simulator center checks again and lists the devices.
    @ObservationIgnored var onInstalled: @MainActor (SimulatorPlatform) async -> Void = { _ in }

    @ObservationIgnored private let installers: [SimulatorPlatform: any SimulatorInstaller]
    @ObservationIgnored private let record: any SimulatorInstallRecordStore
    @ObservationIgnored private var tasks: [SimulatorPlatform: Task<Void, Never>] = [:]

    init(installers: [any SimulatorInstaller] = [], record: any SimulatorInstallRecordStore = InMemorySimulatorInstallRecord()) {
        self.installers = Dictionary(installers.map { ($0.platform, $0) }, uniquingKeysWith: { first, _ in first })
        self.record = record
    }

    func state(of platform: SimulatorPlatform) -> State { states[platform] ?? .idle }

    /// Whether the tab offers Install for what the check found.
    func offersInstall(for platform: SimulatorPlatform, check: SimulatorPlatformCheck) -> Bool {
        guard installers[platform] != nil else { return false }
        switch check.availability {
        case .xcodeMissing, .runtimeMissing, .sdkMissing: return true
        case .available, .xcodeNotSetUp, .xcodeNotSupportedYet: return false
        }
    }

    /// Install: reads what would be downloaded, for the person to accept, or opens the store page right away.
    func prepare(_ platform: SimulatorPlatform, check: SimulatorPlatformCheck, openURL: @escaping @MainActor (URL) -> Void) {
        guard let installer = installers[platform], tasks[platform] == nil else { return }
        set(.preparing, for: platform)
        tasks[platform] = Task { [weak self] in
            let offer: Result<SimulatorInstallOffer?, Error>
            do { offer = .success(try await installer.offer(for: check)) } catch { offer = .failure(error) }
            guard let self, !Task.isCancelled else { return }
            tasks[platform] = nil
            switch offer {
            case let .success(.openStore(url)?):
                set(.idle, for: platform)
                openURL(url)
            case let .success(offer?):
                set(.offered(offer), for: platform)
            case .success(nil):
                set(.idle, for: platform)
            case let .failure(error):
                set(.failed(error.localizedDescription), for: platform)
            }
        }
    }

    /// Download: the person accepted what the tab showed.
    func confirm(_ platform: SimulatorPlatform, check: SimulatorPlatformCheck) {
        guard let installer = installers[platform], tasks[platform] == nil,
              case let .offered(offer) = state(of: platform), case let .download(name, _, _) = offer else { return }
        set(.installing(name: name, SimulatorInstallProgress(stage: .downloading, fraction: nil)), for: platform)
        // The center lives as long as the app; the progress may hold it until the install ends.
        let report: @Sendable (SimulatorInstallProgress) -> Void = { progress in
            Task { @MainActor in
                guard case .installing = self.state(of: platform) else { return }
                self.set(.installing(name: name, progress), for: platform)
            }
        }
        tasks[platform] = Task { [weak self] in
            let result: Result<[SimulatorInstalledItem], Error>
            do {
                result = .success(try await installer.install(offer, for: check, progress: report))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            if case let .success(items) = result { note(items) }
            guard !Task.isCancelled else { return }
            tasks[platform] = nil
            switch result {
            case .success:
                set(.idle, for: platform)
                await onInstalled(platform)
            case let .failure(error):
                set(.failed(error.localizedDescription), for: platform)
            }
        }
    }

    /// Cancel: leaves the offer, or stops the download.
    func cancel(_ platform: SimulatorPlatform) {
        tasks.removeValue(forKey: platform)?.cancel()
        set(.idle, for: platform)
    }

    /// Stops every install, as the switch turns off.
    func cancelAll() {
        for platform in Array(tasks.keys) { cancel(platform) }
        states = [:]
    }

    /// What Yardlet installed that is still there as it left it.
    func removableItems() async -> [SimulatorInstalledItem] {
        var still: [SimulatorInstalledItem] = []
        var gone: [SimulatorInstalledItem] = []
        for item in record.load() {
            if let installer = installers[item.platform], await installer.isStillInstalled(item) {
                still.append(item)
            } else {
                gone.append(item)
            }
        }
        // What is gone, or changed by someone else, is no longer Yardlet's to remove.
        if !gone.isEmpty { forget(gone) }
        return still
    }

    /// Removes the items, the AVDs and packages before the folder that holds them, and forgets each one removed.
    /// Returns those that could not be removed, with why.
    @discardableResult
    func remove(_ items: [SimulatorInstalledItem]) async -> [(SimulatorInstalledItem, String)] {
        var failures: [(SimulatorInstalledItem, String)] = []
        let ordered = items.sorted { Self.removalOrder($0) < Self.removalOrder($1) }
        for item in ordered {
            guard let installer = installers[item.platform] else { continue }
            do {
                try await installer.remove(item)
                forget([item])
            } catch {
                failures.append((item, error.localizedDescription))
            }
        }
        return failures
    }

    private static func removalOrder(_ item: SimulatorInstalledItem) -> Int {
        switch item {
        case .androidAVD: 0
        case .iOSRuntime, .androidPackage: 1
        case .androidSDKFolder: 2
        }
    }

    private func note(_ items: [SimulatorInstalledItem]) {
        guard !items.isEmpty else { return }
        var all = record.load()
        for item in items where !all.contains(item) { all.append(item) }
        record.save(all)
    }

    private func forget(_ items: [SimulatorInstalledItem]) {
        record.save(record.load().filter { !items.contains($0) })
    }

    private func set(_ state: State, for platform: SimulatorPlatform) {
        if state == .idle {
            if states[platform] != nil { states[platform] = nil }
        } else if states[platform] != state {
            states[platform] = state
        }
    }
}

/// The progress a downloader prints, read from its output a line at a time: the last percentage in a line
/// ("Downloading... (42.5%)", "45% (3.4 GB of 7.6 GB)"), and whether it has moved on to installing.
enum SimulatorInstallOutput {
    static func progress(in line: String) -> SimulatorInstallProgress? {
        let lowered = line.lowercased()
        if lowered.contains("installing") || lowered.contains("importing") || lowered.contains("done downloading") {
            return SimulatorInstallProgress(stage: .installing, fraction: nil)
        }
        guard let fraction = lastPercentage(in: line) else { return nil }
        return SimulatorInstallProgress(stage: .downloading, fraction: fraction)
    }

    static func lastPercentage(in line: String) -> Double? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = percentage.matches(in: line, range: range).last,
              let number = Range(match.range(at: 1), in: line),
              let value = Double(line[number]), (0...100).contains(value) else { return nil }
        return value / 100
    }

    private static let percentage = try! NSRegularExpression(pattern: #"(\d{1,3}(?:\.\d+)?)\s?%"#)
}
