import AppKit

/// A trackpad scroll with its phases, `points` up in `count` moves, which is how SwiftUI tells a
/// reader's scroll from layout. It only moves while the display is awake and unlocked
/// (`requireAwakeDisplay`): AppKit moves the view by the deltas it has received on the display's next
/// refresh, and drops those it has not applied when the gesture ends. So each move waits for the view
/// to follow before the next; on a busy machine a fixed pause can pass without a refresh, and the
/// scroll stopped short of where it was sent.
@MainActor
func trackpadScroll(_ scroll: NSScrollView, up points: Int32, steps count: Int32 = 6) {
    let steps: [(phase: Int64, delta: Int32)] = [(1, 0)]
        + Array(repeating: (2, points / count), count: Int(count)) + [(4, 0)]
    let deadline = Date().addingTimeInterval(testWaitLimitSeconds)
    for step in steps {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: step.delta, wheel2: 0, wheel3: 0) else { continue }
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: step.phase)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        let before = scroll.contentView.bounds.minY
        if let wheel = NSEvent(cgEvent: event) { scroll.scrollWheel(with: wheel) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        // Up from the top there is nowhere to move.
        while step.delta != 0, before > 0, scroll.contentView.bounds.minY == before, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
