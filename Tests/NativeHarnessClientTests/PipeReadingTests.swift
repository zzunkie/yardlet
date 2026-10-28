import Foundation
import os
import XCTest
@testable import NativeHarnessClient

final class PipeReadingTests: XCTestCase {
    /// A child that writes and exits at once leaves its pipe readable for good. Reading stops at
    /// the end: a handler left in place would run again and again with no data and keep a core
    /// busy long after the process is gone.
    func testAPipeIsReadToItsEndOnceAfterTheProcessExits() async throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "printf ready"]
        process.standardOutput = output
        let read = OSAllocatedUnfairLock(initialState: (data: Data(), ends: 0))
        let ended = expectation(description: "the pipe reached its end")
        output.fileHandleForReading.readChunks { chunk in
            read.withLock { $0.data.append(chunk) }
        } atEnd: {
            if read.withLock({ $0.ends += 1; return $0.ends }) == 1 { ended.fulfill() }
        }
        try process.run()
        await fulfillment(of: [ended], timeout: 10)
        try await Task.sleep(for: .milliseconds(200))

        let (data, ends) = read.withLock { ($0.data, $0.ends) }
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ready")
        XCTAssertEqual(ends, 1, "The end of the pipe was handled again after it was reached")
        XCTAssertNil(output.fileHandleForReading.readabilityHandler)
    }
}
