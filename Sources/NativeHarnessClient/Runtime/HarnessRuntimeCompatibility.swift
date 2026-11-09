import Foundation

/// How a harness runtime version is matched against the list Yardlet actually verified.
enum HarnessRuntimeVersionRule: Equatable, Sendable {
    case exact(String)
    case prefix(String)

    func accepts(_ version: String) -> Bool {
        switch self {
        case let .exact(expected):
            version == expected
        case let .prefix(prefix):
            version.hasPrefix(prefix)
        }
    }
}

/// `major.minor.patch` of a harness runtime version. Pre-release tags are kept for display only;
/// the floor compares the release core so an alpha of the floor's minor family still qualifies.
struct HarnessRuntimeVersion: Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: String?

    init?(_ text: String) {
        let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              let major = Int(core[0]),
              let minor = Int(core[1]),
              let patch = Int(core[2])
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = parts.count == 2 ? String(parts[1]) : nil
    }

    func isAtLeast(_ other: HarnessRuntimeVersion) -> Bool {
        (major, minor, patch) >= (other.major, other.minor, other.patch)
    }
}

/// A harness runtime policy: the lowest release core Yardlet supports plus the versions whose
/// live behaviour was verified against this source. Pinning exact versions blocks every provider
/// update, so each harness keeps a floor and reports verification separately.
protocol HarnessRuntimeCompatibility: Sendable {
    /// Lowest release core whose contract this source supports.
    var minimum: String { get }
    /// Versions whose live behaviour was verified against this source.
    var verified: [HarnessRuntimeVersionRule] { get }
    /// Extracts the runtime version from that harness' `--version` output, or `nil` when the
    /// output carries no marker identifying the expected runtime.
    func version(from output: String) -> String?
}

extension HarnessRuntimeCompatibility {
    func accepts(versionOutput: String) -> Bool {
        guard let version = version(from: versionOutput),
              let parsed = HarnessRuntimeVersion(version),
              let floor = HarnessRuntimeVersion(minimum)
        else { return false }
        return parsed.isAtLeast(floor)
    }

    func isVerified(versionOutput: String) -> Bool {
        guard let version = version(from: versionOutput) else { return false }
        return verified.contains { $0.accepts(version) }
    }

    func readVersionOutput(executableURL: URL) throws -> String {
        try HarnessRuntimeVersionProbe.output(executableURL: executableURL)
    }
}

/// Runs `<runtime> --version` and returns its trimmed output. No home, account, or thread is
/// touched, and no model turn is started.
enum HarnessRuntimeVersionProbe {
    /// The CLI runs with the environment every other run of the runtime has: a CLI installed as a Node
    /// script (npm's `claude` and `codex`) finds `node` beside it or on the login shell's `PATH`, not in
    /// launchd's. `inheritsAppEnvironment` gives it the app's own instead, for an adapter whose
    /// version check has always run that way.
    static func output(executableURL: URL, inheritsAppEnvironment: Bool = false) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--version"]
        if !inheritsAppEnvironment {
            process.environment = RuntimeProcessEnvironment.values(executableURL: executableURL)
        }
        process.standardOutput = pipe
        process.standardError = pipe
        let exit = try ProcessExit(running: process)
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard exit.waitBlockingThread(timeout: .seconds(10)) else {
            NativeProcessTree.terminate(process: process)
            throw HarnessAdapterError.processExited(code: -1, message: output)
        }
        guard process.terminationStatus == 0 else {
            throw HarnessAdapterError.processExited(
                code: process.terminationStatus,
                message: output
            )
        }
        return output
    }
}
