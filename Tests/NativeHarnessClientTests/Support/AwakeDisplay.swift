import CoreGraphics
import XCTest

/// Skips the rest of a test that scrolls with the wheel or the trackpad when the Mac's display
/// cannot show the scroll. AppKit moves a scroll view by such a scroll on the refreshes of the
/// display its window is on (the screen's display link), so while that display sleeps the scroll
/// never lands; a locked screen stops it too. The tests' unshown windows sit at the origin, on the
/// main display. CI's display never sleeps, but a Mac running the tests with its displays off
/// would report every such scroll as a failure.
func requireAwakeDisplay() throws {
    try XCTSkipIf(CGDisplayIsAsleep(CGMainDisplayID()) != 0, "Scrolling needs an awake display")
    // The display can wake for a moment while the screen stays locked; scrolling stops then too.
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    try XCTSkipIf((session?["CGSSessionScreenIsLocked"] as? Bool) == true, "Scrolling needs an unlocked screen")
}
