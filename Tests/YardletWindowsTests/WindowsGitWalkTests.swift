import Foundation
import XCTest
@testable import NativeHarnessClient

/// Finding a folder's Git checkout on Windows (`GitWorktreeOriginResolver`): the walk up from the folder asks only
/// about the folder and the folders above it on its own drive, never a path Windows would read from the process's
/// current folder, which on a runner (and for a build started from a checkout) is another repository.
final class WindowsGitWalkTests: XCTestCase {
    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ path: String) { lock.lock(); values.append(path); lock.unlock() }
        var paths: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }

    func testAsksOnlyAboutTheFolderAndTheFoldersAboveItOnItsDrive() {
        let asked = Asked()
        let reader = GitMetadataReader(kind: { asked.add($0); return nil }, text: { _ in nil })
        let folder = URL(filePath: "C:\\nowhere\\project", directoryHint: .isDirectory)
        XCTAssertFalse(GitWorktreeOriginResolver.isInRepository(folder, reader: reader))
        XCTAssertFalse(asked.paths.isEmpty)
        for path in asked.paths {
            XCTAssertTrue(PathRules.windows.isInside(path, folder: "C:\\"), "asked about \(path) in \(asked.paths)")
        }
    }

    /// A folder outside Git reads as outside it, though the tests run in this repository's checkout.
    func testAFolderOutsideGitIsNotInTheCurrentFoldersRepository() throws {
        let base = ProcessInfo.processInfo.environment["RUNNER_TEMP"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.temporaryDirectory
        let folder = base.appending(path: "yardlet-git-walk-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertFalse(GitWorktreeOriginResolver.isInRepository(folder))
        XCTAssertNil(GitWorktreeOriginResolver.currentBranch(folder))
    }
}
