import Foundation

/// The follow-up policy for every projected task uses the same steering preference.
@MainActor
final class RemoteSnapshotPreferences {
    private(set) var antigravitySteers: Bool
    var onChange: (() -> Void)?
    nonisolated(unsafe) private let observers: [NSObjectProtocol]
    private var refresh: Task<Void, Never>?

    init(defaults: UserDefaults) {
        nonisolated(unsafe) let watched = defaults
        let (changes, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: nil) { _ in
                signal.yield(())
            },
            center.addObserver(forName: AntigravityLiveSteer.didChangeNotification, object: nil, queue: nil) { _ in
                signal.yield(())
            }
        ]
        antigravitySteers = AntigravityLiveSteer.isEnabled(in: defaults)
        refresh = Task.detached(priority: .utility) { [weak self] in
            for await _ in changes {
                let latest = AntigravityLiveSteer.isEnabled(in: watched)
                await self?.update(latest)
            }
        }
    }

    deinit {
        refresh?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    private func update(_ latest: Bool) {
        guard antigravitySteers != latest else { return }
        antigravitySteers = latest
        onChange?()
    }
}
