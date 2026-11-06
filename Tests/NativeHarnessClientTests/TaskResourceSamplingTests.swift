import AppKit
import Darwin
import Foundation
import Observation
import SwiftTerm
import XCTest
@testable import NativeHarnessClient

/// Task Resource Usage's sampler: CPU over a tree of processes from an injected process table, what
/// counts toward which task (Yardlet's own processes, the Claude processes other apps run, shared
/// Codex App Servers, terminal and bash-mode shells), the busy indicator's hysteresis, publication,
/// and the sampler's own cost on the real process table.
final class TaskResourceSamplingTests: XCTestCase {
    // MARK: - CPU over a tree

    func testCPUIsEachTreesChangeOverTheIntervalAndOnlyItsProcessesAreRead() {
        let table = FakeProcessTable()
        table.set(1, parent: 0)
        table.set(500, parent: 1)                       // Yardlet
        table.set(600, parent: 500, cpu: 1.0, memory: 100 << 20)   // the task's CLI
        table.set(601, parent: 600, cpu: 2.0, memory: 50 << 20)    // a test runner
        table.set(602, parent: 601, cpu: 0.5, memory: 10 << 20)    // its worker
        table.set(700, parent: 1, cpu: 50)              // someone else's process
        let task = UUID()
        let roots = [TaskResourceRoot(owner: .task(task), location: .yardlet, processID: 600)]
        var sampler = TaskResourceSampler()

        let first = sampler.sample(roots, table: table, at: Self.time(0))
        XCTAssertEqual(first.map(\.owner), [.task(task)])
        XCTAssertEqual(first[0].processCount, 3)
        XCTAssertEqual(first[0].memoryBytes, 160 << 20)
        XCTAssertNil(first[0].cpuNanoseconds, "A first sample has nothing to compare with")
        XCTAssertEqual(table.usageReads.sorted(), [600, 601, 602], "Only counted processes are read")

        table.addCPU(600, 0.3)
        table.addCPU(601, 2.4)
        table.addCPU(602, 0.3)
        table.addCPU(700, 3)
        let second = sampler.sample(roots, table: table, at: Self.time(3))
        XCTAssertEqual(second[0].cpuNanoseconds, 3_000_000_000)
        XCTAssertEqual(second[0].intervalNanoseconds, 3_000_000_000)
    }

    func testAProcessIDReusedBetweenSamplesIsAnotherProcess() {
        let table = FakeProcessTable()
        table.set(600, parent: 1, cpu: 1)
        table.set(601, parent: 600, cpu: 5)
        let roots = [TaskResourceRoot(owner: .task(UUID()), location: .yardlet, processID: 600)]
        var sampler = TaskResourceSampler()
        _ = sampler.sample(roots, table: table, at: Self.time(0))

        // 601 used one more second, ended, and its parent collected it; a new process took its ID.
        table.addEndedChildrenCPU(600, 6)
        table.set(601, parent: 600, start: Self.wall(2), cpu: 1)
        let second = sampler.sample(roots, table: table, at: Self.time(3))
        // The old 601's last second, through its parent, and the new 601's whole second.
        XCTAssertEqual(second[0].cpuNanoseconds, 2_000_000_000)
        XCTAssertEqual(second[0].processCount, 2)
    }

    func testEndedProcessesAreNeitherLostNorCountedTwice() {
        let table = FakeProcessTable()
        table.set(600, parent: 1, cpu: 1)
        table.set(601, parent: 600, cpu: 10)
        let task = UUID()
        let roots = [TaskResourceRoot(owner: .task(task), location: .yardlet, processID: 600)]
        var sampler = TaskResourceSampler()
        _ = sampler.sample(roots, table: table, at: Self.time(0))

        // 601 has ended and its usage cannot be read, but its parent has not collected it yet.
        table.setUsage(601, nil)
        XCTAssertEqual(sampler.sample(roots, table: table, at: Self.time(3))[0].cpuNanoseconds, 0)

        // Collected: its final 10.5 s move into the parent. Only the half second not yet seen counts.
        table.remove(601)
        table.addEndedChildrenCPU(600, 10.5)
        let collected = sampler.sample(roots, table: table, at: Self.time(6))
        XCTAssertEqual(collected[0].cpuNanoseconds, 500_000_000)
        XCTAssertEqual(collected[0].processCount, 1)

        // The task's process has ended: nothing is left to count.
        table.remove(600)
        XCTAssertEqual(sampler.sample(roots, table: table, at: Self.time(9)), [])
    }

    func testACommandThatStartsAndEndsBetweenSamplesCountsThroughItsParent() {
        let table = FakeProcessTable()
        table.set(600, parent: 1, cpu: 1)
        let roots = [TaskResourceRoot(owner: .task(UUID()), location: .yardlet, processID: 600)]
        var sampler = TaskResourceSampler()
        _ = sampler.sample(roots, table: table, at: Self.time(0))
        table.addEndedChildrenCPU(600, 2.4)
        let second = sampler.sample(roots, table: table, at: Self.time(3))
        XCTAssertEqual(second[0].cpuNanoseconds, 2_400_000_000)
    }

