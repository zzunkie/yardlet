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
        let remote = RemoteGitDiffReading(model: client, taskID: session.id.uuidString, workspaceURL: root)
        let readLast = try await remote.lastTurn()
        let last = try XCTUnwrap(readLast)
        let expectedLast = ReviewLastTurn.transcript(host.transcriptBySessionID[session.id] ?? [], harness: .claudeCode,
                                                     isRunning: false, workspaceURL: root)
        XCTAssertEqual(last.diff?.text, expectedLast.diff?.text)
        XCTAssertTrue(last.isOffered)

        let local = GitDiffService()
        let expected = try await local.load(workspaceURL: root)
        let received = try await remote.load(workspaceURL: root, target: .unstaged)
        XCTAssertEqual(received, expected)
        let commits = try await remote.recentCommits(workspaceURL: root, limit: 50)
        XCTAssertEqual(commits.count, 1)
        let old = try await remote.fileText(workspaceURL: root, revision: commits[0].id, path: "README.md")
        let new = try await remote.workingText(root.appending(path: "README.md"))
        XCTAssertTrue(old?.contains("Monday") == true)
        XCTAssertTrue(new?.contains("Tuesday") == true)
        let staged = try await remote.load(workspaceURL: root, target: .staged)
        XCTAssertTrue(staged.isEmpty)
        let commitDiff = try await remote.load(workspaceURL: root, target: .commit(commits[0].id))
        XCTAssertEqual(commitDiff.files.first?.path, "README.md")
        let output = try WindowlessRender.directory("remote-review-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            for (name, markdown, scope) in [("diff", false, GitDiffScope.unstaged),
                                            ("markdown", true, .unstaged), ("last-turn", false, .lastTurn)] {
                let size = NSSize(width: 1440, height: 660)
                let view = ReviewPair(root: root, remote: remote, markdown: markdown, scope: scope, lastTurn: expectedLast)
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
}

private struct ReviewPair: View {
    let root: URL
    let remote: RemoteGitDiffReading
    let lastTurn: ReviewLastTurn
    @State var localPreferences: DiffReviewPreferences
    @State var remotePreferences: DiffReviewPreferences
    init(root: URL, remote: RemoteGitDiffReading, markdown: Bool, scope: GitDiffScope, lastTurn: ReviewLastTurn) {
        self.root = root; self.remote = remote; self.lastTurn = lastTurn
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
            DiffPane(workspaceURL: root, review: $remotePreferences, reading: remote, onClose: {})
        }
    }
}
