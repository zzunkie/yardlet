import AppKit
import IOSurface
import SwiftUI
import XCTest
import YardletSimulatorHostProtocol
@testable import NativeHarnessClient

/// The Simulator tab against a real, booted simulator, in a window that is never on screen: the live screen fit into
/// the panel, a click that opens Settings, a trackpad scroll that scrolls it as a finger drag, ⇧⌘H for Home, a drag
/// that opens Search and keys typed into it past the Mac's input method, and the person's input written down for the
/// agent's tools. The window's renders go to `YARDLET_SIMULATOR_QA_OUTPUT`. scripts/simulator-qa/run-check.sh runs it
/// after SimulatorHostQATests, against the same throwaway device; without `YARDLET_SIMULATOR_QA_DEVICE` it is skipped.
@MainActor
final class SimulatorPanelQATests: XCTestCase {
    private let size = NSSize(width: 460, height: 900)

    func testTheTabShowsTheDeviceLiveAndTakesThePersonsHands() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let deviceValue = environment["YARDLET_SIMULATOR_QA_DEVICE"] else {
            throw XCTSkip("scripts/simulator-qa/run-check.sh runs this check against a throwaway simulator")
        }
        let device = try XCTUnwrap(UUID(uuidString: deviceValue))
        let built = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appending(path: "YardletSimulatorHost")
        let helper = environment["YARDLET_SIMULATOR_QA_HELPER"].map { URL(fileURLWithPath: $0) } ?? built
        let output = URL(fileURLWithPath: environment["YARDLET_SIMULATOR_QA_OUTPUT"]
            ?? FileManager.default.temporaryDirectory.appending(path: "yardlet-simulator-qa").path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let values = (environment["YARDLET_SIMULATOR_QA_SETTINGS"] ?? "0.843,0.492").split(separator: ",").compactMap { Double($0) }
        let settingsIcon = CGPoint(x: values[0], y: values[1])

        SimulatorScreenView.ignoresWindowOcclusion = true
        defer { SimulatorScreenView.ignoresWindowOcclusion = false }
        // The device is on already: the center attaches it without starting it, so it never stops it.
        let center = SimulatorCenter(backends: [MacIOSSimulatorBackend()])
        await center.setEnabled(true)
        let (task, tab) = (UUID(), UUID())
        guard case let .attached(attachment) = await center.attach(device.uuidString, to: task, tab: tab, by: .person) else {
            return XCTFail("The throwaway device was not attached")
        }
        XCTAssertFalse(attachment.isStartedByYardlet)
        let screens = MacSimulatorScreens()
        screens.executable = helper
        let services = SimulatorPanelServices(center: center, screens: screens, taskTitle: { _ in nil })
        let host = WindowlessRender.Host(
            SimulatorPane(task: task, tab: tab, workspaceURL: URL(filePath: "/tmp/project"), services: services,
                          attached: attachment.device.identity, onClose: {})
                .frame(width: size.width, height: size.height),
            size: size, appearance: .light)
        defer {
            host.close()
            screens.endAll()
        }

        // The live screen, fit into the panel with its proportions, the room around it empty.
        await host.settle(until: { self.screenView(in: host.hosting)?.frameDisplay.current != nil })
        let view = try XCTUnwrap(screenView(in: host.hosting))
        guard case let .attached(screen) = screens.link(of: attachment.device.identity) else { return XCTFail("The device is not attached") }
        let rect = view.screenRect
        XCTAssertEqual(Double(rect.width / rect.height), Double(screen.pixelWidth) / Double(screen.pixelHeight), accuracy: 0.01)
        XCTAssertEqual(rect.height, size.height - 42 - 2 * SimulatorScreenView.margin, accuracy: 2, "The screen fills the height")
        let first = try XCTUnwrap(view.frameDisplay.current)
        XCTAssertEqual(first.frame.pixelHeight, Int(rect.height * (host.hosting.window?.backingScaleFactor ?? 2)), accuracy: 2,
                       "The helper sends frames of the size the panel shows")
        XCTAssertTrue(host.accessibilityElements().contains { $0.label == L10n.string("Home (⇧⌘H)") })
        try write(host, view, output.appending(path: "panel-1-live.png"))

        // A click on Settings: a finger down and up there opens it.
        screens.press(.home, on: attachment.device.identity)
        try await settleFrames(host, view)
        let beforeTap = sample(view.frameDisplay.current)
        try click(view, at: settingsIcon)
        try await waitForChange(host, view, from: beforeTap, "the click did not open Settings")
        try await settleFrames(host, view, seconds: 3)
        try write(host, view, output.appending(path: "panel-2-settings.png"))
        XCTAssertNotNil(center.lastPersonInput(on: attachment.device.identity), "The person's input was not written down")

        // A trackpad scroll drags the list with one finger.
        let beforeScroll = sample(view.frameDisplay.current)
        try scroll(view, at: CGPoint(x: 0.5, y: 0.6), by: -360)
        try await waitForChange(host, view, from: beforeScroll, "the scroll did not move Settings")
        try await settleFrames(host, view, seconds: 1.5)
        try write(host, view, output.appending(path: "panel-3-scrolled.png"))

        // ⇧⌘H is Home, with the screen focused.
        host.hosting.window?.makeFirstResponder(view)
        let beforeHome = sample(view.frameDisplay.current)
        XCTAssertTrue(view.performKeyEquivalent(with: try key(.keyDown, "h", code: 0x04, flags: [.command, .shift])))
        try await waitForChange(host, view, from: beforeHome, "⇧⌘H did not go home")
        try await settleFrames(host, view, seconds: 1.5)

        // A drag down the home screen opens Search; keys type into it as the device's own keyboard reads them.
        try drag(view, from: CGPoint(x: 0.5, y: 0.45), to: CGPoint(x: 0.5, y: 0.62))
        try await settleFrames(host, view, seconds: 1.5)
        let beforeKeys = sample(view.frameDisplay.current)
        for (character, code) in [("y", 0x10), ("a", 0x00), ("r", 0x0F), ("d", 0x02)] as [(String, UInt16)] {
            view.keyDown(with: try key(.keyDown, character, code: code))
            view.keyUp(with: try key(.keyUp, character, code: code))
        }
        try await waitForChange(host, view, from: beforeKeys, "the keys typed nothing")
        try await settleFrames(host, view, seconds: 1.5)
        try write(host, view, output.appending(path: "panel-4-typed.png"))
        XCTAssertTrue(view.performKeyEquivalent(with: try key(.keyDown, "h", code: 0x04, flags: [.command, .shift])))
        try await settleFrames(host, view, seconds: 1)

        // The panel goes: it asks for no more frames.
        view.stopFrames()
        XCTAssertNil(view.frameDisplay.current, "The panel kept a frame after it stopped showing the device")
    }

