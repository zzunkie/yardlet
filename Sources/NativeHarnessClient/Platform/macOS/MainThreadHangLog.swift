import Darwin
import Foundation
import Synchronization

/// Writes the main thread's stack to `~/Library/Logs/Yardlet/hangs.log` whenever the main run loop
/// stays busy longer than 250 ms, the threshold at which Apple's tools report a hang. Each entry
/// has the time, how long the main thread was busy, and the stack at 250 ms and at each further
/// second (up to five, after which a hang still going is written as it is); a deep stack keeps its
/// innermost frames and its outermost, which say what started the work; nothing of a
/// conversation, a setting or a credential. On by default; turn it off with
///
///     defaults write com.zzunkie.yardlet Yardlet.debug.hangLog -bool NO
///
/// and quit and open Yardlet (`defaults delete …` turns it on again). The setting is read once per
/// launch; while it is off there is no observer and no thread.
///
/// MetricKit's `MXHangDiagnostic` reports hangs too, but only after the fact, with a threshold the
/// system picks and stacks that are often a few frames long, so this watches the run loop itself.
enum MainThreadHangLog {
    static let defaultsKey = "Yardlet.debug.hangLog"

    static var isEnabled: Bool {
        UserDefaults.yardlet.object(forKey: defaultsKey) as? Bool ?? true
    }

    /// The log in real use. It is kept under `maximumFileSize`; the entries before go to `hangs.1.log`.
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/Yardlet", directoryHint: .isDirectory)
            .appending(path: "hangs.log")
    }

    static let maximumFileSize = 1_000_000

    @MainActor private static var watchdog: MainThreadWatchdog?

    /// Starts watching at launch, unless the log is off or this is a test process.
    @MainActor
    static func start() {
        guard watchdog == nil, isEnabled, NSClassFromString("XCTestCase") == nil else { return }
        let url = fileURL
        let watchdog = MainThreadWatchdog { hang in append(hang.description, to: url) }
        watchdog.start()
        self.watchdog = watchdog
    }

    /// Runs on the watchdog's thread, which does nothing else while it writes.
    static func append(_ entry: String, to url: URL) {
        let manager = FileManager.default
        let path = url.path(percentEncoded: false)
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? manager.attributesOfItem(atPath: path))?[.size] as? Int, size > maximumFileSize {
            let previous = url.deletingLastPathComponent().appending(path: "hangs.1.log")
            try? manager.removeItem(at: previous)
            try? manager.moveItem(at: url, to: previous)
        }
        if !manager.fileExists(atPath: path) { manager.createFile(atPath: path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(entry.utf8))
    }
}

/// One main-thread hang: when the busy period began, how long it lasted, and the stacks taken
/// while it lasted.
struct MainThreadHang: Sendable {
    struct Sample: Sendable {
        /// How long the main thread had been busy when the stack was taken.
        let after: Duration
        let frames: [String]
        /// Frames of a deep stack left out between its innermost `MainThreadWatchdog.innerFrames`
        /// and its outermost.
        var omitted = 0
    }

    let began: Date
    let duration: Duration
    /// Written before the main thread ran again: after its last sample it was still busy, as it
    /// stays when it waits on itself.
    var isOngoing = false
    let samples: [Sample]

    var description: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let time = began.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current))
        let still = isOngoing ? " and still busy" : ""
        var text = "\(time) main thread busy \(duration.milliseconds) ms\(still) (Yardlet \(version) (\(build)))\n"
        for sample in samples {
            text += "  at \(sample.after.milliseconds) ms:\n"
            for (index, frame) in sample.frames.enumerated() {
                let inner = index < MainThreadWatchdog.innerFrames || sample.omitted == 0
                if !inner, index == MainThreadWatchdog.innerFrames {
                    text += "    ... \(sample.omitted) frames left out\n"
                }
                text += "    \(inner ? index : index + sample.omitted) \(frame)\n"
            }
        }
        return text
    }
}

private extension Duration {
    var milliseconds: Int64 { components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000 }
}

