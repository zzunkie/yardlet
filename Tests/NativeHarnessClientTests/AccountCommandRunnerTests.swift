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

    /// A CLI read for its limits may be renewing the login. It is never stopped first: the end of its
    /// input ends it, and what it was saving gets saved, after the answer and after a timeout alike.
    /// Waiting for it costs nothing, also once it has closed its output and goes on (2026-11-09: a
    /// reader left on the ended pipe kept a core busy).
    func testTheUsageProbeLetsTheCLIFinishInsteadOfStoppingIt() async throws {
        let script = """
        #!/bin/sh
        while read -r line; do
          case "$line" in *get_usage*)
            [ -n "$ANSWERS" ] && printf '%s\\n' '{"type":"control_response","response":{"request_id":"usage","subtype":"success","response":{}}}';;
          esac
        done
        exec >&-
        sleep 2
        touch "$0.saved"
        """
        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        for answers in [true, false] {
            let fixture = try makeExecutable(script)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let cpu = cpuSeconds()
            _ = await ClaudeUsageProbe.read(executableURL: fixture.executable,
                environment: answers ? ["ANSWERS": "1"] : [:], timeout: .milliseconds(500), exitGrace: .seconds(30))
            let saved = fixture.executable.path(percentEncoded: false) + ".saved"
            try await waitUntil(timeout: .seconds(20)) { FileManager.default.fileExists(atPath: saved) }
            XCTAssertLessThan(cpuSeconds() - cpu, 0.5, "The probe spent CPU while the CLI finished")
        }
    }

    func testTitleTimeoutAndCancellationLetTheCLIFinishSaving() async throws {
        for cancel in [true, false] {
            let fixture = try makeExecutable("""
            #!/bin/sh
            cat >/dev/null
            touch "$0.ready"
            sleep 2
            touch "$0.saved"
            """)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let task = Task {
                try await ClaudeTitleRequest.run(executableURL: fixture.executable, environment: [:],
                    model: "fixture", prompt: "Title", timeout: cancel ? .seconds(30) : .seconds(1),
                    exitGrace: .seconds(10))
            }
            if cancel {
                let ready = fixture.executable.appendingPathExtension("ready")
                try await waitUntil { FileManager.default.fileExists(atPath: ready.path) }
                task.cancel()
            }
            do {
                _ = try await task.value
                XCTFail("An interrupted title request cannot return a title")
            } catch {
                if cancel { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertTrue(error.localizedDescription.contains(
                    L10n.format("%@ did not answer in time.", HarnessKind.claudeCode.displayName))) }
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.executable.appendingPathExtension("saved").path))
        }
    }

    func testStalledTitleProcessIsReapedAfterItsGracePeriod() async throws {
        let fixture = try makeExecutable("""
        #!/bin/sh
        cat >/dev/null
        echo "$$" > "$0.pid"
        exec sleep 60
        """)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pidFile = fixture.executable.appendingPathExtension("pid")
        let grace: Duration = .milliseconds(300)
        let task = Task {
            try await ClaudeTitleRequest.run(executableURL: fixture.executable, environment: [:],
                model: "fixture", prompt: "Title", exitGrace: grace)
        }
        try await waitUntil {
            guard let text = try? String(contentsOf: pidFile, encoding: .utf8) else { return false }
            return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        }
        let pid = try readPID(pidFile)
        let interrupted = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - interrupted, grace)
        XCTAssertLessThan(ContinuousClock.now - interrupted, .seconds(10))
        try await waitUntilGone(pid)
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
