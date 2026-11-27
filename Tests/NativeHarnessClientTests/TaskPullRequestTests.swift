import Foundation
import XCTest
@testable import NativeHarnessClient

/// A task's pull request: the `pr-link` Claude Code writes to its transcript, what `gh pr view`
/// says about it, when GitHub is asked, what shows without `gh`, and the new-task warning about a
/// task already running in the chosen folder. No test starts the real `gh` (a fake runner answers),
/// reads a real transcript, or touches the network.
final class TaskPullRequestTests: XCTestCase {
    // MARK: - pr-link records

    private static func linkLine(_ number: Int, repository: String = "example-org/web",
                                 session: String = "5b0c9d0e-1111-4222-8333-944455556666") -> String {
        #"{"type":"pr-link","sessionId":"\#(session)","prNumber":\#(number),"prUrl":"https://github.com/\#(repository)/pull/\#(number)","prRepository":"\#(repository)","timestamp":"2026-10-15T09:00:00.000Z"}"#
    }

    private static func messageLine(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return #"{"type":"user","uuid":"\#(UUID().uuidString)","message":{"role":"user","content":"\#(escaped)"}}"#
    }

    func testAPrLinkRecordReadsItsNumberLinkAndRepository() throws {
        let link = try XCTUnwrap(TaskPullRequestLink(line: Data(Self.linkLine(123).utf8)))
        XCTAssertEqual(link.number, 123)
        XCTAssertEqual(link.url.absoluteString, "https://github.com/example-org/web/pull/123")
        XCTAssertEqual(link.repository, "example-org/web")

        // A record without its repository takes it from the link; a number written as text still reads.
        let bare = #"{"type":"pr-link","prNumber":"7","prUrl":"https://github.com/o/r/pull/7"}"#
        XCTAssertEqual(TaskPullRequestLink(line: Data(bare.utf8))?.repository, "o/r")
        XCTAssertEqual(TaskPullRequestLink(line: Data(bare.utf8))?.number, 7)

        // Other records, and a message that only talks about a pr-link, are not links.
        XCTAssertNil(TaskPullRequestLink(line: Data(Self.messageLine(#"write {"type":"pr-link","prNumber":9}"#).utf8)))
        XCTAssertNil(TaskPullRequestLink(line: Data(#"{"type":"pr-link","prNumber":0,"prUrl":"https://github.com/o/r/pull/0"}"#.utf8)))
        XCTAssertNil(TaskPullRequestLink(line: Data(#"{"type":"pr-link","prNumber":5,"prUrl":"file:///etc/passwd"}"#.utf8)))
        XCTAssertNil(TaskPullRequestLink(line: Data(#"{"type":"pr-link","prNumber":5"#.utf8)), "a line still being written")
    }

    func testTheLatestPrLinkWins() {
        let lines = [Self.linkLine(10), Self.messageLine("hello"), Self.linkLine(11, repository: "o/other"),
                     Self.messageLine(#"the old "pr-link" was #10"#), #"{"type":"pr-link","prNumber":5"#]
        let link = TaskPullRequestLink.latest(in: Data((lines.joined(separator: "\n") + "\n").utf8))
        XCTAssertEqual(link?.number, 11)
        XCTAssertEqual(link?.repository, "o/other")
        XCTAssertNil(TaskPullRequestLink.latest(in: Data((Self.messageLine("no links") + "\n").utf8)))
    }

    // MARK: - Scanning a transcript

    private static let identity = ClaudePullRequestLinkScan.FileIdentity(device: 1, inode: 42)

    private static func scan(_ data: Data, previous: ClaudePullRequestLinkScan? = nil,
                             identity: ClaudePullRequestLinkScan.FileIdentity = identity,
                             maximumFirstScanBytes: Int64 = ClaudePullRequestLinkScanner.maximumFirstScanBytes,
                             reads: UnsafeMutablePointer<Int>? = nil) throws -> ClaudePullRequestLinkScan {
        try ClaudePullRequestLinkScanner.scan(file: identity, size: Int64(data.count), previous: previous,
                                              maximumFirstScanBytes: maximumFirstScanBytes) { offset, count in
            reads?.pointee += count
            let start = Int(offset)
            return data.subdata(in: start..<min(data.count, start + count))
        }
    }

    /// A transcript of `megabytes` of conversation, with links where asked.
    private static func transcript(megabytes: Double, links: [(atFraction: Double, number: Int)]) -> Data {
        let filler = messageLine(String(repeating: "lorem ipsum ", count: 80))
        let lineCount = Int(megabytes * 1_048_576) / (filler.utf8.count + 1)
        var lines = Array(repeating: filler, count: lineCount)
        for link in links.sorted(by: { $0.atFraction > $1.atFraction }) {
            lines.insert(linkLine(link.number), at: Int(Double(lineCount) * link.atFraction))
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    func testTheFirstScanReadsBackFromTheEndAndStopsAtTheNewestLink() throws {
        let data = Self.transcript(megabytes: 3, links: [(0.1, 3), (0.5, 4)])
        var read = 0
        let scan = try Self.scan(data, reads: &read)
        XCTAssertEqual(scan.link?.number, 4)
        XCTAssertEqual(scan.scannedThrough, Int64(data.count))
        XCTAssertLessThan(read, data.count, "it stopped at the newest link")

        // A link more than the first scan's reach from the end is not looked for.
        let far = Self.transcript(megabytes: 3, links: [(0.05, 8)])
        XCTAssertNil(try Self.scan(far, maximumFirstScanBytes: 1_048_576).link)
        XCTAssertEqual(try Self.scan(far).link?.number, 8)
        var farRead = 0
        _ = try Self.scan(Self.transcript(megabytes: 10, links: []), reads: &farRead)
        XCTAssertLessThanOrEqual(Int64(farRead), ClaudePullRequestLinkScanner.maximumFirstScanBytes)
    }

    func testLaterScansReadOnlyWhatWasAppended() throws {
        var data = Self.transcript(megabytes: 2.5, links: [(0.3, 20)])
        let first = try Self.scan(data)
        XCTAssertEqual(first.link?.number, 20)

        // Nothing new: nothing read.
        var read = 0
        XCTAssertEqual(try Self.scan(data, previous: first, reads: &read), first)
        XCTAssertEqual(read, 0)

        // Appended conversation keeps the link; only the appended bytes are read.
        let appended = Data((Self.messageLine("more") + "\n").utf8)
        data.append(appended)
        read = 0
        let second = try Self.scan(data, previous: first, reads: &read)
        XCTAssertEqual(second.link?.number, 20)
        XCTAssertEqual(read, appended.count)

        // A newer link wins; a line still being written waits for its end.
        data.append(Data((Self.linkLine(21) + "\n").utf8))
        let partial = Self.linkLine(22)
        data.append(Data(partial.prefix(30).utf8))
        let third = try Self.scan(data, previous: second)
        XCTAssertEqual(third.link?.number, 21)
        XCTAssertEqual(third.scannedThrough, Int64(data.count - 30))
        data.append(Data((partial.dropFirst(30) + "\n").utf8))
        XCTAssertEqual(try Self.scan(data, previous: third).link?.number, 22)

        // A replaced file is scanned again from its end.
        let replaced = Data((Self.messageLine("new file") + "\n").utf8)
        let other = ClaudePullRequestLinkScan.FileIdentity(device: 1, inode: 43)
        XCTAssertNil(try Self.scan(replaced, previous: third, identity: other).link)
        // So is one that shrank.
        XCTAssertNil(try Self.scan(replaced, previous: third).link)
    }

    func testTheTranscriptReaderFindsTheConversationsLink() throws {
        let config = FileManager.default.temporaryDirectory.appending(path: "pr-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: config) }
        let project = config.appending(path: "projects/-tmp-repo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let sessionID = "5b0c9d0e-1111-4222-8333-944455556666"
        let file = project.appending(path: "\(sessionID).jsonl")
        try Data(([Self.messageLine("hi"), Self.linkLine(31)].joined(separator: "\n") + "\n").utf8).write(to: file)
        let reader = ClaudeSubagentTranscriptReader(configDirectory: config)

        let first = try XCTUnwrap(try reader.pullRequestLinkScan(sessionID: sessionID, previous: nil))
        XCTAssertEqual(first.link?.number, 31)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((Self.linkLine(32) + "\n").utf8))
        try handle.close()
        XCTAssertEqual(try reader.pullRequestLinkScan(sessionID: sessionID, previous: first)?.link?.number, 32)
        XCTAssertNil(try reader.pullRequestLinkScan(sessionID: "6b0c9d0e-1111-4222-8333-944455556666", previous: nil))
    }

    /// A later scan reads the file the last one found while it is the same file, without looking
    /// through every project folder again; a file that moved is looked for again.
    func testALaterScanReadsTheFileItFoundAndAMovedOneIsLookedForAgain() throws {
        let config = FileManager.default.temporaryDirectory.appending(path: "pr-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: config) }
        let projects = config.appending(path: "projects")
        let project = projects.appending(path: "-tmp-repo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let sessionID = "5b0c9d0e-1111-4222-8333-944455556666"
        let name = "\(sessionID).jsonl"
        let file = project.appending(path: name)
        try Data((Self.linkLine(31) + "\n").utf8).write(to: file)
        let reader = ClaudeSubagentTranscriptReader(configDirectory: config)

        let first = try XCTUnwrap(try reader.pullRequestLinkScan(sessionID: sessionID, previous: nil))
        XCTAssertEqual(first.path, ["-tmp-repo", name])

        // A second folder with a file of the same name: a fresh look refuses to choose between them,
        // while the file already found is still read.
        let other = projects.appending(path: "-tmp-other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data((Self.linkLine(90) + "\n").utf8).write(to: other.appending(path: name))
        XCTAssertThrowsError(try reader.pullRequestLinkScan(sessionID: sessionID, previous: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((Self.linkLine(32) + "\n").utf8))
        try handle.close()
        let second = try XCTUnwrap(try reader.pullRequestLinkScan(sessionID: sessionID, previous: first))
        XCTAssertEqual(second.link?.number, 32)
        XCTAssertEqual(second.path, ["-tmp-repo", name])

        // Moved to another folder: found there again by looking.
        try FileManager.default.removeItem(at: other)
        let moved = projects.appending(path: "-tmp-moved")
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: moved.appending(path: name))
        let third = try XCTUnwrap(try reader.pullRequestLinkScan(sessionID: sessionID, previous: second))
        XCTAssertEqual(third.link?.number, 32)
        XCTAssertEqual(third.path, ["-tmp-moved", name])
    }

    // MARK: - gh pr view --json

    private static func ghJSON(state: String, isDraft: Bool = false, review: String? = nil,
                               checks: [[String: Any]] = [], number: Int = 77) -> Data {
        var object: [String: Any] = ["number": number, "url": "https://github.com/o/r/pull/\(number)",
                                     "state": state, "isDraft": isDraft, "statusCheckRollup": checks]
        object["reviewDecision"] = review ?? ""
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private static func run(_ status: String, _ conclusion: String = "") -> [String: Any] {
        ["__typename": "CheckRun", "name": "build", "status": status, "conclusion": conclusion]
    }

    private static func context(_ state: String) -> [String: Any] {
        ["__typename": "StatusContext", "context": "ci", "state": state]
    }

    func testGhOutputReadsEachState() throws {
        func parse(_ data: Data) throws -> TaskPullRequest {
            try XCTUnwrap(GitHubPullRequestStatus.parse(data, source: .transcriptLink))
        }
        XCTAssertEqual(try parse(Self.ghJSON(state: "OPEN")).state, .open)
        XCTAssertEqual(try parse(Self.ghJSON(state: "OPEN", isDraft: true)).state, .draft)
        XCTAssertEqual(try parse(Self.ghJSON(state: "MERGED")).state, .merged)
        XCTAssertEqual(try parse(Self.ghJSON(state: "CLOSED")).state, .closed)
        let open = try parse(Self.ghJSON(state: "OPEN"))
        XCTAssertEqual(open.number, 77)
        XCTAssertEqual(open.repository, "o/r")
        XCTAssertNil(open.checks, "no checks")
        XCTAssertNil(open.review, "no review decision")

        XCTAssertEqual(try parse(Self.ghJSON(state: "OPEN", review: "CHANGES_REQUESTED")).review, .changesRequested)
        XCTAssertEqual(try parse(Self.ghJSON(state: "OPEN", review: "APPROVED")).review, .approved)
        XCTAssertNil(try parse(Self.ghJSON(state: "OPEN", review: "REVIEW_REQUIRED")).review)

        let passing = [Self.run("COMPLETED", "SUCCESS"), Self.run("COMPLETED", "SKIPPED"), Self.context("SUCCESS")]
        XCTAssertEqual(try parse(Self.ghJSON(state: "OPEN", checks: passing)).checks, .passing)
        XCTAssertEqual(try parse(Self.ghJSON(state: "OPEN", checks: passing + [Self.run("IN_PROGRESS")])).checks, .pending)
        XCTAssertEqual(try parse(Self.ghJSON(state: "OPEN", checks: passing + [Self.context("PENDING")])).checks, .pending)
        XCTAssertEqual(try parse(Self.ghJSON(state: "OPEN", checks: passing + [Self.run("IN_PROGRESS"),
                                                                                Self.run("COMPLETED", "FAILURE")])).checks,
                       .failing)
        XCTAssertEqual(try parse(Self.ghJSON(state: "OPEN", checks: [Self.context("ERROR")])).checks, .failing)
        XCTAssertEqual(try parse(Self.ghJSON(state: "OPEN", checks: [Self.run("COMPLETED", "TIMED_OUT")])).checks, .failing)

        XCTAssertNil(GitHubPullRequestStatus.parse(Data("not json".utf8), source: .transcriptLink))
        XCTAssertNil(GitHubPullRequestStatus.parse(Data(#"{"number":0}"#.utf8), source: .transcriptLink))
    }

    func testTheClientAsksGhReadOnlyAndNeverPrompts() async throws {
        let folder = URL(filePath: "/tmp/repo")
        let fake = FakeGitHubCLI { arguments, _ in
            if arguments.contains("https://github.com/o/r/pull/77") {
                return .init(status: 0, output: Self.ghJSON(state: "OPEN"), errorText: "")
            }
            return .init(status: 1, output: Data(), errorText: "no pull requests found for branch \"feature\"\n")
        }
        let client = GitHubPullRequestClient(cli: fake)
        let found = await client.pullRequest(at: URL(string: "https://github.com/o/r/pull/77")!, in: folder)
        guard case let .found(pullRequest) = found else { return XCTFail("\(found)") }
        XCTAssertEqual(pullRequest.state, .open)
        let none = await client.pullRequest(forBranch: "feature", in: folder)
        XCTAssertEqual(none, .none)
        let calls = await fake.calls
        XCTAssertEqual(calls.map(\.arguments), [
            ["pr", "view", "https://github.com/o/r/pull/77", "--json", "number,url,state,isDraft,reviewDecision,statusCheckRollup"],
            ["pr", "view", "--json", "number,url,state,isDraft,reviewDecision,statusCheckRollup"]
        ])
        XCTAssertEqual(calls.map(\.directory), [folder, folder])

        // Signed out (gh exits 4), missing, or too slow: unavailable, never a prompt.
        let signedOut = GitHubPullRequestClient(cli: FakeGitHubCLI { _, _ in
            .init(status: 4, output: Data(), errorText: "To get started with GitHub CLI, please run:  gh auth login\n")
        })
        let signedOutAnswer = await signedOut.pullRequest(forBranch: "feature", in: folder)
        XCTAssertEqual(signedOutAnswer, .unavailable)
        let missing = GitHubPullRequestClient(cli: LocalGitHubCLI(executableURL: nil))
        let missingAnswer = await missing.pullRequest(forBranch: "feature", in: folder)
        XCTAssertEqual(missingAnswer, .unavailable)
        let slow = GitHubPullRequestClient(cli: FakeGitHubCLI { _, _ in throw GitHubCLIFailure.timedOut })
        let slowAnswer = await slow.pullRequest(forBranch: "feature", in: folder)
        XCTAssertEqual(slowAnswer, .unavailable)

        XCTAssertEqual(LocalGitHubCLI.environment["GH_PROMPT_DISABLED"], "1")
        XCTAssertEqual(LocalGitHubCLI.environment["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertNil(LocalGitHubCLI.locate(candidates: [], homeURL: URL(filePath: "/nonexistent"), isExecutableFile: { _ in false }))
        XCTAssertEqual(LocalGitHubCLI.locate(candidates: ["/a/gh", "/b/gh"], isExecutableFile: { $0 == "/b/gh" })?.path, "/b/gh")
    }

    // MARK: - Which branch to ask about

    func testOnlyAFeatureBranchOfAGitHubRepositoryIsAskedAbout() {
        func reader(head: String = "ref: refs/heads/fix-parser\n", remote: String = "https://github.com/o/r.git",
                    originHead: String? = "ref: refs/remotes/origin/main\n", worktree: Bool = false) -> GitMetadataReader {
            GitMetadataReader(
                kind: { path in
                    switch path {
                    case "/repo/.git": worktree ? nil : .directory
                    case "/wt/.git": worktree ? .file : nil
                    default: nil
                    }
                },
                text: { path in
                    switch path {
                    case "/repo/.git/HEAD": worktree ? "ref: refs/heads/main\n" : head
                    case "/repo/.git/config":
                        "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = \(remote)\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n"
                    case "/repo/.git/refs/remotes/origin/HEAD": originHead
                    case "/wt/.git": "gitdir: /repo/.git/worktrees/wt\n"
                    case "/repo/.git/worktrees/wt/HEAD": head
                    case "/repo/.git/worktrees/wt/commondir": "../..\n"
                    default: nil
                    }
                }
            )
        }
        let repo = URL(filePath: "/repo")
        XCTAssertEqual(TaskPullRequestSources.branchToAsk(in: repo, reader: reader()), "fix-parser")
        XCTAssertEqual(TaskPullRequestSources.branchToAsk(in: repo.appending(path: "Sources"), reader: reader()), "fix-parser")
        XCTAssertEqual(TaskPullRequestSources.branchToAsk(in: URL(filePath: "/wt"), reader: reader(worktree: true)),
                       "fix-parser", "a linked worktree reads its repository's remotes")
        XCTAssertEqual(TaskPullRequestSources.branchToAsk(in: repo, reader: reader(remote: "git@github.com:o/r.git")),
                       "fix-parser")
        XCTAssertNil(TaskPullRequestSources.branchToAsk(in: repo, reader: reader(head: "ref: refs/heads/main\n")),
                     "the default branch")
        XCTAssertNil(TaskPullRequestSources.branchToAsk(in: repo, reader: reader(head: "ref: refs/heads/master\n",
                                                                                 originHead: nil)),
                     "without origin/HEAD, main and master")
        XCTAssertEqual(TaskPullRequestSources.branchToAsk(in: repo, reader: reader(head: "ref: refs/heads/master\n")),
                       "master", "origin's default is main here")
        XCTAssertNil(TaskPullRequestSources.branchToAsk(in: repo, reader: reader(head: "3f1c0a2e\n")), "detached HEAD")
        XCTAssertNil(TaskPullRequestSources.branchToAsk(in: repo, reader: reader(remote: "https://gitlab.com/o/r.git")))
        XCTAssertNil(TaskPullRequestSources.branchToAsk(in: URL(filePath: "/elsewhere"), reader: reader()))
    }

    // MARK: - When GitHub is asked

    func testThePolicyAsksOnShowingAndEveryFewMinutesWhileShown() {
        let policy = TaskPullRequestRefreshPolicy()
        let start = Date(timeIntervalSince1970: 1_000_000)
        func ask(after seconds: TimeInterval, _ occasion: TaskPullRequestRefreshPolicy.Occasion, focused: Bool = true,
                 changed: Bool = false, settled: Bool = false) -> Bool {
            policy.shouldAsk(lastAsked: start, now: start.addingTimeInterval(seconds), occasion: occasion,
                             isFocused: focused, subjectChanged: changed, settled: settled)
        }
        XCTAssertTrue(policy.shouldAsk(lastAsked: nil, now: start, occasion: .shown, subjectChanged: false, settled: false))
        XCTAssertFalse(ask(after: 30, .shown), "shown again soon after an answer")
        XCTAssertTrue(ask(after: 61, .shown))
        XCTAssertFalse(ask(after: 120, .stillShown))
        XCTAssertTrue(ask(after: 181, .stillShown))
        XCTAssertFalse(ask(after: 200, .stillShown, focused: false), "a row waits longer")
        XCTAssertTrue(ask(after: 301, .stillShown, focused: false))
        XCTAssertTrue(ask(after: 1, .stillShown, changed: true), "another pull request or branch")
        XCTAssertFalse(ask(after: 10_000, .stillShown, settled: true), "merged does not change")
    }

    // MARK: - The monitor

    private static let repo = URL(filePath: "/tmp/pr-monitor-repo")

    private static func claudeTarget(_ id: UUID = UUID(), working: Bool = false) -> TaskPullRequestTarget {
        TaskPullRequestTarget(taskID: id, workspaceURL: repo, claudeConversation: ClaudeConversationReference(
            taskID: id, providerSessionID: "5b0c9d0e-1111-4222-8333-944455556666",
            configDirectory: URL(filePath: "/tmp/no-config")), isWorking: working)
    }

    private static func codexTarget(_ id: UUID = UUID(), folder: URL = repo) -> TaskPullRequestTarget {
        TaskPullRequestTarget(taskID: id, workspaceURL: folder, claudeConversation: nil, isWorking: false)
    }

    @MainActor
    private func monitor(link: LinkBox, branch: String? = "feature", cli: FakeGitHubCLI,
                         clock: PullRequestTestClock) -> TaskPullRequestMonitor {
        let monitor = TaskPullRequestMonitor()
        monitor.now = { clock.now }
        monitor.lookInterval = .seconds(3_600)
        monitor.start(TaskPullRequestSources(
            scanLink: { _, _ in link.value.map { ClaudePullRequestLinkScan(file: Self.identity, scannedThrough: 1, link: $0) } },
            gitHubBranch: { _ in branch },
            gitHub: GitHubPullRequestClient(cli: cli)
        ))
        return monitor
    }

    @MainActor
    func testATaskInViewShowsItsLinkAtOnceAndGitHubsStateAfter() async {
        let link = LinkBox(TaskPullRequestLink(number: 77, url: URL(string: "https://github.com/o/r/pull/77")!,
                                               repository: "o/r"))
        let cli = FakeGitHubCLI { _, _ in .init(status: 0, output: Self.ghJSON(state: "OPEN", review: "APPROVED",
                                                                                checks: [Self.run("COMPLETED", "FAILURE")]),
                                                 errorText: "") }
        let clock = PullRequestTestClock()
        let monitor = monitor(link: link, cli: cli, clock: clock)
        let target = Self.claudeTarget()
        await monitor.show([target]).value
        let shown = monitor.pullRequest(for: target.taskID)
        XCTAssertEqual(shown?.number, 77)
        XCTAssertEqual(shown?.state, .open)
        XCTAssertEqual(shown?.checks, .failing)
        XCTAssertEqual(shown?.review, .approved)
        XCTAssertEqual(shown?.source, .transcriptLink)
        XCTAssertEqual(monitor.questionCount, 1)

        // Shown again soon: not asked again. A look within the refresh interval: not asked either.
        await monitor.show([]).value
        clock.now += 20
        await monitor.show([target]).value
        await monitor.lookAtShownTasks()
        XCTAssertEqual(monitor.questionCount, 1)
        // After a few minutes in view: asked again.
        clock.now += 200
        await monitor.lookAtShownTasks()
        XCTAssertEqual(monitor.questionCount, 2)

        // Hidden: never asked, however long.
        await monitor.show([]).value
        clock.now += 10_000
        await monitor.lookAtShownTasks()
        XCTAssertEqual(monitor.questionCount, 2)
        XCTAssertEqual(monitor.pullRequest(for: target.taskID)?.number, 77, "what was known stays for the row")
    }

    @MainActor
    func testANewTaskScreenAsksAboutItsTasksAsASidebarRowDoes() async {
        let cli = FakeGitHubCLI { _, _ in .init(status: 0, output: Self.ghJSON(state: "OPEN",
                                                                                checks: [Self.run("COMPLETED", "FAILURE")]),
                                                 errorText: "") }
        let clock = PullRequestTestClock()
        let monitor = monitor(link: LinkBox(nil), cli: cli, clock: clock)
        let target = Self.codexTarget()
        let screen = UUID(), split = UUID()

        await monitor.showHome([target], screen: screen).value
        XCTAssertEqual(monitor.pullRequest(for: target.taskID)?.checks, .failing, "The failing checks row reads this")
        XCTAssertEqual(monitor.questionCount, 1)
        // The same task on another new-task screen, or in a sidebar row: nothing new to ask.
        await monitor.showHome([target], screen: split).value
        await monitor.showRow(target).value
        XCTAssertEqual(monitor.questionCount, 1)
        // A row's interval, not the title bar's.
        clock.now += 200
        await monitor.lookAtShownTasks()
        XCTAssertEqual(monitor.questionCount, 1)
        clock.now += 120
        await monitor.lookAtShownTasks()
        XCTAssertEqual(monitor.questionCount, 2)
        // The row and one screen leave; the other screen still shows the task.
        monitor.hideRow(target.taskID)
        await monitor.showHome([], screen: screen).value
        clock.now += 400
        await monitor.lookAtShownTasks()
        XCTAssertEqual(monitor.questionCount, 3)
        // Every screen gone: never asked again.
        await monitor.showHome([], screen: split).value
        clock.now += 10_000
        await monitor.lookAtShownTasks()
        XCTAssertEqual(monitor.questionCount, 3)
    }

    @MainActor
    func testWithoutGhTheLinksNumberShowsWithoutAState() async {
        let link = LinkBox(TaskPullRequestLink(number: 5, url: URL(string: "https://github.com/o/r/pull/5")!,
                                               repository: "o/r"))
        let cli = FakeGitHubCLI { _, _ in throw GitHubCLIFailure.missing }
        let monitor = monitor(link: link, cli: cli, clock: PullRequestTestClock())
        let target = Self.claudeTarget()
        await monitor.show([target]).value
        let shown = monitor.pullRequest(for: target.taskID)
        XCTAssertEqual(shown?.number, 5)
        XCTAssertNil(shown?.state)
        XCTAssertFalse(shown?.hasState ?? true)
        XCTAssertNil(shown.flatMap(TaskPullRequestRowMark.init), "the row stays quiet without a state")
        XCTAssertEqual(TaskPullRequestBadge(shown!).title, L10n.format("PR #%@", String(5)))
        // A pull request number is an identifier, never grouped like a count.
        let big = TaskPullRequest(number: 2356, url: shown!.url, repository: shown!.repository, state: .merged)
        XCTAssertEqual(TaskPullRequestBadge(big).title, "PR #2356")

        // Signed out of gh: the same.
        let signedOut = self.monitor(link: link, cli: FakeGitHubCLI { _, _ in
            .init(status: 4, output: Data(), errorText: "gh auth login")
        }, clock: PullRequestTestClock())
        await signedOut.show([target]).value
        XCTAssertEqual(signedOut.pullRequest(for: target.taskID)?.number, 5)
        XCTAssertNil(signedOut.pullRequest(for: target.taskID)?.state)
    }

    @MainActor
    func testATaskWithoutALinkIsFoundByItsBranchAndTasksOnTheSameBranchShareOneQuestion() async {
        let answers = AnswerBox(.init(status: 0, output: Self.ghJSON(state: "OPEN", isDraft: true, number: 12), errorText: ""))
        let cli = FakeGitHubCLI { _, _ in answers.value }
        let clock = PullRequestTestClock()
        let monitor = monitor(link: LinkBox(nil), cli: cli, clock: clock)
        let first = Self.codexTarget()
        let second = Self.codexTarget()
        let firstLook = monitor.showRow(first)
        await monitor.showRow(second).value
        await firstLook.value
        await monitor.lookAtShownTasks()
        XCTAssertEqual(monitor.pullRequest(for: first.taskID)?.state, .draft)
        XCTAssertEqual(monitor.pullRequest(for: second.taskID)?.state, .draft)
        XCTAssertEqual(monitor.pullRequest(for: first.taskID)?.source, .branch("feature"))
        XCTAssertEqual(monitor.questionCount, 1, "one question for the branch both tasks are on")
        // Another task on the branch comes into view after the answer: it takes that answer.
        let third = Self.codexTarget()
        await monitor.showRow(third).value
        XCTAssertEqual(monitor.pullRequest(for: third.taskID)?.state, .draft)
        XCTAssertEqual(monitor.questionCount, 1, "a task that reads its branch after the answer does not ask again")

        // The branch's pull request is gone: it is no longer shown.
        answers.value = .init(status: 1, output: Data(), errorText: "no pull requests found for branch \"feature\"")
        clock.now += 400
        await monitor.lookAtShownTasks()
        XCTAssertNil(monitor.pullRequest(for: first.taskID))
        XCTAssertNil(monitor.pullRequest(for: second.taskID))
        XCTAssertNil(monitor.pullRequest(for: third.taskID))

        // A pull request on the branch merges: tasks that share the checkout all show it merged, so
        // "Archive N tasks with merged pull requests…" counts every one of them when they are nested
        // under one task and nothing holds them back (`SidebarMergedNestedTasks`).
        answers.value = .init(status: 0, output: Self.ghJSON(state: "MERGED", number: 13), errorText: "")
        clock.now += 400
        await monitor.lookAtShownTasks()
        let sharing = [first, second, third].map(\.taskID)
        XCTAssertEqual(SidebarMergedNestedTasks(nested: sharing, pullRequest: { monitor.pullRequest(for: $0) },
                                                isHeld: { _ in false })?.taskIDs, sharing)
    }

    @MainActor
    func testANewLinkWhenATurnEndsIsAskedAboutAtOnceAndAMergedOneIsNotAskedAgain() async {
        let link = LinkBox(nil)
        let cli = FakeGitHubCLI { arguments, _ in
            .init(status: 0, output: Self.ghJSON(state: "MERGED", number: arguments.contains { $0.hasSuffix("/pull/9") } ? 9 : 1),
                  errorText: "")
        }
        let monitor = monitor(link: link, branch: nil, cli: cli, clock: PullRequestTestClock())
        let id = UUID()
        await monitor.show([Self.claudeTarget(id, working: true)]).value
        XCTAssertNil(monitor.pullRequest(for: id))
        XCTAssertEqual(monitor.questionCount, 0, "nothing to ask about")

        // The turn opened a pull request; when it ends the transcript is read again.
        link.value = TaskPullRequestLink(number: 9, url: URL(string: "https://github.com/o/r/pull/9")!, repository: "o/r")
        await monitor.show([Self.claudeTarget(id, working: false)]).value
        XCTAssertEqual(monitor.pullRequest(for: id)?.state, .merged)
        XCTAssertEqual(monitor.questionCount, 1)
        await monitor.lookAtShownTasks()
        XCTAssertEqual(monitor.questionCount, 1)
    }

    @MainActor
    func testAtMostTwoGhCommandsRunAtOnce() async {
        let cli = FakeGitHubCLI(delay: .milliseconds(30)) { arguments, folder in
            .init(status: 0, output: Self.ghJSON(state: "OPEN"), errorText: "")
        }
        let monitor = TaskPullRequestMonitor()
        monitor.start(TaskPullRequestSources(scanLink: { _, _ in nil },
                                             gitHubBranch: { $0.lastPathComponent },
                                             gitHub: GitHubPullRequestClient(cli: cli)))
        let targets = (0..<6).map { Self.codexTarget(folder: URL(filePath: "/tmp/repos/r\($0)")) }
        await monitor.show(targets).value
        XCTAssertEqual(monitor.questionCount, 6)
        let most = await cli.mostAtOnce
        XCTAssertEqual(most, 2)
    }

    @MainActor
    func testNothingIsReadBeforeTheLookupsStart() async {
        let monitor = TaskPullRequestMonitor()
        await monitor.show([Self.claudeTarget()]).value
        monitor.showRow(Self.codexTarget())
        await monitor.lookAtShownTasks()
        XCTAssertTrue(monitor.pullRequests.isEmpty)
        XCTAssertEqual(monitor.questionCount, 0)
    }

    /// A view showing one task's pull request redraws for that task's answer only, not whenever any
    /// task in view hears back from GitHub.
    @MainActor
    func testEachTasksPullRequestIsObservedOnItsOwn() {
        let monitor = TaskPullRequestMonitor()
        let shown = UUID()
        let other = UUID()
        let url = URL(string: "https://github.com/o/r/pull/3")!
        let changes = ObservedChanges()
        withObservationTracking { _ = monitor.pullRequest(for: shown) } onChange: { changes.add() }
        monitor.setPullRequest(TaskPullRequest(number: 4, url: url, repository: "o/r"), for: other)
        XCTAssertEqual(changes.count, 0)
        monitor.setPullRequest(TaskPullRequest(number: 3, url: url, repository: "o/r"), for: shown)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(monitor.pullRequest(for: shown)?.number, 3)
    }

    // MARK: - Badge and row mark

    func testTheBadgeTintsAsTheClaudeAppsSessionGlyph() {
        let url = URL(string: "https://github.com/o/r/pull/3")!
        func badge(_ state: TaskPullRequest.State?, checks: TaskPullRequest.Checks? = nil,
                   review: TaskPullRequest.Review? = nil) -> TaskPullRequestBadge {
            TaskPullRequestBadge(TaskPullRequest(number: 3, url: url, repository: nil, state: state, checks: checks,
                                                 review: review))
        }
        XCTAssertEqual(badge(nil).tone, .neutral)
        XCTAssertEqual(badge(nil).facts, [])
        XCTAssertEqual(badge(.open).tone, .success)
        XCTAssertEqual(badge(.open).glyph, .pullRequest)
        XCTAssertEqual(badge(.draft).tone, .neutral)
        XCTAssertEqual(badge(.merged).glyph, .merged)
        XCTAssertEqual(badge(.merged).tone, .merged)
        XCTAssertEqual(badge(.closed).tone, .failure)
        XCTAssertEqual(badge(.open, review: .changesRequested).glyph, .changesRequested)
        XCTAssertEqual(badge(.open, review: .changesRequested).tone, .failure)
        XCTAssertEqual(badge(.open, review: .approved).glyph, .approved)
        XCTAssertEqual(badge(.open, checks: .failing).checksTone, .failure)
        XCTAssertEqual(badge(.open, checks: .pending).checksTone, .pending)
        XCTAssertNil(badge(.merged, checks: .failing).checksTone, "checks only beside an open or draft one")
        let full = badge(.open, checks: .failing, review: .changesRequested)
        XCTAssertEqual(full.facts, [L10n.string("Pull request state open"), L10n.string("Checks failing"),
                                    L10n.string("Changes requested")])
        XCTAssertEqual(full.help, "o/r #3\n" + ([L10n.string("Pull request")] + full.facts).joined(separator: " · "))
        XCTAssertEqual(full.accessibilityLabel, L10n.format("Pull request #%@", String(3)))

        // The row's quiet mark: the Claude app's state glyph and tint for every known state, no number.
        func mark(_ state: TaskPullRequest.State?, checks: TaskPullRequest.Checks? = nil,
                  review: TaskPullRequest.Review? = nil) -> TaskPullRequestRowMark? {
            TaskPullRequestRowMark(TaskPullRequest(number: 3, url: url, repository: nil, state: state, checks: checks,
                                                   review: review))
        }
        XCTAssertEqual(mark(.open)?.glyph, .pullRequest)
        XCTAssertEqual(mark(.open)?.tone, .success)
        XCTAssertEqual(mark(.draft)?.glyph, .pullRequest)
        XCTAssertEqual(mark(.draft)?.tone, .neutral)
        XCTAssertEqual(mark(.merged)?.glyph, .merged)
        XCTAssertEqual(mark(.merged)?.tone, .merged)
        XCTAssertEqual(mark(.closed)?.glyph, .pullRequest)
        XCTAssertEqual(mark(.closed)?.tone, .failure)
        XCTAssertEqual(mark(.open, review: .changesRequested)?.glyph, .changesRequested)
        XCTAssertEqual(mark(.open, review: .changesRequested)?.tone, .failure)
        XCTAssertEqual(mark(.open, checks: .pending, review: .approved)?.glyph, .approved)
        XCTAssertEqual(mark(.open, checks: .pending, review: .approved)?.tone, .success)
        // Failing checks turn an open or draft one's mark red, ahead of approval and behind a
        // person's request for changes; passing or running checks change nothing. The checks stay
        // in the row's help and accessibility value, with the number.
        XCTAssertEqual(mark(.open, checks: .failing)?.glyph, .checksFailing)
        XCTAssertEqual(mark(.open, checks: .failing)?.tone, .failure)
        XCTAssertEqual(mark(.draft, checks: .failing)?.glyph, .checksFailing)
        XCTAssertEqual(mark(.open, checks: .failing, review: .approved)?.glyph, .checksFailing)
        XCTAssertEqual(mark(.open, checks: .failing, review: .changesRequested)?.glyph, .changesRequested)
        XCTAssertEqual(mark(.open, checks: .passing)?.glyph, .pullRequest)
        XCTAssertEqual(mark(.open, checks: .pending)?.tone, .success)
        XCTAssertEqual(mark(.merged, checks: .failing)?.glyph, .merged, "checks only for an open or draft one")
        XCTAssertEqual(mark(.closed, checks: .failing)?.glyph, .pullRequest)
        XCTAssertEqual(badge(.open, checks: .failing).glyph, .pullRequest,
                       "The title bar keeps the state's glyph and shows checks as its dot")
        XCTAssertEqual(Set([TaskPullRequestBadge.Glyph.pullRequest, .merged, .approved, .changesRequested,
                            .checksFailing].map(\.systemName)).count, 5, "each mark has its own symbol")
        XCTAssertEqual(mark(.open, checks: .failing)?.help, ([L10n.format("PR #%@", "3"),
            L10n.string("Pull request state open"), L10n.string("Checks failing")]).joined(separator: " · "))
        XCTAssertEqual(mark(.open, checks: .failing)?.accessibilityName, ([L10n.format("Pull request #%@", "3"),
            L10n.string("Pull request state open"), L10n.string("Checks failing")]).joined(separator: ", "))
        // The row's menu opens it by its number.
        XCTAssertEqual(mark(.merged)?.openTitle, L10n.format("Open pull request #%@", "3"))
        XCTAssertEqual(mark(.merged)?.url, url)
        XCTAssertNil(mark(nil), "no state, no mark")
        XCTAssertEqual(SidebarTaskIndicatorProjection.trailingItems(isWorktree: true, pullRequest: mark(.open),
                                                                    cpuPercent: 80, status: .running),
                       [.worktree, .pullRequest(mark(.open)!), .cpu(80), .status(.running)])
    }

    // MARK: - New task in a folder with a running task

    func testTheWarningShowsOnlyBesideARunningTaskInTheSameFolder() {
        let folder = URL(filePath: "/tmp/warn-repo", directoryHint: .isDirectory)
        func session(_ status: SessionStatus, in url: URL = folder) -> SessionRecord {
            SessionRecord(harness: .claudeCode, workspaceURL: url, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
                          title: "Running", status: status)
        }
        func warns(_ sessions: [SessionRecord], in url: URL? = folder, repository: Bool = true,
                   worktree: Bool = false, chat: Bool = false) -> Bool {
            NewTaskFolderConflict.runningTask(in: url, isInRepository: repository, startsInNewWorktree: worktree,
                                              startsChat: chat, sessions: sessions) != nil
        }
        XCTAssertTrue(warns([session(.running)]))
        XCTAssertTrue(warns([session(.waitingForApproval)]))
        XCTAssertTrue(warns([session(.running, in: URL(filePath: "/tmp/warn-repo/"))]), "the same folder spelled differently")
        XCTAssertFalse(warns([session(.completed), session(.ready), session(.failed)]), "nothing running")
        XCTAssertFalse(warns([session(.running, in: folder.appending(path: "packages/app"))]), "another folder")
        XCTAssertFalse(warns([session(.running, in: URL(filePath: "/Users/me/.yardlet/worktrees/warn-repo/fix"))]),
                       "a task in its own worktree")
        XCTAssertFalse(warns([session(.running)], worktree: true), "the new task starts in a worktree")
        XCTAssertFalse(warns([session(.running)], repository: false), "no worktree is possible outside Git")
        XCTAssertFalse(warns([session(.running)], chat: true))
        XCTAssertFalse(warns([session(.running)], in: nil))
    }
}

// MARK: - Fakes

/// Answers `gh` as a test says, recording what it was asked. Never starts a process.
final class FakeGitHubCLI: GitHubCLIRunning, @unchecked Sendable {
    struct Call: Equatable { let arguments: [String]; let directory: URL }
    private let respond: @Sendable ([String], URL) throws -> GitHubCLIOutput
    private let delay: Duration?
    private let state = Counter()

    init(delay: Duration? = nil, respond: @escaping @Sendable ([String], URL) throws -> GitHubCLIOutput) {
        self.respond = respond
        self.delay = delay
    }

    var calls: [Call] { get async { await state.calls } }
    var mostAtOnce: Int { get async { await state.most } }

    func run(_ arguments: [String], in directory: URL, timeout: Duration) async throws -> GitHubCLIOutput {
        await state.begin(Call(arguments: arguments, directory: directory))
        if let delay { try? await Task.sleep(for: delay) }
        await state.end()
        return try respond(arguments, directory)
    }

    private actor Counter {
        var calls: [Call] = []
        var running = 0
        var most = 0
        func begin(_ call: Call) {
            calls.append(call)
            running += 1
            most = max(most, running)
        }
        func end() { running -= 1 }
    }
}

final class LinkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TaskPullRequestLink?
    init(_ value: TaskPullRequestLink?) { stored = value }
    var value: TaskPullRequestLink? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

final class AnswerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: GitHubCLIOutput
    init(_ value: GitHubCLIOutput) { stored = value }
    var value: GitHubCLIOutput {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@MainActor
final class PullRequestTestClock {
    var now = Date(timeIntervalSince1970: 2_000_000)
}

private final class ObservedChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
}
