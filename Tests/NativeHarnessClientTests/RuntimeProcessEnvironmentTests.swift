import Foundation
import XCTest
@testable import NativeHarnessClient

final class RuntimeProcessEnvironmentTests: XCTestCase {
    func testRuntimePathIncludesExecutableDirectoryAndCommonNodeLocations() {
        let environment = RuntimeProcessEnvironment.values(
            executableURL: URL(filePath: "/custom/runtime/pi"),
            base: ["HOME": "/Users/test", "PATH": "/existing/bin:/usr/bin"]
        )
        let paths = environment["PATH"]?.split(separator: ":").map(String.init)

        XCTAssertEqual(paths?.first, "/custom/runtime")
        XCTAssertTrue(paths?.contains("/opt/homebrew/bin") ?? false)
        XCTAssertTrue(paths?.contains("/usr/local/bin") ?? false)
        XCTAssertTrue(paths?.contains("/existing/bin") ?? false)
        XCTAssertEqual(paths?.filter { $0 == "/usr/bin" }.count, 1)
    }

    func testRuntimeOverridesWinWithoutDiscardingAugmentedPath() {
        let environment = RuntimeProcessEnvironment.values(
            executableURL: URL(filePath: "/opt/homebrew/bin/pi"),
            base: ["HOME": "/Users/test", "PATH": "/usr/bin"],
            overrides: ["PAGER": "cat", "CUSTOM": "value"]
        )

        XCTAssertEqual(environment["PAGER"], "cat")
        XCTAssertEqual(environment["CUSTOM"], "value")
        XCTAssertTrue(environment["PATH"]?.hasPrefix("/opt/homebrew/bin:") ?? false)
    }

    /// The login shell's `PATH` leads, the app's folders it lacks follow, and nothing else changes;
    /// before a read, the app's environment stays as it is.
    func testLoginShellPathLeadsTheAppsOwn() {
        let base = ["HOME": "/Users/test", "PATH": "/usr/bin:/bin:/app/only"]
        XCTAssertEqual(RuntimeProcessEnvironment.withLoginShellPath("/opt/homebrew/bin:/usr/bin:/bin", base: base),
                       ["HOME": "/Users/test", "PATH": "/opt/homebrew/bin:/usr/bin:/bin:/app/only"])
        XCTAssertEqual(RuntimeProcessEnvironment.withLoginShellPath(nil, base: base), base)
    }

    /// The read starts the shell as a terminal window does, so both the login profile and the
    /// interactive rc file count, and a shell that hangs is given up on at the time limit. zsh runs
    /// with a temporary `ZDOTDIR` and `HOME`, so none of the person's files are read.
    func testTheLoginShellReadTakesTheProfilesAndRcFilesPathAndGivesUpOnAHang() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "LoginShellPath-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let environment = ["HOME": folder.path(percentEncoded: false), "ZDOTDIR": folder.path(percentEncoded: false),
                           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        try "export PATH=/from/profile:$PATH\n".write(to: folder.appending(path: ".zprofile"), atomically: true, encoding: .utf8)
        try "export PATH=/from/rc:$PATH\n".write(to: folder.appending(path: ".zshrc"), atomically: true, encoding: .utf8)

        let path = await LoginShellPath.read(shell: URL(filePath: "/bin/zsh"), environment: environment)
        let folders = path?.split(separator: ":").map(String.init) ?? []
        XCTAssertEqual(folders.first, "/from/rc", path ?? "nil")
        XCTAssertTrue(folders.contains("/from/profile"), path ?? "nil")
        XCTAssertTrue(folders.contains("/usr/bin"), path ?? "nil")

        try "sleep 30\n".write(to: folder.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        let started = ContinuousClock.now
        let hung = await LoginShellPath.read(shell: URL(filePath: "/bin/zsh"), environment: environment,
                                             timeout: .milliseconds(500))
        XCTAssertNil(hung)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    }
}
