import AppKit
import SwiftUI

/// A view that keeps its own back and forward history, as a browser page does. The mouse's back and
/// forward buttons pressed over it are its own, and the window's Back and Forward do not run.
@MainActor
protocol MouseHistoryNavigating: NSView {}

/// The mouse's back and forward buttons (buttons 4 and 5, AppKit's `buttonNumber` 3 and 4), which
/// both apps read: the Claude app's main view and the Codex app's window send them to Back and Forward,
/// and the Codex app's browser page to that page's own history.
enum MouseNavigationButton: Equatable {
    case back, forward

    init?(_ event: NSEvent) {
        switch event.buttonNumber {
        case 3: self = .back
        case 4: self = .forward
        default: return nil
        }
    }
}

/// The window's Back and Forward on the mouse's buttons. Where the pointer is decides: over a view
/// with its own history (`MouseHistoryNavigating`) the press goes on to that view; anywhere else in
/// the window it is the window's, and its release goes back or forward. Neither half of a press the
/// window takes reaches the view under the pointer, which would read it as a middle click.
struct MouseNavigationMonitor: NSViewRepresentable {
    var goBack: (() -> Void)?
    var goForward: (() -> Void)?

    func makeNSView(context: Context) -> MouseNavigationMonitorView {
        let view = MouseNavigationMonitorView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MouseNavigationMonitorView, context: Context) {
        view.goBack = goBack
        view.goForward = goForward
    }

    static func dismantleNSView(_ view: MouseNavigationMonitorView, coordinator: ()) {
        view.stopMonitoring()
    }
}

final class MouseNavigationMonitorView: NSView {
    var goBack: (() -> Void)?
    var goForward: (() -> Void)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) { [weak self] event in
            guard let self, self.handle(event) else { return event }
            return nil
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Whether the window took the press.
    func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, let button = MouseNavigationButton(event),
              !Self.keepsOwnHistory(at: event.locationInWindow, in: window) else { return false }
        if event.type == .otherMouseUp {
            (button == .back ? goBack : goForward)?()
        }
        return true
    }

    static func keepsOwnHistory(at point: NSPoint, in window: NSWindow) -> Bool {
        guard let content = window.contentView,
              let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point) else { return false }
        return sequence(first: hit, next: \.superview).contains { $0 is any MouseHistoryNavigating }
    }
}
