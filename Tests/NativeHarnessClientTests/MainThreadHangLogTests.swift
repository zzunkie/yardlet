import Foundation
import Synchronization
import XCTest
@testable import NativeHarnessClient

@MainActor
final class MainThreadHangLogTests: XCTestCase {
    /// A main thread held past the threshold is reported once it runs again, with how long it was
    /// busy and a stack that names the function holding it.
    func testABusyMainThreadIsReportedWithTheStackThatHeldIt() async throws {
        let hangs = Mutex<[MainThreadHang]>([])
        let watchdog = MainThreadWatchdog(threshold: .milliseconds(100)) { hang in
            hangs.withLock { $0.append(hang) }
        }
        watchdog.start()
        defer { watchdog.stop() }
        try await Task.sleep(for: .milliseconds(50))
        hangs.withLock { $0.removeAll() }

        Self.holdMainThread(for: .milliseconds(400))
        try await waitUntil { hangs.withLock { !$0.isEmpty } }

        let hang = try XCTUnwrap(hangs.withLock { $0.first })
        XCTAssertGreaterThanOrEqual(hang.duration, .milliseconds(400))
        let stack = try XCTUnwrap(hang.samples.first).frames
        XCTAssertTrue(stack.contains { $0.contains("holdMainThread") }, stack.joined(separator: "\n"))
        XCTAssertTrue(hang.description.contains("main thread busy"))
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

    @inline(never)
    private static func holdMainThread(for duration: Duration) {
        let end = ContinuousClock.now + duration
        while ContinuousClock.now < end {}
    }
}