/// Watches the main run loop as Apple's hang reporting does: the time from leaving one wait for
/// events to entering the next is a busy period, and one longer than `threshold` is a hang.
///
/// The main thread only stores the time at each boundary, from two run loop observers, one that
/// runs first as it wakes and one that runs last before it sleeps (after Core Animation's commit).
/// A thread of the watchdog sleeps until a busy period could reach the threshold and sleeps
/// without a timer while the main thread waits for events, so an idle app wakes it never. At the
/// threshold it suspends the main thread for the few microseconds it takes to read its frame
/// pointers, and names the frames once the main thread runs again.
final class MainThreadWatchdog: @unchecked Sendable {
    private let threshold: Duration
    private let report: @Sendable (MainThreadHang) -> Void
    /// When the current busy period began (`clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`, which stops
    /// while the Mac sleeps); 0 while the main thread waits for events.
    private let busySince = Atomic<UInt64>(0)
    /// Counts busy periods, so the watchdog tells a long one from two that began at the same time.
    private let period = Atomic<UInt64>(0)
    /// The watchdog waits on `wake` until a busy period begins.
    private let parked = Atomic<Bool>(false)
    private let wake = DispatchSemaphore(value: 0)
    /// Set while the watchdog records a hang; the main thread clears it, stores when the hang
    /// ended in `hangEnded` and signals `ended` at the next boundary.
    private let hanging = Atomic<Bool>(false)
    private let hangEnded = Atomic<UInt64>(0)
    private let ended = DispatchSemaphore(value: 0)
    private let stopped = Atomic<Bool>(false)
    /// The main thread and its stack, read by `start()` on the main thread before the watchdog's
    /// thread begins. Every frame the main thread saves lies between the stack's two ends.
    private var mainThread: thread_act_t = 0
    private var stackTop: UInt = 0
    private var stackBottom: UInt = 0
    private var observers: [CFRunLoopObserver] = []

    static let maximumFrames = 64
    /// A deeper stack keeps this many of its innermost frames, and its outermost after them.
    static let innerFrames = 48
    /// A hang is sampled again every `resampleInterval`, up to `maximumSamples` times.
    private let resampleInterval: Duration
    private let maximumSamples: Int

    init(threshold: Duration = .milliseconds(250), resampleInterval: Duration = .seconds(1), maximumSamples: Int = 5,
         report: @escaping @Sendable (MainThreadHang) -> Void) {
        self.threshold = threshold
        self.resampleInterval = resampleInterval
        self.maximumSamples = maximumSamples
        self.report = report
    }

