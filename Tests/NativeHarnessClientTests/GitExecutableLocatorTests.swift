import Foundation
import Testing
@testable import NativeHarnessClient

struct GitExecutableLocatorTests {
    @Test func testSelectedGitReadsBothReviewScopesWithoutChangingIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try runGit(["init", "-q"], at: root)
        let file = root.appending(path: "review.txt")
        try Data("indexed\n".utf8).write(to: file)
        try runGit(["add", "review.txt"], at: root)
        try Data("working\n".utf8).write(to: file)
        try Data("new file\n".utf8).write(to: root.appending(path: "새 파일.txt"))
        // A folder may come with a config of its own that names a program for Git to start as it reads.
        let monitor = root.appending(path: ".git/monitor.sh")
        try Data("#!/bin/sh\ntouch \"$(dirname \"$0\")/ran\"\n".utf8).write(to: monitor)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: monitor.path)
        try runGit(["config", "core.fsmonitor", monitor.path], at: root)
        let indexURL = root.appending(path: ".git/index")
        let index = try Data(contentsOf: indexURL)
        let service = GitDiffService()
        let unstaged = try await service.load(workspaceURL: root)
        let staged = try await service.load(workspaceURL: root, target: .staged)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".git/ran").path),
                "Reading a folder starts no program its config names")
        let given = GitExecutableLocator.withFileSystemMonitorOff(["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "a.b",
                                                                   "GIT_CONFIG_VALUE_0": "c"])
        #expect(given == ["GIT_CONFIG_COUNT": "2", "GIT_CONFIG_KEY_0": "a.b", "GIT_CONFIG_VALUE_0": "c",
                          "GIT_CONFIG_KEY_1": "core.fsmonitor", "GIT_CONFIG_VALUE_1": "false"])
        #expect(Set(unstaged.files.map(\.path)) == ["review.txt", "새 파일.txt"])
        #expect(staged.files.map(\.path) == ["review.txt"])
        #expect(unstaged.lines.contains { $0.text == "+working" })
        #expect(staged.lines.contains { $0.text == "+indexed" })
        #expect(try Data(contentsOf: indexURL) == index)
    }

    @Test func testStandardLookupPrefersIndependentGitAndFallsBackToAppleGit() {
        var visited: [String] = []
        let selected = GitExecutableLocator.preferredURL { path in
            visited.append(path)
            return path == "/usr/local/bin/git"
        }
        #expect(selected.path == "/usr/local/bin/git")
        #expect(visited == ["/opt/homebrew/bin/git", "/usr/local/bin/git"])
        #expect(GitExecutableLocator.preferredURL(isExecutableFile: { _ in false }).path == "/usr/bin/git")
    }

    /// On Windows Git is `git.exe` in an absolute folder of `Path`, else where Git for Windows installs it for everyone,
    /// for one person, or through Scoop; a relative folder of `Path` is never looked in.
    @Test func testWindowsLooksInPathThenWhereGitForWindowsInstalls() {
        let environment = [
            "Path": "C:\\Windows\\system32;.\\tools;tools;C:\\Program Files\\Git\\cmd\\",
            "ProgramFiles": "C:\\Program Files", "PROGRAMFILES(X86)": "C:\\Program Files (x86)",
            "LocalAppData": "C:\\Users\\me\\AppData\\Local", "USERPROFILE": "C:\\Users\\me"
        ]
        let candidates = GitExecutableLocator.windowsCandidates(environment: environment)
        #expect(candidates == [
            "C:\\Windows\\system32\\git.exe", "C:\\Program Files\\Git\\cmd\\git.exe",
            "C:\\Program Files (x86)\\Git\\cmd\\git.exe", "C:\\Users\\me\\AppData\\Local\\Programs\\Git\\cmd\\git.exe",
            "C:\\Users\\me\\scoop\\apps\\git\\current\\cmd\\git.exe"
        ])
        #expect(GitExecutableLocator.windowsCandidates(environment: ["ProgramFiles": "Program Files"]).isEmpty)
    }

    @Test func testSkipsDirectoriesAndNonExecutableFiles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "git")
        try Data("not executable".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(GitExecutableLocator.preferredURL(candidates: [root.path, file.path]).path == "/usr/bin/git")
    }

    @Test func testExplicitDiffExecutableStillControlsTheProcess() async throws {
        do {
            _ = try await GitDiffService(
                executableURL: URL(filePath: "/bin/sh"),
                arguments: ["-c", "printf 'explicit executable' >&2; exit 37"]
            ).load(workspaceURL: FileManager.default.temporaryDirectory)
            Issue.record("Expected the injected executable's failure")
        } catch let error as GitDiffServiceError {
            #expect(error == .commandFailed(code: 37, message: "explicit executable"))
        }
    }

    @Test func testWarningsOnStandardErrorStayOutOfTheDiff() async throws {
        let snapshot = try await GitDiffService(
            executableURL: URL(filePath: "/bin/sh"),
            arguments: ["-c", """
                printf 'warning: fixture noise\\n' >&2
                printf 'diff --git a/a.txt b/a.txt\\n--- a/a.txt\\n+++ b/a.txt\\n@@ -1 +1 @@\\n-old\\n+new\\n'
                """]
        ).load(workspaceURL: FileManager.default.temporaryDirectory)
        #expect(snapshot.files.map(\.path) == ["a.txt"])
        #expect(!snapshot.lines.contains { $0.text.contains("fixture noise") })
        #expect(snapshot.lines.contains { $0.text == "+new" })
    }

    private func runGit(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = GitExecutableLocator.preferredURL()
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "GitFixture", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
        }
    }
}
