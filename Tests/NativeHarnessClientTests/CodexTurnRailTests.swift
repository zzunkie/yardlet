import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The rail beside a conversation (`CodexTurnRail`): a mark for each turn, which a click on it goes to.
@MainActor
final class CodexTurnRailTests: XCTestCase {
    private let marks = (1...4).map { CodexTurnRail.Turn(id: "turn-\($0)", status: L10n.string("Completed")) }

    /// A click goes to the turn whose place on the rail it lands on: anywhere across the rail and most of the way to
    /// the marks above and below, not only on the short line the mark draws (2026-11-21: a person found the marks hard
    /// to click).
    func testAClickAnywhereOnATurnsPlaceGoesToThatTurn() throws {
        var focused: [String] = []
        let host = makeHost(focusedTurnID: marks.last?.id) { focused.append($0) }
        defer { host.close() }
        for (index, mark) in marks.enumerated() {
            let center = try center(ofMark: index, in: host)
            // By the rail's edges, and above and below the line.
            for offset in [CGVector(dx: -10.5, dy: 0), CGVector(dx: 10.5, dy: 0),
                           CGVector(dx: 0, dy: 4.5), CGVector(dx: 0, dy: -4.5)] {
                try click(NSPoint(x: center.x + offset.dx, y: center.y + offset.dy), in: host)
            }
            XCTAssertEqual(focused, Array(repeating: mark.id, count: 4), "Turn \(index + 1)")
            focused.removeAll()
        }
    }

    /// A click on a mark gives the rail the keyboard, whose arrow keys go on from the turn, and no focus ring is
    /// drawn around the rail: the turn it marks shows where it is (docs/DESIGN_SYSTEM.md, Focus).
    func testAClickedRailTakesTheArrowKeysWithoutAFocusRing() throws {
        var focused: [String] = []
        let host = makeHost(focusedTurnID: marks[1].id) { focused.append($0) }
        defer { host.close() }
        try click(try center(ofMark: 1, in: host), in: host)
        try press(String(UnicodeScalar(NSDownArrowFunctionKey)!), keyCode: 125, in: host)
        XCTAssertEqual(focused, [marks[1].id, marks[2].id])
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        XCTAssertEqual(views(host.hosting).filter { String(describing: type(of: $0)).contains("FocusRing") }.count, 0,
                       "The rail draws a focus ring")
    }

    /// The rail in a window the window server has, so clicks and keys reach it: transparent, far off every screen,
    /// and the test app is never activated, so nothing comes to the front or takes the keyboard.
    private func makeHost(focusedTurnID: String?, onFocus: @escaping (String) -> Void)
        -> WindowlessRender.Host<some View> {
        let rail = CodexTurnRail(marks: marks, focusedTurnID: focusedTurnID, onFocus: onFocus,
                                 hasMoreTurns: false, onLoadMore: {})
            .frame(height: 160)
            .background(ParityTheme.canvas)
        let host = WindowlessRender.Host(rail, size: NSSize(width: 24, height: 160), appearance: .light)
        host.window.alphaValue = 0
        host.window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        host.window.orderFrontRegardless()
        XCTAssertFalse(NSApplication.shared.isActive)
        host.settle(passes: 10)
        return host
    }

    /// The middle of the mark of turn `index + 1`, from the window's lower left, where a click is placed.
    private func center(ofMark index: Int, in host: WindowlessRender.Host<some View>) throws -> NSPoint {
        let label = L10n.format("Turn %lld of %lld", Int64(index + 1), Int64(marks.count))
        host.hosting.layoutSubtreeIfNeeded()
        let frame = try XCTUnwrap(WindowlessRender.withAccessibilityTree { () -> NSRect? in
            func visit(_ node: AnyObject) -> NSRect? {
                for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                    if (child.accessibilityLabel?() ?? nil) == label, let frame = child.accessibilityFrame?() {
                        return frame
                    }
                    if let found = visit(child) { return found }
                }
                return nil
            }
            return visit(host.hosting)
        }, label)
        return NSPoint(x: frame.midX - host.window.frame.minX, y: frame.midY - host.window.frame.minY)
    }

    /// A click at `point`, from the window's lower left, sent to the window as the window server would.
    private func click(_ point: NSPoint, in host: WindowlessRender.Host<some View>) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: host.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1))
            host.window.sendEvent(event)
            host.settle(passes: 3, interval: 0.02)
        }
    }

    /// A key pressed in the window, sent as the window server sends it.
    private func press(_ characters: String, keyCode: UInt16, in host: WindowlessRender.Host<some View>) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: host.window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        host.window.sendEvent(event)
        host.settle(passes: 4)
    }
}
