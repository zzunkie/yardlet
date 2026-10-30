import Foundation

/// The kernel's memory pressure warnings, at warning and critical.
enum MemoryPressureWatch {
    /// Calls `handler` on the main actor at each warning, for as long as the returned source is kept.
    static func start(_ handler: @escaping @MainActor () -> Void) -> AnyObject? {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { handler() }
        }
        source.resume()
        return source
    }
}
