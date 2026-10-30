import Foundation
import YardletRemote

// The platform layer, in Foundation alone. Engine code names these types and functions, and each
// platform defines them under the same names in its own folder: Platform/macOS for the Mac app, and
// here for a build of the engine on its own (YARDLET_ENGINE_ONLY=1, docs/PLATFORM_PORTABILITY.md). What
// this folder defines is what a new platform's layer has to provide. Where the platform has nothing
// to offer, these do nothing and report nothing.

/// System notifications: none are shown.
final class LocalSystemNotificationCenter: SystemNotificationCenter {
    func authorization() async -> SystemNotificationAuthorization { .denied }
    func requestAuthorization() async -> Bool { false }
    func post(title: String, body: String, identifier: String) async {}
}

/// The process table: empty, so Task Resource Usage counts nothing.
struct LiveProcessTable: ProcessTableReading {
    func entries() -> [ProcessTableEntry] { [] }
    func usage(of processID: Int32) -> ProcessUsageReading? { nil }
}

/// The computer's load, from what Foundation reports: no load average or memory pressure.
enum MacConditionReader {
    static func notices(home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> [NewTaskHomeNotice] {
        var notices: [NewTaskHomeNotice] = []
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: home.path),
           let available = (attributes[.systemFreeSize] as? NSNumber)?.int64Value,
           available < NewTaskHomeNotice.lowDiskBytes {
            notices.append(.lowDisk(availableBytes: available))
        }
        return notices
    }

    static func memoryPressure() -> MacLoad.MemoryPressure { .normal }

    static func load() -> MacLoad {
        let info = ProcessInfo.processInfo
        return MacLoad(cores: info.activeProcessorCount, physicalMemory: info.physicalMemory, loadAverage: 0,
                       memoryPressure: .normal, thermalState: .nominal)
    }
}

extension HarnessAccountBroker {
    /// Where the Antigravity CLI keeps its credential on this platform is not known.
    static func antigravityCredentialState() -> AccountAuthState { .unknown }
}

extension ShellLaunchEnvironment {
    /// `$SHELL` as a login shell, else `/bin/sh`.
    static func userLoginShell(environment: [String: String] = ProcessInfo.processInfo.environment) -> ShellLaunchEnvironment {
        ShellLaunchEnvironment(executable: loginShellPath(environment: environment), arguments: ["-l"])
    }

    static func loginShellPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let path = environment["SHELL"], FileManager.default.isExecutableFile(atPath: path) { return path }
        return "/bin/sh"
    }
}

extension ClaudeConversationCatalog {
    /// Which Claude Code processes run cannot be told here, so none is taken for running.
    static func runningSessionIDs(configDirectory: URL, excludingProcessesOf owner: Int32 = 0) -> Set<String> { [] }
}

/// The phone remote is not offered.
@MainActor
final class RemoteControlService {
    private(set) var isEnabled = false
    private(set) var devices: [RemoteDevice] = []
}

/// No helper keeps the computer awake.
@MainActor
final class LidSleepHelper {}

/// No memory pressure warnings here; the memory saver keeps its timed looks.
enum MemoryPressureWatch {
    static func start(_ handler: @escaping @MainActor () -> Void) -> AnyObject? { nil }
}

#if DEBUG
/// The performance bench's per-event timings (macOS's `EventCostLog`): nothing is recorded here.
@MainActor
enum EventCostLog {
    enum Kind: String, CaseIterable {
        case codexState, transcriptPublication, agentRunState, agentRunEvent
    }

    struct Start {}

    static var isEnabled = false

    static func start() -> Start? { nil }

    static func record(_ kind: Kind, since start: Start?) {}
}
#endif