    // MARK: - Helpers

    private func screenView(in view: NSView) -> SimulatorScreenView? {
        if let screen = view as? SimulatorScreenView { return screen }
        for subview in view.subviews { if let found = screenView(in: subview) { return found } }
        return nil
    }

    /// A point of the screen, as fractions, in the view's window.
    private func windowPoint(_ fraction: CGPoint, in view: SimulatorScreenView) -> NSPoint {
        let rect = view.screenRect
        return view.convert(NSPoint(x: rect.minX + fraction.x * rect.width, y: rect.minY + fraction.y * rect.height), to: nil)
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in view: NSView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                         windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                                         clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }

    private func click(_ view: SimulatorScreenView, at fraction: CGPoint) throws {
        let point = windowPoint(fraction, in: view)
        view.mouseDown(with: try mouse(.leftMouseDown, at: point, in: view))
        view.mouseUp(with: try mouse(.leftMouseUp, at: point, in: view))
    }

    private func drag(_ view: SimulatorScreenView, from start: CGPoint, to end: CGPoint) throws {
        view.mouseDown(with: try mouse(.leftMouseDown, at: windowPoint(start, in: view), in: view))
        for step in 1...12 {
            let t = Double(step) / 12
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            view.mouseDragged(with: try mouse(.leftMouseDragged, at: windowPoint(point, in: view), in: view))
            RunLoop.main.run(until: Date().addingTimeInterval(0.016))
        }
        view.mouseUp(with: try mouse(.leftMouseUp, at: windowPoint(end, in: view), in: view))
    }

    /// A trackpad gesture's phases, in points: began, changes of 30 points a frame, ended.
    private func scroll(_ view: SimulatorScreenView, at fraction: CGPoint, by distance: Int32) throws {
        let window = try XCTUnwrap(view.window)
        let inWindow = windowPoint(fraction, in: view)
        func event(_ phase: CGScrollPhase, _ delta: Int32) throws -> NSEvent {
            let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta,
                                              wheel2: 0, wheel3: 0))
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            // An event of no window reads its location as the window's.
            let height = NSScreen.screens.first?.frame.height ?? 0
            event.location = CGPoint(x: inWindow.x, y: height - inWindow.y)
            _ = window
            return try XCTUnwrap(NSEvent(cgEvent: event))
        }
        view.scrollWheel(with: try event(.began, 0))
        let step: Int32 = distance < 0 ? -30 : 30
        for _ in 0..<Int(abs(distance) / 30) {
            view.scrollWheel(with: try event(.changed, step))
            RunLoop.main.run(until: Date().addingTimeInterval(0.016))
        }
        view.scrollWheel(with: try event(.ended, 0))
    }

    private func key(_ type: NSEvent.EventType, _ character: String, code: UInt16,
                     flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                       context: nil, characters: flags.contains(.shift) ? character.uppercased() : character,
                                       charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
    }

    /// Lets the device draw for a while, the run loop turning so frames reach the layer.
    private func settleFrames(_ host: WindowlessRender.Host<some View>, _ view: SimulatorScreenView,
                              seconds: Double = 2) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { await host.settle(until: { true }); try await Task.sleep(for: .milliseconds(50)) }
    }

    private func waitForChange(_ host: WindowlessRender.Host<some View>, _ view: SimulatorScreenView,
                               from before: [UInt32], _ message: String) async throws {
        try await waitUntil(message: message) {
            host.settle(passes: 1, interval: 0.01)
            return sample(view.frameDisplay.current) != before
        }
    }

    /// The window drawn as its layers are, the device's screen with them.
    private func write(_ host: WindowlessRender.Host<some View>, _ view: SimulatorScreenView, _ url: URL) throws {
        try WindowlessRender.writePNG(host.capture().bitmap, to: url)
    }
}

/// A few hundred pixels across the frame's surface, to tell one frame from another.
private func sample(_ current: (frame: SimulatorFrame, surface: IOSurfaceRef)?) -> [UInt32] {
    guard let surface = current?.surface else { return [] }
    IOSurfaceLock(surface, .readOnly, nil)
    defer { IOSurfaceUnlock(surface, .readOnly, nil) }
    let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
    let row = IOSurfaceGetBytesPerRow(surface)
    let base = IOSurfaceGetBaseAddress(surface)
    var values: [UInt32] = []
    for y in stride(from: height / 20, to: height, by: max(height / 20, 1)) {
        for x in stride(from: width / 20, to: width, by: max(width / 20, 1)) {
            values.append(base.load(fromByteOffset: y * row + x * 4, as: UInt32.self))
        }
    }
    return values
}
