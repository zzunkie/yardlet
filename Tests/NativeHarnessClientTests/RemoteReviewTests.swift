import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient
@testable import YardletRemote

@MainActor
private enum ReviewFixture {
    static func repository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "review-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-b", "main"], at: root)
        try "# Release\n\nReady on Monday.\n".write(to: root.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try git(["add", "."], at: root)
        try git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "Initial"], at: root)
        try "# Release\n\nReady on Tuesday.\n".write(to: root.appending(path: "README.md"), atomically: true, encoding: .utf8)
        return root
    }
    static func git(_ arguments: [String], at root: URL) throws {
        let process = Process()
        process.executableURL = GitExecutableLocator.preferredURL()
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

extension RemoteBridgeTests {
    func testAConversationFileSelectsItsHostRepositoryRelativePath() async throws {
        let reader = RemoteGitDiffReading(taskID: "task") { request in
            var response = RemoteResponse(re: "read")
            var value = RemoteReviewResult()
            if case let .readReview(_, query) = request {
                switch query.operation {
                case .context: value.workspace = "/host/project/Sources"
                case .root: value.root = "/host/project"
                default: XCTFail("Only existing Review metadata reads are needed")
                }
            } else { XCTFail("No file mutation or local file read is needed") }
            response.review = value
            return response
        }
        let target = try await RemoteReviewFileTarget.read(path: "Parser.swift", reader: reader)
        XCTAssertEqual(target, RemoteReviewFileTarget(repository: "/host/project", path: "Sources/Parser.swift"))
        let escaped = try await RemoteReviewFileTarget.read(path: "../outside", reader: reader)
        XCTAssertNil(escaped)
    }

    func testReviewLastTurnUsesTheHostsProviderProjection() async throws {
        let root = try ReviewFixture.repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = SessionRecord(harness: .claudeCode, workspaceURL: root,
                                    runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Review")
        let entries = [TranscriptEntry(content: .user(text: "Write the release note", images: [])),
                       TranscriptEntry(content: .activity(HarnessActivity(id: "write", kind: "Write", title: "Write",
                           diff: HarnessActivityDiff(path: "README.md", newText: "# Release\nTuesday\n")), state: .completed))]
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteReviewLastTurn")))
        let adapter = FakeHarnessAdapter(kind: .claudeCode)
        let host = AppModel(store: SessionStore(sessions: [session], repository: InMemorySessionRepository(sessions: [session])),
                            runtimeSelections: RuntimeSelectionStore(defaults: defaults), registry: HarnessRegistry { _, _ in adapter },
                            initialTranscripts: [session.id: entries],
                            restoresIndexOnLaunch: false)
        let bridge = AppModelRemoteBridge(model: host)
        let result = try await bridge.readReview(taskID: session.id.uuidString, query: .init(.lastTurn)).get()
        let expected = ReviewLastTurn.transcript(entries, harness: .claudeCode, isRunning: false, workspaceURL: root)
        XCTAssertEqual(result.lastTurnOffered, expected.isOffered)
        XCTAssertEqual(result.text, expected.diff?.text)
        XCTAssertEqual(result.turnID, expected.diff?.turnID)
        XCTAssertTrue(result.text?.contains("Tuesday") == true)
        await host.shutdown()
    }

    func testReviewReadsStayWithinTheTasksRepositoryAndNeverFollowWorkingLinks() async throws {
        let root = try ReviewFixture.repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = RemoteFileScope(folder: root)
        let local = try await GitDiffService().load(workspaceURL: root)
        let remote = try await RemoteReviewReader.read(.init(.diff, target: "unstaged"), scope: scope).get()
        XCTAssertEqual(UnifiedDiffParser().parse(remote.text ?? "").files, local.files)
        let invalid = await RemoteReviewReader.read(.init(.text, revision: "--help", path: "README.md"), scope: scope)
        if case let .failure(error) = invalid { XCTAssertEqual(error.code, .badRequest) } else { XCTFail() }
        let outside = await RemoteReviewReader.read(.init(.diff, repository: "/private", target: "unstaged"), scope: scope)
        if case let .failure(error) = outside { XCTAssertEqual(error.code, .notFound) } else { XCTFail() }
        try FileManager.default.createSymbolicLink(at: root.appending(path: "outside.md"), withDestinationURL: URL(filePath: "/etc/hosts"))
        let linked = await RemoteReviewReader.read(.init(.text, path: "outside.md"), scope: scope)
        if case let .failure(error) = linked { XCTAssertEqual(error.code, .notFound) } else { XCTFail() }
        let other = try ReviewFixture.repository()
        defer { try? FileManager.default.removeItem(at: other) }
        try "Other repository".write(to: other.appending(path: "README.md"), atomically: true, encoding: .utf8)
        let multi = RemoteFileScope(folder: root, otherFolders: [other])
        let otherText = try await RemoteReviewReader.read(.init(.text, repository: other.path, path: "README.md"), scope: multi).get()
        XCTAssertEqual(otherText.text, "Other repository")
        let largeText = String(repeating: "Markdown text\n", count: 90_000)
        try largeText.write(to: root.appending(path: "large.md"), atomically: true, encoding: .utf8)
        let large = try await RemoteReviewReader.read(.init(.text, path: "large.md"), scope: scope).get()
        XCTAssertEqual(large.text, largeText)
        let unknown = RemoteReviewQuery(.diff, target: "discard")
        XCTAssertFalse(unknown.isValid)
    }

    func testReviewChangesActOnlyOnTheReviewedChangesInTheTasksRepository() async throws {
        let root = try ReviewFixture.repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = try ReviewFixture.repository()
        defer { try? FileManager.default.removeItem(at: other) }
        let scope = RemoteFileScope(folder: root)
        let git = GitDiffService()
        func reviewed(_ folder: URL, _ target: GitDiffTarget = .unstaged) async throws -> String {
            RemoteReviewChange.fingerprint(try await git.load(workspaceURL: folder, target: target).text)
        }
        func write(_ change: RemoteReviewChange, confirmed: Bool = false, in scope: RemoteFileScope,
                   authorize: @Sendable () throws -> Void = {}) async -> RemoteError? {
            await RemoteReviewWriter.write(change, confirmed: confirmed, scope: scope, authorize: authorize)
        }
        func untouched() async throws {
            let staged = try await git.load(workspaceURL: root, target: .staged)
            XCTAssertTrue(staged.isEmpty)
            let text = try String(contentsOf: root.appending(path: "README.md"), encoding: .utf8)
            XCTAssertTrue(text.contains("Tuesday"))
        }

        // Changes other than the reviewed ones, a Discard not confirmed, and a permission withdrawn before Git writes.
        let stale = await write(.init(.stage, expected: RemoteReviewChange.fingerprint("")), in: scope)
        XCTAssertEqual(stale?.reason, .changing)
        let unconfirmed = await write(.init(.discard, expected: try await reviewed(root)), in: scope)
        XCTAssertEqual(unconfirmed?.reason, .confirmation)
        let revoked = await write(.init(.discard, expected: try await reviewed(root)), confirmed: true, in: scope) {
            throw RemoteError(.notAllowed, reason: .fileWrites)
        }
        XCTAssertEqual(revoked, RemoteError(.notAllowed, reason: .fileWrites))
        try await untouched()

        // Another repository, named directly or through a link in the task's folder, and a task below a larger
        // checkout's root: none of them is changed.
        let outside = await write(.init(.discard, repository: other.path, expected: try await reviewed(other)),
                                  confirmed: true, in: scope)
        XCTAssertEqual(outside?.code, .notFound)
        let nested = root.appending(path: "Sources")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let below = await write(.init(.discard, expected: try await reviewed(root)), confirmed: true,
                                in: RemoteFileScope(folder: nested))
        XCTAssertEqual(below, RemoteError(.notAllowed))
        try await untouched()
        try FileManager.default.createSymbolicLink(at: root.appending(path: "linked"), withDestinationURL: other)
        let linked = await write(.init(.discard, repository: root.appending(path: "linked").path,
                                       expected: try await reviewed(other)), confirmed: true, in: scope)
        XCTAssertEqual(linked?.code, .notFound)
        let otherText = try String(contentsOf: other.appending(path: "README.md"), encoding: .utf8)
        XCTAssertTrue(otherText.contains("Tuesday"))
        try FileManager.default.removeItem(at: root.appending(path: "linked"))

        // The reviewed changes, staged and unstaged again.
        let stagedNow = await write(.init(.stage, expected: try await reviewed(root)), in: scope)
        XCTAssertNil(stagedNow)
        let staged = try await git.load(workspaceURL: root, target: .staged)
        XCTAssertEqual(staged.files.map(\.path), ["README.md"])
        let unstagedNow = await write(.init(.unstage, expected: try await reviewed(root, .staged)), in: scope)
        XCTAssertNil(unstagedNow)
        try await untouched()
    }
}

extension RemoteHostModelTests {
    func testReviewReadsAndRendersTheSamePanelThroughTwoYardlets() async throws {
        let root = try ReviewFixture.repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = FakeHarnessAdapter(kind: .claudeCode)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteReview")))
        let host = AppModel(store: SessionStore(repository: InMemorySessionRepository()),
                            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
                            registry: HarnessRegistry { _, _ in adapter }, restoresIndexOnLaunch: false)
        let created = await host.createSession(harness: .claudeCode, workspaceURL: root,
                                               runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Review")
        let session = try XCTUnwrap(created)
        let stack = try await LoopbackStack(bridge: AppModelRemoteBridge(model: host), port: 47876)
        defer { stack.stop() }
        let ticket = await stack.server.openPairing()
        let link = try XCTUnwrap(RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey, secret: ticket.secret,
                                                        name: "Host", hosts: ["127.0.0.1:\(stack.port)"]).url)
        let directory = RemoteHostDirectory(store: RemoteHostStore(fileURL: nil), keys: RemoteMemoryClientKeys(),
                                            hello: RemoteHandshakeHello(name: "Client", platform: "macos", appVersion: "test"))
        let paired = try await directory.pair(link: link.absoluteString)
        let client = try XCTUnwrap(directory.model(for: paired.id))
        defer { client.stop() }
        try await waitUntil { client.offersReview }
        await host.send("Write the release note", to: session)
        await adapter.emit(.activityCompleted(HarnessActivity(id: "write", kind: "Write", title: "Write",
            diff: HarnessActivityDiff(path: "README.md", newText: "# Release\n\nReady on Tuesday.\n"))),
                           for: session.id, sequence: 1)
        await adapter.emit(.turnCompleted, for: session.id, sequence: 2)
        try await waitUntil {
            ConversationFileChangeProjection.carriesFileChanges(host.transcriptBySessionID[session.id] ?? [])
        }
        let remote = RemoteGitDiffReading(model: client, taskID: session.id.uuidString)
        // The client starts with only the task ID; the task snapshot does not disclose host folders.
        let context = try await remote.context()
        let hostRoot = URL(filePath: try XCTUnwrap(context.workspace))
        XCTAssertEqual(hostRoot.standardizedFileURL.path, session.workspaceURL.standardizedFileURL.path)
        let readLast = try await remote.lastTurn()
        let last = try XCTUnwrap(readLast)
        let expectedLast = ReviewLastTurn.transcript(host.transcriptBySessionID[session.id] ?? [], harness: .claudeCode,
                                                     isRunning: false, workspaceURL: root)
        XCTAssertEqual(last.diff?.text, expectedLast.diff?.text)
        XCTAssertTrue(last.isOffered)

        let local = GitDiffService()
        let expected = try await local.load(workspaceURL: root)
        let received = try await remote.load(workspaceURL: hostRoot, target: .unstaged)
        XCTAssertEqual(received, expected)
        let commits = try await remote.recentCommits(workspaceURL: hostRoot, limit: 50)
        XCTAssertEqual(commits.count, 1)
        let old = try await remote.fileText(workspaceURL: hostRoot, revision: commits[0].id, path: "README.md")
        let new = try await remote.workingText(hostRoot.appending(path: "README.md"))
        XCTAssertTrue(old?.contains("Monday") == true)
        XCTAssertTrue(new?.contains("Tuesday") == true)
        let staged = try await remote.load(workspaceURL: hostRoot, target: .staged)
        XCTAssertTrue(staged.isEmpty)
        let commitDiff = try await remote.load(workspaceURL: hostRoot, target: .commit(commits[0].id))
        XCTAssertEqual(commitDiff.files.first?.path, "README.md")
        let output = try WindowlessRender.directory("remote-review-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            for (name, markdown, scope) in [("diff", false, GitDiffScope.unstaged),
                                            ("markdown", true, .unstaged), ("last-turn", false, .lastTurn)] {
                let size = NSSize(width: 1440, height: 660)
                let view = ReviewPair(root: root, client: client, taskID: session.id.uuidString, markdown: markdown, scope: scope, lastTurn: expectedLast)
                    .environment(\.colorScheme, appearance.colorScheme)
                    .frame(width: size.width, height: size.height)
                    .background(ParityTheme.canvas)
                let rendered = WindowlessRender.Host(view, size: size, appearance: appearance)
                defer { rendered.close() }
                await rendered.settle(until: {
                    rendered.accessibilityElements().filter { $0.description.contains("Tuesday") }.count >= 2
                })
                rendered.settle(passes: 8)
                let elements = rendered.accessibilityElements().map(\.description).joined(separator: "\n")
                XCTAssertTrue(elements.contains("Tuesday"))
                try WindowlessRender.writePNG(rendered.capture().bitmap,
                    to: output.appending(path: "review-\(name)-\(appearance.suffix).png"))
            }
        }
        await host.shutdown()
    }

    /// Also draws, into `.build/remote-review-qa`, the remote pane's Stage all and Discard, the refusal after Stage all
    /// from a device without Write files, and the Discard sheet the pane asks with. `QA_LANGUAGE` names the files of a
    /// run in another language (`-AppleLanguages '(ko)'`).
    func testReviewChangesNeedTheDevicesWriteFilesPermissionThroughTwoYardlets() async throws {
        let root = try ReviewFixture.repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try "Draft\n".write(to: root.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        let adapter = FakeHarnessAdapter(kind: .claudeCode)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteReviewChanges")))
        let host = AppModel(store: SessionStore(repository: InMemorySessionRepository()),
                            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
                            registry: HarnessRegistry { _, _ in adapter }, restoresIndexOnLaunch: false)
        let created = await host.createSession(harness: .claudeCode, workspaceURL: root,
                                               runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Review")
        let session = try XCTUnwrap(created)
        let stack = try await LoopbackStack(bridge: AppModelRemoteBridge(model: host))
        defer { stack.stop() }
        let ticket = await stack.server.openPairing()
        let link = try XCTUnwrap(RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey, secret: ticket.secret,
                                                        name: "Host", hosts: ["127.0.0.1:\(stack.port)"]).url)
        let directory = RemoteHostDirectory(store: RemoteHostStore(fileURL: nil), keys: RemoteMemoryClientKeys(),
                                            hello: RemoteHandshakeHello(name: "Client", platform: "macos", appVersion: "test"))
        let paired = try await directory.pair(link: link.absoluteString)
        let client = try XCTUnwrap(directory.model(for: paired.id))
        defer { client.stop() }
        try await waitUntil { client.offersReview && client.offersReviewChanges }
        let taskID = session.id.uuidString
        let remote = RemoteGitDiffReading(model: client, taskID: taskID)
        XCTAssertNil(remote.mutationUnavailableReason)
        let context = try await remote.context()
        let hostRoot = URL(filePath: try XCTUnwrap(context.workspace))
        let git = GitDiffService()
        let reviewed = try await remote.load(workspaceURL: hostRoot, target: .unstaged)
        XCTAssertEqual(reviewed.files.map(\.path), ["README.md", "notes.txt"])

        // A paired device has no Write files until the person at the host allows it.
        let notAllowed = L10n.format("To change files from here, allow Write files for this device in Settings › Remote › Paired devices on %@.",
                                     client.name)
        do {
            try await remote.mutate(.stage, workspaceURL: hostRoot, expected: reviewed)
            XCTFail("Staged without Write files")
        } catch { XCTAssertEqual(error.localizedDescription, notAllowed) }
        let unchanged = try await git.load(workspaceURL: root, target: .staged)
        XCTAssertTrue(unchanged.isEmpty)

        let language = ProcessInfo.processInfo.environment["QA_LANGUAGE"] ?? "en"
        let output = try WindowlessRender.directory("remote-review-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            let size = NSSize(width: 900, height: 520)
            let view = RemoteReviewOnly(client: client, taskID: taskID)
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height)
                .background(ParityTheme.canvas)
            let rendered = WindowlessRender.Host(view, size: size, appearance: appearance)
            defer { rendered.close() }
            let stage = L10n.string("Stage all")
            await rendered.settle(until: { rendered.accessibilityElements().contains { $0.label == stage } })
            rendered.settle(passes: 8)
            XCTAssertTrue(rendered.accessibilityElements().contains { $0.label == L10n.string("Discard changes") })
            try WindowlessRender.writePNG(rendered.capture().bitmap,
                to: output.appending(path: "review-changes-\(language)-\(appearance.suffix).png"))
            XCTAssertTrue(rendered.hosting.pressAccessibilityElement(labelled: stage))
            await rendered.settle(until: {
                rendered.accessibilityElements().contains { $0.description.contains(notAllowed) }
            })
            rendered.settle(passes: 4)
            try WindowlessRender.writePNG(rendered.capture().bitmap,
                to: output.appending(path: "review-changes-not-allowed-\(language)-\(appearance.suffix).png"))

            let sheetSize = NSSize(width: 440, height: 300)
            let sheet = GitDiscardReviewSheet(request: GitDiscardRequest(workspaceURL: hostRoot, snapshot: reviewed),
                                              onCancel: {}, onDiscard: {})
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: sheetSize.width, height: sheetSize.height)
                .background(ParityTheme.canvas)
            let drawnSheet = WindowlessRender.Host(sheet, size: sheetSize, appearance: appearance)
            defer { drawnSheet.close() }
            drawnSheet.settle(passes: 6)
            try WindowlessRender.writePNG(drawnSheet.capture().bitmap,
                to: output.appending(path: "review-discard-sheet-\(language)-\(appearance.suffix).png"))
        }
        let refusedFromThePane = try await git.load(workspaceURL: root, target: .staged)
        XCTAssertTrue(refusedFromThePane.isEmpty)

        // Allowed: Stage all, Unstage all and Discard change the host's repository as its own Review does.
        try await stack.server.setPermission(.fileWrites, allowed: true, for: try XCTUnwrap(client.host.deviceID))
        try await remote.mutate(.stage, workspaceURL: hostRoot, expected: reviewed)
        let staged = try await git.load(workspaceURL: root, target: .staged)
        XCTAssertEqual(staged.files.map(\.path), ["README.md", "notes.txt"])
        let remoteStaged = try await remote.load(workspaceURL: hostRoot, target: .staged)
        try await remote.mutate(.unstage, workspaceURL: hostRoot, expected: remoteStaged)
        let unstaged = try await remote.load(workspaceURL: hostRoot, target: .unstaged)
        XCTAssertEqual(unstaged, reviewed)
        try await remote.mutate(.discard, workspaceURL: hostRoot, expected: unstaged)
        let discarded = try await git.load(workspaceURL: root, target: .unstaged)
        XCTAssertTrue(discarded.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "notes.txt").path))
        // A Review read before the discard no longer matches the host's changes.
        do {
            try await remote.mutate(.discard, workspaceURL: hostRoot, expected: unstaged)
            XCTFail("Discarded changes that are no longer there")
        } catch { XCTAssertEqual(error as? GitDiffServiceError, .changedSinceReview) }
        await host.shutdown()
    }
}

private struct RemoteReviewOnly: View {
    let client: RemoteHostModel
    let taskID: String
    @State private var preferences = DiffReviewPreferences()
    var body: some View { RemoteReviewPane(model: client, taskID: taskID, review: $preferences) }
}

private struct ReviewPair: View {
    let root: URL
    let client: RemoteHostModel
    let taskID: String
    let lastTurn: ReviewLastTurn
    @State var localPreferences: DiffReviewPreferences
    @State var remotePreferences: DiffReviewPreferences
    init(root: URL, client: RemoteHostModel, taskID: String, markdown: Bool, scope: GitDiffScope, lastTurn: ReviewLastTurn) {
        self.root = root; self.client = client; self.taskID = taskID; self.lastTurn = lastTurn
        var preferences = DiffReviewPreferences()
        preferences.scope = scope
        preferences.rendersMarkdown = markdown
        _localPreferences = State(initialValue: preferences)
        _remotePreferences = State(initialValue: preferences)
    }
    var body: some View {
        HStack(spacing: 0) {
            DiffPane(workspaceURL: root, review: $localPreferences, lastTurn: lastTurn, onClose: {})
            Divider()
            RemoteReviewPane(model: client, taskID: taskID, review: $remotePreferences)
        }
    }
}
