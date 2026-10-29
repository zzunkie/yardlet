import XCTest
@testable import NativeHarnessClient

/// Claude account folders that share one conversation folder (the Session Switch layout): plan
/// usage from the CLI, continuing a task under another signed-in account, and moving every task of
/// an account to another folder of it before it leaves the list.
@MainActor final class ClaudeAccountFolderTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    func testUsageRowsKeepEachWindowAndModelLimit() throws {
        let response = try json(#"""
        {"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":3},"limits":[
          {"kind":"session","group":"session","percent":2,"resets_at":"2026-10-06T18:00:00.123456+00:00"},
          {"kind":"weekly_all","group":"weekly","percent":95,"resets_at":"2026-10-12T05:00:00+00:00"},
          {"kind":"weekly_scoped","group":"weekly","percent":3,"scope":{"model":{"id":null,"display_name":"Fable"}}},
          {"kind":"spend","group":"monthly","percent":10}]}}
        """#)
        let usage = try XCTUnwrap(ClaudeUsageProbe.usage(from: response))
        XCTAssertEqual(usage.map(\.label), [
            HarnessAccountBroker.usageWindowLabel(minutes: 300, fallback: ""),
            HarnessAccountBroker.usageWindowLabel(minutes: 10_080, fallback: ""),
            "Fable · " + HarnessAccountBroker.usageWindowLabel(minutes: 10_080, fallback: "")
        ], "The newer rows win and an unknown window is not shown as a plan limit")
        XCTAssertEqual(usage.map(\.usedFraction), [0.02, 0.95, 0.03])
        XCTAssertEqual(usage[0].resetsAt, Date(timeIntervalSince1970: 1_791_309_600))
        XCTAssertEqual(usage[1].resetsAt, Date(timeIntervalSince1970: 1_791_781_200))
        XCTAssertNil(usage[2].resetsAt)
        XCTAssertTrue(usage.allSatisfy { $0.evidence == .exactQuota })
    }

    func testOlderUsageObjectsAndLoginsWithoutPlanLimits() throws {
        let older = try json(#"""
        {"rate_limits":{"five_hour":{"utilization":40,"resets_at":null},"seven_day":{"utilization":100},
          "model_scoped":[{"display_name":"Fable","utilization":7}]}}
        """#)
        XCTAssertEqual(ClaudeUsageProbe.usage(from: older)?.map(\.usedFraction), [0.4, 1, 0.07])
        XCTAssertNil(ClaudeUsageProbe.usage(from: try json(#"{"rate_limits_available":false,"rate_limits":null}"#)))
        XCTAssertNil(ClaudeUsageProbe.usage(from: nil))
    }

    func testUsageProbeAsksTheCLIFromAPrivateFolderWithoutAModelRequest() async throws {
        let root = try directory()
        let record = root.appending(path: "record")
        let cli = try script(root, """
        printf '%s|%s|%s\\n' "$PWD" "${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC-unset}" "$*" > "$PROBE_RECORD"
        read first; read second
        printf '%s\\n%s\\n' "$first" "$second" >> "$PROBE_RECORD"
        echo '{"type":"control_response","response":{"subtype":"success","request_id":"init","response":{}}}'
        echo '{"type":"control_response","response":{"subtype":"success","request_id":"usage","response":{"rate_limits_available":true,"rate_limits":{"seven_day":{"utilization":25}}}}}'
        sleep 30
        """)
        let usage = try await ClaudeUsageProbe.read(executableURL: cli, environment: [
            "PROBE_RECORD": record.path, "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"])
        XCTAssertEqual(usage?.map(\.usedFraction), [0.25])
        let lines = try String(contentsOf: record, encoding: .utf8).split(separator: "\n").map(String.init)
        let fields = lines[0].split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        XCTAssertTrue(fields[0].contains("Yardlet-ClaudeUsage-"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fields[0]), "The private folder is removed")
        XCTAssertEqual(fields[1], "unset")
        XCTAssertTrue(fields[2].contains("--strict-mcp-config"))
        XCTAssertEqual(lines.dropFirst().map { try? json($0)["request"]?["subtype"]?.stringValue }, ["initialize", "get_usage"])
    }

    func testOnlyAccountsSharingTheConversationFolderCanTakeOverATask() throws {
        let shared = try directory()
        let projects = shared.appending(path: "projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let first = try account(linkingTo: projects), second = try account(linkingTo: projects)
        let separate = try directory()
        try FileManager.default.createDirectory(at: separate.appending(path: "projects"), withIntermediateDirectories: true)
        let missing = try directory()
        let session = SessionRecord(harness: .claudeCode, workspaceURL: shared,
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Task", connection: connection(first))

        XCTAssertTrue(ClaudeConversationStorage.isShared(connection(first), connection(second)))
        XCTAssertTrue(ClaudeConversationStorage.isShared(connection(shared), connection(second)),
            "The folder that owns the history shares it with every account linked to it")
        XCTAssertFalse(ClaudeConversationStorage.isShared(connection(first), connection(separate)))
        XCTAssertFalse(ClaudeConversationStorage.isShared(connection(missing), connection(missing)))
        XCTAssertTrue(TaskAccountSwitch.allows(connection(second), for: session))
        XCTAssertFalse(TaskAccountSwitch.allows(connection(separate), for: session))
        XCTAssertFalse(TaskAccountSwitch.allows(ProviderConnection(id: "pi", name: "Pi", harness: .pi, providerID: nil,
            homePath: second.path, credentialSelector: nil), for: session))
    }

    func testSwitchResumesTheSameSessionOnlyUnderASignedInSharedAccount() async throws {
        let shared = try directory()
        let projects = shared.appending(path: "projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let first = try account(linkingTo: projects, signedIn: true)
        let signedOut = try account(linkingTo: projects, signedIn: false)
        let next = try account(linkingTo: projects, signedIn: true)
        let separate = try directory()
        try FileManager.default.createDirectory(at: separate.appending(path: "projects"), withIntermediateDirectories: true)
        try Data().write(to: separate.appending(path: ".signed-in"))
        let cli = try script(shared, """
        if [ "$1" = "auth" ] && [ -f "$CLAUDE_CONFIG_DIR/.signed-in" ]; then echo '{"loggedIn":true}'; else echo '{"loggedIn":false}'; fi
        """)
        let adapters = AdapterLog()
        let model = AppModel(store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(discoversRuntimes: false),
            registry: HarnessRegistry { kind, _ in adapters.make(kind) }, restoresIndexOnLaunch: false)
        addTeardownBlock { await model.shutdown() }
        let created = await model.createSession(harness: .claudeCode, workspaceURL: shared, runtimeExecutableURL: cli,
            title: "Task", connection: connection(first))
        let task = try XCTUnwrap(created, model.errorBySessionID.values.first ?? "Missing task")
        let providerID = try XCTUnwrap(task.providerSessionID)
        model.composerDrafts.tasks.draft(for: task.id).text = "Keep my draft"

        await model.switchAccount(to: connection(separate), for: task)
        XCTAssertEqual(model.store.sessions.first?.connection, connection(first), "Another history folder is refused")
        XCTAssertNil(model.errorBySessionID[task.id])

        await model.switchAccount(to: connection(next), for: task)
        let switched = try XCTUnwrap(model.store.sessions.first)
        XCTAssertNil(model.errorBySessionID[task.id])
        XCTAssertEqual(switched.connection, connection(next))
        XCTAssertEqual(switched.providerSessionID, providerID)
        XCTAssertEqual(model.composerDrafts.tasks.draft(for: task.id).text, "Keep my draft")
        let resumed = await adapters.resumedIDs()
        XCTAssertEqual(resumed, [providerID], "The task reattaches to its own session under the new account")

        await model.switchAccount(to: connection(signedOut), for: switched)
        XCTAssertEqual(model.store.sessions.first?.connection, connection(next))
        XCTAssertEqual(model.errorBySessionID[task.id], ProviderConnectionError.signedOut.localizedDescription)
        let afterRefusal = await adapters.resumedIDs()
        XCTAssertEqual(afterRefusal, [providerID], "A refused switch leaves the attached session alone")
    }

    /// An account's tasks, archived ones too, move to another folder signed in to the same account (the
    /// same address and organization) that keeps the same conversations, each with its own provider
    /// session; a task in a turn moves once the turn ends, and only then does the account leave the list.
    /// A folder whose CLI reports another account takes nothing.
    func testMovingAnAccountsTasksKeepsTheirSessionsAndRemovesItOnceAllMoved() async throws {
        let shared = try directory()
        let projects = shared.appending(path: "projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let owner = #"{"loggedIn":true,"email":"owner@example.test","orgName":"owner@example.test's Organization"}"#
        let old = try account(linkingTo: projects, login: owner), new = try account(linkingTo: projects, login: owner)
        let team = try account(linkingTo: projects,
            login: #"{"loggedIn":true,"email":"owner@example.test","orgName":"Example Team"}"#)
        let impostor = try account(linkingTo: projects, login: #"{"loggedIn":true,"email":"other@example.test"}"#)
        let separate = try directory()
        try FileManager.default.createDirectory(at: separate.appending(path: "projects"), withIntermediateDirectories: true)
        try Data(owner.utf8).write(to: separate.appending(path: ".signed-in"))
        let cli = try script(shared, """
        if [ "$1" = "auth" ] && [ -f "$CLAUDE_CONFIG_DIR/.signed-in" ]; then cat "$CLAUDE_CONFIG_DIR/.signed-in"; else echo '{"loggedIn":false}'; fi
        """)
        let connections = ProviderConnectionStore()
        // The impostor's folder was last read as the owner's; its CLI now reports another address.
        for (home, organization) in [(old, "owner@example.test's Organization"), (new, "owner@example.test's Organization"),
                                     (team, "Example Team"), (impostor, "owner@example.test's Organization"),
                                     (separate, "owner@example.test's Organization")] {
            try connections.save(connection(home))
            connections.publish(HarnessAccountSnapshot(id: home.lastPathComponent, harness: .claudeCode, providerID: nil,
                state: .signedIn, accountLabel: "owner@example.test", accountOrganization: organization, detail: "",
                credentialOwner: "", checkedAt: Date(), usage: [], canLogin: false, canLogout: true), for: connection(home))
        }
        XCTAssertEqual(connections.taskMoveTargets(for: connection(old)), [connection(new), connection(impostor)],
            "Another organization and a folder with its own conversations are no targets")

        func record(_ title: String, on home: URL) -> SessionRecord {
            SessionRecord(harness: .claudeCode, workspaceURL: shared, runtimeExecutableURL: cli, title: title,
                providerSessionID: UUID().uuidString.lowercased(), connection: connection(home))
        }
        let detached = record("Detached", on: old), archived = record("Archived", on: old)
        let working = record("Working", on: old), teamTask = record("Team", on: team)
        let repository = InMemorySessionRepository(sessions: [detached, archived, working, teamTask])
        try await repository.archive(id: archived.id)
        let store = SessionStore(repository: repository)
        try await store.restore()
        let runtime = RuntimeSelectionStore(discoversRuntimes: false)
        runtime.select(cli, for: .claudeCode)
        let adapters = AdapterLog()
        let model = AppModel(store: store, runtimeSelections: runtime,
            registry: HarnessRegistry { kind, _ in adapters.make(kind) }, connections: connections,
            restoresIndexOnLaunch: false)
        model.accountMoveSleep = { try await Task.sleep(for: .milliseconds(10)) }
        addTeardownBlock { await model.shutdown() }
        let created = await model.createSession(harness: .claudeCode, workspaceURL: shared, runtimeExecutableURL: cli,
            title: "Attached", connection: connection(old))
        let attached = try XCTUnwrap(created, model.errorBySessionID.values.first ?? "Missing task")
        let ownTasks = [attached, detached, archived, working]
        XCTAssertTrue(model.isAttached(attached.id))
        XCTAssertEqual(model.accountTasks(on: connection(old)), AccountTaskCount(listed: 3, archived: 1, working: 0))
        // The launch restores the new-task choice; the account being moved is the one chosen.
        connections.selection[.claudeCode] = connection(old).id

        await model.moveTasks(from: connection(old), to: connection(impostor))
        XCTAssertNotNil(connections.taskMoves[connection(old).id]?.failure)
        XCTAssertEqual(model.accountTasks(on: connection(old)).total, 4, "Nothing moves to another account's login")

        try await store.updateSession(id: working.id, status: .running)
        let move = Task { await model.moveTasks(from: connection(old), to: connection(new)) }
        try await waitUntil { connections.taskMoves[connection(old).id]?.waiting == 1 }
        XCTAssertEqual(store.sessions.first { $0.id == working.id }?.connection, connection(old), "A turn is not cut off")
        XCTAssertEqual(store.archivedSessions?.first { $0.id == archived.id }?.session.connection, connection(new))
        let archivedNow = try await repository.loadArchivedSessions()
        XCTAssertEqual(archivedNow.map(\.session.connection), [connection(new)],
            "The archived task stays archived, with its new binding saved")
        XCTAssertTrue(connections.connections.contains(connection(old)), "The account stays until every task moved")

        try await store.updateSession(id: working.id, status: .ready)
        await move.value
        XCTAssertFalse(connections.connections.contains(connection(old)))
        XCTAssertNil(connections.taskMoves[connection(old).id])
        XCTAssertEqual(connections.selection[.claudeCode], connection(new).id, "New tasks start on the folder they moved to")
        let moved = store.sessions + (store.archivedSessions ?? []).map(\.session)
        for task in ownTasks {
            let now = try XCTUnwrap(moved.first { $0.id == task.id })
            XCTAssertEqual(now.connection, connection(new), task.title)
            XCTAssertEqual(now.providerSessionID, task.providerSessionID, task.title)
            XCTAssertEqual(now.environmentScope, task.environmentScope, task.title)
        }
        XCTAssertEqual(moved.first { $0.id == teamTask.id }?.connection, connection(team))
        let resumed = await adapters.resumedIDs()
        XCTAssertEqual(resumed, [try XCTUnwrap(attached.providerSessionID)], "Only the task that had a runtime starts one again")
        XCTAssertTrue(model.isAttached(attached.id))
        XCTAssertFalse(model.isAttached(detached.id))
    }

    /// Opt-in: `NHC_CLAUDE_ACCOUNT_LIVE=<config folder>` checks a real login's plan limits through the
    /// installed CLI, that it shares history with `~/.claude`, and (with `NHC_CLAUDE_ACCOUNT_LIVE_SESSION`)
    /// that a saved conversation reads through it. No model request is sent and nothing is written.
    func testLiveAccountFolderReportsUsageAndSharesHistory() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let home = environment["NHC_CLAUDE_ACCOUNT_LIVE"] else {
            throw XCTSkip("Set NHC_CLAUDE_ACCOUNT_LIVE to a signed-in Claude config folder")
        }
        let cli = URL(filePath: NSHomeDirectory()).appending(path: ".local/bin/claude")
        let account = connection(URL(filePath: home))
        let descriptor = try XCTUnwrap(HarnessCatalog.descriptor(for: .claudeCode))
        let snapshot = await HarnessAccountBroker(connection: account).snapshot(for: descriptor, executableURL: cli)
        XCTAssertEqual(snapshot.state, .signedIn, snapshot.detail)
        let quota = snapshot.usage.filter { $0.evidence == .exactQuota }
        XCTAssertFalse(quota.isEmpty, snapshot.usage.map(\.detail).joined(separator: "; "))
        print("Claude account usage:", quota.map { "\($0.label) \($0.detail)" })
        let original = ProviderConnection(id: "native", name: "native", harness: .claudeCode, providerID: nil,
            homePath: NSHomeDirectory() + "/.claude", credentialSelector: nil)
        XCTAssertTrue(ClaudeConversationStorage.isShared(account, original))
        if let session = environment["NHC_CLAUDE_ACCOUNT_LIVE_SESSION"] {
            let transcript = try XCTUnwrap(ClaudeSubagentTranscriptReader(configDirectory: URL(filePath: home))
                .readConversation(sessionID: session))
            XCTAssertFalse(transcript.entries.isEmpty)
        }
    }

    // MARK: - Fixtures

    private final class AdapterLog: @unchecked Sendable {
        private let lock = NSLock()
        private var adapters: [RecordingAdapter] = []
        func make(_ kind: HarnessKind) -> any HarnessAdapter {
            let adapter = RecordingAdapter(kind: kind)
            lock.withLock { adapters.append(adapter) }
            return adapter
        }
        func resumedIDs() async -> [String] {
            var result: [String] = []
            for adapter in lock.withLock({ adapters }) { result += await adapter.resumed }
            return result
        }
    }

    /// Keeps each session's event stream open until it is closed, as a running CLI does.
    private actor RecordingAdapter: HarnessAdapter {
        nonisolated let kind: HarnessKind
        private(set) var resumed: [String] = []
        private var streams: [UUID: AsyncStream<HarnessEventEnvelope>.Continuation] = [:]
        init(kind: HarnessKind) { self.kind = kind }

        func probeRuntime() async throws -> HarnessRuntimeDescriptor {
            HarnessRuntimeDescriptor(harness: kind, executableURL: URL(filePath: "/tmp/stub"), version: "stub",
                                     capabilities: .unavailable, fingerprint: "stub")
        }
        func createSession(_ request: CreateHarnessSessionRequest) async throws -> HarnessSessionHandle {
            HarnessSessionHandle(harness: kind, localSessionID: request.localSessionID,
                                 providerSessionID: UUID().uuidString.lowercased(), workspaceURL: request.workspaceURL)
        }
        func resumeSession(providerSessionID: String, localSessionID: UUID, workspaceURL: URL) async throws -> HarnessSessionHandle {
            resumed.append(providerSessionID)
            return HarnessSessionHandle(harness: kind, localSessionID: localSessionID, providerSessionID: providerSessionID,
                                        workspaceURL: workspaceURL)
        }
        func send(_ prompt: String, to session: HarnessSessionHandle) async throws {}
        func interrupt(_ session: HarnessSessionHandle) async throws {}
        func respond(to permissionRequestID: String, decision: PermissionDecision, in session: HarnessSessionHandle) async throws {}
        func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> {
            let (stream, continuation) = AsyncStream.makeStream(of: HarnessEventEnvelope.self)
            streams[session.localSessionID] = continuation
            return stream
        }
        func close(_ session: HarnessSessionHandle) async { streams.removeValue(forKey: session.localSessionID)?.finish() }
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "claude-account-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    /// `login` is what the fake CLI's `auth status` prints for the folder.
    private func account(linkingTo projects: URL, signedIn: Bool = false, login: String? = nil) throws -> URL {
        let root = try directory()
        try FileManager.default.createSymbolicLink(at: root.appending(path: "projects"), withDestinationURL: projects)
        if signedIn || login != nil { try Data((login ?? "").utf8).write(to: root.appending(path: ".signed-in")) }
        return root
    }

    private func connection(_ home: URL) -> ProviderConnection {
        ProviderConnection(id: home.lastPathComponent, name: home.lastPathComponent, harness: .claudeCode,
            providerID: nil, homePath: home.path, credentialSelector: nil)
    }

    private func script(_ root: URL, _ body: String) throws -> URL {
        let url = root.appending(path: "claude-\(UUID().uuidString.prefix(6))")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
}
