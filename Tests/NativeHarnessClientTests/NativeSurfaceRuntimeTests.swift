import AppKit
import Darwin
import Foundation
import SwiftTerm
import XCTest
@testable import NativeHarnessClient

final class NativeSurfaceRuntimeTests: XCTestCase {
    func testGitDiffIncludesUntrackedFilesAndWorksBeforeFirstCommit() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "nhc-new-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try runGit(["init", "-q"], in: root)
        try Data("staged\n".utf8).write(to: root.appending(path: "staged.txt"))
        try runGit(["add", "staged.txt"], in: root)
        try Data("latest\n".utf8).write(to: root.appending(path: "staged.txt"))
        try Data("new\n".utf8).write(to: root.appending(path: "한글 new.txt"))
        try Data().write(to: root.appending(path: "empty.txt"))
        try Data([0, 1, 2]).write(to: root.appending(path: "binary.bin"))
        let first = try await GitDiffService().load(workspaceURL: root)
        XCTAssertEqual(Set(first.files.map(\.path)), Set(["staged.txt", "한글 new.txt", "empty.txt", "binary.bin"]))
        XCTAssertEqual(first.files.first { $0.path == "staged.txt" }?.oldPath, "staged.txt")
        XCTAssertTrue(first.lines.contains { $0.text == "+latest" })
        XCTAssertTrue(first.lines.contains { $0.text == "-staged" })
        XCTAssertFalse(first.lines.contains { $0.text == "+staged" })
        XCTAssertTrue(first.files.first { $0.path == "binary.bin" }?.isBinary == true)
        let staged = try await GitDiffService().load(workspaceURL: root, target: .staged)
        XCTAssertEqual(staged.files.map(\.path), ["staged.txt"])
        XCTAssertNil(staged.files.first?.oldPath)
        XCTAssertTrue(staged.lines.contains { $0.text == "+staged" })
        XCTAssertFalse(staged.lines.contains { $0.text == "+latest" })

