import Foundation

/// Writes Yardlet's small state files (composer drafts, split views, remembered account readings and
/// assignments, the runtimes' model lists, the browser's address history and which task uses which
/// profile) and the preferences a store sets on every change (the follow-up queues)
/// off the main thread. A store hands over a file's next contents as a write that encodes and saves a
/// snapshot it took, and returns at once: an atomic write syncs the file to disk, which takes a second or
/// more while the disk is busy, and setting a preference can wait as long for cfprefsd to write the whole
/// domain. The main thread must not wait for either.
///
/// Writes run one at a time on one serial queue, in the order they were handed over. A file's (or a
/// preference's) write that has not started yet gives way to a newer one of the same file, so a burst of
/// changes is written once and the newest contents always win. `flush()` returns once every write handed
/// over so far has ended: a store calls it before it reads its file, so a read sees the last save, and
/// Yardlet calls it when it quits, so nothing handed over is lost.
final class StateFileWriter: @unchecked Sendable {
    typealias Write = @Sendable () throws -> Void
    /// Told on the main actor whether the file's write succeeded.
    typealias Done = @MainActor @Sendable (Bool) -> Void

    static let shared = StateFileWriter()

    private enum Target: Hashable {
        case file(URL)
        case preference(ObjectIdentifier, String)
    }

    private struct Waiting {
        var write: Write
        /// The writes this one replaced are told its result: it holds their contents and more.
        var done: [Done]
    }

    private let queue = DispatchQueue(label: "Yardlet.stateFiles", qos: .utility)
    private let lock = NSLock()
    /// Each file's newest write not started yet. A file has at most one block on the queue for it.
    private var waiting: [Target: Waiting] = [:]

    /// Hands over `write` as `file`'s next contents. `done`, when given, hears on the main actor whether
    /// the contents were saved, after every write handed over before it was told.
    func write(_ file: URL, done: Done? = nil, _ write: @escaping Write) {
        hand(write, to: .file(file.standardizedFileURL), done: done)
    }

    /// Hands over `write` as the next value of `key` in `defaults`, which it sets or removes.
    func write(_ key: String, in defaults: UserDefaults, _ write: @escaping Write) {
        hand(write, to: .preference(ObjectIdentifier(defaults), key), done: nil)
    }

    private func hand(_ write: @escaping Write, to key: Target, done: Done?) {
        let queued = lock.withLock {
            let queued = waiting[key] != nil
            waiting[key] = Waiting(write: write, done: (waiting[key]?.done ?? []) + (done.map { [$0] } ?? []))
            return queued
        }
        guard !queued else { return }
        queue.async { [self] in
            guard let next = lock.withLock({ waiting.removeValue(forKey: key) }) else { return }
            let saved = (try? next.write()) != nil
            guard !next.done.isEmpty else { return }
            // The main queue runs these in the order they were sent, so the last result is the one kept.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { for done in next.done { done(saved) } }
            }
        }
    }

    /// Returns once every write handed over so far has ended. Never called on the writer's own queue.
    func flush() {
        queue.sync {}
    }

    /// `flush()` without holding the caller's thread while the writes finish.
    func flushed() async {
        let queue = queue
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { done.resume() }
        }
    }
}
