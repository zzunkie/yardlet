import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

@MainActor
final class WindowFrameAutosaveTests: XCTestCase {
    // Visible frames: the built-in display (menu bar and Dock excluded) and an external one above it.
    private let builtIn = NSRect(x: 0, y: 0, width: 1512, height: 949)
    private let external = NSRect(x: -200, y: 982, width: 2560, height: 1415)
    private let minimum = NSSize(width: 760, height: 560)

    private func placed(_ frame: NSRect, zoomed: Bool = false, on screens: [NSRect]) -> NSRect {
        WindowFramePlacement.restoredFrame(SavedWindowFrame(frame, isZoomed: zoomed), screens: screens, minimumSize: minimum)
    }

    func testAFrameStillOnItsScreensComesBackUnchanged() {
        let filling = NSRect(x: 0, y: 0, width: 1512, height: 949)
        XCTAssertEqual(placed(filling, on: [builtIn, external]), filling)
        let onExternal = NSRect(x: 400, y: 1100, width: 1800, height: 1125)
        XCTAssertEqual(placed(onExternal, on: [builtIn, external]), onExternal)
        // Side by side screens: a window across both stays where it is.
        let left = NSRect(x: 0, y: 0, width: 1512, height: 949), right = NSRect(x: 1512, y: 0, width: 1920, height: 1055)
        let across = NSRect(x: 1200, y: 100, width: 900, height: 700)
        XCTAssertEqual(placed(across, on: [left, right]), across)
    }

    func testAFrameWhoseMonitorIsGoneMovesOntoTheMainScreen() {
        let onExternal = NSRect(x: 400, y: 1100, width: 1800, height: 1125)
        let frame = placed(onExternal, on: [builtIn])
        XCTAssertTrue(builtIn.contains(frame), "\(frame)")
        XCTAssertEqual(frame.size, NSSize(width: 1512, height: 949), "It shrinks to the screen it moves to")
        let small = placed(NSRect(x: 3000, y: 2000, width: 900, height: 600), on: [builtIn, external])
        XCTAssertEqual(small, NSRect(x: 306, y: 175, width: 900, height: 600), "Centered on the main screen")
    }

    func testAFramePartlyOffItsScreenIsPulledBackOntoIt() {
        // The external monitor now has a lower resolution: the saved frame hangs off its edges.
        let smallerExternal = NSRect(x: -200, y: 982, width: 1920, height: 1055)
        let frame = placed(NSRect(x: 400, y: 1100, width: 1800, height: 1125), on: [builtIn, smallerExternal])
        XCTAssertTrue(smallerExternal.contains(frame), "\(frame)")
        XCTAssertEqual(frame.width, 1800)
        XCTAssertEqual(frame.height, 1055)
    }

    func testAZoomedWindowThatMovesFillsItsNewScreen() {
        let zoomedOnExternal = external
        XCTAssertEqual(placed(zoomedOnExternal, zoomed: true, on: [builtIn]), builtIn)
        XCTAssertEqual(placed(builtIn, zoomed: true, on: [builtIn, external]), builtIn)
    }

    func testTheWindowMinimumSizeApplies() {
        let tiny = placed(NSRect(x: 100, y: 100, width: 300, height: 200), on: [builtIn])
        XCTAssertEqual(tiny.size, minimum)
        XCTAssertTrue(builtIn.contains(tiny))
    }

    func testStoreRoundTripsAndIgnoresDamagedValues() {
        let defaults = temporaryDefaults()
        let store = WindowFrameStore(defaults: defaults)
        XCTAssertNil(store.load())
        let saved = SavedWindowFrame(NSRect(x: -120.5, y: 40, width: 1400, height: 900), isZoomed: true)
        store.save(saved)
        XCTAssertEqual(store.load(), saved)
        XCTAssertNotNil(defaults.data(forKey: WindowFrameStore.mainWindowKey))
        defaults.set(Data("broken".utf8), forKey: WindowFrameStore.mainWindowKey)
        XCTAssertNil(store.load())
        store.save(SavedWindowFrame(NSRect(x: 0, y: 0, width: 0, height: 900)))
        XCTAssertNil(store.load())
    }

