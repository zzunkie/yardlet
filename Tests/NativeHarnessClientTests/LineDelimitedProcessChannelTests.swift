import XCTest
@testable import NativeHarnessClient

final class LineDelimitedProcessChannelTests: XCTestCase {
    private typealias Event = LineDelimitedProcessChannel.Event

    /// A line written just before the process exits is delivered, and the exit comes after it with
    /// the process's last words on standard error. The exit is reported while the end of the output
    /// can still be in the pipe, so a channel that passed the exit on as it came would drop it.
    func testALineWrittenJustBeforeTheProcessExitsIsDeliveredBeforeItsExit() async throws {
        let lines = 2_000
        let executable = try script("""
        #!/bin/sh
        i=0
        while [ $i -lt \(lines) ]; do
          printf '%s\\n' '{"index":'$i'}'
          i=$((i + 1))
        done
        printf '%s\\n' 'discarded: more than the limit keeps' 'fatal: gave up' >&2
        printf '%s\\n' '{"last":true}'
        exit 3
        """)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let channel = try LineDelimitedProcessChannel(.init(executableURL: executable), stderrLimit: 15,
                                                      drainGrace: testWaitLimit)

        var events: [Event] = []
        for await event in channel.events { events.append(event) }

        XCTAssertEqual(events.count, lines + 2)
        XCTAssertEqual(events.prefix(lines).map(Self.text), (0..<lines).map { #"{"index":\#($0)}"# })
        XCTAssertEqual(events.dropLast().last, .line(Data(#"{"last":true}"#.utf8)))
        XCTAssertEqual(events.last, .exited(code: 3, stderr: "fatal: gave up"))
        XCTAssertFalse(channel.isRunning)
        XCTAssertEqual(channel.exitCode, 3)
    }

    /// Lines arrive whole however the process's writes cut them, without `\n` or `\r\n`, and what
    /// Yardlet writes reaches the process.
    func testLinesArriveWholeHoweverTheWritesCutThem() async throws {
        let executable = try script(#"""
        #!/bin/sh
        IFS= read -r request
        printf '{"echo":'
        sleep 0.05
        printf '%s}\n\n{"crlf":true}\r' "$request"
        sleep 0.05
        printf '\n{"third":3}\n{"fourth":4}\n'
        """#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let channel = try LineDelimitedProcessChannel(.init(executableURL: executable), stderrLimit: 1_024,
                                                      drainGrace: testWaitLimit)
        try channel.write(Data("7\n".utf8))

        var events: [Event] = []
        for await event in channel.events { events.append(event) }

        XCTAssertEqual(events.dropLast().map(Self.text),
                       [#"{"echo":7}"#, #"{"crlf":true}"#, #"{"third":3}"#, #"{"fourth":4}"#])
        XCTAssertEqual(events.last, .exited(code: 0, stderr: ""))
    }

    /// A child the process leaves behind with the pipes open holds the exit back only for the drain
    /// grace, and the line written before the exit still comes first. What the child writes later
    /// does not replace the process's own last words.
    func testAChildHoldingThePipesOpenDelaysTheExitOnlyForTheGrace() async throws {
        let executable = try script(#"""
        #!/bin/sh
        (
          while [ ! -e "$0.exit-read" ]; do sleep 0.05; done
          printf '%s\n' 'noise from the child' >&2
          touch "$0.noise"
          exec sleep 60
        ) &
        printf '%s' $! > "$0.child"
        printf '%s\n' 'fatal: gave up' >&2
        printf '%s\n' '{"last":true}'
        exit 4
        """#)
        defer {
            if let child = try? String(contentsOf: URL(filePath: executable.path + ".child"), encoding: .utf8),
               let pid = pid_t(child) {
                kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: executable.deletingLastPathComponent())
        }
        let start = ContinuousClock.now
        let channel = try LineDelimitedProcessChannel(.init(executableURL: executable), stderrLimit: 1_024,
                                                      drainGrace: .milliseconds(500))

        var events: [Event] = []
        for await event in channel.events { events.append(event) }

        XCTAssertEqual(events, [.line(Data(#"{"last":true}"#.utf8)), .exited(code: 4, stderr: "fatal: gave up")])
        XCTAssertLessThan(ContinuousClock.now - start, testWaitLimit, "The exit waited for the child's pipes")

        FileManager.default.createFile(atPath: executable.path + ".exit-read", contents: nil)
        try await waitUntil { FileManager.default.fileExists(atPath: executable.path + ".noise") }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(channel.stderrText, "fatal: gave up")
    }

    private static func text(_ event: Event) -> String {
        guard case let .line(line) = event else { return "\(event)" }
        return String(decoding: line, as: UTF8.self)
    }

    private func script(_ text: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "yardlet-channel-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appending(path: "fake-cli")
        try Data(text.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }
}