    /// A tree first found already running (another app's Claude process, seen once Yardlet starts)
    /// sets its baseline; its earlier CPU is not taken for a burst.
    func testATreeFoundAlreadyRunningStartsFromABaseline() {
        let table = FakeProcessTable()
        table.set(600, parent: 1, cpu: 1)
        table.set(800, parent: 1, cpu: 900)
        let a = TaskResourceRoot(owner: .task(UUID()), location: .yardlet, processID: 600)
        let b = TaskResourceRoot(owner: .task(UUID()), location: .claudeApp, processID: 800)
        var sampler = TaskResourceSampler()
        _ = sampler.sample([a], table: table, at: Self.time(0))
        table.addCPU(800, 1)
        let found = sampler.sample([a, b], table: table, at: Self.time(3))
        XCTAssertEqual(found.first { $0.owner == b.owner }?.cpuNanoseconds, nil)
        table.addCPU(800, 1.5)
        let next = sampler.sample([a, b], table: table, at: Self.time(6))
        XCTAssertEqual(next.first { $0.owner == b.owner }?.cpuNanoseconds, 1_500_000_000)
    }

    /// A registration whose process ended unnoticed is not followed into another process that took
    /// its ID later.
    func testARegisteredRootWhoseIDWasTakenIsNotFollowed() {
        let table = FakeProcessTable()
        table.set(600, parent: 1, cpu: 1)
        let roots = [TaskResourceRoot(owner: .task(UUID()), location: .yardlet, processID: 600)]
        var sampler = TaskResourceSampler()
        XCTAssertEqual(sampler.sample(roots, table: table, at: Self.time(0)).count, 1)
        table.remove(600)
        XCTAssertEqual(sampler.sample(roots, table: table, at: Self.time(3)).count, 0)
        table.set(600, parent: 1, start: Self.wall(5), cpu: 40)
        XCTAssertEqual(sampler.sample(roots, table: table, at: Self.time(6)).count, 0)
    }

    // MARK: - Attribution