    /// A real window: frames saved while it moves and resizes come back in the next launch's window.
    func testARealWindowReopensWithTheFrameItHadWhenItClosed() throws {
        let store = WindowFrameStore(defaults: temporaryDefaults())
        let screens = { [self] in [builtIn, external] }

        let first = makeWindow()
        let firstKeeper = try XCTUnwrap(WindowFrameKeeper.attach(to: first, store: store, screens: screens))
        XCTAssertEqual(first.frame, NSRect(x: 306, y: 179, width: 900, height: 592), "Nothing saved yet")
        let used = NSRect(x: 400, y: 1100, width: 1800, height: 1125)
        first.setFrame(used, display: false)
        XCTAssertEqual(store.load()?.frame, used, "Moving or resizing saves the frame")
        // A second window in the same launch opens where AppKit places it and saves nothing.
        let second = makeWindow()
        XCTAssertNil(WindowFrameKeeper.attach(to: second, store: store, screens: screens))
        second.setFrame(NSRect(x: 10, y: 10, width: 800, height: 600), display: false)
        XCTAssertEqual(store.load()?.frame, used)
        first.close()
        _ = firstKeeper
        second.close()

        // Next launch.
        let reopened = makeWindow()
        let keeper = try XCTUnwrap(WindowFrameKeeper.attach(to: reopened, store: store, screens: screens))
        XCTAssertEqual(reopened.frame, used)
        keeper.detach()

        // Next launch without the external monitor.
        let withoutExternal = makeWindow()
        let laptopKeeper = try XCTUnwrap(WindowFrameKeeper.attach(to: withoutExternal, store: store, screens: { [self] in [builtIn] }))
        XCTAssertTrue(builtIn.contains(withoutExternal.frame), "\(withoutExternal.frame)")
        laptopKeeper.detach()
    }

    func testQuittingSavesTheFrameEvenWhenNoMoveWasReported() throws {
        let store = WindowFrameStore(defaults: temporaryDefaults())
        let window = makeWindow()
        let keeper = try XCTUnwrap(WindowFrameKeeper.attach(to: window, store: store, screens: { [self] in [builtIn] }))
        XCTAssertNil(store.load())
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApplication.shared)
        XCTAssertEqual(store.load()?.frame, window.frame)
        keeper.detach()
        window.close()
    }

    func testFullScreenFramesAreNotSavedAndTheFrameBeforeItIs() throws {
        let store = WindowFrameStore(defaults: temporaryDefaults())
        let window = makeWindow()
        let keeper = try XCTUnwrap(WindowFrameKeeper.attach(to: window, store: store, screens: { [self] in [builtIn] }))
        let before = NSRect(x: 100, y: 80, width: 1200, height: 800)
        window.setFrame(before, display: false)
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1512, height: 982), display: false)
        XCTAssertEqual(store.load()?.frame, before)
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApplication.shared)
        XCTAssertEqual(store.load()?.frame, before, "Quitting in full screen keeps the frame from before it")
        window.setFrame(before, display: false)
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        window.setFrame(NSRect(x: 120, y: 90, width: 1100, height: 760), display: false)
        XCTAssertEqual(store.load()?.frame, NSRect(x: 120, y: 90, width: 1100, height: 760))
        keeper.detach()
        window.close()
    }

    /// The SwiftUI view behind the window's content applies the saved frame once SwiftUI has placed
    /// the window, and lets go of it when it leaves the window.
    func testTheViewInTheWindowContentRestoresAndReleasesTheFrame() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first?.visibleFrame)
        let saved = NSRect(x: screen.minX + 20, y: screen.minY + 10, width: 800, height: 580)
        let store = WindowFrameStore(defaults: temporaryDefaults())
        store.save(SavedWindowFrame(saved))
        let window = makeWindow()
        window.contentView = NSHostingView(rootView: Color.clear.background(MainWindowFrameAutosave(store: store)))
        XCTAssertNotEqual(window.frame, saved, "Nothing changes in the turn the view joins the window")
        try await waitUntil { window.frame == saved }
        window.contentView = nil
        // The frame is free again, as for the window of the next launch.
        let next = makeWindow()
        let keeper = try XCTUnwrap(WindowFrameKeeper.attach(to: next, store: store))
        XCTAssertEqual(next.frame, saved)
        keeper.detach()
        window.close()
        next.close()
    }

    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 306, y: 179, width: 900, height: 592),
                              styleMask: [.titled, .resizable, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentMinSize = minimum
        // The content rect equals the frame with a full-size content view and no title bar height.
        window.setFrame(NSRect(x: 306, y: 179, width: 900, height: 592), display: false)
        return window
    }

    private func temporaryDefaults() -> UserDefaults {
        let suite = testDefaultsSuite("Yardlet.window-frame-test")
        return UserDefaults(suiteName: suite)!
    }
}
