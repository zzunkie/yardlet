import Foundation

/// One command a check or an update runs.
struct CLICommand: Equatable, Sendable {
    var executable: URL
    var arguments: [String]
    var environment: [String: String] = [:]
    var timeout: Duration
}

struct CLICommandResult: Equatable, Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String

    var succeeded: Bool { exitCode == 0 }

    /// The last line worth showing when a command failed.
    var failureSummary: String {
        let text = [stderr, stdout].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
        let line = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return line.isEmpty ? L10n.format("exit code %lld", Int64(exitCode)) : String(line.prefix(160))
    }
}

/// Runs the commands of a check or an update. The app runs real processes; tests pass a fake.
protocol CLICommandRunning: Sendable {
    func run(_ command: CLICommand) async -> CLICommandResult
}

/// The newest version a check found.
enum CLILatest: Equatable, Sendable {
    /// The CLI has no check that installs nothing; its own updater looks when it runs.
    case unknown
    case upToDate
    case available(String)
    case failed(String)
}

/// The version text of a harness CLI.
enum CLIVersion {
    /// The first version-shaped token: `codex-cli 0.163.0`, `2.1.291 (Claude Code)`,
    /// `grok 1.0.30 (04b7ffed98c6) [stable]`, `2026.08.11-e8db854`.
    static func parse(_ output: String) -> String? {
        guard let range = output.range(of: #"[0-9]+(\.[0-9]+)+(-[0-9A-Za-z][0-9A-Za-z.\-]*)?"#,
                                       options: .regularExpression) else { return nil }
        return String(output[range])
    }

    /// Release cores compared part by part; a release is newer than a prerelease of the same core.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func split(_ text: String) -> ([Int], String?) {
            let parts = text.split(separator: "-", maxSplits: 1).map(String.init)
            return (parts[0].split(separator: ".").map { Int($0) ?? 0 }, parts.count > 1 ? parts[1] : nil)
        }
        let (a, aTag) = split(candidate)
        let (b, bTag) = split(current)
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        switch (aTag, bTag) {
        case (nil, .some): return true
        case let (.some(left), .some(right)): return left.compare(right, options: .numeric) == .orderedDescending
        default: return false
        }
    }
}

/// What Yardlet runs for one harness's install, and how it reads the answers.
struct CLIUpdatePlan: Equatable, Sendable {
    let harness: HarnessKind
    /// The selected runtime, as the person chose or Yardlet found it (often a link).
    let launcher: URL
    let method: CLIInstallMethod
    let retention: CLIPreviousVersionRetention

    static let versionTimeout: Duration = .seconds(20)
    static let checkTimeout: Duration = .seconds(120)
    static let updateTimeout: Duration = .seconds(900)

    init(harness: HarnessKind, launcher: URL, method: CLIInstallMethod) {
        self.harness = harness
        self.launcher = launcher
        self.method = method
        let resolved = launcher.standardizedFileURL.resolvingSymlinksInPath()
        switch method {
        case .homebrewFormula:
            // `HOMEBREW_NO_INSTALL_CLEANUP` on the upgrade keeps the earlier keg in the Cellar.
            retention = .installerKeepsEarlierVersions
        case let .homebrewCask(_, _, directory), let .npmGlobal(_, _, directory):
            // Homebrew removes a cask's earlier version and npm replaces the package in place.
            retention = .yardletCopy(root: directory, executable: CLIInstallDetector.executable(resolved, inside: directory))
        case let .selfUpdater(updater):
            retention = updater.retention
        case .appBundled, .manual:
            retention = .none
        }
    }

    var versionCommand: CLICommand {
        CLICommand(executable: launcher, arguments: ["--version"], timeout: Self.versionTimeout)
    }

    /// The commands that look for a newer version without installing one; the last one's output
    /// is what `latest(from:installed:)` reads. Homebrew first refreshes its own metadata the way it
    /// does before an install (`brew update --auto-update`), unless the person turned that off.
    func checkCommands(environment: [String: String] = ProcessInfo.processInfo.environment) -> [CLICommand] {
        func brewCommands(_ brew: URL, _ kind: String, _ name: String) -> [CLICommand] {
            let refresh = environment["HOMEBREW_NO_AUTO_UPDATE"].map { !$0.isEmpty } == true ? [] : [
                CLICommand(executable: brew, arguments: ["update", "--auto-update", "--quiet"],
                           environment: Self.homebrewEnvironment, timeout: Self.checkTimeout)
            ]
            return refresh + [CLICommand(executable: brew, arguments: ["outdated", "--json=v2", kind, name],
                                         environment: Self.homebrewEnvironment, timeout: Self.checkTimeout)]
        }
        switch method {
        case let .homebrewFormula(name, brew): return brewCommands(brew, "--formula", name)
        case let .homebrewCask(token, brew, _): return brewCommands(brew, "--cask", token)
        case let .npmGlobal(package, npm, _):
            return [CLICommand(executable: npm, arguments: ["view", package, "version", "--json"], timeout: Self.checkTimeout)]
        case let .selfUpdater(updater):
            return updater.checkArguments.map { [CLICommand(executable: launcher, arguments: $0, timeout: Self.checkTimeout)] } ?? []
        case .appBundled, .manual:
            return []
        }
    }

