import Foundation
import XCTest
@testable import NativeHarnessClient

/// Reading beneath a folder without following links on Windows (`ScopedFiles`, docs/PLATFORM_PORTABILITY.md), on a
/// Windows CI runner: what Claude Code saved reads back, and a link beneath the folder is refused, not followed.
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
