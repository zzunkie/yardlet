import Foundation
import Synchronization
import XCTest
@testable import NativeHarnessClient

@MainActor
final class MainThreadHangLogTests: XCTestCase {
    func testOnlyAnIdleSheetAnimationLoopIsExcluded() {
        let wait = [
            "libsystem_kernel.dylib 0x1 mach_msg2_trap + 8",
            "libsystem_kernel.dylib 0x2 mach_msg + 4",
            "CoreFoundation 0x3 __CFRunLoopServiceMachPort + 8",
            "CoreFoundation 0x4 __CFRunLoopRun + 4",
            "CoreFoundation 0x5 _CFRunLoopRunSpecificWithOptions + 4"
        ]
        func sample(_ frames: [String]) -> MainThreadHang.Sample { .init(after: .milliseconds(250), frames: frames) }
        func hang(_ samples: [MainThreadHang.Sample], ongoing: Bool = false) -> MainThreadHang {
            .init(began: Date(), duration: .milliseconds(300), isOngoing: ongoing, samples: samples)
        }
        XCTAssertTrue(hang([]).shouldReport)
        for selector in ["openSheet", "closeSheet"] {
            let animation = ["AppKit 0x6 -[NSMoveHelper _doAnimation] + 4",
                             "AppKit 0x7 -[NSSheetMoveHelper \(selector)] + 8"]
            let idle = sample(wait + animation)
            XCTAssertFalse(hang([idle]).shouldReport)
            XCTAssertTrue(hang([idle], ongoing: true).shouldReport)
            let callback = sample(wait + ["Yardlet 0x8 waitForResult + 4"] + wait.suffix(2) + animation)
            XCTAssertTrue(hang([idle, callback]).shouldReport)
            XCTAssertTrue(hang([sample(["Yardlet 0x9 prepareSheet + 8"] + animation)]).shouldReport)
        }
    }

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
        let hangs = Mutex<[MainThreadHang]>([])
        let written = Atomic<Bool>(false)
        let watchdog = MainThreadWatchdog(threshold: .milliseconds(100), resampleInterval: .milliseconds(50),
                                          maximumSamples: 2) { hang in
            hangs.withLock { $0.append(hang) }
            written.store(true, ordering: .sequentiallyConsistent)
        }
        // `start()` begins a busy period, which the hold below carries on: no hang before it.
        watchdog.start()
        defer { watchdog.stop() }

        // Busy until the hang is written, however late the watchdog's thread gets a core: a hold
        // of fixed length can end first on a loaded machine, and the hang is then written as ended.
        let writtenWhileBusy = Self.holdMainThread(atMost: testWaitLimit) {
            written.load(ordering: .sequentiallyConsistent)
        }

        XCTAssertTrue(writtenWhileBusy, "The hang was written only once it ended")
        let hang = try XCTUnwrap(hangs.withLock { $0.first })
        XCTAssertTrue(hang.isOngoing)
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

    /// Keeps the main thread busy until `done` holds, for at most `limit`; returns whether it held.
    @inline(never)
    private static func holdMainThread(atMost limit: Duration, until done: () -> Bool) -> Bool {
        let end = ContinuousClock.now + limit
        while ContinuousClock.now < end {
            if done() { return true }
        }
        return done()
    }
}
