import Foundation
import WinSDK

/// Ending a process Yardlet started together with what it started (docs/PLATFORM_PORTABILITY.md, "What a
/// Windows layer needs"). Foundation's `Process` puts a child in no job object and its `terminate()` ends the
/// child alone, so the node and MCP servers a CLI started would stay behind. `run(_:)` puts each process in a
/// job object of its own right after it starts, a job that ends its processes when its last handle closes:
/// `terminate(process:)` ends the whole job, and when Yardlet exits, Windows closes every job and ends what is
/// left in them. Yardlet closes a job itself once its last process has ended, which the job reports through
/// a completion port. A process the child starts in the moment before it is in the job stays outside it.
///
/// `run(_:)` also names each environment variable once (`ExecutableLookup.normalized`) and starts what npm's
/// shim would rather than the shim, refusing any other batch file (`NPMCommandShim`).
enum NativeProcessTree {
    static func run(_ process: Process) throws {
        let lookup = ExecutableLookup.current
        let environment = lookup.normalized(process.environment ?? ProcessInfo.processInfo.environment)
        if process.environment != nil { process.environment = environment }
        if let executable = process.executableURL,
           let launch = try NPMCommandShim.launch(executable, arguments: process.arguments ?? [],
                                                  searchPath: lookup.searchPath(in: environment), lookup: lookup) {
            process.executableURL = launch.executable
            process.arguments = launch.arguments
        }
        try process.run()
        ProcessJobs.shared.contain(process.processIdentifier)
    }

    @discardableResult
    static func terminate(process: Process) -> Int32 {
        guard process.isRunning else { return process.terminationStatus }
        if !ProcessJobs.shared.terminate(process.processIdentifier) {
            process.terminate()
        }
        // Foundation sees the end on its own thread; the caller's wait is bounded. -1 means unconfirmed.
        let deadline = ContinuousClock.now + .seconds(2)
        while process.isRunning, ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return process.isRunning ? -1 : process.terminationStatus
    }
}

/// The job object of each process `NativeProcessTree.run(_:)` started, by its process ID, until the job's last
/// process has ended or Yardlet ended the job.
private final class ProcessJobs: @unchecked Sendable {
    static let shared = ProcessJobs()

    /// A Windows handle, a pointer, which is not `Sendable` on its own.
    private struct Handle: @unchecked Sendable {
        let raw: HANDLE
    }

    private struct Job {
        let handle: Handle
        let processID: Int32
    }

    /// What a process the job ended exits with: an NTSTATUS-shaped code carrying SIGKILL's number, which
    /// Foundation's `Process` reports as that signal, as the Mac's layer ends a tree with SIGKILL.
    private static let terminatedExitCode: UINT = 0xC000_0009

    private let lock = NSLock()
    /// The jobs by the key their completion port messages carry.
    private var jobs: [UInt: Job] = [:]
    /// The key of each running root process's job.
    private var keys: [Int32: UInt] = [:]
    private var nextKey: UInt = 1
    /// Where each job reports that its last process ended.
    private let port: Handle?

    private init() {
        port = CreateIoCompletionPort(INVALID_HANDLE_VALUE, nil, 0, 1).map { Handle(raw: $0) }
        if let port {
            let thread = Thread { [self] in watch(port) }
            thread.name = "Yardlet process jobs"
            thread.start()
        }
    }

    /// Puts the process `processID` in a job of its own. When that fails, the process runs outside one, and
    /// `terminate` leaves it to `Process`.
    func contain(_ processID: Int32) {
        guard processID > 0, let job = CreateJobObjectW(nil, nil) else { return }
        var limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
        limits.BasicLimitInformation.LimitFlags = DWORD(JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE)
        guard SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits,
                                      DWORD(MemoryLayout<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>.size)) else {
            CloseHandle(job)
            return
        }
        // Kept before the job has a process, so its completion message always finds it.
        let key: UInt = lock.withLock {
            let key = nextKey
            nextKey += 1
            jobs[key] = Job(handle: Handle(raw: job), processID: processID)
            keys[processID] = key
            return key
        }
        if let port {
            var association = JOBOBJECT_ASSOCIATE_COMPLETION_PORT()
            association.CompletionKey = UnsafeMutableRawPointer(bitPattern: key)
            association.CompletionPort = port.raw
            _ = SetInformationJobObject(job, JobObjectAssociateCompletionPortInformation, &association,
                                        DWORD(MemoryLayout<JOBOBJECT_ASSOCIATE_COMPLETION_PORT>.size))
        }
        // Foundation closes its own handle of the process once the process has ended, so the job is given one
        // of its own.
        var assigned = false
        if let target = OpenProcess(DWORD(PROCESS_SET_QUOTA | PROCESS_TERMINATE), false, DWORD(processID)) {
            assigned = AssignProcessToJobObject(job, target)
            CloseHandle(target)
        }
        if !assigned { release(key) }
    }

    /// Ends the job of the running process `processID` and every process in it; false when it has none.
    func terminate(_ processID: Int32) -> Bool {
        let job: Handle? = lock.withLock {
            guard let key = keys.removeValue(forKey: processID) else { return nil }
            return jobs.removeValue(forKey: key)?.handle
        }
        guard let job else { return false }
        TerminateJobObject(job.raw, Self.terminatedExitCode)
        CloseHandle(job.raw)
        return true
    }

    private func release(_ key: UInt) {
        let job: Handle? = lock.withLock {
            guard let job = jobs.removeValue(forKey: key) else { return nil }
            if keys[job.processID] == key { keys[job.processID] = nil }
            return job.handle
        }
        if let job { CloseHandle(job.raw) }
    }

    /// Closes each job once it reports that its last process ended.
    private func watch(_ port: Handle) {
        var message: DWORD = 0
        var key: ULONG_PTR = 0
        var overlapped: LPOVERLAPPED?
        while true {
            guard GetQueuedCompletionStatus(port.raw, &message, &key, &overlapped, INFINITE) else {
                // A job's messages never fail; a failure without one is the port's own.
                if overlapped == nil { return }
                continue
            }
            if message == DWORD(JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO) { release(UInt(key)) }
        }
    }
}
