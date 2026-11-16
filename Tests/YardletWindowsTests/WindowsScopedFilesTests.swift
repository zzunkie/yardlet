import Foundation
import WinSDK
import XCTest
@testable import NativeHarnessClient

/// Reading and saving beneath a folder without following links on Windows (`ScopedFiles` and
/// `WorkspaceFileReplacement`, docs/PLATFORM_PORTABILITY.md), on a Windows CI runner: what Claude Code saved reads back,
/// a reviewed file is saved, and a link beneath the folder is refused, not followed.
final class WindowsScopedFilesTests: XCTestCase {
    private static let sessionID = "8F7C2A51-3E0B-4C47-9C2D-6A1B0E4F9D33"
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "yardlet-windows-tests-\(UUID().uuidString)",
                                                                  directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Files and folders beneath the root read as on the Mac, and a junction, a symbolic link to a folder and one to a
    /// file beneath it are refused, though each reaches a file outside. The root itself may be a link.
    func testReadsBeneathTheRootAndRefusesLinks() throws {
        let root = folder.appending(path: "projects", directoryHint: .isDirectory)
        let project = root.appending(path: "C--work-app", directoryHint: .isDirectory)
        let outside = folder.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("first\nsecond\n".utf8).write(to: project.appending(path: "session.jsonl"))
        try Data("secret\n".utf8).write(to: outside.appending(path: "session.jsonl"))
        try makeLink(root.appending(path: "junction"), to: outside, "/J")
        try makeLink(root.appending(path: "folder-link"), to: outside, "/D")
        try makeLink(project.appending(path: "file-link.jsonl"), to: outside.appending(path: "session.jsonl"), nil)

        let files = ScopedFiles(root: root)
        XCTAssertEqual(Set(try files.names([], limit: 10)), ["C--work-app", "junction", "folder-link"])
        XCTAssertEqual(try files.directories([], limit: 10), ["C--work-app"])
        XCTAssertEqual(Set(try files.names(["C--work-app"], limit: 10)), ["session.jsonl", "file-link.jsonl"])
        XCTAssertThrowsError(try files.names([], limit: 2))
        XCTAssertTrue(files.isDirectory([]))
        XCTAssertTrue(files.isDirectory(["C--work-app"]))
        XCTAssertFalse(files.isRegularFile(["C--work-app"]))
        XCTAssertTrue(files.isRegularFile(["C--work-app", "session.jsonl"]))
        XCTAssertFalse(files.isDirectory(["C--work-app", "session.jsonl"]))
        XCTAssertEqual(try files.data(["C--work-app", "session.jsonl"], maximumBytes: 100, tail: false)?.data,
                       Data("first\nsecond\n".utf8))
        XCTAssertNil(try files.data(["C--work-app", "session.jsonl"], maximumBytes: 8, tail: false))
        let tail = try XCTUnwrap(try files.data(["C--work-app", "session.jsonl"], maximumBytes: 8, tail: true))
        XCTAssertEqual(tail.data, Data("second\n".utf8))
        XCTAssertTrue(tail.truncated)

        let file = try XCTUnwrap(files.openRegularFile(["C--work-app", "session.jsonl"]))
        XCTAssertEqual(file.size, 13)
        let lines = try file.lines(from: 3, to: 13)
        XCTAssertEqual(lines.data, Data("second\n".utf8))
        XCTAssertEqual(lines.start, 6)
        XCTAssertEqual(files.openRegularFile(["C--work-app", "session.jsonl"])?.identity, file.identity)

        for link in [["junction"], ["folder-link"]] {
            XCTAssertFalse(files.isDirectory(link), "\(link)")
            XCTAssertEqual(try files.names(link, limit: 10), [], "\(link)")
            XCTAssertFalse(files.isRegularFile(link + ["session.jsonl"]), "\(link)")
            XCTAssertNil(files.openRegularFile(link + ["session.jsonl"]), "\(link)")
            XCTAssertNil(try files.data(link + ["session.jsonl"], maximumBytes: 100, tail: true), "\(link)")
        }
        XCTAssertFalse(files.isRegularFile(["C--work-app", "file-link.jsonl"]))
        XCTAssertNil(files.openRegularFile(["C--work-app", "file-link.jsonl"]))
        for name in ["", ".", "..", #"..\outside"#, "../outside", "session.jsonl:stream", "C:", "*.jsonl"] {
            XCTAssertFalse(files.isRegularFile(["C--work-app", name]), name)
            XCTAssertFalse(files.isDirectory([name]), name)
        }

        // As an account's `projects` linked to another's.
        let linkedRoot = folder.appending(path: "linked-projects", directoryHint: .isDirectory)
        try makeLink(linkedRoot, to: root, "/J")
        XCTAssertEqual(ScopedFiles(root: linkedRoot).openRegularFile(["C--work-app", "session.jsonl"])?.identity,
                       file.identity)
    }