    /// The install method's own update. Nil where the person or a desktop app updates it.
    var updateCommand: CLICommand? {
        switch method {
        case let .homebrewFormula(name, brew):
            return CLICommand(executable: brew, arguments: ["upgrade", "--formula", name],
                environment: Self.homebrewEnvironment.merging(["HOMEBREW_NO_INSTALL_CLEANUP": "1"]) { _, new in new },
                timeout: Self.updateTimeout)
        case let .homebrewCask(token, brew, _):
            return CLICommand(executable: brew, arguments: ["upgrade", "--cask", token],
                environment: Self.homebrewEnvironment, timeout: Self.updateTimeout)
        case let .npmGlobal(package, npm, _):
            return CLICommand(executable: npm, arguments: ["install", "--global", "\(package)@latest"],
                timeout: Self.updateTimeout)
        case let .selfUpdater(updater):
            return CLICommand(executable: launcher, arguments: updater.updateArguments, timeout: Self.updateTimeout)
        case .appBundled, .manual:
            return nil
        }
    }

    private static let homebrewEnvironment = ["HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_EMOJI": "1"]

    /// Reads the check's answer. A Homebrew or npm answer names the newest version; grok's JSON
    /// says whether one is available.
    func latest(from result: CLICommandResult, installed: String?) -> CLILatest {
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        switch method {
        case .homebrewFormula, .homebrewCask:
            // `brew outdated` given a name exits 1 when that name is outdated, so its JSON is read
            // whatever the exit status; an error writes none.
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(output.utf8)),
                  value["formulae"] != nil || value["casks"] != nil else {
                return .failed(result.succeeded ? L10n.string("Homebrew's answer could not be read") : result.failureSummary)
            }
            let rows = (value["formulae"]?.arrayValue ?? []) + (value["casks"]?.arrayValue ?? [])
            guard let row = rows.first else { return .upToDate }
            guard let current = row["current_version"]?.stringValue, !current.isEmpty else { return .upToDate }
            return .available(current)
        case .npmGlobal:
            guard result.succeeded else { return .failed(result.failureSummary) }
            let text = (try? JSONDecoder().decode(String.self, from: Data(output.utf8))) ?? output
            guard let newest = CLIVersion.parse(text) else { return .failed(L10n.string("npm's answer could not be read")) }
            guard let installed else { return .available(newest) }
            return CLIVersion.isNewer(newest, than: installed) ? .available(newest) : .upToDate
        case .selfUpdater:
            guard result.succeeded else { return .failed(result.failureSummary) }
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(output.utf8)) else { return .unknown }
            if let error = value["error"]?.stringValue, !error.isEmpty { return .failed(error) }
            guard let newest = value["latestVersion"]?.stringValue else { return .unknown }
            if value["updateAvailable"]?.boolValue == false { return .upToDate }
            if let installed, !CLIVersion.isNewer(newest, than: installed) { return .upToDate }
            return .available(newest)
        case .appBundled, .manual:
            return result.succeeded ? .unknown : .failed(result.failureSummary)
        }
    }
}

/// Why an update does not run now.
enum CLIUpdateSkipReason: Equatable, Sendable {
    case autoUpdateOff
    /// A desktop app or the person updates it.
    case notUpdatable
    /// Yardlet has no check of this harness that makes no model turn.
    case cannotVerify
    /// An update could not be undone.
    case cannotKeepPrevious
    case upToDate
    /// The newest version is the one that already failed Yardlet's check.
    case failedBefore
    case checkFailed
}

enum CLIUpdateDecision: Equatable, Sendable {
    case update
    /// A task of the harness is running; the update waits until none is.
    case waitForIdle
    case skip(CLIUpdateSkipReason)

    /// Whether to update a harness now. A running task always blocks it, and only an install whose
    /// earlier version stays available, of a harness Yardlet can check without a model turn, is
    /// updated. An install whose CLI looks for the newest version itself is updated on schedule.
    static func decide(
        autoUpdate: Bool,
        plan: CLIUpdatePlan,
        canVerify: Bool,
        latest: CLILatest?,
        failedVersion: String?,
        isBusy: Bool
    ) -> CLIUpdateDecision {
        guard autoUpdate else { return .skip(.autoUpdateOff) }
        guard plan.method.canUpdate, plan.updateCommand != nil else { return .skip(.notUpdatable) }
        guard canVerify else { return .skip(.cannotVerify) }
        guard plan.retention != .none else { return .skip(.cannotKeepPrevious) }
        switch latest {
        case .upToDate?: return .skip(.upToDate)
        case .failed?: return .skip(.checkFailed)
        case let .available(version)? where version == failedVersion: return .skip(.failedBefore)
        case .available?, .unknown?, nil: break
        }
        return isBusy ? .waitForIdle : .update
    }
}

/// When the next pass runs: a check of every harness a minute after launch (after the tasks a
/// restart continues have started) and every six hours, and, while an update waits for a harness's
/// tasks to finish, a look at those harnesses every ten minutes.
enum CLIUpdateSchedule {
    static let launchDelay: TimeInterval = 60
    static let checkInterval: TimeInterval = 6 * 60 * 60
    static let waitingRetryInterval: TimeInterval = 10 * 60

    enum Pass: Equatable, Sendable {
        case checkAll
        case retryWaiting
    }

    /// `launchedAt` is when the app started; nil checks at once.
    static func next(lastCheckAll: Date?, hasWaiting: Bool, now: Date, launchedAt: Date? = nil) -> (at: Date, pass: Pass) {
        guard let lastCheckAll else {
            return (max(now, launchedAt.map { $0.addingTimeInterval(launchDelay) } ?? now), .checkAll)
        }
        let due = lastCheckAll.addingTimeInterval(checkInterval)
        let retry = now.addingTimeInterval(waitingRetryInterval)
        if hasWaiting, retry < due { return (retry, .retryWaiting) }
        return (max(due, now), .checkAll)
    }
}