    /// Claude processes other apps run, from fixture `sessions/<pid>.json` files: a task's
    /// conversation counts only through its own account's `sessions` folder (a Session Switch
    /// account links its folder to the shared one), a stale file whose ID another process took is
    /// skipped, as is a Claude process under Yardlet, and the Claude app is told apart by its
    /// `entrypoint`.
    func testClaudeProcessesAnotherAppRunsCountForTheTaskWithTheirConversation() async throws {
        let root = try temporaryFolder("claude-sessions")
        let shared = root.appending(path: "home/.claude", directoryHint: .isDirectory)
        let sessions = shared.appending(path: "sessions", directoryHint: .isDirectory)
        let accountA = root.appending(path: "accounts/a", directoryHint: .isDirectory)
        let accountB = root.appending(path: "accounts/b", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: accountA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: accountB.appending(path: "sessions"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: accountA.appending(path: "sessions"), withDestinationURL: sessions)

        let held = "6F1C2D3E-0000-4000-8000-00000000000A"
        let terminal = "6f1c2d3e-0000-4000-8000-00000000000b"
        let stale = "6f1c2d3e-0000-4000-8000-00000000000c"
        let underYardlet = "6f1c2d3e-0000-4000-8000-00000000000d"
        func register(_ pid: Int32, _ session: String, entrypoint: String, startedAt: Int64) throws {
            let value: JSONValue = .object([
                "pid": .integer(Int64(pid)), "sessionId": .string(session), "startedAt": .integer(startedAt),
                "entrypoint": .string(entrypoint), "kind": .string("interactive")
            ])
            try JSONEncoder().encode(value).write(to: sessions.appending(path: "\(pid).json"))
        }
        let started = Self.wall(-100)
        try register(600, held, entrypoint: "claude-desktop", startedAt: started / 1_000 + 400)
        try register(610, terminal, entrypoint: "cli", startedAt: started / 1_000)
        try register(620, stale, entrypoint: "claude-desktop", startedAt: started / 1_000 - 3_600_000)
        try register(630, underYardlet, entrypoint: "sdk-ts", startedAt: started / 1_000)
        try register(640, UUID().uuidString, entrypoint: "claude-desktop", startedAt: started / 1_000)
        try Data("{not json".utf8).write(to: sessions.appending(path: "650.json"))

        let table = FakeProcessTable()
        table.set(1, parent: 0)
        table.set(500, parent: 1)                       // Yardlet
        table.set(77, parent: 1)                        // the Claude app's wrapper
        table.set(600, parent: 77, start: started, cpu: 1, memory: 200 << 20)
        table.set(601, parent: 600, cpu: 30, memory: 80 << 20)     // pytest
        table.set(602, parent: 601, cpu: 30, memory: 80 << 20)     // a pytest worker
        table.set(610, parent: 1, start: started, cpu: 1)
        table.set(620, parent: 1, start: started, cpu: 1)
        table.set(630, parent: 500, start: started, cpu: 1)
        table.set(640, parent: 1, start: started, cpu: 1)

        let taskA = UUID(), taskB = UUID(), taskC = UUID(), taskD = UUID(), taskE = UUID()
        let request = TaskResourceRequest(claudeConversations: [
            ClaudeConversationReference(taskID: taskA, providerSessionID: held.lowercased(), configDirectory: accountA),
            ClaudeConversationReference(taskID: taskB, providerSessionID: terminal, configDirectory: shared),
            ClaudeConversationReference(taskID: taskC, providerSessionID: stale, configDirectory: shared),
            ClaudeConversationReference(taskID: taskD, providerSessionID: underYardlet, configDirectory: shared),
            // The same conversation ID under an account whose `sessions` is its own folder.
            ClaudeConversationReference(taskID: taskE, providerSessionID: held, configDirectory: accountB)
        ])
        let engine = TaskResourceEngine(table: table, registry: TaskProcessRegistry(), ownProcessID: 500,
                                        clock: { Self.time(0) })
        let usages = await engine.sample(request)
        XCTAssertEqual(usages.map(\.owner), [.task(taskA), .task(taskB)])
        XCTAssertEqual(usages[0].locations, [.claudeApp])
        XCTAssertEqual(usages[0].processCount, 3)
        XCTAssertEqual(usages[0].memoryBytes, 360 << 20)
        XCTAssertEqual(usages[1].locations, [.otherApp])
        XCTAssertEqual(usages[1].processCount, 1)
    }

    /// The CLI Yardlet starts for a Claude task registers under the task while it runs, and its tree
    /// (here the CLI and a command it started) counts toward the task on the real process table.
    func testTheClaudeCLIYardletStartsCountsWithItsChildrenForItsTask() async throws {
        let root = try temporaryFolder("claude-cli")
        let executable = try Self.parentWithChild(in: root)
        let registry = TaskProcessRegistry()
        let task = UUID()
        let transport = ClaudeProcessTransport(executableURL: executable, resourceOwner: .task(task),
                                               processRegistry: registry)
        try await transport.start(ClaudeLaunchConfiguration(providerSessionID: "s", workspaceURL: root,
                                                            resumesExistingSession: false))
        let pid = try XCTUnwrap(registry.registered.first?.key)
        XCTAssertEqual(registry.registered, [pid: .task(task)])

        let engine = TaskResourceEngine(table: LiveProcessTable(), registry: registry)
        let usage = try await Self.waitForTree(of: .task(task), processes: 2, engine: engine)
        XCTAssertEqual(usage.locations, [.yardlet])
        XCTAssertGreaterThan(usage.memoryBytes, 0)

        await transport.stop()
        XCTAssertTrue(registry.registered.isEmpty)
        let afterStop = await engine.sample(TaskResourceRequest())
        XCTAssertEqual(afterStop, [])
    }

    /// The App Server a Codex adapter starts is its own row for its account, whatever tasks share it.
    func testTheCodexAppServerIsItsOwnRowForItsAccount() async throws {
        let root = try temporaryFolder("codex-server")
        let executable = try Self.parentWithChild(in: root)
        let registry = TaskProcessRegistry()
        let account = ProviderConnection(id: "work", name: "Work", harness: .codex, providerID: nil,
                                         homePath: "/tmp/codex-work", credentialSelector: nil)
        let server = TaskResourceOwner.codexAppServer(CodexAppServerIdentity(connection: account,
                                                                               environmentScope: .native))
        let transport = CodexProcessTransport(executableURL: executable, resourceOwner: server,
                                              processRegistry: registry)
        try await transport.start()
        XCTAssertEqual(Array(registry.registered.values), [server])
        let engine = TaskResourceEngine(table: LiveProcessTable(), registry: registry)
        let usage = try await Self.waitForTree(of: server, processes: 2, engine: engine)
        XCTAssertEqual(usage.processCount, 2)
        await transport.stop()
        XCTAssertTrue(registry.registered.isEmpty)
    }

    /// The registry's Codex adapter starts its App Server under the account and scope it serves.
    func testTheRegistryNamesItsCodexAdaptersAppServer() async throws {
        let account = ProviderConnection(id: "work", name: "Work", harness: .codex, providerID: nil,
                                         homePath: "/tmp/codex-work", credentialSelector: nil)
        XCTAssertEqual(
            TaskResourceOwner.codexAppServer(CodexAppServerIdentity(connection: account, environmentScope: .native)),
            .codexAppServer(CodexAppServerIdentity(connection: account, environmentScope: .native))
        )
        XCTAssertNotEqual(
            TaskResourceOwner.codexAppServer(CodexAppServerIdentity(connection: nil, environmentScope: .native)),
            .codexAppServer(CodexAppServerIdentity(connection: account, environmentScope: .native))
        )
    }

    /// A task's terminal panel registers its shell under the task, and what the shell starts counts
    /// with it, a server it starts among the task's servers; stopping the panel removes it.
    @MainActor
    func testATasksTerminalShellCountsForTheTask() async throws {
        let home = try temporaryFolder("terminal-home")
        let task = UUID()
        let session = NativeTerminalSession(workspaceURL: home, launch: .isolatedZsh(in: home), taskID: task)
        let view = LocalProcessTerminalView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 300),
            font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            options: TerminalOptions(cursorStyle: .steadyBlock, scrollback: 100)
        )
        session.attach(view)
        defer { session.stop() }
        let shellPID = try XCTUnwrap(session.process?.shellPid)
        XCTAssertEqual(TaskProcessRegistry.shared.registered[shellPID], .task(task))

        let listener = try Self.listener(in: home)
        _ = await session.typeWhenReady("/usr/bin/python3 '\(listener.path)' '\(home.path)/port' &\n")
        let engine = TaskResourceEngine(table: LiveProcessTable(), registry: TaskProcessRegistry.shared)
        let usage = try await Self.waitForTree(of: .task(task), processes: 2, engine: engine)
        XCTAssertEqual(usage.locations, [.yardlet])
        let port = try await Self.listening(home.appending(path: "port"))
        let sample = await engine.takeSample(TaskResourceRequest(findsServers: true))
        XCTAssertEqual(sample.servers[task]?.map(\.port), [port.port])
        XCTAssertEqual(sample.servers[task]?.map(\.processID), [port.processID])

