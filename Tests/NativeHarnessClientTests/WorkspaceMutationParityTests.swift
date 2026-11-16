import Foundation
import XCTest
@testable import NativeHarnessClient

@MainActor
final class WorkspaceMutationParityTests: XCTestCase {
    func testEditorDraftRestartSaveAndExternalChangePreservation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Yardlet.Editor.\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "sample.swift")
        try Data("original\n".utf8).write(to: file)
        let state = WorkspaceFilesState()
        state.open(.init(relativePath: "sample.swift"), in: root)
        try await loaded(state)
        state.edit("edited\n")
        XCTAssertTrue(state.isDirty)
        let persisted = try JSONDecoder().decode(WorkspaceFilePreferences.self, from: JSONEncoder().encode(state.preferences))
        let restored = WorkspaceFilesState(preferences: persisted)
        restored.restore(in: root); try await loaded(restored)
        XCTAssertEqual(restored.document?.text, "edited\n")
        await restored.save(in: root)
        XCTAssertFalse(restored.isDirty)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "edited\n")
        restored.edit("unsent editor changes\n")
        try Data("changed externally\n".utf8).write(to: file)
        await restored.save(in: root)
        XCTAssertNotNil(restored.saveError)
        XCTAssertEqual(restored.document?.text, "unsent editor changes\n")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "changed externally\n")
        restored.discard(in: root); try await loaded(restored)
        XCTAssertFalse(restored.isDirty)
        XCTAssertEqual(restored.document?.text, "changed externally\n")
    }

    func testSavePreservesUTF16AndRefusesLinkedOrOutsideFile() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Yardlet.Encoding.\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "utf16.txt")
        try XCTUnwrap(WorkspaceFileEncoding.utf16LittleEndian.data("처음\n")).write(to: file)
        let created = Date(timeIntervalSince1970: 1_577_836_800), modified = Date(timeIntervalSince1970: 1_609_459_200)
        try FileManager.default.setAttributes([.posixPermissions: 0o640, .creationDate: created, .modificationDate: modified],
                                              ofItemAtPath: file.path)
        XCTAssertEqual(setxattr(file.path, "user.yardlet-note", "kept", 4, 0, 0), 0)
        let doc = try WorkspaceFileService.read(.init(relativePath: "utf16.txt"), in: root)
        let saved = try WorkspaceFileService.save(path: doc.path, text: "변경\n", expectedDigest: try XCTUnwrap(doc.sourceDigest), encoding: doc.encoding, in: root)
        XCTAssertEqual(saved.text, "변경\n")
        XCTAssertEqual(saved.encoding, .utf16LittleEndian)
        XCTAssertTrue(try Data(contentsOf: file).starts(with: [0xff, 0xfe]))
        // Like an editor's save, the file keeps its permissions, extended attributes and creation date, and is
        // modified now, so tools that compare modification times see the change.
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o640)
        XCTAssertEqual(getxattr(file.path, "user.yardlet-note", nil, 0, 0, 0), 4)
        XCTAssertEqual(attributes[.creationDate] as? Date, created)
        XCTAssertGreaterThan(try XCTUnwrap(attributes[.modificationDate] as? Date), modified)
        let link = root.appending(path: "linked.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try WorkspaceFileService.save(path: "linked.txt", text: "No", expectedDigest: saved.sourceDigest!, encoding: .utf8, in: root))
        XCTAssertThrowsError(try WorkspaceFileService.save(path: "../outside.txt", text: "No", expectedDigest: "unknown", encoding: .utf8, in: root))
        XCTAssertEqual(try WorkspaceFileService.read(.init(relativePath: "utf16.txt"), in: root).text, "변경\n")
    }

    func testGitStageUnstageDiscardAndStaleReviewGuardInPrivateRepository() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Yardlet.GitMutation.\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try git(["init", "--quiet"], in: root)
        try git(["config", "commit.gpgsign", "false"], in: root)
        let file = root.appending(path: "tracked.txt"), added = root.appending(path: "new.txt")
        try Data("original\n".utf8).write(to: file)
        try git(["add", "--", "tracked.txt"], in: root)
        try git(["-c", "user.name=QA", "-c", "user.email=qa@example.invalid", "commit", "--quiet", "-m", "fixture"], in: root)
        try Data("modified\n".utf8).write(to: file); try Data("new\n".utf8).write(to: added)
        let service = GitDiffService()
        let unstaged = try await service.load(workspaceURL: root)
        try await service.mutate(.stage, workspaceURL: root, expected: unstaged)
        let staged = try await service.load(workspaceURL: root, target: .staged)
        XCTAssertEqual(staged.fileCount, 2)
        try await service.mutate(.unstage, workspaceURL: root, expected: staged)
        let empty = try await service.load(workspaceURL: root, target: .staged); XCTAssertTrue(empty.isEmpty)
        let old = try await service.load(workspaceURL: root)
        try Data("changed after review\n".utf8).write(to: file)
        do { try await service.mutate(.discard, workspaceURL: root, expected: old); XCTFail() } catch {}
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "changed after review\n")
        let fresh = try await service.load(workspaceURL: root)
        try await service.mutate(.discard, workspaceURL: root, expected: fresh)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: added.path))
    }

    private func loaded(_ state: WorkspaceFilesState) async throws {
        try await waitUntil { !state.isLoading }
        XCTAssertFalse(state.isLoading); XCTAssertNotNil(state.document, state.fileError ?? "No document")
    }

    private func git(_ arguments: [String], in root: URL) throws {
        let process = Process(); process.executableURL = GitExecutableLocator.preferredURL()
        process.arguments = arguments; process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
