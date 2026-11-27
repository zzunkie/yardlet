@preconcurrency import IOSurface
import QuartzCore
import XCTest
@testable import NativeHarnessClient

/// Page frames reach the panel's layer from the event pipe's queue, and the main thread gets at
/// most one already-shown frame per tab per turn.
final class BrowserFrameDisplayTests: XCTestCase {
    private func surface(width: Int = 8, height: Int = 6) -> IOSurfaceRef {
        IOSurfaceCreate([
            kIOSurfaceWidth: width, kIOSurfaceHeight: height, kIOSurfaceBytesPerElement: 4,
            kIOSurfacePixelFormat: 0x4247_5241
        ] as CFDictionary)!
    }

    private func frame(_ sequence: UInt64, layer: BrowserFrameLayer = .view, width: Int = 8, height: Int = 6) -> BrowserFrame {
        BrowserFrame(layer: layer, surface: sequence, pixelWidth: width, pixelHeight: height, sequence: sequence,
                     paintedAt: DispatchTime.now().uptimeNanoseconds, source: "accelerated")
    }

    func testAFrameShownOffTheMainThreadSetsTheLayerAndSkipsOlderFrames() {
        let layer = CALayer()
        let display = BrowserFrameDisplay(layer: layer)
        display.setScale(2)
        let shownOnMain = LockedFlags()
        display.setObserver { _, _ in shownOnMain.append(Thread.isMainThread) }
        let newer = surface(width: 40, height: 20)
        let older = surface()
        let (fifth, fourth) = (frame(5, width: 40, height: 20), frame(4))
        let done = expectation(description: "shown")
        DispatchQueue.global().async {
            display.show(fifth, surface: newer)
            display.show(fourth, surface: older)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)

        XCTAssertTrue(display.currentSurface === newer)
        XCTAssertTrue((layer.contents as AnyObject?) === newer)
        XCTAssertEqual(layer.frame, CGRect(x: 0, y: 0, width: 20, height: 10))
        XCTAssertEqual(shownOnMain.values, [false], "the older frame is skipped; the observer runs where the frame was shown")
        XCTAssertTrue(display.hasShown(frame(5)))
        XCTAssertFalse(display.hasShown(frame(6)))

        display.clear()
        XCTAssertNil(display.currentSurface)
        XCTAssertNil(layer.contents)
        display.show(frame(1), surface: older)
        XCTAssertTrue(display.currentSurface === older, "a new tab's frames start over after a clear")
    }

    func testPreparingForTheNextTabKeepsTheLastSurfaceAndRestartsTheSequence() {
        let layer = CALayer()
        let display = BrowserFrameDisplay(layer: layer)
        display.setScale(2)
        let onScreen = surface(width: 40, height: 20)
        let cached = surface()
        display.show(frame(100, width: 40, height: 20), surface: onScreen)
        XCTAssertTrue(display.currentSurface === onScreen)

        display.prepareForNextTab()
        XCTAssertTrue(display.currentSurface === onScreen, "the last frame stays while the next tab paints")
        XCTAssertTrue((layer.contents as AnyObject?) === onScreen)

        // A cached frame of the next tab with a lower sequence than the one last shown is not skipped,
        // so `showFrames(of:in:)` can place the latest cached frame of a tab the engine still draws.
        display.show(frame(2), surface: cached)
        XCTAssertTrue(display.currentSurface === cached)
    }

    func testRouterKeepsTheLastPanelThatAdoptedTheTab() {
        let router = BrowserFrameRouter()
        let first = BrowserFrameDisplay(layer: CALayer())
        let second = BrowserFrameDisplay(layer: CALayer())
        router.set(first, for: 1)
        router.set(second, for: 1)
        router.remove(first, for: 1)
        XCTAssertTrue(router.display(for: 1) === second, "an earlier panel leaving does not take the frames away")
        router.remove(second, for: 1)
        XCTAssertNil(router.display(for: 1))
    }

    @MainActor
    func testFramesWaitingForTheMainThreadMergePerTabAndKeepOtherEventsInOrder() async {
        let delivered = expectation(description: "delivered")
        var batches: [[BrowserHostEvent]] = []
        let events = BrowserMainThreadEvents { batch in
            batches.append(batch)
            delivered.fulfill()
        }
        // All enqueued before the main thread runs the first delivery.
        events.enqueue([.frame(tab: 1, frame: frame(1)), .address(tab: 1, url: "https://a.example/")])
        events.enqueue([.frame(tab: 2, frame: frame(2)), .frame(tab: 1, frame: frame(3))])
        events.enqueue([.frame(tab: 1, frame: frame(4, layer: .popup)), .frame(tab: 1, frame: frame(5))])
        await fulfillment(of: [delivered], timeout: 2)

        XCTAssertEqual(batches.count, 1, "one main-thread turn for everything that waited")
        XCTAssertEqual(batches[0].map(Self.describe), [
            "address 1", "frame 2 view 2", "frame 1 popup 4", "frame 1 view 5"
        ])
    }

    private static func describe(_ event: BrowserHostEvent) -> String {
        switch event {
        case .frame(let tab, let frame): "frame \(tab) \(frame.layer) \(frame.sequence)"
        case .address(let tab, _): "address \(tab)"
        default: "other"
        }
    }
}

private final class LockedFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var flags: [Bool] = []
    func append(_ flag: Bool) { lock.withLock { flags.append(flag) } }
    var values: [Bool] { lock.withLock { flags } }
}