        session.stop()
        XCTAssertNil(TaskProcessRegistry.shared.registered[shellPID])
    }

    /// Each task's bash-mode shell is a root of its task's tree.
    @MainActor
    func testATasksBashModeShellIsARootOfItsTask() async {
        let shells = TaskShells(launch: .userLoginShell()) { folder, _ in FakeShell(workingDirectory: folder) }
        let task = UUID(), other = UUID()
        _ = shells.command("true", for: task, in: URL(filePath: "/tmp"))
        _ = shells.command("true", for: other, in: URL(filePath: "/tmp"))
        (shells.shell(for: task) as? FakeShell)?.processID = 4_242
        (shells.shell(for: other) as? FakeShell)?.isAlive = false
        (shells.shell(for: other) as? FakeShell)?.processID = 4_343
        XCTAssertEqual(shells.processIDs(), [task: 4_242])

        let table = FakeProcessTable()
        table.set(4_242, parent: 1, cpu: 1)
        table.set(4_250, parent: 4_242, cpu: 1)
        let engine = TaskResourceEngine(table: table, registry: TaskProcessRegistry(), clock: { Self.time(0) })
        let usages = await engine.sample(TaskResourceRequest(shells: shells.processIDs()))
        XCTAssertEqual(usages.map(\.owner), [.task(task)])
        XCTAssertEqual(usages.first?.processCount, 2)
    }

    /// The real bash-mode shell reports its process while it runs.
    @MainActor
    func testTheBashModeShellReportsItsProcess() async throws {
        let home = try temporaryFolder("bash-home")
        let shell = TaskShellProcess(workingDirectory: home, launch: .isolatedZsh(in: home))
        defer { shell.close() }
        XCTAssertEqual(shell.processID, 0)
        let command = shell.command("true", note: nil)
        let finished = expectation(description: "finished")
        command.onFinish = { _ in finished.fulfill() }
        command.start()
        await fulfillment(of: [finished], timeout: 30)
        XCTAssertGreaterThan(shell.processID, 0)
        XCTAssertEqual((shell as any TaskShell).processID, shell.processID)
    }

    // MARK: - Servers

    /// A port belongs to the task whose Yardlet-started tree listens on it: not the harness or shell at
    /// the root, not a process another app runs, and under a shared Codex App Server only through the
    /// `CODEX_THREAD_ID` the command's process or its nearest ancestor carries. A server its shell left to
    /// launchd is the task's whose Yardlet Claude conversation or Codex thread its environment names. A
    /// port the server and its worker share is listed once, for the process nearer the task.
    func testAPortBelongsToTheTaskWhoseProcessesListenOnIt() {
        let table = FakeProcessTable()
        let yardletClaude = ["CLAUDE_CODE_ENTRYPOINT": "native-harness-client"]
        table.set(1, parent: 0)                                 // launchd
        table.set(500, parent: 1)                               // Yardlet
        table.set(600, parent: 500, ports: [9_000])             // task A's Claude Code CLI
        table.set(601, parent: 600, ports: [3_000], name: "node")
        table.set(602, parent: 601, ports: [3_000], name: "node")
        table.set(700, parent: 1)                               // the Claude app's CLI for task B
        table.set(701, parent: 700, ports: [4_000])
        table.set(800, parent: 500)                             // a Codex App Server
        table.set(801, parent: 800, environment: ["CODEX_THREAD_ID": "Thread-C"])
        table.set(802, parent: 801, ports: [5_173], name: "vite")
        table.set(803, parent: 800, ports: [7_000])             // its MCP server
        table.set(804, parent: 800, ports: [8_000], environment: ["CODEX_THREAD_ID": "elsewhere"])
        table.set(900, parent: 500)                             // task A's terminal shell
        table.set(901, parent: 900, ports: [6_006], name: "storybook")
        // Left to launchd when their shells ended.
        table.set(1_000, parent: 1, ports: [55_433], environment: yardletClaude.merging(
            ["CLAUDE_CODE_SESSION_ID": "Session-A"]) { $1 }, name: "postgres")
        table.set(1_001, parent: 1, ports: [5_437], environment: [
            "CLAUDE_CODE_ENTRYPOINT": "claude-desktop", "CLAUDE_CODE_SESSION_ID": "session-a"])
        table.set(1_002, parent: 1, environment: ["CODEX_THREAD_ID": "thread-c"])
        table.set(1_003, parent: 1_002, ports: [8_080], name: "python3")
        table.set(1_004, parent: 1, ports: [9_999])
        let taskA = UUID(), taskB = UUID(), taskC = UUID()
        let server = TaskResourceOwner.codexAppServer(CodexAppServerIdentity(connection: nil, environmentScope: .native))
        var sampler = TaskResourceSampler()
        _ = sampler.sample([
            TaskResourceRoot(owner: .task(taskA), location: .yardlet, processID: 600),
            TaskResourceRoot(owner: .task(taskB), location: .claudeApp, processID: 700),
            TaskResourceRoot(owner: server, location: .yardlet, processID: 800),
            TaskResourceRoot(owner: .task(taskA), location: .yardlet, processID: 900)
        ], table: table, at: Self.time(0))

        var finder = TaskServerFinder()
        let servers = finder.servers(
            descendants: sampler.yardletDescendants, entries: sampler.lastEntries, claimed: sampler.claimedProcessIDs,
            table: table, claudeSessions: ["session-a": taskA, "session-b": taskB], codexThreads: ["thread-c": taskC])
        XCTAssertEqual(servers, [
            taskA: [TaskServerPort(port: 3_000, processID: 601, processName: "node"),
                    TaskServerPort(port: 6_006, processID: 901, processName: "storybook"),
                    TaskServerPort(port: 55_433, processID: 1_000, processName: "postgres")],
            taskC: [TaskServerPort(port: 5_173, processID: 802, processName: "vite"),
                    TaskServerPort(port: 8_080, processID: 1_003, processName: "python3")]
        ])
    }

    /// On the real process table, through the kernel's socket and environment readings: a Codex App
    /// Server's command that listens on a loopback port is its thread's task's, and so is one whose shell
    /// ended and left it to launchd; a listener on no thread is no task's; nothing is read when the request
    /// does not ask.
    func testRealListenersOfACodexThreadAreFoundForItsTask() async throws {
        let root = try temporaryFolder("codex-servers")
        let listener = try Self.listener(in: root)
        let executable = root.appending(path: "stand-in")
        try Data("""
            #!/bin/sh
            CODEX_THREAD_ID=Thread-1 /usr/bin/python3 '\(listener.path)' '\(root.path)/child' &
            /bin/sh -c "CODEX_THREAD_ID=Thread-1 /usr/bin/python3 '\(listener.path)' '\(root.path)/left' &"
            /usr/bin/python3 '\(listener.path)' '\(root.path)/unowned' &
            exec /bin/cat >/dev/null

            """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let registry = TaskProcessRegistry()
        let server = TaskResourceOwner.codexAppServer(CodexAppServerIdentity(connection: nil, environmentScope: .native))
        let transport = CodexProcessTransport(executableURL: executable, resourceOwner: server, processRegistry: registry)
        try await transport.start()
        addTeardownBlock { await transport.stop() }

        let child = try await Self.listening(root.appending(path: "child"))
        let left = try await Self.listening(root.appending(path: "left"))
        let unowned = try await Self.listening(root.appending(path: "unowned"))
        // The one the ended shell left to launchd is out of the server's tree; the test ends it itself.
        addTeardownBlock { _ = Darwin.kill(left.processID, SIGKILL) }
        XCTAssertEqual(LiveProcessTable().entries().first { $0.processID == left.processID }?.parentID, 1)

        let task = UUID()
        let request = TaskResourceRequest(findsServers: true, codexThreads: ["thread-1": task])
        let engine = TaskResourceEngine(table: LiveProcessTable(), registry: registry)
        let sample = await engine.takeSample(request)
        XCTAssertEqual(Set(sample.servers.keys), [task])
        XCTAssertEqual(sample.servers[task]?.map(\.port), [child.port, left.port].sorted())
        XCTAssertEqual(Set(sample.servers[task]?.map(\.processID) ?? []), [child.processID, left.processID])
        XCTAssertFalse(sample.servers[task]?.contains { $0.port == unowned.port } ?? true)
        XCTAssertEqual(sample.servers[task]?.first?.processName.isEmpty, false)
        let notAsked = await engine.takeSample(TaskResourceRequest(codexThreads: ["thread-1": task]))
        XCTAssertEqual(notAsked.servers, [:])
    }

    // MARK: - Busy indicator

    /// On at 50 % over a nearly full ten seconds, off below 25 %: a load between the two does not
    /// switch it, and a short burst does not light it.
    func testTheBusyIndicatorHasHysteresis() {
        var averager = TaskResourceAverager()
        let owner = TaskResourceOwner.task(UUID())
        func feed(_ percent: Double, seconds: Double = 3) -> TaskResourceUsage {
            let interval = UInt64(seconds * 1_000_000_000)
            return averager.update([TaskResourceMeasurement(
                owner: owner, locations: [.claudeApp], processCount: 3, memoryBytes: 0,
                cpuNanoseconds: UInt64(Double(interval) * percent / 100), intervalNanoseconds: interval
            )])[0]
        }
        XCTAssertNil(averager.update([TaskResourceMeasurement(owner: owner, locations: [], processCount: 1,
                                                              memoryBytes: 0)])[0].cpuPercent)
        XCTAssertFalse(feed(300).isBusy, "Three seconds are not enough to call it sustained")
        var calm = TaskResourceAverager()
        for percent in [100.0, 0, 0, 0] {
            let usage = calm.update([TaskResourceMeasurement(
                owner: owner, locations: [], processCount: 1, memoryBytes: 0,
                cpuNanoseconds: UInt64(30_000_000 * percent), intervalNanoseconds: 3_000_000_000
            )])[0]
            XCTAssertFalse(usage.isBusy, "One core busy for three seconds averages at most a third of the window")
        }

        // A steady 60 % fills the window (the newest samples covering ten seconds: four of three
        // seconds) and lights it.
        for _ in 0..<3 { _ = feed(0) }
        XCTAssertFalse(feed(60).isBusy)
        XCTAssertFalse(feed(60).isBusy)
        XCTAssertFalse(feed(60).isBusy)
        let lit = feed(60)
        XCTAssertTrue(lit.isBusy)
        XCTAssertEqual(lit.cpuPercent ?? 0, 60, accuracy: 0.01)

        var switches = 0
        var wasBusy = true
        for percent in [30.0, 45, 28, 40, 35, 30, 48, 26] {
            let usage = feed(percent)
            if usage.isBusy != wasBusy { switches += 1 }
            wasBusy = usage.isBusy
        }
        XCTAssertEqual(switches, 0, "Between the thresholds it stays on")
        for _ in 0..<4 { _ = feed(10) }
        XCTAssertFalse(feed(10).isBusy)
        for percent in [45.0, 40, 48, 35, 45, 40] {
            XCTAssertFalse(feed(percent).isBusy, "Between the thresholds it stays off")
        }

        // In the background a sample covers ten seconds on its own.
        var background = TaskResourceAverager()
        let hot = TaskResourceMeasurement(owner: owner, locations: [], processCount: 1, memoryBytes: 0,
                                          cpuNanoseconds: 9_000_000_000, intervalNanoseconds: 10_000_000_000)
        XCTAssertTrue(background.update([hot])[0].isBusy)
    }

    func testCollapsedAndSplitRowsSumTheirBusyTasks() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertNil(SidebarTaskIndicatorProjection.cpuPercent(for: [a], busyCPU: [:]))
        XCTAssertNil(SidebarTaskIndicatorProjection.cpuPercent(for: [c], busyCPU: [a: 120]))
        XCTAssertEqual(SidebarTaskIndicatorProjection.cpuPercent(for: [a, b, c], busyCPU: [a: 120, b: 64]), 184)
    }

    // MARK: - Publication

    @MainActor
    func testTheMonitorPublishesOnlyWhatSomeoneCanSee() {
        let monitor = TaskResourceMonitor(table: FakeProcessTable())
        let heavy = UUID(), idle = UUID(), gone = UUID()
        let server = TaskResourceOwner.codexAppServer(CodexAppServerIdentity(connection: nil, environmentScope: .native))
        monitor.describe = { owner in
            switch owner {
            case .task(heavy): (.claudeCode, "Run the test suite")
            case .task(idle): (.claudeCode, "Idle")
            case .task: nil
            case .codexAppServer: (.codex, "Codex App Server · Default")
            }
        }
        func usages(cpu: Double, memory: UInt64, count: Int = 81) -> [TaskResourceUsage] {
            [TaskResourceUsage(owner: .task(idle), locations: [.yardlet], processCount: 1, memoryBytes: 90 << 20,
                               cpuPercent: 0.4, isBusy: false),
             TaskResourceUsage(owner: server, locations: [.yardlet], processCount: 2, memoryBytes: 40 << 20,
                               cpuPercent: 2, isBusy: false),
             TaskResourceUsage(owner: .task(heavy), locations: [.claudeApp], processCount: count, memoryBytes: memory,
                               cpuPercent: cpu, isBusy: true),
             TaskResourceUsage(owner: .task(gone), locations: [.yardlet], processCount: 3, memoryBytes: 1,
                               cpuPercent: 99, isBusy: true)]
        }
        monitor.apply(usages(cpu: 1_412.04, memory: 6 << 30))
        XCTAssertEqual(monitor.rows.map(\.title), ["Run the test suite", "Codex App Server · Default", "Idle"])
        XCTAssertEqual(monitor.rows.first?.cpuPercent, 1_412.0)
        XCTAssertEqual(monitor.rows.first?.location, L10n.string("Claude app"))
        XCTAssertEqual(monitor.busyTaskCPU, [heavy: 1_412], "A task the app no longer lists is left out")

        let publications = PublicationCounter()
        withObservationTracking { _ = monitor.rows; _ = monitor.busyTaskCPU } onChange: { publications.add() }
        monitor.apply(usages(cpu: 1_412.01, memory: (6 << 30) + 100_000))
        XCTAssertEqual(publications.count, 0, "Less than a tenth of a percent and a MiB is not published")
        monitor.apply(usages(cpu: 1_412.01, memory: 6 << 30, count: 82))
        XCTAssertEqual(publications.count, 1)
    }

    /// A sidebar row reads its own task's busy CPU, so a sample that changes another task's CPU,
    /// or makes another task busy, leaves the row alone; its own task's change reaches it.
    @MainActor
    func testARowReadingOneTasksBusyCPUIsToldOnlyOfThatTask() {
        let monitor = TaskResourceMonitor(table: FakeProcessTable())
        let mine = UUID(), other = UUID(), newcomer = UUID()
        monitor.describe = { _ in (.claudeCode, "Task") }
        func sample(_ cpu: [UUID: Double]) {
            monitor.apply(cpu.map { id, percent in
                TaskResourceUsage(owner: .task(id), locations: [.yardlet], processCount: 2, memoryBytes: 1 << 26,
                                  cpuPercent: percent, isBusy: true)
            })
        }
        sample([mine: 80, other: 120])
        XCTAssertEqual(monitor.busyCPU(of: [mine]), [mine: 80])
        XCTAssertEqual(monitor.busyCPU(of: [mine, other, newcomer]), [mine: 80, other: 120])

        let told = PublicationCounter()
        withObservationTracking { _ = monitor.busyCPU(of: [mine]) } onChange: { told.add() }
        sample([mine: 80, other: 150])
        sample([mine: 80, other: 150, newcomer: 90])
        XCTAssertEqual(told.count, 0, "Another task's CPU reached the row")
        sample([mine: 95, other: 150, newcomer: 90])
        XCTAssertEqual(told.count, 1)
        XCTAssertEqual(monitor.busyTaskCPU, [mine: 95, other: 150, newcomer: 90])
        sample([other: 150])
        XCTAssertEqual(monitor.busyCPU(of: [mine]), [:], "A task no longer busy is absent")
    }

    @MainActor
    func testACodexAppServerRowNamesItsAccount() {
        let account = ProviderConnection(id: "work", name: "Work", harness: .codex, providerID: nil,
                                         homePath: "/tmp/codex-work", credentialSelector: nil)
        let codexTask = SessionRecord(harness: .codex, workspaceURL: URL(filePath: "/tmp/w"),
                                      runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Codex task")
        let model = AppModel(store: SessionStore(sessions: [codexTask]),
                             runtimeSelections: RuntimeSelectionStore(discoversRuntimes: false),
                             restoresIndexOnLaunch: false)
        let owner = TaskResourceOwner.codexAppServer(CodexAppServerIdentity(connection: account, environmentScope: .native))
        XCTAssertEqual(model.taskResourceDescription(owner)?.title, L10n.format("Codex App Server · %@", "Work"))
        XCTAssertEqual(model.taskResourceDescription(.task(codexTask.id))?.title, "Codex task")
        XCTAssertNil(model.taskResourceDescription(.task(UUID())))
        XCTAssertFalse(model.resourceMonitor.isRunning, "Only the app starts the sampler")
    }

    // MARK: - The real process table

    /// The live table reads CPU in nanoseconds (the Mach timebase converted), the footprint, and
    /// the parent of each process.
    func testTheLiveTableReadsThisProcess() throws {
        let table = LiveProcessTable()
        let pid = getpid()
        let entry = try XCTUnwrap(table.entries().first { $0.processID == pid })
        XCTAssertEqual(entry.parentID, getppid())
        let before = try XCTUnwrap(table.usage(of: pid))
        let cpuBefore = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
        var spin: UInt64 = 0
        let deadline = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) + 200_000_000
        while clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) < deadline { spin &+= 1 }
        let used = Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - cpuBefore)
        let after = try XCTUnwrap(table.usage(of: pid))
        XCTAssertGreaterThan(spin, 0)
        let read = Double(after.cpuNanoseconds - before.cpuNanoseconds)
        XCTAssertEqual(read / used, 1, accuracy: 0.2, "read \(read) ns, used \(used) ns")
        XCTAssertGreaterThan(after.memoryBytes, 1 << 20)
    }

    /// One sample of the real process table, with the bookkeeping it does, takes a few milliseconds
    /// of the sampler's own CPU. Written to `.build/resource-usage-qa/sampler-cost.txt`.
    func testTheSamplerCostsAFewMillisecondsASample() throws {
        let folder = try temporaryFolder("sampler-cost")
        let sessions = folder.appending(path: "sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        for pid in 0..<40 {
            let value: JSONValue = .object(["pid": .integer(Int64(90_000 + pid)), "sessionId": .string(UUID().uuidString),
                                            "startedAt": .integer(1_791_888_357_555), "entrypoint": .string("claude-desktop")])
            try JSONEncoder().encode(value).write(to: sessions.appending(path: "\(90_000 + pid).json"))
        }
        let table = LiveProcessTable()
        let roots = [TaskResourceRoot(owner: .task(UUID()), location: .yardlet, processID: getpid())]
        var sampler = TaskResourceSampler()
        var reader = ClaudeSessionRegistryReader()
        var averager = TaskResourceAverager()
        let samples = 30
        var cpu: [UInt64] = []
        var wall: [UInt64] = []
        let processes = table.entries().count
        for _ in 0..<samples {
            let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let wallStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            _ = reader.sessions(in: sessions)
            _ = averager.update(sampler.sample(roots, table: table, at: .now()))
            cpu.append(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart)
            wall.append(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - wallStart)
        }
        // The first sample warms caches; the median of the rest is what each tick costs.
        func median(_ values: [UInt64]) -> Double { Double(values.dropFirst().sorted()[(values.count - 1) / 2]) / 1e6 }
        let report = String(format: "processes %d, samples %d, CPU median %.2f ms (max %.2f), wall median %.2f ms (max %.2f)\n"
                            + "each sample: 40 registered Claude session files, one process table read, this process's tree\n",
                            processes, samples, median(cpu), Double(cpu.dropFirst().max() ?? 0) / 1e6,
                            median(wall), Double(wall.dropFirst().max() ?? 0) / 1e6)
        try report.write(to: WindowlessRenderPaths.directory("resource-usage-qa").appending(path: "sampler-cost.txt"),
                         atomically: true, encoding: .utf8)
        print(report)
        XCTAssertLessThan(median(cpu), 15, report)
    }

    /// Opt-in, read-only: `NHC_RESOURCE_LIVE=1` prints how the Claude processes registered in
    /// `~/.claude/sessions` and their trees count, as counts, CPU and memory only, without titles,
    /// conversation IDs or command lines.
    func testLiveAttributionOfRegisteredClaudeProcesses() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NHC_RESOURCE_LIVE"] == "1",
                          "Set NHC_RESOURCE_LIVE=1 to read this Mac's Claude processes")
        let config = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude", directoryHint: .isDirectory)
        var reader = ClaudeSessionRegistryReader()
        let registered = reader.sessions(in: config.appending(path: "sessions").resolvingSymlinksInPath())
        let references = registered.map {
            ClaudeConversationReference(taskID: UUID(), providerSessionID: $0.sessionID, configDirectory: config)
        }
        let engine = TaskResourceEngine(table: LiveProcessTable(), registry: TaskProcessRegistry())
        let request = TaskResourceRequest(claudeConversations: references)
        _ = await engine.sample(request)
        try await Task.sleep(for: .seconds(3))
        let usages = await engine.sample(request).sorted { ($0.cpuPercent ?? 0) > ($1.cpuPercent ?? 0) }
        var lines = ["registered files \(registered.count), counted trees \(usages.count)"]
        for (index, usage) in usages.enumerated() {
            lines.append(String(format: "#%d %@ processes %d CPU %.1f%% memory %.0f MB", index + 1,
                                usage.locations.map { "\($0)" }.sorted().joined(separator: "+"), usage.processCount,
                                usage.cpuPercent ?? -1, Double(usage.memoryBytes) / 1_048_576))
        }
        print(lines.joined(separator: "\n"))
    }

    // MARK: - Helpers

    private static let baseWall: Int64 = 1_791_888_000_000_000

    static func wall(_ seconds: Double) -> Int64 { baseWall + Int64(seconds * 1_000_000) }

    static func time(_ seconds: Double) -> TaskResourceSampleTime {
        TaskResourceSampleTime(uptimeNanoseconds: 1_000_000_000_000 + UInt64(seconds * 1_000_000_000),
                               wallMicroseconds: wall(seconds))
    }

    /// A new folder under the temporary directory, removed after the test.
    func temporaryFolder(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "nhc-resource-\(name)-\(UUID().uuidString)",
                                                                       directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.resolvingSymlinksInPath()
    }

    /// A stand-in CLI that starts one child and then waits for its input to close.
    static func parentWithChild(in folder: URL) throws -> URL {
        let executable = folder.appending(path: "stand-in")
        try Data("#!/bin/sh\n/bin/sleep 30 &\nexec /bin/cat >/dev/null\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    /// A Python script that listens on a free loopback port and writes "<port> <pid>" to the file its
    /// argument names, then waits a minute.
    static func listener(in folder: URL) throws -> URL {
        let script = folder.appending(path: "listen.py")
        try Data("""
            import os, socket, sys, time
            s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen()
            open(sys.argv[1] + ".part", "w").write("%d %d" % (s.getsockname()[1], os.getpid()))
            os.rename(sys.argv[1] + ".part", sys.argv[1])
            time.sleep(60)

            """.utf8).write(to: script)
        return script
    }

    /// The port and process a `listener` wrote to `file`, once it has.
    static func listening(_ file: URL) async throws -> (port: Int, processID: Int32) {
        let deadline = ContinuousClock.now + testWaitLimit
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: file, encoding: .utf8) {
                let parts = text.split(separator: " ").compactMap { Int($0) }
                if parts.count == 2 { return (parts[0], Int32(parts[1])) }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: file.path])
    }

    static func waitForTree(of owner: TaskResourceOwner, processes: Int, engine: TaskResourceEngine) async throws
        -> TaskResourceUsage {
        let deadline = ContinuousClock.now + testWaitLimit
        var last: TaskResourceUsage?
        while ContinuousClock.now < deadline {
            last = await engine.sample(TaskResourceRequest()).first { $0.owner == owner }
            if let last, last.processCount >= processes { return last }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try XCTUnwrap(last.flatMap { $0.processCount >= processes ? $0 : nil },
                             "\(owner) had \(last?.processCount ?? 0) processes")
    }
}