    /// Installs the observers and starts the watchdog's thread. Call once, on the main thread.
    @MainActor
    func start() {
        let main = pthread_self()
        mainThread = pthread_mach_thread_np(main)
        stackTop = UInt(bitPattern: pthread_get_stackaddr_np(main))
        stackBottom = stackTop - UInt(pthread_get_stacksize_np(main))
        beginBusyPeriod()
        let wakes = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity([.entry, .afterWaiting, .exit]).rawValue, true, CFIndex.min
        ) { [unowned self] _, _ in beginBusyPeriod() }
        let sleeps = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
        ) { [unowned self] _, _ in endBusyPeriod() }
        for observer in [wakes, sleeps].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }
        let thread = Thread { [self] in watch() }
        thread.name = "Yardlet main thread watchdog"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Removes the observers; the watchdog's thread ends at its next wake.
    @MainActor
    func stop() {
        for observer in observers { CFRunLoopObserverInvalidate(observer) }
        observers.removeAll()
        stopped.store(true, ordering: .sequentiallyConsistent)
        wake.signal()
        ended.signal()
    }

    // MARK: Main thread

    private func beginBusyPeriod() {
        let now = Self.now()
        noteBoundary(at: now)
        busySince.store(now, ordering: .sequentiallyConsistent)
        period.wrappingAdd(1, ordering: .sequentiallyConsistent)
        if parked.exchange(false, ordering: .sequentiallyConsistent) { wake.signal() }
    }

    private func endBusyPeriod() {
        noteBoundary(at: Self.now())
        busySince.store(0, ordering: .sequentiallyConsistent)
    }

    private func noteBoundary(at now: UInt64) {
        guard hanging.exchange(false, ordering: .sequentiallyConsistent) else { return }
        hangEnded.store(now, ordering: .sequentiallyConsistent)
        ended.signal()
    }

    // MARK: Watchdog thread

    private func watch() {
        let frames = UnsafeMutablePointer<UInt>.allocate(capacity: Self.maximumFrames)
        defer { frames.deallocate() }
        while !stopped.load(ordering: .sequentiallyConsistent) {
            let since = busySince.load(ordering: .sequentiallyConsistent)
            guard since != 0 else {
                parked.store(true, ordering: .sequentiallyConsistent)
                // A busy period that began after the check above found `parked` false and did not
                // signal; one that began after the store took it back and did.
                if busySince.load(ordering: .sequentiallyConsistent) == 0
                    || !parked.exchange(false, ordering: .sequentiallyConsistent) {
                    wake.wait()
                }
                continue
            }
            let current = period.load(ordering: .sequentiallyConsistent)
            let due = since &+ UInt64(threshold.nanoseconds)
            let now = Self.now()
            if now < due {
                Self.sleep(nanoseconds: due - now)
                continue
            }
            hanging.store(true, ordering: .sequentiallyConsistent)
            guard period.load(ordering: .sequentiallyConsistent) == current,
                  busySince.load(ordering: .sequentiallyConsistent) == since else {
                // The period ended as the hang was noted; if the main thread saw the note, it signalled.
                if !hanging.exchange(false, ordering: .sequentiallyConsistent) { ended.wait() }
                continue
            }
            record(busySince: since, frames: frames)
        }
    }

    /// Samples the main thread until the hang ends, or until the last sample, after which a hang
    /// that goes on is written at once: one that never ends, as a deadlock does, is written too.
    private func record(busySince since: UInt64, frames: UnsafeMutablePointer<UInt>) {
        var samples: [MainThreadHang.Sample] = []
        var hasEnded = false
        while !hasEnded, samples.count < maximumSamples {
            let (count, depth) = sampleMainThread(into: frames)
            let omitted = depth - count
            if omitted > 0 {
                // The outermost frames went round in their part of the buffer; the oldest is where the next would go.
                let outer = UnsafeMutableBufferPointer(rebasing: UnsafeMutableBufferPointer(
                    start: frames, count: Self.maximumFrames)[Self.innerFrames...])
                let start = (depth - Self.innerFrames) % outer.count
                let ordered = Array(outer[start...]) + Array(outer[..<start])
                for (index, frame) in ordered.enumerated() { outer[index] = frame }
            }
            samples.append(MainThreadHang.Sample(
                after: .nanoseconds(Int64(Self.now() &- since)),
                frames: (0..<count).map { Self.describe(frames[$0], returnAddress: $0 > 0) },
                omitted: omitted
            ))
            hasEnded = ended.wait(timeout: .now() + .nanoseconds(Int(resampleInterval.nanoseconds))) == .success
        }
        let reports = !stopped.load(ordering: .sequentiallyConsistent) && !Self.isBeingDebugged
        let elapsed = (hasEnded ? hangEnded.load(ordering: .sequentiallyConsistent) : Self.now()) &- since
        let began = Date(timeIntervalSinceNow: -Double(Self.now() &- since) / 1e9)
        if reports {
            report(MainThreadHang(began: began, duration: .nanoseconds(Int64(elapsed)), isOngoing: !hasEnded,
                                  samples: samples))
        }
        // The main thread signals once it runs again; that signal belongs to this hang.
        if !hasEnded { ended.wait() }
    }

    /// Reads the main thread's program counter, link register and frame-pointer chain into
    /// `frames` while it is suspended: all of it when it fits, else its innermost `innerFrames`
    /// and, going round in the rest of `frames`, the frames after them, which end with the
    /// outermost. Returns how many frames it kept and how deep the stack was. Nothing between
    /// suspending and resuming allocates or takes a lock the main thread could hold.
    private func sampleMainThread(into frames: UnsafeMutablePointer<UInt>) -> (count: Int, depth: Int) {
        #if arch(arm64)
        guard thread_suspend(mainThread) == KERN_SUCCESS else { return (0, 0) }
        defer { thread_resume(mainThread) }
        var state = arm_thread_state64_t()
        var stateCount = mach_msg_type_number_t(
            MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let read = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                thread_get_state(mainThread, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &stateCount)
            }
        }
        guard read == KERN_SUCCESS else { return (0, 0) }
        var depth = 0
        Self.keep(Self.stripped(UInt(state.__pc)), in: frames, depth: &depth)
        var framePointer = UInt(state.__fp)
        let linkRegister = Self.stripped(UInt(state.__lr))
        var first = true
        // Each frame record is the caller's frame pointer and the return address, on the main
        // thread's own stack; a frame pointer outside it ends the chain instead of being read.
        while framePointer >= stackBottom, framePointer + 16 <= stackTop,
              framePointer % 8 == 0, let record = UnsafePointer<UInt>(bitPattern: framePointer) {
            let previous = record[0]
            let returnAddress = Self.stripped(record[1])
            guard returnAddress != 0 else { break }
            // A function that has not saved its frame yet returns to the link register.
            if first, linkRegister != 0, linkRegister != returnAddress { Self.keep(linkRegister, in: frames, depth: &depth) }
            first = false
            Self.keep(returnAddress, in: frames, depth: &depth)
            // Callers' frames sit higher on the stack.
            guard previous > framePointer else { break }
            framePointer = previous
        }
        return (min(depth, Self.maximumFrames), depth)
        #else
        return (0, 0)
        #endif
    }

    /// Puts the frame at `depth` where `sampleMainThread` keeps it, past the innermost going round.
    private static func keep(_ frame: UInt, in frames: UnsafeMutablePointer<UInt>, depth: inout Int) {
        let outer = maximumFrames - innerFrames
        frames[depth < maximumFrames ? depth : innerFrames + (depth - innerFrames) % outer] = frame
        depth += 1
    }

    /// Return addresses saved by arm64e system code carry a pointer signature in their high bits.
    private static func stripped(_ address: UInt) -> UInt {
        address & 0x0000_7FFF_FFFF_FFFF
    }

    /// `image  address  symbol + offset`, the symbol demangled when it is Swift's.
    private static func describe(_ address: UInt, returnAddress: Bool) -> String {
        // A return address points past its call; the call is what names the frame.
        let lookup = returnAddress && address > 0 ? address - 1 : address
        var info = Dl_info()
        guard let pointer = UnsafeRawPointer(bitPattern: lookup), dladdr(pointer, &info) != 0 else {
            return "? 0x\(String(address, radix: 16))"
        }
        let image = info.dli_fname.map { URL(filePath: String(cString: $0)).lastPathComponent } ?? "?"
        let base = UInt(bitPattern: info.dli_fbase)
        guard let name = info.dli_sname else {
            return "\(image) 0x\(String(address, radix: 16)) \(image) + \(address &- base)"
        }
        let symbol = demangled(name) ?? String(cString: name)
        return "\(image) 0x\(String(address, radix: 16)) \(symbol) + \(address &- UInt(bitPattern: info.dli_saddr))"
    }

    private static func demangled(_ name: UnsafePointer<CChar>) -> String? {
        guard let result = swift_demangle(name, strlen(name), nil, nil, 0) else { return nil }
        defer { free(result) }
        return String(cString: result)
    }

    private static var isBeingDebugged: Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return false }
        return info.kp_proc.p_flag & P_TRACED != 0
    }

    private static func now() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    private static func sleep(nanoseconds: UInt64) {
        var time = timespec(tv_sec: Int(nanoseconds / 1_000_000_000), tv_nsec: Int(nanoseconds % 1_000_000_000))
        var remaining = timespec()
        while nanosleep(&time, &remaining) == -1, errno == EINTR { time = remaining }
    }
}

private extension Duration {
    var nanoseconds: Int64 { components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000 }
}

@_silgen_name("swift_demangle")
private func swift_demangle(
    _ mangledName: UnsafePointer<CChar>?, _ mangledNameLength: Int,
    _ outputBuffer: UnsafeMutablePointer<CChar>?, _ outputBufferSize: UnsafeMutablePointer<Int>?,
    _ flags: UInt32
) -> UnsafeMutablePointer<CChar>?
