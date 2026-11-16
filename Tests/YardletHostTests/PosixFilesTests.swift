import Foundation
import Glibc
import XCTest
@testable import NativeHarnessClient

/// File access that follows no link (`ScopedFiles`, `WorkspaceFileReplacement` in Platform/POSIX,
/// docs/PLATFORM_PORTABILITY.md), as the Linux host builds it, on a Linux CI runner: what Claude Code saved reads back, a
/// reviewed file saves, and a link beneath the folder is refused, not followed.
final class PosixFilesTests: XCTestCase {
    private static let sessionID = "8F7C2A51-3E0B-4C47-9C2D-6A1B0E4F9D33"
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "yardlet-posix-tests-\(UUID().uuidString)",
                                                                  directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Files and folders beneath the root read as on the Mac, and a link to a folder and one to a file beneath it are
    /// refused, though each reaches a file outside; a pipe is refused without waiting for a writer. The root itself may
    /// be a link.
    func testReadsBeneathTheRootAndRefusesLinks() throws {
        let root = folder.appending(path: "projects", directoryHint: .isDirectory)
        let project = root.appending(path: "-work-app", directoryHint: .isDirectory)
        let outside = folder.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("first\nsecond\n".utf8).write(to: project.appending(path: "session.jsonl"))
        try Data("secret\n".utf8).write(to: outside.appending(path: "session.jsonl"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "folder-link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: project.appending(path: "file-link.jsonl"),
                                                   withDestinationURL: outside.appending(path: "session.jsonl"))
        XCTAssertEqual(mkfifo(project.appending(path: "pipe.jsonl").path, 0o600), 0)

        let files = ScopedFiles(root: root)
        XCTAssertEqual(Set(try files.names([], limit: 10)), ["-work-app", "folder-link"])
        XCTAssertEqual(try files.directories([], limit: 10), ["-work-app"])
        XCTAssertThrowsError(try files.names([], limit: 1))
        XCTAssertTrue(files.isDirectory([]))
        XCTAssertTrue(files.isDirectory(["-work-app"]))
        XCTAssertFalse(files.isRegularFile(["-work-app"]))
        XCTAssertTrue(files.isRegularFile(["-work-app", "session.jsonl"]))
        XCTAssertEqual(try files.data(["-work-app", "session.jsonl"], maximumBytes: 100, tail: false)?.data,
                       Data("first\nsecond\n".utf8))
        XCTAssertNil(try files.data(["-work-app", "session.jsonl"], maximumBytes: 8, tail: false))
        let tail = try XCTUnwrap(try files.data(["-work-app", "session.jsonl"], maximumBytes: 8, tail: true))
        XCTAssertEqual(tail.data, Data("second\n".utf8))
        XCTAssertTrue(tail.truncated)

        let file = try XCTUnwrap(files.openRegularFile(["-work-app", "session.jsonl"]))
        XCTAssertEqual(file.size, 13)
        let lines = try file.lines(from: 3, to: 13)
        XCTAssertEqual(lines.data, Data("second\n".utf8))
        XCTAssertEqual(lines.start, 6)

        XCTAssertFalse(files.isDirectory(["folder-link"]))
        XCTAssertEqual(try files.names(["folder-link"], limit: 10), [])
        XCTAssertNil(files.openRegularFile(["folder-link", "session.jsonl"]))
        XCTAssertNil(try files.data(["folder-link", "session.jsonl"], maximumBytes: 100, tail: true))
        for name in ["file-link.jsonl", "pipe.jsonl"] {
            XCTAssertFalse(files.isRegularFile(["-work-app", name]), name)
            XCTAssertNil(files.openRegularFile(["-work-app", name]), name)
        }
        for name in ["", ".", "..", "../outside", "-work-app/session.jsonl"] {
            XCTAssertFalse(files.isRegularFile([name]), name)
            XCTAssertFalse(files.isDirectory([name]), name)
        }

        // As an account's `projects` linked to another's.
        let linkedRoot = folder.appending(path: "linked-projects", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: root)
        XCTAssertEqual(ScopedFiles(root: linkedRoot).openRegularFile(["-work-app", "session.jsonl"])?.identity,
                       file.identity)
    }

    /// A conversation Claude Code saved opens with its earlier turns: the newest part first, then the parts before it,
    /// read through the file opened beneath the config's `projects`, back to its first request.
    func testAClaudeConversationReadsBackToItsFirstTurn() throws {
        let config = folder.appending(path: "config", directoryHint: .isDirectory)
        let project = config.appending(path: "projects/-work-app", directoryHint: .isDirectory)
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

    /// A save from the Files panel or another device replaces the file only while it holds the bytes the person
    /// reviewed and the save is still allowed, keeps its permissions whatever the umask, leaves no temporary file, and
    /// writes nothing through a link beneath the folder.
    func testASaveReplacesOnlyTheReviewedFileBeneathTheFolder() throws {
        let root = folder.appending(path: "work", directoryHint: .isDirectory)
        let sources = root.appending(path: "Sources", directoryHint: .isDirectory)
        let outside = folder.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let main = sources.appending(path: "main.swift")
        try Data("reviewed\n".utf8).write(to: main)
        XCTAssertEqual(chmod(main.path, 0o664), 0)
        let secret = outside.appending(path: "main.swift")
        try Data("reviewed\n".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "linked"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: sources.appending(path: "link.swift"), withDestinationURL: secret)
        let previousMask = umask(0o077)
        defer { umask(previousMask) }

        let reviewed = WorkspaceFileReplacement.digest(Data("reviewed\n".utf8))
        func save(_ path: String, over digest: String = reviewed, authorize: () throws -> Void = {}) throws {
            try WorkspaceFileReplacement.replace(path: path, in: root, with: Data("saved\n".utf8), expectedDigest: digest,
                                                 maximumBytes: 1_000, authorize: authorize)
        }
        for path in ["linked/main.swift", "Sources/link.swift", "Sources"] {
            XCTAssertThrowsError(try save(path), path)
        }
        XCTAssertThrowsError(try save("Sources/main.swift", over: WorkspaceFileReplacement.digest(Data("other\n".utf8)))) {
            XCTAssertEqual($0 as? WorkspaceFileError, .changedOnDisk)
        }
        XCTAssertThrowsError(try save("Sources/main.swift") { throw CancellationError() }) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(try Data(contentsOf: secret), Data("reviewed\n".utf8))
        XCTAssertEqual(try Data(contentsOf: main), Data("reviewed\n".utf8))

        try save("Sources/main.swift")
        XCTAssertEqual(try Data(contentsOf: main), Data("saved\n".utf8))
        var status = stat()
        XCTAssertEqual(stat(main.path, &status), 0)
        XCTAssertEqual(status.st_mode & 0o777, 0o664, "The file keeps its permissions")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sources.path).sorted(),
                       ["link.swift", "main.swift"], "No temporary file is left")
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
