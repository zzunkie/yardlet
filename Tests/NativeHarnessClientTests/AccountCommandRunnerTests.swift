import Darwin
import Foundation
import XCTest
@testable import NativeHarnessClient

final class AccountCommandRunnerTests: XCTestCase {
    func testFinishedAccountCommandReturnsItsExitAndOutput() async throws {
        let fixture = try makeExecutable("""
        #!/bin/sh
        printf '%s\\n' 'fixture account status'
        exit 3
        """)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try await AccountCommandRunner.run(
            executableURL: fixture.executable,
            arguments: [],
            timeout: .seconds(10)
        )

        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.output, "fixture account status\n")
    }

    /// A stalled probe is stopped with its children and reaped by Foundation. Neither a
    /// wrapper that exits zero once its child is stopped nor a stolen exit status may read
    /// as the command's answer.
    func testTimedOutAccountCommandStopsItsTreeAndReportsTheTimeout() async throws {
        let shapes = [
            """
            #!/bin/sh
            printf '%s\\n' "$$" > "$0.pid"
            sleep 30 &
            printf '%s\\n' "$!" > "$0.child"
            wait
            """,
            """
            #!/bin/sh
            printf '%s\\n' "$$" > "$0.pid"
            printf '%s\\n' "$$" > "$0.child"
            exec sleep 30
            """
        ]
        for script in shapes {
            let fixture = try makeExecutable(script)
            defer { try? FileManager.default.removeItem(at: fixture.root) }

            // The script has to start and write its process IDs before the timeout stops it, which on
            // a busy machine can take more than half a second.
            let timeout: Duration = .seconds(2)
            let started = ContinuousClock.now
            do {
                let result = try await AccountCommandRunner.run(
                    executableURL: fixture.executable,
                    arguments: [],
                    timeout: timeout
                )
                XCTFail("Expected a stalled account command to time out, got exit \(result.exitCode)")
            } catch let error as AccountCommandError {
                XCTAssertEqual(error, .timedOut)
            }
            XCTAssertLessThan(ContinuousClock.now - started, timeout + .milliseconds(4_500))

            let rootPID = try readPID(fixture.executable.appendingPathExtension("pid"))
            let childPID = try readPID(fixture.executable.appendingPathExtension("child"))
            try await waitUntilGone(childPID)
            try await waitUntilGone(rootPID)
        }
    }

    private func makeExecutable(_ script: String) throws -> (root: URL, executable: URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "yardlet-account-command-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appending(path: "fixture-account")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path(percentEncoded: false)
        )
        return (root, executable)
    }

    private func readPID(_ url: URL) throws -> pid_t {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try XCTUnwrap(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// `kill(pid, 0)` still succeeds for an unreaped zombie, so `ESRCH` also proves the
    /// process was reaped.
    private func waitUntilGone(_ pid: pid_t) async throws {
        try await waitUntil { Darwin.kill(pid, 0) != 0 }
        errno = 0
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
}
