import AppKit
import SwiftUI

/// Tells whether the window showing the dots can be seen: on screen and not covered, minimized or
/// hidden with its app. Another app being in front does not count, as a page in the provider's app
/// stays visible then. It reports only when that changes.
struct PersonalAgentWindowVisibility: NSViewRepresentable {
    /// Whether this view now sees the window shown, and which view it is: a view replaced by another
    /// can report after it.
    let changed: @MainActor (Bool, UUID) -> Void

    func makeNSView(context: Context) -> ReportingView { ReportingView() }

    func updateNSView(_ view: ReportingView, context: Context) {
        view.changed = changed
        view.report()
    }

    final class ReportingView: NSView {
        var changed: (@MainActor (Bool, UUID) -> Void)?
        /// Whether the window can be seen now. Replaced only to observe a room in a window that is not shown.
        @MainActor static var isOnScreen: (NSWindow) -> Bool = { $0.occlusionState.contains(.visible) }
        private var observers: [NSObjectProtocol] = []
        private var reported: Bool?
        /// Which view this is, never reused by another.
        private let id = UUID()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if let window {
                let update: @Sendable (Notification) -> Void = { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
                observers = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                             NSWindow.didDeminiaturizeNotification].map {
                    NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main, using: update)
                }
            }
            report()
        }

        func report() {
            let visible = window.map { Self.isOnScreen($0) && !$0.isMiniaturized } ?? false
            guard visible != reported else { return }
            reported = visible
            // After the update that moved the view, never during it.
            DispatchQueue.main.async { [changed, id] in changed?(visible, id) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
