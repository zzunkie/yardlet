import Foundation
import XCTest
@testable import NativeHarnessClient

final class TranscriptRepositoryTests: XCTestCase {
    func testFileRepositoryRoundTripsAndRemovesBoundedSnapshot() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "YardletTranscriptRepositoryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let repository = FileTranscriptRepository(directoryURL: rootURL)
        let sessionID = UUID()
        let entries = [
            TranscriptEntry(content: .user(text: "question")),
            TranscriptEntry(content: .assistant(text: "answer", isStreaming: false))
        ]

        repository.save(entries, for: sessionID)
        XCTAssertEqual(repository.load(for: sessionID), entries)

        repository.remove(for: sessionID)
        XCTAssertTrue(repository.load(for: sessionID).isEmpty)
    }

    /// A streaming task's snapshot is saved about once a second. Each save writes what changed since
    /// the last, not the whole history again: a long conversation rewritten every second came to
    /// 8.6 GB in 18 minutes across a few streaming tasks (2026-11-09). Another reader of the folder
    /// still gets every save, and a rewound conversation replaces the snapshot.
    func testStreamingSavesWriteWhatChangedNotTheWholeHistory() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "YardletTranscriptStreamingTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let repository = FileTranscriptRepository(directoryURL: rootURL)
        let sessionID = UUID()
        let output = String(repeating: "a line of a tool's output\n", count: 300)
        var entries: [TranscriptEntry] = []
        for index in 0..<300 {
            if index % 30 == 0 { entries.append(TranscriptEntry(content: .user(text: "request \(index)"))) }
            entries.append(TranscriptEntry(content: .activity(HarnessActivity(
                id: "call-\(index)", kind: "command", title: "Run", input: "make \(index)", output: output),
                state: .completed)))
            if index % 10 == 0 { entries.append(TranscriptEntry(content: .assistant(text: "Done \(index).", isStreaming: false))) }
        }
        repository.save(entries, for: sessionID)
        let history = try JSONEncoder().encode(entries).count

        var files: [String: (inode: UInt64, size: Int)] = [:]
        func written() throws -> Int {
            var bytes = 0
            for name in try FileManager.default.contentsOfDirectory(atPath: rootURL.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: rootURL.appending(path: name).path)
                let file = (inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                            size: (attributes[.size] as? NSNumber)?.intValue ?? 0)
                if let before = files[name], before.inode == file.inode { bytes += max(0, file.size - before.size) }
                else { bytes += file.size }
                files[name] = file
            }
            return bytes
        }
        _ = try written()

        // A turn of a minute: the answer grows each second and a command runs every ten.
        entries.append(TranscriptEntry(content: .user(text: "One more change")))
        let answer = TranscriptEntry(content: .assistant(text: "", isStreaming: true))
        entries.append(answer)
        var text = ""
        var bytes = 0
        for second in 1...60 {
            text += "Another sentence of the answer as it streams in. "
            entries[entries.lastIndex { $0.id == answer.id }!].content = .assistant(text: text, isStreaming: true)
            if second % 10 == 0 {
                let call = HarnessActivity(id: "turn-\(second)", kind: "command", title: "Run", input: "test")
                entries.append(TranscriptEntry(content: .activity(call, state: .running)))
                repository.save(entries, for: sessionID)
                bytes += try written()
                var done = call
                done.output = output
                entries[entries.count - 1].content = .activity(done, state: .completed)
            }
            repository.save(entries, for: sessionID)
            bytes += try written()
        }
        XCTAssertLessThan(bytes, history / 4, "A turn of a minute wrote \(bytes) bytes over a history of \(history)")
        XCTAssertEqual(FileTranscriptRepository(directoryURL: rootURL).load(for: sessionID), Array(entries.suffix(500)))

        // Rewinding to an earlier request drops what came after it.
        let rewound = Array(entries.prefix(40)) + [TranscriptEntry(content: .user(text: "Instead, this"))]
        repository.save(rewound, for: sessionID)
        XCTAssertEqual(FileTranscriptRepository(directoryURL: rootURL).load(for: sessionID), rewound)
        repository.remove(for: sessionID)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: rootURL.path), [])
    }

    func testMigratingRepositoryMovesLegacySnapshotAfterVerifiedPrimaryWrite() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "YardletTranscriptMigrationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let sessionID = UUID()
        let legacy = UserDefaultsTranscriptRepository(defaults: defaults, keyPrefix: "legacy.")
        let primary = FileTranscriptRepository(directoryURL: rootURL)
        let repository = MigratingTranscriptRepository(primary: primary, legacy: legacy)
        let entries = [TranscriptEntry(content: .user(text: "migrate me"))]
        legacy.save(entries, for: sessionID)

        XCTAssertEqual(repository.load(for: sessionID), entries)
        XCTAssertEqual(primary.load(for: sessionID), entries)
        XCTAssertTrue(legacy.load(for: sessionID).isEmpty)
    }

    /// The snapshot queue saves a streaming task many times; no save may write to UserDefaults,
    /// whose change notification waits for the main thread (the 2026-10-22 hang).
    func testSavingAndRemovingWithoutALegacySnapshotDoNotWriteUserDefaults() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "YardletTranscriptNoDefaultsTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests")))
        let repository = MigratingTranscriptRepository(
            primary: FileTranscriptRepository(directoryURL: rootURL),
            legacy: UserDefaultsTranscriptRepository(defaults: defaults, keyPrefix: "legacy."))
        var changes = 0
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil) { _ in changes += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        let sessionID = UUID()
        for index in 0..<5 {
            repository.save([TranscriptEntry(content: .user(text: "turn \(index)"))], for: sessionID)
        }
        repository.remove(for: sessionID)
        XCTAssertEqual(changes, 0)
        XCTAssertTrue(repository.load(for: sessionID).isEmpty)
    }

    /// The 2026-10-22 hang the other way round: a legacy snapshot is still moved, on the snapshot
    /// queue, when a task's snapshot is first read, and the main thread waits for that read
    /// (`TranscriptSnapshotWriter.load`). The UserDefaults write that removes the legacy copy must
    /// not wait for the main thread: the menu bar item observing those defaults is told on the
    /// writing thread. Before, its main-queue observer held the write until the main thread ran it,
    /// which it never did while it waited.
    @MainActor
    func testMovingALegacySnapshotOnTheSnapshotQueueDoesNotWaitForTheWaitingMainThread() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "YardletTranscriptMainWaitTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let suite = testDefaultsSuite("NativeHarnessClientTests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: MenuBarPreference.key)
        let item = MenuBarStatusItem(controller: MenuBarMenuController(content: { .empty }, actions: .init()),
                                     defaults: defaults)
        defer { withExtendedLifetime(item) {} }
        let legacy = UserDefaultsTranscriptRepository(defaults: defaults, keyPrefix: "legacy.")
        let sessionID = UUID()
        let entries = [TranscriptEntry(content: .user(text: "moved while the main thread waits"))]
        legacy.save(entries, for: sessionID)
        let repository = SendableRepository(base: MigratingTranscriptRepository(
            primary: FileTranscriptRepository(directoryURL: rootURL), legacy: legacy))

        // The main thread waits for the queue as `queue.sync` would, but gives up after a while
        // instead of hanging the test when the write waits for it.
        let read = DispatchSemaphore(value: 0)
        DispatchQueue(label: "TranscriptRepositoryTests.snapshots").async {
            _ = repository.base.load(for: sessionID)
            read.signal()
        }
        let finished = read.wait(timeout: .now() + 2) == .success
        if !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertTrue(finished, "Removing the legacy copy waited for the main thread")
        XCTAssertTrue(legacy.load(for: sessionID).isEmpty)
        XCTAssertEqual(FileTranscriptRepository(directoryURL: rootURL).load(for: sessionID), entries)
    }
}

private struct SendableRepository: @unchecked Sendable {
    let base: MigratingTranscriptRepository
}
