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

    /// Under a line limit, a longer line arrives cut to one byte more than the limit as soon as it
    /// has grown that long, without waiting for its end; the rest of it is dropped and the lines
    /// after it arrive whole. A line of exactly the limit is whole even when its `\r` and `\n`
    /// come in separate writes.
    func testALineLongerThanTheLimitArrivesCutAndTheLinesAfterItWhole() async throws {
        let executable = try script(#"""
        #!/bin/sh
        printf '%*s\r' 128 '' | tr ' ' w
        sleep 0.1
        printf '\n'
        printf '%*s' 300 '' | tr ' ' x
        IFS= read -r go
        printf '%*s\n{"after":1}\n' 300 '' | tr ' ' y
        printf '%*s\n{"last":2}\n' 200 '' | tr ' ' z
        """#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let channel = try LineDelimitedProcessChannel(.init(executableURL: executable), stderrLimit: 1_024,
                                                      lineLimit: 128, drainGrace: testWaitLimit)
        let received = Received()
        let events = channel.events
        let reading = Task {
            for await event in events { await received.add(event) }
        }

        // The second line has not ended: the process waits for its input before it writes on.
        try await waitUntil { await received.events.count == 2 }
        try channel.write(Data("go\n".utf8))
        await reading.value

        let cut = { (byte: Character) in Event.line(Data(String(repeating: byte, count: 129).utf8)) }
        let all = await received.events
        XCTAssertEqual(all, [.line(Data(String(repeating: "w", count: 128).utf8)), cut("x"),
                             .line(Data(#"{"after":1}"#.utf8)), cut("z"),
                             .line(Data(#"{"last":2}"#.utf8)), .exited(code: 0, stderr: "")])
    }

    private actor Received {
        private(set) var events: [Event] = []

        func add(_ event: Event) {
            events.append(event)
        }
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
