import XCTest
@testable import NativeHarnessClient

/// The CLI updater (product document 13.22) against fixture installs in a temporary folder. No real
/// CLI runs: every command goes to a fake runner that answers like the install method would, and
/// a fake check passes or fails by the version written in each fixture executable.
@MainActor
final class CLIUpdateTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "yardlet-cli-update-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Detection

    func testDetectsHomebrewAndNpmInstallsFromWhereTheRuntimeLeads() throws {
        let brew = try executable("opt/homebrew/bin/brew")
        try executable("opt/homebrew/Caskroom/codex/0.157.1/bin/codex", version: "0.157.1")
        let codex = try link("opt/homebrew/bin/codex", to: "../Caskroom/codex/0.157.1/bin/codex")
        let cask = CLIInstallDetector.detect(harness: .codex, executable: codex)
        guard case let .homebrewCask(token, caskBrew, versionDirectory) = cask else { return XCTFail("\(cask)") }
        XCTAssertEqual(token, "codex")
        XCTAssertEqual(path(caskBrew), path(brew))
        XCTAssertEqual(path(versionDirectory), path(url("opt/homebrew/Caskroom/codex/0.157.1")))
        let caskPlan = CLIUpdatePlan(harness: .codex, launcher: codex, method: cask)
        guard case let .yardletCopy(copyRoot, copied) = caskPlan.retention else { return XCTFail("\(caskPlan.retention)") }
        XCTAssertEqual(path(copyRoot), path(versionDirectory), "Homebrew removes a cask's earlier version, so Yardlet copies it")
        XCTAssertEqual(path(copied), path(url("opt/homebrew/Caskroom/codex/0.157.1/bin/codex")))
        XCTAssertEqual(caskPlan.updateCommand?.arguments, ["upgrade", "--cask", "codex"])
        XCTAssertEqual(caskPlan.checkCommands(environment: [:]).map(\.arguments),
                       [["update", "--auto-update", "--quiet"], ["outdated", "--json=v2", "--cask", "codex"]])
        XCTAssertEqual(caskPlan.checkCommands(environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"]).map(\.arguments),
                       [["outdated", "--json=v2", "--cask", "codex"]], "Homebrew's own switch keeps its metadata as it is")

        try executable("opt/homebrew/Cellar/opencode/1.2.0/bin/opencode", version: "1.2.0")
        let opencode = try link("opt/homebrew/bin/opencode", to: "../Cellar/opencode/1.2.0/bin/opencode")
        let formula = CLIInstallDetector.detect(harness: .openCode, executable: opencode)
        guard case let .homebrewFormula(name, formulaBrew) = formula else { return XCTFail("\(formula)") }
        XCTAssertEqual(name, "opencode")
        XCTAssertEqual(path(formulaBrew), path(brew))
        let formulaPlan = CLIUpdatePlan(harness: .openCode, launcher: opencode, method: formula)
        XCTAssertEqual(formulaPlan.retention, .installerKeepsEarlierVersions)
        XCTAssertEqual(formulaPlan.updateCommand?.arguments, ["upgrade", "--formula", "opencode"])
        XCTAssertEqual(formulaPlan.updateCommand?.environment["HOMEBREW_NO_INSTALL_CLEANUP"], "1",
                       "The earlier keg stays in the Cellar")

        let npm = try executable("opt/homebrew/bin/npm")
        try executable("opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js", version: "0.9.0")
        let pi = try link("opt/homebrew/bin/pi", to: "../lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js")
        let global = CLIInstallDetector.detect(harness: .pi, executable: pi)
        guard case let .npmGlobal(package, npmURL, packageDirectory) = global else { return XCTFail("\(global)") }
        XCTAssertEqual(package, "@earendil-works/pi-coding-agent")
        XCTAssertEqual(path(npmURL), path(npm))
        XCTAssertEqual(path(packageDirectory), path(url("opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent")))
        let npmPlan = CLIUpdatePlan(harness: .pi, launcher: pi, method: global)
        XCTAssertEqual(npmPlan.updateCommand?.arguments, ["install", "--global", "@earendil-works/pi-coding-agent@latest"])
        XCTAssertEqual(npmPlan.checkCommands().map(\.arguments), [["view", "@earendil-works/pi-coding-agent", "version", "--json"]])
        guard case let .yardletCopy(_, npmExecutable) = npmPlan.retention else { return XCTFail("\(npmPlan.retention)") }
        XCTAssertTrue(path(npmExecutable).hasSuffix("pi-coding-agent/dist/cli.js"))

        // A Cellar or Caskroom without Homebrew beside it is not Homebrew's.
        let stray = try executable("elsewhere/Caskroom/codex/1.0.0/bin/codex")
        XCTAssertEqual(CLIInstallDetector.detect(harness: .codex, executable: stray), .manual)
    }

    func testDetectsSelfUpdatersAppBundlesAndManualInstalls() throws {
        let agy = try executable("home/.local/bin/agy", version: "1.4.0")
        guard case let .selfUpdater(antigravity) = CLIInstallDetector.detect(harness: .antigravityCLI, executable: agy)
        else { return XCTFail() }
        XCTAssertEqual(antigravity.kind, .antigravity)
        XCTAssertEqual(antigravity.updateArguments, ["update"])
        XCTAssertNil(antigravity.checkArguments, "agy has no check that installs nothing")
        guard case let .yardletCopy(agyRoot, agyExecutable) = antigravity.retention else { return XCTFail() }
        XCTAssertEqual(path(agyRoot), path(agy), "`agy update` replaces the file, so Yardlet copies it")
        XCTAssertEqual(path(agyExecutable), path(agy))

        try executable("home/.local/share/claude/versions/2.1.291", version: "2.1.291")
        let claude = try link("home/.local/bin/claude", to: "../share/claude/versions/2.1.291")
        guard case let .selfUpdater(native) = CLIInstallDetector.detect(harness: .claudeCode, executable: claude)
        else { return XCTFail() }
        XCTAssertEqual(native.kind, .claudeNative)
        XCTAssertEqual(native.retention, .installerKeepsEarlierVersions)
        XCTAssertEqual(native.commandText, "claude update")

        try executable("home/.local/share/cursor-agent/versions/2026.08.11-e8db854/cursor-agent", version: "2026.08.11-e8db854")
        let cursor = try link("home/.local/bin/cursor-agent", to: "../share/cursor-agent/versions/2026.08.11-e8db854/cursor-agent")
        guard case let .selfUpdater(cursorUpdater) = CLIInstallDetector.detect(harness: .cursorAgent, executable: cursor)
        else { return XCTFail() }
        XCTAssertEqual(cursorUpdater.kind, .cursor)
        XCTAssertEqual(cursorUpdater.retention, .installerKeepsEarlierVersions)

        try executable("home/.grok/downloads/grok-1.0.30-macos-aarch64", version: "1.0.30")
        let grok = try link("home/.grok/bin/grok", to: "../downloads/grok-1.0.30-macos-aarch64")
        guard case let .selfUpdater(grokUpdater) = CLIInstallDetector.detect(harness: .grokBuild, executable: grok)
        else { return XCTFail() }
        XCTAssertEqual(grokUpdater.checkArguments, ["update", "--check", "--json"])
        XCTAssertEqual(grokUpdater.retention, .installerKeepsEarlierVersions)

        let hermes = try executable("home/.hermes/hermes-agent/venv/bin/hermes")
        guard case let .selfUpdater(hermesUpdater) = CLIInstallDetector.detect(harness: .hermes, executable: hermes)
        else { return XCTFail() }
        XCTAssertEqual(hermesUpdater.retention, .none, "A virtual environment does not run from a copy")

        let claudeApp = try executable("home/Library/Application Support/Claude/claude-code/2.1.293/claude.app/Contents/MacOS/claude")
        XCTAssertEqual(CLIInstallDetector.detect(harness: .claudeCode, executable: claudeApp), .appBundled(appName: "Claude"))
        let chatGPT = try executable("Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
        XCTAssertEqual(CLIInstallDetector.detect(harness: .codex, executable: chatGPT), .appBundled(appName: "ChatGPT"))
        XCTAssertNil(CLIUpdatePlan(harness: .codex, launcher: chatGPT, method: .appBundled(appName: "ChatGPT")).updateCommand)

        let kimi = try executable("usr/local/bin/kimi")
        XCTAssertEqual(CLIInstallDetector.detect(harness: .kimiCode, executable: kimi), .manual)
        let notAgy = try executable("home/bin/antigravity")
        XCTAssertEqual(CLIInstallDetector.detect(harness: .antigravityCLI, executable: notAgy), .manual)
    }

    // MARK: - Reading answers

    func testReadsVersionsAndEachMethodsAnswer() throws {
        XCTAssertEqual(CLIVersion.parse("codex-cli 0.163.0"), "0.163.0")
        XCTAssertEqual(CLIVersion.parse("2.1.291 (Claude Code)"), "2.1.291")
        XCTAssertEqual(CLIVersion.parse("grok 1.0.30 (04b7ffed98c6) [stable]"), "1.0.30")
        XCTAssertEqual(CLIVersion.parse("2026.08.11-e8db854\n"), "2026.08.11-e8db854")
        XCTAssertEqual(CLIVersion.parse("1.4.0\n"), "1.4.0")
        XCTAssertNil(CLIVersion.parse("command not found"))
        XCTAssertTrue(CLIVersion.isNewer("0.163.0", than: "0.157.1"))
        XCTAssertFalse(CLIVersion.isNewer("0.157.1", than: "0.163.0"))
        XCTAssertTrue(CLIVersion.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertTrue(CLIVersion.isNewer("1.0.0", than: "1.0.0-alpha.2"))
        XCTAssertTrue(CLIVersion.isNewer("1.0.0-alpha.10", than: "1.0.0-alpha.2"))
        XCTAssertFalse(CLIVersion.isNewer("1.0.0", than: "1.0.0"))

        try executable("opt/homebrew/bin/brew")
        try executable("opt/homebrew/Caskroom/codex/0.157.1/bin/codex")
        let codex = try link("opt/homebrew/bin/codex", to: "../Caskroom/codex/0.157.1/bin/codex")
        let cask = CLIUpdatePlan(harness: .codex, launcher: codex,
                                 method: CLIInstallDetector.detect(harness: .codex, executable: codex))
        XCTAssertEqual(cask.latest(from: ok(Self.outdated("0.157.1", "0.163.0")), installed: "0.157.1"), .available("0.163.0"))
        XCTAssertEqual(cask.latest(from: ok(#"{"formulae":[],"casks":[]}"#), installed: "0.163.0"), .upToDate)
        guard case .failed = cask.latest(from: ok("Error: not JSON"), installed: "0.157.1") else { return XCTFail() }
        guard case .failed = cask.latest(from: CLICommandResult(exitCode: 1, stdout: "", stderr: "Error: Another active Homebrew process"),
                                         installed: "0.157.1") else { return XCTFail() }

        try executable("opt/homebrew/bin/npm")
        try executable("opt/homebrew/lib/node_modules/opencode-ai/bin/opencode.exe")
        let opencode = try link("opt/homebrew/bin/opencode", to: "../lib/node_modules/opencode-ai/bin/opencode.exe")
        let npm = CLIUpdatePlan(harness: .openCode, launcher: opencode,
                                method: CLIInstallDetector.detect(harness: .openCode, executable: opencode))
        XCTAssertEqual(npm.latest(from: ok("\"1.3.0\"\n"), installed: "1.2.0"), .available("1.3.0"))
        XCTAssertEqual(npm.latest(from: ok("\"1.2.0\"\n"), installed: "1.2.0"), .upToDate)

        try executable("home/.grok/downloads/grok-1.0.30-macos-aarch64")
        let grokLink = try link("home/.grok/bin/grok", to: "../downloads/grok-1.0.30-macos-aarch64")
        let grok = CLIUpdatePlan(harness: .grokBuild, launcher: grokLink,
                                 method: CLIInstallDetector.detect(harness: .grokBuild, executable: grokLink))
        // `grok update --check --json` from grok 1.0.30.
        XCTAssertEqual(grok.latest(from: ok(#"{"currentVersion":"1.0.30","latestVersion":"1.0.60","updateAvailable":true,"installer":"internal","channel":"stable","autoUpdate":true,"error":null}"#),
                                   installed: "1.0.30"), .available("1.0.60"))
        XCTAssertEqual(grok.latest(from: ok(#"{"currentVersion":"1.0.60","latestVersion":"1.0.60","updateAvailable":false,"error":null}"#),
                                   installed: "1.0.60"), .upToDate)
    }

    // MARK: - Decisions and schedule

    func testRunningTasksAndMissingSafeguardsBlockAnUpdate() throws {
        let agy = try executable("home/.local/bin/agy")
        let selfUpdating = CLIUpdatePlan(harness: .antigravityCLI, launcher: agy,
                                         method: CLIInstallDetector.detect(harness: .antigravityCLI, executable: agy))
        func decide(_ plan: CLIUpdatePlan, auto: Bool = true, verify: Bool = true, latest: CLILatest? = .available("2.0.0"),
                    failed: String? = nil, busy: Bool = false) -> CLIUpdateDecision {
            .decide(autoUpdate: auto, plan: plan, canVerify: verify, latest: latest, failedVersion: failed, isBusy: busy)
        }
        XCTAssertEqual(decide(selfUpdating), .update)
        XCTAssertEqual(decide(selfUpdating, busy: true), .waitForIdle, "A running task of the harness blocks the update")
        XCTAssertEqual(decide(selfUpdating, auto: false), .skip(.autoUpdateOff))
        XCTAssertEqual(decide(selfUpdating, verify: false), .skip(.cannotVerify))
        XCTAssertEqual(decide(selfUpdating, latest: .upToDate), .skip(.upToDate))
        XCTAssertEqual(decide(selfUpdating, latest: .failed("offline")), .skip(.checkFailed))
        XCTAssertEqual(decide(selfUpdating, failed: "2.0.0"), .skip(.failedBefore), "A version that failed is not tried again")
        XCTAssertEqual(decide(selfUpdating, latest: .unknown), .update, "A CLI that checks for itself is updated on schedule")
        XCTAssertEqual(decide(selfUpdating, latest: .unknown, busy: true), .waitForIdle)

        let hermes = try executable("home/.hermes/hermes-agent/venv/bin/hermes")
        let noCopy = CLIUpdatePlan(harness: .hermes, launcher: hermes,
                                   method: CLIInstallDetector.detect(harness: .hermes, executable: hermes))
        XCTAssertEqual(decide(noCopy), .skip(.cannotKeepPrevious), "An update that could not be undone does not run")
        let app = CLIUpdatePlan(harness: .claudeCode, launcher: agy, method: .appBundled(appName: "Claude"))
        XCTAssertEqual(decide(app), .skip(.notUpdatable))
        let manual = CLIUpdatePlan(harness: .kimiCode, launcher: agy, method: .manual)
        XCTAssertEqual(decide(manual), .skip(.notUpdatable))
    }

    func testChecksAtLaunchEverySixHoursAndRetriesWaitingUpdatesEveryTenMinutes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(CLIUpdateSchedule.next(lastCheckAll: nil, hasWaiting: false, now: now).at, now)
        XCTAssertEqual(CLIUpdateSchedule.next(lastCheckAll: nil, hasWaiting: false, now: now).pass, .checkAll)
        XCTAssertEqual(CLIUpdateSchedule.next(lastCheckAll: nil, hasWaiting: false, now: now, launchedAt: now).at,
                       now.addingTimeInterval(60), "The launch check waits a minute for the tasks a restart continues")
        XCTAssertEqual(CLIUpdateSchedule.next(lastCheckAll: nil, hasWaiting: false, now: now.addingTimeInterval(90),
                                              launchedAt: now).at, now.addingTimeInterval(90))
        let checked = now
        let later = CLIUpdateSchedule.next(lastCheckAll: checked, hasWaiting: false, now: now.addingTimeInterval(60))
        XCTAssertEqual(later.at, checked.addingTimeInterval(6 * 60 * 60))
        XCTAssertEqual(later.pass, .checkAll)
        let retry = CLIUpdateSchedule.next(lastCheckAll: checked, hasWaiting: true, now: now.addingTimeInterval(60))
        XCTAssertEqual(retry.at, now.addingTimeInterval(60 + 10 * 60))
        XCTAssertEqual(retry.pass, .retryWaiting)
        let nearDue = now.addingTimeInterval(6 * 60 * 60 - 60)
        XCTAssertEqual(CLIUpdateSchedule.next(lastCheckAll: checked, hasWaiting: true, now: nearDue).pass, .checkAll,
                       "A full check due before the retry takes its place")
        let overdue = now.addingTimeInterval(8 * 60 * 60)
        XCTAssertEqual(CLIUpdateSchedule.next(lastCheckAll: checked, hasWaiting: false, now: overdue).at, overdue,
                       "After the Mac slept past the check, it runs at once")
    }

    func testTheLoopChecksAtOnceThenSleepsSixHoursOrTenMinutesWhileAnUpdateWaits() async throws {
        let (launcher, runner, _) = try codexCask(installed: "0.157.1", newest: "0.163.0")
        let sleeps = Box<[TimeInterval]>([])
        let busy = Box<Set<HarnessKind>>([.codex])
        let center = makeCenter(runtimes: [.codex: launcher], runner: runner, verifier: FakeVerifier(),
                                busy: busy, sleep: { seconds in
                                    sleeps.value.append(seconds)
                                    throw CancellationError()
                                }).center
        center.start(delaysFirstCheck: false)
        try await waitUntil { !sleeps.value.isEmpty }
        XCTAssertNotNil(center.lastCheckAll, "The launch check ran without waiting")
        XCTAssertEqual(center.row(for: .codex)?.phase, .waitingForTasks)
        XCTAssertEqual(sleeps.value.count, 1)
        XCTAssertEqual(sleeps.value[0], CLIUpdateSchedule.waitingRetryInterval, accuracy: 5)
        center.stop()

        busy.value = []
        let quiet = Box<[TimeInterval]>([])
        let idle = makeCenter(runtimes: [.codex: launcher], runner: runner, verifier: FakeVerifier(), busy: busy,
                              sleep: { seconds in
                                  quiet.value.append(seconds)
                                  throw CancellationError()
                              }).center
        idle.start(delaysFirstCheck: false)
        try await waitUntil { !quiet.value.isEmpty }
        XCTAssertEqual(quiet.value.count, 1)
        XCTAssertEqual(quiet.value[0], CLIUpdateSchedule.checkInterval, accuracy: 5)
        idle.stop()

        // The app's start waits a minute before its first check.
        let first = Box<[TimeInterval]>([])
        let launched = makeCenter(runtimes: [.codex: launcher], runner: runner, verifier: FakeVerifier(), busy: busy,
                                  sleep: { seconds in
                                      first.value.append(seconds)
                                      throw CancellationError()
                                  }).center
        launched.start()
        try await waitUntil { !first.value.isEmpty }
        XCTAssertEqual(first.value[0], CLIUpdateSchedule.launchDelay, accuracy: 5)
        XCTAssertNil(launched.lastCheckAll)
        launched.stop()
    }

    // MARK: - Updating

    /// Today's failure, made safe: a Homebrew cask upgrade whose new Codex fails Yardlet's check.
    func testAFailedUpdateGoesBackToACopyOfTheVersionBefore() async throws {
        let (launcher, runner, newest) = try codexCask(installed: "0.157.1", newest: "0.163.0")
        let verifier = FakeVerifier(failing: ["0.163.0"])
        let made = makeCenter(runtimes: [.codex: launcher], runner: runner, verifier: verifier)
        let center = made.center

        await center.checkAll()

        XCTAssertEqual(runner.commands.map(\.arguments), [
            ["--version"], ["update", "--auto-update", "--quiet"], ["outdated", "--json=v2", "--cask", "codex"],
            ["upgrade", "--cask", "codex"], ["--version"]
        ])
        XCTAssertEqual(verifier.checkedVersions, ["0.157.1", "0.163.0"], "The current version first, then the new one")
        let held = try XCTUnwrap(made.overrides.entry(for: .codex))
        XCTAssertEqual(held.failedVersion, "0.163.0")
        XCTAssertEqual(held.version, "0.157.1")
        XCTAssertTrue(held.target.hasSuffix("cli-previous/codex/0.157.1/0.157.1/bin/codex"), held.target)
        XCTAssertEqual(version(atPath: held.target), "0.157.1", "Homebrew removed 0.157.1; Yardlet's copy keeps it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("opt/homebrew/Caskroom/codex/0.157.1").path(percentEncoded: false)))
        XCTAssertEqual(version(atPath: launcher.path(percentEncoded: false)), "0.163.0", "The install stays as Homebrew left it")
        XCTAssertEqual(path(made.overrides.executable(for: .codex, requested: launcher)), held.target,
                       "A task's recorded path starts the earlier version")
        XCTAssertEqual(center.notice, CLIUpdateNotice(harness: .codex, failedVersion: "0.163.0", restoredVersion: "0.157.1"))
        XCTAssertEqual(center.notice?.message, L10n.format(
            "%1$@ %2$@ did not pass Yardlet's check, so Yardlet went back to %3$@.", "Codex", "0.163.0", "0.157.1"))
        XCTAssertEqual(made.changed.value, [.codex])
        XCTAssertEqual(center.record(for: .codex)?.failedVersion, "0.163.0")

        // The adapter for the task's path runs the copy.
        let started = Box<[String]>([])
        let registry = HarnessRegistry(factory: { harness, url in
            started.value.append(url.path(percentEncoded: false))
            return UnsupportedHarnessAdapter(kind: harness, executableURL: url)
        }, runtimeOverrides: made.overrides)
        _ = await registry.adapter(for: .codex, executableURL: launcher)
        XCTAssertEqual(started.value, [held.target])

        // 0.163.0 is not tried again.
        let ran = runner.commands.count
        await center.checkAll()
        XCTAssertFalse(runner.commands.dropFirst(ran).contains { $0.arguments.first == "upgrade" })
        XCTAssertNotNil(made.overrides.entry(for: .codex))

        // A newer version that passes: Yardlet runs the install again and keeps 0.157.1 to go back to.
        newest.value = "0.164.0"
        await center.checkAll()
        XCTAssertNil(made.overrides.entry(for: .codex))
        XCTAssertEqual(center.record(for: .codex)?.verifiedVersion, "0.164.0")
        XCTAssertNil(center.record(for: .codex)?.failedVersion)
        XCTAssertEqual(center.record(for: .codex)?.previous?.version, "0.157.1")
        XCTAssertEqual(center.row(for: .codex)?.outcome, .updated(from: "0.163.0", to: "0.164.0"))
        XCTAssertEqual(path(made.overrides.executable(for: .codex, requested: launcher)), path(launcher))
    }

    func testARunningTaskHoldsTheUpdateUntilItFinishes() async throws {
        let (launcher, runner, _) = try codexCask(installed: "0.157.1", newest: "0.163.0")
        let busy = Box<Set<HarnessKind>>([.codex])
        let made = makeCenter(runtimes: [.codex: launcher], runner: runner, verifier: FakeVerifier(), busy: busy)
        let center = made.center

        await center.checkAll()
        XCTAssertEqual(center.row(for: .codex)?.phase, .waitingForTasks)
        XCTAssertEqual(center.row(for: .codex)?.decision, .waitForIdle)
        XCTAssertFalse(runner.commands.contains { $0.arguments.first == "upgrade" }, "Nothing updates under a running task")

        await center.retryWaiting()
        XCTAssertFalse(runner.commands.contains { $0.arguments.first == "upgrade" })

        busy.value = []
        let checks = runner.commands.filter { $0.arguments.first == "outdated" }.count
        await center.retryWaiting()
        XCTAssertEqual(runner.commands.filter { $0.arguments.first == "outdated" }.count, checks,
                       "A retry reuses the newest version the check found")
        XCTAssertTrue(runner.commands.contains { $0.arguments == ["upgrade", "--cask", "codex"] })
        XCTAssertEqual(center.row(for: .codex)?.outcome, .updated(from: "0.157.1", to: "0.163.0"))
        XCTAssertEqual(center.row(for: .codex)?.phase, .idle)
        XCTAssertNil(made.overrides.entry(for: .codex))
        let previous = try XCTUnwrap(center.record(for: .codex)?.previous)
        XCTAssertEqual(previous.version, "0.157.1")
        XCTAssertTrue(previous.isCopy)
        XCTAssertEqual(version(atPath: previous.executable), "0.157.1", "The version before stays available")
        XCTAssertEqual(made.changed.value, [.codex])
    }

    func testAnUpdateDoesNotRunWhenTheCurrentVersionAlreadyFailsTheCheck() async throws {
        let (launcher, runner, _) = try codexCask(installed: "0.157.1", newest: "0.163.0")
        let made = makeCenter(runtimes: [.codex: launcher], runner: runner, verifier: FakeVerifier(failing: ["0.157.1"]))
        await made.center.checkAll()
        XCTAssertFalse(runner.commands.contains { $0.arguments.first == "upgrade" },
                       "A failure afterwards could not be told apart from the account or the network")
        guard case .couldNotVerifyCurrent? = made.center.row(for: .codex)?.outcome else {
            return XCTFail("\(String(describing: made.center.row(for: .codex)?.outcome))")
        }
        XCTAssertNil(made.overrides.entry(for: .codex))
        XCTAssertNil(made.center.notice)
    }

    /// Claude Code's native installer updated itself outside Yardlet; it keeps earlier versions.
    func testAnUpdateMadeOutsideYardletIsCheckedAndGoesBackToTheVersionTheInstallerKept() async throws {
        try executable("home/.local/share/claude/versions/2.1.291", version: "2.1.291")
        let claude = try link("home/.local/bin/claude", to: "../share/claude/versions/2.1.291")
        let runner = versionRunner()
        let verifier = FakeVerifier(failing: ["2.1.293"])
        let made = makeCenter(runtimes: [.claudeCode: claude], runner: runner, verifier: verifier)

        await made.center.checkAll()
        XCTAssertEqual(made.center.record(for: .claudeCode)?.verifiedVersion, "2.1.291")
        XCTAssertEqual(made.center.row(for: .claudeCode)?.latest, .upToDate, "`claude update` found nothing newer")
        XCTAssertNil(made.center.notice)

        // `claude update` in a terminal moved the link to 2.1.293 and kept 2.1.291.
        try executable("home/.local/share/claude/versions/2.1.293", version: "2.1.293")
        try FileManager.default.removeItem(at: claude)
        try link("home/.local/bin/claude", to: "../share/claude/versions/2.1.293")

        await made.center.checkAll()
        let held = try XCTUnwrap(made.overrides.entry(for: .claudeCode))
        XCTAssertEqual(held.failedVersion, "2.1.293")
        XCTAssertEqual(held.version, "2.1.291")
        XCTAssertEqual(held.target, path(url("home/.local/share/claude/versions/2.1.291")))
        XCTAssertEqual(made.center.notice?.restoredVersion, "2.1.291")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("cli-previous").path(percentEncoded: false)),
                       "The installer kept it, so Yardlet copied nothing")
    }

    /// `agy` replaced itself between checks: Yardlet goes back to the copy it made before its last update.
    func testASelfUpdateBetweenChecksGoesBackToYardletsCopy() async throws {
        let agy = try executable("home/.local/bin/agy", version: "1.4.0")
        let runner = FakeCLIRunner { command in
            command.arguments == ["--version"]
                ? Self.ok(Self.version(of: command.executable) ?? "?")
                : Self.ok("Already on the latest version")
        }
        let made = makeCenter(runtimes: [.antigravityCLI: agy], runner: runner, verifier: FakeVerifier(failing: ["1.5.0"]))

        await made.center.checkAll()
        XCTAssertEqual(runner.commands.map(\.arguments), [["--version"], ["update"], ["--version"]],
                       "agy has no check, so its own updater looks")
        let copy = try XCTUnwrap(made.center.record(for: .antigravityCLI)?.previous)
        XCTAssertEqual(copy.version, "1.4.0")
        XCTAssertTrue(copy.executable.hasSuffix("cli-previous/antigravity-cli/1.4.0/agy"), copy.executable)
        XCTAssertNil(made.center.notice)

        try Self.writeExecutable(agy, version: "1.5.0")
        await made.center.checkAll()
        let held = try XCTUnwrap(made.overrides.entry(for: .antigravityCLI))
        XCTAssertEqual(held.failedVersion, "1.5.0")
        XCTAssertEqual(held.target, copy.executable)
        XCTAssertEqual(URL(filePath: held.target).lastPathComponent, "agy", "Yardlet still recognizes the runtime")
        XCTAssertEqual(made.center.notice, CLIUpdateNotice(harness: .antigravityCLI, failedVersion: "1.5.0", restoredVersion: "1.4.0"))

        // In the app the copies live under `~/.yardlet/cli-previous`; a copy never updates itself.
        let kept = URL(filePath: "/Users/someone/.yardlet/cli-previous/antigravity-cli/1.4.0/agy")
        XCTAssertTrue(CLIRuntimeOverrides.isYardletCopy(kept))
        let environment = RuntimeProcessEnvironment.values(executableURL: kept, base: ["PATH": "/usr/bin"])
        XCTAssertEqual(environment["AGY_CLI_DISABLE_AUTO_UPDATE"], "true")
        XCTAssertEqual(environment["DISABLE_AUTOUPDATER"], "1")
        let installed = RuntimeProcessEnvironment.values(executableURL: agy, base: ["PATH": "/usr/bin"])
        XCTAssertNil(installed["AGY_CLI_DISABLE_AUTO_UPDATE"], "The person's install keeps its own updater")
    }

    func testTurningAutomaticUpdatesOffLeavesNothingOfYardletsBehind() async throws {
        let (launcher, runner, _) = try codexCask(installed: "0.157.1", newest: "0.163.0")
        let made = makeCenter(runtimes: [.codex: launcher], runner: runner, verifier: FakeVerifier(failing: ["0.163.0"]))
        await made.center.checkAll()
        XCTAssertNotNil(made.overrides.entry(for: .codex))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url("cli-previous").path(percentEncoded: false)))

        made.center.setAutoUpdate(false)
        XCTAssertNil(made.overrides.entry(for: .codex))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("cli-previous").path(percentEncoded: false)))
        XCTAssertNil(made.center.record(for: .codex))
        XCTAssertNil(made.center.notice)
        XCTAssertNil(made.defaults.data(forKey: CLIRuntimeOverrides.defaultsKey))
        XCTAssertEqual(made.defaults.object(forKey: CLIUpdateCenter.enabledKey) as? Bool, false)
        XCTAssertEqual(version(atPath: launcher.path(percentEncoded: false)), "0.163.0", "The install is the person's")

        let ran = runner.commands.count
        await made.center.checkAll()
        XCTAssertFalse(runner.commands.dropFirst(ran).contains { $0.arguments.first == "upgrade" })
        XCTAssertEqual(made.center.row(for: .codex)?.decision, .skip(.autoUpdateOff))
        try await waitUntil { made.changed.value.count >= 2 }
    }

    func testRowsSayWhatEachInstallDoes() throws {
        let (launcher, _, _) = try codexCask(installed: "0.157.1", newest: "0.163.0")
        let method = CLIInstallDetector.detect(harness: .codex, executable: launcher)
        var row = CLIUpdateCenter.Row(harness: .codex, method: method,
                                      plan: CLIUpdatePlan(harness: .codex, launcher: launcher, method: method))
        row.installed = "0.157.1"
        row.latest = .available("0.163.0")
        var text = CLIUpdateRowPresentation(row: row, held: nil)
        XCTAssertEqual(text.method, L10n.format("Homebrew cask %@", "codex"))
        XCTAssertEqual(text.versions, L10n.format("Installed %1$@ · Latest %2$@", "0.157.1", "0.163.0"))
        XCTAssertEqual(text.status, L10n.string("Update available"))

        row.phase = .waitingForTasks
        XCTAssertEqual(CLIUpdateRowPresentation(row: row, held: nil).status, L10n.string("Updates when its tasks finish"))
        row.phase = .idle
        text = CLIUpdateRowPresentation(row: row, held: CLIRuntimeOverrides.Entry(launcher: "", installed: "", target: "",
                                                                                   failedVersion: "0.163.0", version: "0.157.1"))
        XCTAssertEqual(text.status, L10n.format("%1$@ did not pass Yardlet's check, so Yardlet runs %2$@", "0.163.0", "0.157.1"))
        XCTAssertTrue(text.isWarning)

        let app = CLIUpdateCenter.Row(harness: .claudeCode, method: .appBundled(appName: "Claude"),
                                      plan: CLIUpdatePlan(harness: .claudeCode, launcher: launcher, method: .appBundled(appName: "Claude")))
        XCTAssertEqual(CLIUpdateRowPresentation(row: app, held: nil).status, L10n.format("Updated with the %@ app", "Claude"))
        XCTAssertEqual(CLIUpdateRowPresentation(row: app, held: nil).method, L10n.format("Comes with the %@ app", "Claude"))
    }

    // MARK: - The checks themselves

    /// The real checks against shell scripts that answer like each CLI: Codex App Server
    /// `initialize` then `thread/list`, Claude Code's `initialize` control request, `agy models`,
    /// and ACP `initialize`. No turn is asked for; a refusal, a silent CLI and a crash all fail.
    func testTheChecksSpeakEachHarnessProtocolWithoutAModelTurn() async throws {
        let probe = CLIVerificationProbe(codexEnvironment: nil, timeout: .seconds(5))
        let codex = try script("codex", #"""
            [ "$1" = app-server ] || exit 2
            read -r line; case "$line" in *'"method":"initialize"'*) ;; *) exit 3;; esac
            echo '{"id":1,"result":{"platformOs":"macos","userAgent":"codex"}}'
            read -r line; case "$line" in *'"method":"thread\/list"'*|*'"method":"thread/list"'*) ;; *) exit 4;; esac
            case "$line" in *'"limit":1'*) ;; *) exit 5;; esac
            echo '{"id":2,"result":{"data":[],"nextCursor":null}}'
            read -r line
            """#)
        var result = await probe.verify(.codex, executable: codex)
        XCTAssertEqual(result, .passed)
        let refusing = try script("codex-refusing", #"""
            read -r line
            echo '{"id":1,"error":{"code":-32600,"message":"unknown field capabilities"}}'
            read -r line
            """#)
        result = await probe.verify(.codex, executable: refusing)
        XCTAssertEqual(result, .failed("unknown field capabilities"))
        let crashing = try script("codex-crashing", "exit 1")
        result = await probe.verify(.codex, executable: crashing)
        guard case .failed = result else { return XCTFail("\(result)") }

        let claude = try script("claude", #"""
            if [ "$1" = --version ]; then echo '2.1.300 (Claude Code)'; exit 0; fi
            case " $* " in *' --input-format stream-json '*) ;; *) exit 2;; esac
            read -r line; case "$line" in *'"subtype":"initialize"'*) ;; *) exit 3;; esac
            echo '{"type":"system","subtype":"status"}'
            echo '{"type":"control_response","response":{"request_id":"yardlet-check","subtype":"success","response":{"models":[]}}}'
            read -r line
            """#)
        result = await probe.verify(.claudeCode, executable: claude)
        XCTAssertEqual(result, .passed)
        let silent = try script("claude-silent", #"""
            if [ "$1" = --version ]; then echo '2.1.300 (Claude Code)'; exit 0; fi
            sleep 30
            """#)
        let quick = CLIVerificationProbe(codexEnvironment: nil, timeout: .seconds(1))
        result = await quick.verify(.claudeCode, executable: silent)
        XCTAssertEqual(result, .failed(L10n.string("Timed out")))

        let agy = try script("agy", #"""
            [ "$1" = models ] || exit 2
            printf 'gemini-3.8-flash-low\tGemini 3.8 Flash (low)\n'
            """#)
        result = await probe.verify(.antigravityCLI, executable: agy)
        XCTAssertEqual(result, .passed)
        let signedOut = try script("agy-signed-out", "echo 'not signed in' >&2; exit 1")
        result = await probe.verify(.antigravityCLI, executable: signedOut)
        XCTAssertEqual(result, .failed("not signed in"))
        // From the version Yardlet runs over ACP, `agy acp` has to answer `initialize` too.
        let agyACP = try script("agy-acp", #"""
            if [ "$1" = --version ]; then echo 1.4.12; exit 0; fi
            if [ "$1" = models ]; then printf 'gemini-3.8-flash-low\tGemini 3.8 Flash (low)\n'; exit 0; fi
            [ "$1" = acp ] || exit 2
            read -r line; case "$line" in *'"method":"initialize"'*) ;; *) exit 3;; esac
            echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true}}}'
            read -r line
            """#)
        result = await probe.verify(.antigravityCLI, executable: agyACP)
        XCTAssertEqual(result, .passed)
        let agyWithoutACP = try script("agy-without-acp", #"""
            if [ "$1" = --version ]; then echo 1.4.12; exit 0; fi
            if [ "$1" = models ]; then printf 'gemini-3.8-flash-low\tGemini 3.8 Flash (low)\n'; exit 0; fi
            echo "unknown subcommand: $1" >&2; exit 2
            """#)
        result = await probe.verify(.antigravityCLI, executable: agyWithoutACP)
        guard case .failed = result else { return XCTFail("\(result)") }

        let opencode = try script("opencode", #"""
            if [ "$1" = --version ]; then echo 1.2.0; exit 0; fi
            [ "$1" = acp ] || exit 2
            read -r line; case "$line" in *'"method":"initialize"'*) ;; *) exit 3;; esac
            echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{}}}'
            read -r line
            """#)
        result = await probe.verify(.openCode, executable: opencode)
        XCTAssertEqual(result, .passed)
        XCTAssertTrue(probe.canVerify(.grokBuild))
        XCTAssertFalse(probe.canVerify(.cursorAgent), "Cursor has no check without a turn")
        XCTAssertFalse(probe.canVerify(.museCode))
        XCTAssertFalse(probe.canVerify(.pi))
    }

    // MARK: - Fixtures

    /// A Homebrew prefix with Codex installed as a cask. The fake `brew` answers `outdated` against
    /// `newest` and performs `upgrade` the way Homebrew does: the new version directory, the link
    /// moved to it, and the earlier version removed.
    private func codexCask(installed: String, newest: String) throws -> (URL, FakeCLIRunner, Box<String>) {
        try executable("opt/homebrew/bin/brew")
        try executable("opt/homebrew/Caskroom/codex/\(installed)/bin/codex", version: installed)
        let launcher = try link("opt/homebrew/bin/codex", to: "../Caskroom/codex/\(installed)/bin/codex")
        let newestBox = Box(newest)
        let caskroom = url("opt/homebrew/Caskroom/codex")
        let runner = FakeCLIRunner { command in
            switch command.arguments.first {
            case "--version":
                return Self.ok("codex-cli \(Self.version(of: command.executable) ?? "?")")
            case "update":
                return Self.ok("")
            case "outdated":
                let current = Self.version(of: launcher) ?? ""
                return Self.ok(CLIVersion.isNewer(newestBox.value, than: current)
                    ? Self.outdated(current, newestBox.value) : #"{"formulae":[],"casks":[]}"#)
            case "upgrade":
                let current = Self.version(of: launcher) ?? ""
                let target = newestBox.value
                do {
                    try Self.writeExecutable(caskroom.appending(path: "\(target)/bin/codex"), version: target)
                    try FileManager.default.removeItem(at: launcher)
                    try FileManager.default.createSymbolicLink(atPath: launcher.path(percentEncoded: false),
                        withDestinationPath: "../Caskroom/codex/\(target)/bin/codex")
                    try FileManager.default.removeItem(at: caskroom.appending(path: current))
                } catch {
                    return CLICommandResult(exitCode: 1, stdout: "", stderr: error.localizedDescription)
                }
                return Self.ok("==> Upgrading codex")
            default:
                return CLICommandResult(exitCode: 1, stdout: "", stderr: "unexpected \(command.arguments)")
            }
        }
        return (launcher, runner, newestBox)
    }

    /// A runner whose `--version` reads the fixture executable and whose update finds nothing newer.
    private func versionRunner() -> FakeCLIRunner {
        FakeCLIRunner { command in
            command.arguments == ["--version"]
                ? Self.ok("\(Self.version(of: command.executable) ?? "?") (Claude Code)")
                : Self.ok("Claude Code is up to date")
        }
    }

    private func makeCenter(
        runtimes: [HarnessKind: URL],
        runner: FakeCLIRunner,
        verifier: FakeVerifier,
        busy: Box<Set<HarnessKind>> = Box([]),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in throw CancellationError() }
    ) -> (center: CLIUpdateCenter, overrides: CLIRuntimeOverrides, changed: Box<[HarnessKind]>, defaults: UserDefaults) {
        let suite = testDefaultsSuite("CLIUpdateTests")
        let defaults = UserDefaults(suiteName: suite)!
        let overrides = CLIRuntimeOverrides(defaults: defaults)
        let changed = Box<[HarnessKind]>([])
        let center = CLIUpdateCenter(dependencies: .init(
            runtimes: { runtimes },
            busyHarnesses: { busy.value },
            runner: runner,
            verifier: verifier,
            overrides: overrides,
            defaults: defaults,
            previousVersionsDirectory: url("cli-previous"),
            environment: [:],
            sleep: sleep,
            runtimeChanged: { harness, _ in changed.value.append(harness) }))
        return (center, overrides, changed, defaults)
    }

    nonisolated private static func outdated(_ installed: String, _ current: String) -> String {
        #"{"formulae":[],"casks":[{"name":"codex","installed_versions":[""# + installed + #""],"current_version":""# + current + #""}]}"#
    }

    nonisolated private static func ok(_ stdout: String) -> CLICommandResult {
        CLICommandResult(exitCode: 0, stdout: stdout, stderr: "")
    }

    private func ok(_ stdout: String) -> CLICommandResult { Self.ok(stdout) }

    nonisolated private static func version(of url: URL) -> String? {
        guard let text = try? String(contentsOf: url.resolvingSymlinksInPath(), encoding: .utf8),
              let range = text.range(of: #"(?<=# version )\S+"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    private func version(atPath path: String) -> String? { Self.version(of: URL(filePath: path)) }

    nonisolated private static func writeExecutable(_ url: URL, version: String?) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n# version \(version ?? "none")\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
    }

    private func script(_ name: String, _ body: String) throws -> URL {
        let file = url("scripts/\(name)")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false))
        return file
    }

    @discardableResult
    private func executable(_ relative: String, version: String? = nil) throws -> URL {
        let file = url(relative)
        try Self.writeExecutable(file, version: version)
        return file
    }

    @discardableResult
    private func link(_ relative: String, to destination: String) throws -> URL {
        let file = url(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: file.path(percentEncoded: false), withDestinationPath: destination)
        return file
    }

    private func url(_ relative: String) -> URL { root.appending(path: relative) }

    /// Where `url` leads, without the trailing slash a directory URL carries.
    private func path(_ url: URL) -> String {
        let text = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        return text.count > 1 && text.hasSuffix("/") ? String(text.dropLast()) : text
    }
}

final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

final class FakeCLIRunner: CLICommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [CLICommand] = []
    private let respond: @Sendable (CLICommand) -> CLICommandResult

    init(_ respond: @escaping @Sendable (CLICommand) -> CLICommandResult) { self.respond = respond }

    var commands: [CLICommand] { lock.withLock { log } }

    func run(_ command: CLICommand) async -> CLICommandResult {
        lock.withLock { log.append(command) }
        return respond(command)
    }
}

/// Passes unless the executable it checks is one of the `failing` versions.
final class FakeVerifier: CLIVerifying, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private let failing: Set<String>
    private let verifiable: Set<HarnessKind>

    init(failing: Set<String> = [], verifiable: Set<HarnessKind> = [.codex, .claudeCode, .antigravityCLI]) {
        self.failing = failing
        self.verifiable = verifiable
    }

    var checkedVersions: [String] { lock.withLock { log } }

    func canVerify(_ harness: HarnessKind) -> Bool { verifiable.contains(harness) }

    func verify(_ harness: HarnessKind, executable: URL) async -> CLIVerification {
        let text = (try? String(contentsOf: executable.resolvingSymlinksInPath(), encoding: .utf8)) ?? ""
        let version = text.range(of: #"(?<=# version )\S+"#, options: .regularExpression).map { String(text[$0]) } ?? "?"
        lock.withLock { log.append(version) }
        return failing.contains(version) ? .failed("refused") : .passed
    }
}