    /// A transcript open for reading leaves Claude Code free to go on appending to it and to remove it.
    func testAnOpenFileLetsClaudeAppendAndRemove() throws {
        let root = folder.appending(path: "projects", directoryHint: .isDirectory)
        let project = root.appending(path: "C--work-app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let url = project.appending(path: "session.jsonl")
        try Data("first\n".utf8).write(to: url)
        let file = try XCTUnwrap(ScopedFiles(root: root).openRegularFile(["C--work-app", "session.jsonl"]))

        let writer = try FileHandle(forWritingTo: url)
        try writer.seekToEnd()
        try writer.write(contentsOf: Data("second\n".utf8))
        try writer.close()
        XCTAssertEqual(try file.read(100, at: 0), Data("first\nsecond\n".utf8))
        try FileManager.default.removeItem(at: url)
    }

    /// A conversation Claude Code saved opens with its earlier turns: the newest part first, then the parts before it,
    /// read through the file opened beneath the config's `projects`, back to its first request.
    func testAClaudeConversationReadsBackToItsFirstTurn() throws {
        let config = folder.appending(path: "config", directoryHint: .isDirectory)
        let project = config.appending(path: "projects/C--work-app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var data = Data()
        var parent: String?
        for index in 1...40 {
            for record in [Self.user("Request \(index)", uuid: "u-\(index)", parent: parent),
                           Self.assistant("Answer \(index). " + String(repeating: "Words of the answer. ", count: 60),
                                          uuid: "a-\(index)", parent: "u-\(index)")] {
                data.append(try JSONEncoder().encode(JSONValue.object(record)))
                data.append(10)
            }
            parent = "a-\(index)"
        }
        try data.write(to: project.appending(path: "\(Self.sessionID).jsonl"))

        let reader = ClaudeSubagentTranscriptReader(configDirectory: config)
        XCTAssertEqual(Self.requests(try XCTUnwrap(reader.readConversation(sessionID: Self.sessionID)).entries),
                       Array(1...40))
        var read = try XCTUnwrap(reader.readNewest(sessionID: Self.sessionID, bytes: 8_192))
        XCTAssertTrue(read.window.hasEarlierRecords)
        var shown = read.entries
        while read.window.hasEarlierRecords {
            read = try XCTUnwrap(reader.readEarlier(read.window, bytes: ClaudeTranscriptTail.budget(after: read.window.bytes)))
            shown = read.applied(to: shown)
        }
        XCTAssertEqual(Self.requests(shown), Array(1...40))
    }

    /// A reviewed file is saved over the old one, keeping its attributes and an access list of its own. A save through
    /// a junction, a symbolic link to a folder or one to a file beneath the folder is refused, though each reaches a
    /// file outside, and so is a save over bytes other than those reviewed, or one the caller stops at the last moment.
    func testSavesAReviewedFileAndRefusesLinks() throws {
        let root = folder.appending(path: "work", directoryHint: .isDirectory)
        let sources = root.appending(path: "Sources", directoryHint: .isDirectory)
        let outside = folder.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let secret = Data("secret\n".utf8)
        try secret.write(to: outside.appending(path: "App.swift"))
        try makeLink(root.appending(path: "junction"), to: outside, "/J")
        try makeLink(root.appending(path: "folder-link"), to: outside, "/D")
        try makeLink(sources.appending(path: "Link.swift"), to: outside.appending(path: "App.swift"), nil)
        for path in ["junction/App.swift", "folder-link/App.swift", "Sources/Link.swift", #"junction\App.swift"#,
                     "../outside/App.swift", #"Sources\..\..\outside\App.swift"#] {
            XCTAssertThrowsError(try Self.save(path, in: root, "changed\n", over: secret), path)
        }
        // Each link still reaches the file outside, which is as it was.
        for path in ["junction/App.swift", "folder-link/App.swift", "Sources/Link.swift"] {
            XCTAssertEqual(try Data(contentsOf: root.appending(path: path)), secret, path)
        }

        let file = sources.appending(path: "App.swift")
        let reviewed = Data("let a = 1\n".utf8)
        try reviewed.write(to: file)
        XCTAssertTrue(PathRules.windows.nativePath(of: file).withCString(encodedAs: UTF16.self) {
            SetFileAttributesW($0, DWORD(FILE_ATTRIBUTE_HIDDEN))
        })
        // The folder's entries copied into an access list of the file's own, which a new file there does not have.
        try accessList(file, change: "/inheritance:d")
        let ownList = try accessList(file)
        XCTAssertFalse(ownList.contains("(I)"), ownList)
        let fresh = sources.appending(path: "New.swift")
        try Data().write(to: fresh)
        XCTAssertTrue(try accessList(fresh).contains("(I)"))
        try FileManager.default.removeItem(at: fresh)

        XCTAssertThrowsError(try Self.save("Sources/App.swift", in: root, "let a = 2\n", over: Data("let a = 0\n".utf8))) {
            XCTAssertEqual($0 as? WorkspaceFileError, .changedOnDisk)
        }
        XCTAssertThrowsError(try WorkspaceFileReplacement.replace(
            path: "Sources/App.swift", in: root, with: Data("let a = 2\n".utf8),
            expectedDigest: WorkspaceFileReplacement.digest(reviewed), maximumBytes: 1_000) { throw CancellationError() })
        XCTAssertEqual(try Data(contentsOf: file), reviewed)

        try Self.save("Sources/App.swift", in: root, "let a = 2\n", over: reviewed)
        XCTAssertEqual(try Data(contentsOf: file), Data("let a = 2\n".utf8))
        let attributes = PathRules.windows.nativePath(of: file).withCString(encodedAs: UTF16.self) { GetFileAttributesW($0) }
        XCTAssertNotEqual(attributes & DWORD(FILE_ATTRIBUTE_HIDDEN), 0)
        XCTAssertEqual(try accessList(file), ownList)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: sources.path(percentEncoded: false))),
                       ["App.swift", "Link.swift"])
    }

    /// A save while another program has the file open: one reading it and sharing its removal, as most do, goes on
    /// reading the bytes it opened while the new file takes its place. One reading it without sharing its removal, or
    /// one writing to it, makes the save fail and leaves the file as it was, with nothing beside it.
    func testASaveWhileAnotherProgramHasTheFileOpen() throws {
        let root = folder.appending(path: "work", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "notes.txt")
        try Data("first\n".utf8).write(to: file)

        let reader = try XCTUnwrap(Self.open(file, access: DWORD(GENERIC_READ),
                                             sharing: DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)))
        try Self.save("notes.txt", in: root, "second\n", over: Data("first\n".utf8))
        XCTAssertEqual(try Data(contentsOf: file), Data("second\n".utf8))
        XCTAssertEqual(Self.read(reader), Data("first\n".utf8))
        CloseHandle(reader)

        for (access, sharing) in [(DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ)),
                                  (DWORD(GENERIC_WRITE), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE))] {
            let other = try XCTUnwrap(Self.open(file, access: access, sharing: sharing))
            XCTAssertThrowsError(try Self.save("notes.txt", in: root, "third\n", over: Data("second\n".utf8)),
                                 "access \(access), sharing \(sharing)")
            CloseHandle(other)
            XCTAssertEqual(try Data(contentsOf: file), Data("second\n".utf8))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false)), ["notes.txt"])
    }

    /// Saves `text` at `path` beneath `root` over the file holding `reviewed`.
    private static func save(_ path: String, in root: URL, _ text: String, over reviewed: Data) throws {
        try WorkspaceFileReplacement.replace(path: path, in: root, with: Data(text.utf8),
                                             expectedDigest: WorkspaceFileReplacement.digest(reviewed), maximumBytes: 1_000)
    }

    /// `url` opened as another program opens it, for `access` and sharing it as `sharing` says.
    private static func open(_ url: URL, access: DWORD, sharing: DWORD) -> HANDLE? {
        let handle = PathRules.windows.nativePath(of: url).withCString(encodedAs: UTF16.self) {
            CreateFileW($0, access, sharing, nil, DWORD(OPEN_EXISTING), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { return nil }
        return handle
    }

    /// What `handle` reads from where it is, up to 100 bytes.
    private static func read(_ handle: HANDLE) -> Data {
        var buffer = [UInt8](repeating: 0, count: 100)
        var count: DWORD = 0
        guard ReadFile(handle, &buffer, DWORD(buffer.count), &count, nil) else { return Data() }
        return Data(buffer.prefix(Int(count)))
    }

    /// The access list Windows' own `icacls` shows for `url`, after it makes `change` when there is one.
    @discardableResult
    private func accessList(_ url: URL, change: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: (ProcessInfo.processInfo.environment["SystemRoot"] ?? #"C:\Windows"#)
                                    + #"\System32\icacls.exe"#)
        process.arguments = [PathRules.windows.nativePath(of: url)] + (change.map { [$0] } ?? [])
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "icacls \(change ?? "")")
        // Its output is ASCII here, in UTF-16 or a code page; without the zero bytes it reads the same either way.
        return String(decoding: data.filter { $0 != 0 }, as: UTF8.self)
    }

    /// A link as Windows' own `mklink` makes it: `/J` a junction, `/D` a symbolic link to a folder, none one to a
    /// file. It must reach what it links to, or a refusal would prove nothing.
    private func makeLink(_ link: URL, to target: URL, _ kind: String?) throws {
        let process = Process()
        process.executableURL = URL(filePath: ProcessInfo.processInfo.environment["ComSpec"] ?? #"C:\Windows\System32\cmd.exe"#)
        process.arguments = ["/c", "mklink"] + (kind.map { [$0] } ?? [])
            + [PathRules.windows.nativePath(of: link), PathRules.windows.nativePath(of: target)]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "mklink \(kind ?? "") \(link.lastPathComponent)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path(percentEncoded: false)), link.lastPathComponent)
    }

    private static func user(_ text: String, uuid: String, parent: String?) -> [String: JSONValue] {
        ["type": .string("user"), "uuid": .string(uuid), "parentUuid": parent.map(JSONValue.string) ?? .null,
         "sessionId": .string(sessionID), "isSidechain": .bool(false),
         "message": .object(["role": .string("user"), "content": .string(text)])]
    }

    private static func assistant(_ text: String, uuid: String, parent: String) -> [String: JSONValue] {
        ["type": .string("assistant"), "uuid": .string(uuid), "parentUuid": .string(parent),
         "sessionId": .string(sessionID),
         "message": .object(["id": .string("m-\(uuid)"), "role": .string("assistant"),
                             "content": .array([.object(["type": .string("text"), "text": .string(text)])])])]
    }

    /// The requests' numbers, in order.
    private static func requests(_ entries: [TranscriptEntry]) -> [Int] {
        entries.compactMap { entry in
            guard case let .user(text, _) = entry.content, text.hasPrefix("Request ") else { return nil }
            return Int(text.dropFirst("Request ".count))
        }
    }
}