        try runGit(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "-qm", "initial"], in: root)
        try FileManager.default.createDirectory(at: root.appending(path: "nested"), withIntermediateDirectories: true)
        let next = try await GitDiffService().load(workspaceURL: root.appending(path: "nested"))
        XCTAssertEqual(next.fileCount, 4)
        XCTAssertTrue(next.lines.contains { $0.text == "-staged" })
        XCTAssertTrue(next.lines.contains { $0.text == "+latest" })
        XCTAssertFalse(next.isTruncated)
    }

    func testReviewScopesKeepOpposingStagedAndUnstagedChangesWithoutWritingIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "nhc-review-scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try runGit(["init", "-q"], in: root)
        let file = root.appending(path: "한글 review.txt")
        try Data("base 👩🏽‍💻\n".utf8).write(to: file)
        try runGit(["add", "."], in: root)
        try runGit(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "-qm", "initial"], in: root)
        try Data("indexed 👩🏽‍💻\n".utf8).write(to: file)
        try runGit(["add", "."], in: root)
        // The working tree equals HEAD, but both review scopes still contain real changes.
        try Data("base 👩🏽‍💻\n".utf8).write(to: file)
        try Data("new\n".utf8).write(to: root.appending(path: "untracked.txt"))
        let index = try Data(contentsOf: root.appending(path: ".git/index"))

        let unstaged = try await GitDiffService().load(workspaceURL: root)
        let staged = try await GitDiffService().load(workspaceURL: root, target: .staged)
        XCTAssertEqual(Set(unstaged.files.map(\.path)), ["한글 review.txt", "untracked.txt"])
        XCTAssertEqual(staged.files.map(\.path), ["한글 review.txt"])
        XCTAssertTrue(unstaged.lines.contains { $0.text == "-indexed 👩🏽‍💻" })
        XCTAssertTrue(unstaged.lines.contains { $0.text == "+base 👩🏽‍💻" })
        XCTAssertTrue(staged.lines.contains { $0.text == "-base 👩🏽‍💻" })
        XCTAssertTrue(staged.lines.contains { $0.text == "+indexed 👩🏽‍💻" })
        XCTAssertEqual(try Data(contentsOf: root.appending(path: ".git/index")), index)
    }

    func testCleanGitRepositoryHasNoSyntheticBlankDiffLine() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "nhc-clean-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try runGit(["init", "-q"], in: root)
        try runGit(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "--allow-empty", "-qm", "initial"], in: root)
        let snapshot = try await GitDiffService().load(workspaceURL: root)
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertTrue(snapshot.lines.isEmpty)
    }

    func testGitDiffServiceReadsWorkingTreeChange() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "nhc-diff-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try runGit(["init", "-q"], in: root)
        let fileURL = root.appending(path: "example.txt")
        try Data("old\n".utf8).write(to: fileURL)
        try runGit(["add", "example.txt"], in: root)
        try runGit([
            "-c", "user.name=Native Harness Client",
            "-c", "user.email=nhc@example.invalid",
            "commit", "-qm", "initial"
        ], in: root)
        try Data("new\n".utf8).write(to: fileURL)

        let snapshot = try await GitDiffService().load(workspaceURL: root)

        XCTAssertTrue(snapshot.lines.contains { $0.kind == .deletion && $0.text == "-old" })
        XCTAssertTrue(snapshot.lines.contains { $0.kind == .addition && $0.text == "+new" })
        XCTAssertFalse(snapshot.isTruncated)
    }

    func testGitDiffFailurePreservesExitCodeAndMessageAsGitError() async throws {
        do {
            _ = try await GitDiffService(
                executableURL: URL(filePath: "/bin/sh"),
                arguments: ["-c", "printf 'fixture git failure' >&2; exit 7"]
            ).load(workspaceURL: FileManager.default.temporaryDirectory)
            XCTFail("A failed Git command should not become an empty diff")
        } catch let error as GitDiffServiceError {
            XCTAssertEqual(error, .commandFailed(code: 7, message: "fixture git failure"))
        }
    }

    func testGitDiffServiceTerminatesTimedOutProcess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "nhc-diff-timeout-(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let startedAt = ContinuousClock.now
        do {
            _ = try await GitDiffService(
                processTimeout: .milliseconds(50),
                executableURL: URL(filePath: "/bin/sh"),
                arguments: ["-c", "sleep 120"]
            ).load(workspaceURL: root)
            XCTFail("A blocked diff process should time out")
        } catch let error as GitDiffServiceError {
            XCTAssertEqual(error, .timedOut)
        }
        XCTAssertLessThan(ContinuousClock.now - startedAt, .seconds(3))
    }

    func testGitDiffServiceCancellationTerminatesProcess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "nhc-diff-cancel-(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let loadTask = Task { () throws -> DiffSnapshot in
            try await GitDiffService(
                processTimeout: .seconds(30),
                executableURL: URL(filePath: "/bin/sh"),
                arguments: ["-c", "sleep 120"]
            ).load(workspaceURL: root)
        }
        try await Task.sleep(for: .milliseconds(50))
        loadTask.cancel()

        do {
            _ = try await loadTask.value
            XCTFail("A cancelled diff load should not complete")
        } catch is CancellationError {
            // Expected: the task cancellation path must reap the child process.
        }
    }

    @MainActor
    func testNativeTerminalReportsTheShellExitCodeInsteadOfWaitpidStatus() async throws {
        let session = try isolatedTerminalSession()
        let view = LocalProcessTerminalView(
            frame: NSRect(x: 0, y: 0, width: 700, height: 300),
            font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            options: TerminalOptions(cursorStyle: .steadyBlock, scrollback: 200)
        )
        session.attach(view)
        defer { session.stop() }
        session.send("exit 7\n")
        try await waitUntil { !session.isRunning }
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.exitCode, 7)
        XCTAssertNil(session.terminationSignal)
        session.stop()
        XCTAssertEqual(session.exitCode, 7)
    }

    @MainActor
    func testNativeTerminalUsesPTYAndStopsWithSurfaceLifecycle() async throws {
        let session = try isolatedTerminalSession()
        let view = LocalProcessTerminalView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 500),
            font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            options: TerminalOptions(cursorStyle: .steadyBlock, scrollback: 200)
        )
        session.attach(view)
        session.send(
            "if test -t 0 && test -t 1; "
                + "then printf '\\033[32mNHC_%s_%s\\033[0m\\r\\n' 'PTY' 'OK'; "
                + "else printf 'NHC_%s_%s\\r\\n' 'NOT' 'PTY'; fi\n"
        )

        try await waitUntil { session.bufferText.contains("NHC_PTY_OK") }
        XCTAssertTrue(session.isRunning)
        XCTAssertTrue(session.bufferText.contains("NHC_PTY_OK"))
        XCTAssertFalse(session.bufferText.contains("NHC_NOT_PTY"), session.bufferText)
        let shellPID = try XCTUnwrap(session.process?.shellPid)
        XCTAssertGreaterThan(shellPID, 0)
        session.stop()
        XCTAssertFalse(session.isRunning)

        try await waitUntil { Darwin.kill(shellPID, 0) != 0 }
        errno = 0
        XCTAssertEqual(Darwin.kill(shellPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    @MainActor
    func testNativeTerminalStopsDescendantProcessGroup() async throws {
        let session = try isolatedTerminalSession()
        let view = LocalProcessTerminalView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 500),
            font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            options: TerminalOptions(cursorStyle: .steadyBlock, scrollback: 200)
        )
        session.attach(view)
        defer { session.stop() }

        session.send(
            "sleep 120 & child=$!; printf 'NHC_CHILD_PID=%s\\r\\n' \"$child\"; wait\n"
        )

        var childPID: pid_t?
        let startDeadline = ContinuousClock.now + testWaitLimit
        while childPID == nil, ContinuousClock.now < startDeadline {
            if let marker = session.bufferText.components(separatedBy: "NHC_CHILD_PID=").last,
               let token = marker.split(whereSeparator: { $0 == " " || $0 == "\r" || $0 == "\n" }).first,
               let value = Int32(String(token)) {
                childPID = value
            } else {
                try await Task.sleep(for: .milliseconds(25))
            }
        }

        let descendantPID = try XCTUnwrap(childPID, session.bufferText)
        XCTAssertGreaterThan(descendantPID, 0)
        XCTAssertEqual(Darwin.kill(descendantPID, 0), 0)

        session.stop()
        XCTAssertFalse(session.isRunning)

        try await waitUntil { Darwin.kill(descendantPID, 0) != 0 }
        errno = 0
        XCTAssertEqual(Darwin.kill(descendantPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testNativeProcessTreeStopsWrapperDescendants() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appending(path: "nhc-process-tree-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "sleep 120 & echo $! > \(pidFile.path); wait"]
        try process.run()
        defer {
            if process.isRunning {
                _ = NativeProcessTree.terminate(process: process)
            }
        }

        var childPID: pid_t?
        let startDeadline = ContinuousClock.now + testWaitLimit
        while childPID == nil, ContinuousClock.now < startDeadline {
            if let value = try? String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               let parsed = Int32(value), parsed > 0 {
                childPID = parsed
            } else {
                try await Task.sleep(for: .milliseconds(25))
            }
        }

        let descendantPID = try XCTUnwrap(childPID)
        XCTAssertEqual(Darwin.kill(descendantPID, 0), 0)
        let terminationStartedAt = ContinuousClock.now
        let exitCode = NativeProcessTree.terminate(process: process)
        XCTAssertLessThan(ContinuousClock.now - terminationStartedAt, .seconds(3))
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(exitCode, process.terminationStatus)

        try await waitUntil { Darwin.kill(descendantPID, 0) != 0 }
        errno = 0
        XCTAssertEqual(Darwin.kill(descendantPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = GitExecutableLocator.preferredURL()
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HarnessAdapterError.processExited(
                code: process.terminationStatus,
                message: String(decoding: data, as: UTF8.self)
            )
        }
    }

    /// A terminal whose zsh reads an empty `ZDOTDIR`: the commands these tests type must not go
    /// into the person's own shell history, and their rc files must not slow or change the shell.
    @MainActor
    private func isolatedTerminalSession() throws -> NativeTerminalSession {
        let home = FileManager.default.temporaryDirectory.appending(path: "nhc-terminal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return NativeTerminalSession(workspaceURL: FileManager.default.temporaryDirectory, launch: .isolatedZsh(in: home))
    }
}
