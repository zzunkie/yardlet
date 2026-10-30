import Foundation

/// Ending a process Yardlet started, with Foundation alone: the process is asked to end, and what
/// it started is left to end with it. A platform's own layer also ends the descendants.
enum NativeProcessTree {
    @discardableResult
    static func terminate(process: Process) -> Int32 {
        guard process.isRunning else { return process.terminationStatus }
        process.terminate()
        let deadline = ContinuousClock.now + .seconds(2)
        while process.isRunning, ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return process.isRunning ? -1 : process.terminationStatus
    }
}

/// Foundation outside Apple's platforms has no autorelease pool; the work just runs.
func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
    try body()
}
