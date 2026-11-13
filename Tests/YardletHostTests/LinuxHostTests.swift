import Foundation
import Glibc
import XCTest
import YardletRemote
@testable import NativeHarnessClient

/// The Linux layer's contracts (docs/LINUX_HOST.md), on a Linux CI runner.
final class LinuxHostTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "yardlet-host-tests-\(UUID().uuidString)",
                                                                  directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Ending a task's process ends what it started, also a process whose parent has already ended: it is still in the
    /// group Foundation started the task's process in.
    func testEndingAProcessEndsWhatItStartedEvenWithoutItsParent() throws {
        let orphanFile = folder.appending(path: "orphan.pid")
        let childFile = folder.appending(path: "child.pid")
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        // The subshell starts a sleep and ends at once, so that sleep's parent is gone; the second sleep stays a child.
        process.arguments = ["-c", "(sleep 300 & echo $! > '\(orphanFile.path)'); sleep 300 & echo $! > '\(childFile.path)'; wait"]
        try NativeProcessTree.run(process)
        let orphan = try waitForProcessID(in: orphanFile)
        let child = try waitForProcessID(in: childFile)
        XCTAssertEqual(getpgid(process.processIdentifier), process.processIdentifier,
                       "Foundation starts the process in a group of its own")
        XCTAssertNotEqual(LinuxProcessTable.read(orphan)?.parent, process.processIdentifier)

        NativeProcessTree.terminate(process: process)

        XCTAssertFalse(process.isRunning)
        try waitUntilEnded(orphan)
        try waitUntilEnded(child)
    }

    /// The signals the host handles stay handled, not ignored, so a harness it starts gets them back: an ignored
    /// SIGINT would outlast exec, and the harness would not stop its turn for it.
    func testAHarnessDoesNotInheritTheSignalsTheHostHandles() throws {
        LinuxSignals.handle([SIGHUP, SIGINT, SIGTERM], on: .global()) { _ in }
        LinuxSignals.absorb(SIGPIPE)
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "sed -n 's/^SigIgn:[[:space:]]*//p' /proc/self/status"]
        process.standardOutput = output
        try NativeProcessTree.run(process)
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let ignored = try XCTUnwrap(UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16))
        for number in [SIGHUP, SIGINT, SIGTERM, SIGPIPE] {
            XCTAssertEqual(ignored & (1 << UInt64(number - 1)), 0, "signal \(number) is ignored in a started program")
        }
    }

    /// The remote's keys stay the same from one start to the next, in a file its owner alone may read.
    func testRemoteKeysAreKeptPrivateAndReused() throws {
        let file = folder.appending(path: "remote/identity.json")
        let first = try RemoteFileIdentityStore(fileURL: file).loadOrCreate()
        var status = stat()
        XCTAssertEqual(stat(file.path, &status), 0)
        XCTAssertEqual(status.st_mode & 0o777, 0o600)
        XCTAssertEqual(stat(file.deletingLastPathComponent().path, &status), 0)
        XCTAssertEqual(status.st_mode & 0o777, 0o700)
        let second = try RemoteFileIdentityStore(fileURL: file).loadOrCreate()
        XCTAssertEqual(second.noise.publicKey, first.noise.publicKey)
    }

    /// Keys made where a keyring is open stay in the keyring, a keyring that cannot be read is waited for rather than
    /// replaced with new keys (which would unpair every device), and a service keeps new keys in the file. Needs a
    /// Secret Service in the session (linux-host.yml runs this in one with gnome-keyring).
    func testKeysInTheKeyringStayThereAndAreWaitedFor() throws {
        guard ProcessInfo.processInfo.environment["YARDLET_TEST_SECRET_SERVICE"] == "1" else {
            throw XCTSkip("Needs a Secret Service; linux-host.yml provides one")
        }
        let keyring = try XCTUnwrap(LinuxSecretService.load())
        func store(_ name: String, keyring: LinuxSecretService?, service: Bool = false) -> LinuxRemoteIdentityStore {
            LinuxRemoteIdentityStore(file: RemoteFileIdentityStore(fileURL: folder.appending(path: "\(name)/identity.json")),
                                     marker: folder.appending(path: "\(name)/identity.keyring"),
                                     keyring: keyring, keepsNewKeysInKeyring: !service)
        }
        let made = try store("session", keyring: keyring).loadOrCreate()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "session/identity.json").path))
        XCTAssertEqual(store("session", keyring: keyring).place, "keyring")
        XCTAssertEqual(try store("session", keyring: keyring).loadOrCreate().noise.publicKey, made.noise.publicKey)
        XCTAssertThrowsError(try store("session", keyring: nil).loadOrCreate())

        _ = try store("service", keyring: keyring, service: true).loadOrCreate()
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "service/identity.json").path))
        XCTAssertEqual(store("service", keyring: keyring).place, "file")
    }

    /// A systemd service has no login shell's PATH; the host reads it from the person's login shell.
    func testTheLoginShellsPathIsRead() async throws {
        let home = folder.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "export PATH=\"/opt/yardlet-test/bin:$PATH\"\n".write(to: home.appending(path: ".profile"), atomically: true, encoding: .utf8)
        let path = await LoginShellPath.read(shell: URL(filePath: "/bin/bash"),
                                             environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        XCTAssertEqual(path?.split(separator: ":").first, "/opt/yardlet-test/bin")
    }

    private func waitForProcessID(in file: URL) throws -> pid_t {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
            usleep(20_000)
        }
        throw XCTSkip("The shell wrote no process ID to \(file.lastPathComponent)")
    }

    /// Gone, or a zombie no one has reaped yet: a container's first process may not reap the orphans it inherits.
    private func waitUntilEnded(_ pid: pid_t) throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            guard let state = processState(pid), state != "Z", state != "X" else { return }
            usleep(20_000)
        }
        XCTFail("Process \(pid) is still running (\(processState(pid) ?? "?"))")
    }

    private func processState(_ pid: pid_t) -> String? {
        // A file in /proc reports no size, so it is read to its end rather than by its size.
        guard let handle = FileHandle(forReadingAtPath: "/proc/\(pid)/stat") else { return nil }
        defer { try? handle.close() }
        let line = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        guard let close = line.lastIndex(of: ")") else { return nil }
        return line[line.index(after: close)...].split(separator: " ").first.map(String.init)
    }
}
