import Foundation
import Observation

/// How often what `reads` reads changed, re-reading after each change as a view body would.
@MainActor
final class Invalidations {
    private(set) var count = 0
    private let reads: @MainActor () -> Void
    private var isStopped = false

    init(_ reads: @escaping @MainActor () -> Void) {
        self.reads = reads
        arm()
    }

    func stop() { isStopped = true }

    private func arm() {
        guard !isStopped else { return }
        withObservationTracking { reads() } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isStopped else { return }
                self.count += 1
                self.arm()
            }
        }
    }
}

/// The longest the main actor went without running a 5 ms timer.
@MainActor
final class MainActorGapProbe {
    private var longest = Duration.zero
    private var task: Task<Void, Never>?

    /// Returns once the timer runs.
    func start() async {
        task = Task { @MainActor [weak self] in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
                let now = ContinuousClock.now
                if let self { self.longest = max(self.longest, now - last) }
                last = now
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
    }

    func stop() async -> Duration {
        // One more tick, so a hold that ends the measured work is counted.
        try? await Task.sleep(for: .milliseconds(20))
        task?.cancel()
        await task?.value
        return longest
    }
}
