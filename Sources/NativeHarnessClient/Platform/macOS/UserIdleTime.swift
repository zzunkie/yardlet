import CoreGraphics

/// How long ago the person last typed, clicked or moved the pointer anywhere on this Mac (reads only).
enum UserIdleTime {
    static var seconds: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}