private final class PublicationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
}

/// `WindowlessRender.directory` without the main actor, for files written next to the renders.
enum WindowlessRenderPaths {
    static func directory(_ folder: String) throws -> URL {
        let directory = WindowlessRender.repositoryRoot.appending(path: ".build/\(folder)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// A process table a test writes: each process's parent, start and usage.
final class FakeProcessTable: ProcessTableReading, @unchecked Sendable {
    private struct Process {
        var parent: Int32
        var start: Int64
        var usage: ProcessUsageReading?
        var ports: [Int] = []
        var environment: [String: String] = [:]
        var name: String?
    }

    private let lock = NSLock()
    private var processes: [Int32: Process] = [:]
    private var reads: [Int32] = []

    var usageReads: [Int32] { lock.withLock { reads } }

    func set(_ pid: Int32, parent: Int32, start: Int64 = TaskResourceSamplingTests.wall(-1_000),
             cpu: Double = 0, memory: UInt64 = 0, ports: [Int] = [], environment: [String: String] = [:],
             name: String? = nil) {
        lock.withLock {
            processes[pid] = Process(parent: parent, start: start, usage: ProcessUsageReading(
                cpuNanoseconds: UInt64(cpu * 1_000_000_000), memoryBytes: memory),
                ports: ports, environment: environment, name: name)
        }
    }

    func listeningPorts(of processID: Int32) -> [Int] {
        lock.withLock { processes[processID]?.ports ?? [] }
    }

    func environment(_ names: Set<String>, of processID: Int32) -> [String: String] {
        lock.withLock { processes[processID]?.environment.filter { names.contains($0.key) } ?? [:] }
    }

    func name(of processID: Int32) -> String? {
        lock.withLock { processes[processID]?.name }
    }

    func setUsage(_ pid: Int32, _ usage: ProcessUsageReading?) {
        lock.withLock { processes[pid]?.usage = usage }
    }

    func addCPU(_ pid: Int32, _ seconds: Double) {
        lock.withLock { processes[pid]?.usage?.cpuNanoseconds += UInt64(seconds * 1_000_000_000) }
    }

    func addEndedChildrenCPU(_ pid: Int32, _ seconds: Double) {
        lock.withLock { processes[pid]?.usage?.endedChildrenCPUNanoseconds += UInt64(seconds * 1_000_000_000) }
    }

    func remove(_ pid: Int32) {
        lock.withLock { processes[pid] = nil }
    }

    func entries() -> [ProcessTableEntry] {
        lock.withLock {
            reads = []
            return processes.sorted { $0.key < $1.key }.map {
                ProcessTableEntry(processID: $0.key, parentID: $0.value.parent, startMicroseconds: $0.value.start)
            }
        }
    }

    func usage(of processID: Int32) -> ProcessUsageReading? {
        lock.withLock {
            reads.append(processID)
            return processes[processID]?.usage
        }
    }
}

@MainActor
private final class FakeShell: TaskShell {
    let workingDirectory: URL
    var isAlive = true
    var wasReset = false
    var hasOwnProcesses = false
    var isRunningCommand = false
    var processID: Int32 = 0

    init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
    }

    func command(_ command: String, note: String?) -> any ShellCommandRunning { FakeCommand() }
    func close() { isAlive = false }
}

@MainActor
private final class FakeCommand: ShellCommandRunning {
    var onOutput: ((String) -> Void)?
    var onFinish: ((ShellCommandResult) -> Void)?
    func start() {}
    func stop() {}
    func terminate() {}
}
