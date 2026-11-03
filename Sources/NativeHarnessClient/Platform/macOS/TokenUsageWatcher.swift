import CoreServices
import Foundation

/// Tells which transcript files changed under the ledger's folders (FSEvents, file events, a couple of
/// seconds' latency so a streaming turn's many writes come as one batch).
final class TokenUsageWatcher: TokenUsageWatching, @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "Yardlet.TokenUsageWatcher", qos: .utility)
    private let onChange: @Sendable (_ paths: [String], _ rescan: Bool) -> Void

    init?(roots: [URL], latency: TimeInterval = 2,
          onChange: @escaping @Sendable (_ paths: [String], _ rescan: Bool) -> Void) {
        self.onChange = onChange
        let paths = roots.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return nil }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<TokenUsageWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            let rescanFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
            let rescan = (0..<count).contains { eventFlags[$0] & rescanFlags != 0 }
            watcher.onChange(paths, rescan)
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    /// The watch the app hands `TokenUsageCenter`.
    static func watch(_ roots: [URL], onChange: @escaping @Sendable (_ paths: [String], _ rescan: Bool) -> Void)
        -> (any TokenUsageWatching)? {
        TokenUsageWatcher(roots: roots, onChange: onChange)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}
