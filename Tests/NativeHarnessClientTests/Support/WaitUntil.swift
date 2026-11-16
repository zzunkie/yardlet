import Foundation
import XCTest

/// How long a test waits for something that happens in its own time: an event a stream delivers,
/// a debounce or publication interval coming due, a child process answering. CI runs four test
/// processes on three cores, where a step that takes milliseconds on a Mac can take seconds, so the
/// limit is generous; a passing test waits only as long as the work takes.
let testWaitLimit: Duration = .seconds(20)

/// `testWaitLimit` for the helpers that count time in `TimeInterval`.
let testWaitLimitSeconds: TimeInterval = testWaitLimit / .seconds(1)

/// Waits until `condition` holds, checking it every 10 ms on the caller's actor, and fails the test
/// at the caller's line when it still does not hold after `timeout`. Use it instead of sleeping for
/// a fixed time before asserting that something happened. A check that something did *not* happen
/// still sleeps: there is nothing to wait for. `message`, read only when the wait fails, says what
/// was there instead.
func waitUntil(
    timeout: Duration = testWaitLimit,
    isolation: isolated (any Actor)? = #isolation,
    message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    if try await condition() { return }
    let detail = message()
    XCTFail("Condition was not met within \(timeout)" + (detail.isEmpty ? "" : ": \(detail)"), file: file, line: line)
}
