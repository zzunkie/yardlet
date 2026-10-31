import Foundation
import Synchronization
import XCTest
@testable import NativeHarnessClient

@MainActor
final class MainThreadHangLogTests: XCTestCase {
    /// A main thread held past the threshold is reported once it runs again, with how long it was
    /// busy and a stack that names the function holding it and, deep as it is, what called it.
    func testABusyMainThreadIsReportedWithTheStackThatHeldIt() async throws {
        let hangs = Mutex<[MainThreadHang]>([])
        let watchdog = MainThreadWatchdog(threshold: .milliseconds(100)) { hang in
            hangs.withLock { $0.append(hang) }
        }
        watchdog.start()
        defer { watchdog.stop() }
        try await Task.sleep(for: .milliseconds(50))
        hangs.withLock { $0.removeAll() }

        Self.nest(100) { Self.holdMainThread(for: .milliseconds(400)) }
        try await waitUntil { hangs.withLock { !$0.isEmpty } }

        let hang = try XCTUnwrap(hangs.withLock { $0.first })
        XCTAssertGreaterThanOrEqual(hang.duration, .milliseconds(400))
        let sample = try XCTUnwrap(hang.samples.first)
        let stack = sample.frames.joined(separator: "\n")
        XCTAssertTrue(sample.frames.prefix(MainThreadWatchdog.innerFrames).contains { $0.contains("holdMainThread") }, stack)
        XCTAssertGreaterThan(sample.omitted, 0, stack)
        XCTAssertTrue(sample.frames.suffix(MainThreadWatchdog.maximumFrames - MainThreadWatchdog.innerFrames)
            .contains { $0.contains("testABusyMainThreadIsReportedWithTheStackThatHeldIt") }, stack)
        XCTAssertTrue(hang.description.contains("main thread busy"))
        XCTAssertTrue(hang.description.contains("frames left out"))
    }

    /// A main thread that stays busy past the last sample is written then, before it runs again: a
    /// deadlock, which never ends, is in the log too.
    func testAHangStillGoingAfterItsLastSampleIsWrittenBeforeItEnds() async throws {
        let hangs = Mutex<[(hang: MainThreadHang, at: ContinuousClock.Instant)]>([])
        let watchdog = MainThreadWatchdog(threshold: .milliseconds(100), resampleInterval: .milliseconds(50),
                                          maximumSamples: 2) { hang in
            hangs.withLock { $0.append((hang, ContinuousClock.now)) }
        }
        watchdog.start()
        defer { watchdog.stop() }
        try await Task.sleep(for: .milliseconds(50))
        hangs.withLock { $0.removeAll() }

        Self.holdMainThread(for: .seconds(1))
        let released = ContinuousClock.now
        try await waitUntil { hangs.withLock { !$0.isEmpty } }

        let (hang, writtenAt) = try XCTUnwrap(hangs.withLock { $0.first })
        XCTAssertTrue(hang.isOngoing)
        XCTAssertLessThan(writtenAt, released, "The hang was written only once it ended")
        XCTAssertEqual(hang.samples.count, 2)
        XCTAssertTrue(hang.description.contains("still busy"))
    }

    /// Calls `body` from `depth` frames down, a stack as deep as SwiftUI's layout makes.
    @inline(never)
    private static func nest(_ depth: Int, _ body: () -> Void) {
        guard depth > 0 else { return body() }
        nest(depth - 1, body)
        // Something after the call, so it is not a tail call that leaves no frame.
        blackHole(depth)
    }

    @inline(never)
    private static func blackHole(_ value: Int) {}

    @inline(never)
    private static func holdMainThread(for duration: Duration) {
        let end = ContinuousClock.now + duration
        while ContinuousClock.now < end {}
    }
}
