import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Draws a conversation in an unshown window and lists its accessibility elements (role, label and
/// value, in reading order), for the rendering tests to read and to compare between harnesses.
///
/// A running turn counts its seconds from when it was first drawn, so two renders can fall in
/// different seconds; the elements are listed with those seconds evened out.
@MainActor
enum ConversationDrawing {
    struct Drawing {
        let capture: WindowlessRender.Capture
        /// The accessibility elements with a running turn's seconds evened out.
        let elements: [WindowlessRender.AccessibilityElement]
    }

    /// `content` in an unshown window of `size`, settled for `passes` turns of the run loop.
    ///
    /// - Parameter visibleOnly: list only the elements inside the window. A lazy stack lays out turns
    ///   beyond its viewport by how it groups them, so a conversation taller than the window is read
    ///   by what it shows.
    static func draw<Content: View>(
        _ content: Content, size: NSSize, appearance: WindowlessRender.Appearance, passes: Int = 10,
        visibleOnly: Bool = false
    ) throws -> Drawing {
        let host = WindowlessRender.Host(
            content
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(ParityTheme.canvas),
            size: size, appearance: appearance
        )
        defer { host.close() }
        host.settle(passes: passes)
        let elements = host.accessibilityElements(visibleOnly: visibleOnly)
        return Drawing(capture: try host.capture(), elements: elements.map(steady))
    }

    /// A turn on the rail: "Turn 2 of 5".
    static func isRailTurn(_ text: String) -> Bool {
        // Some languages name the count before the turn, so each number becomes a digit run.
        let sample = NSRegularExpression.escapedPattern(for: L10n.format("Turn %lld of %lld", Int64(7), Int64(8)))
        let pattern = "^" + sample.replacingOccurrences(of: "7", with: #"\d+"#)
            .replacingOccurrences(of: "8", with: #"\d+"#) + "$"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    /// A turn header's work time: "Worked for", "You stopped after" or "Working for" some time.
    static func isWorkTime(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return workTimePatterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    private static let workTimePatterns: [String] = [
        L10n.format("Worked for %lld seconds", Int64(0)), L10n.format("Worked for %lld minutes", Int64(0)),
        L10n.format("Worked for %lld hours", Int64(0)), L10n.format("You stopped after %lld seconds", Int64(0)),
        L10n.format("You stopped after %lld minutes", Int64(0)), L10n.format("You stopped after %lld hours", Int64(0)),
        L10n.format("Working for %lld seconds", Int64(0))
    ].compactMap { sample in
        guard let range = sample.range(of: "0") else { return nil }
        return "^" + NSRegularExpression.escapedPattern(for: String(sample[..<range.lowerBound])) + #"\d+"#
            + NSRegularExpression.escapedPattern(for: String(sample[range.upperBound...])) + "$"
    }

    /// Ends on a live line's elapsed time: "12s", "1m 5s" or "2h 3m".
    static func endsWithElapsedTime(_ text: String) -> Bool {
        elapsedTimePatterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    private static let elapsedTimePatterns: [String] = [
        L10n.format("%llds", Int64(0)), L10n.format("%lldm %llds", Int64(0), Int64(0)),
        L10n.format("%lldh %lldm", Int64(0), Int64(0))
    ].map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: "0", with: #"\d+"#) + "$" }

    /// A running turn counts its seconds from when it was first drawn; two renders can fall in
    /// different seconds.
    static func steady(_ element: WindowlessRender.AccessibilityElement) -> WindowlessRender.AccessibilityElement {
        let working = L10n.format("Working for %lld seconds", Int64(0))
        guard let range = working.range(of: "0") else { return element }
        let pattern = NSRegularExpression.escapedPattern(for: String(working[..<range.lowerBound])) + #"\d+"#
            + NSRegularExpression.escapedPattern(for: String(working[range.upperBound...]))
        func normalized(_ text: String) -> String {
            text.replacingOccurrences(of: pattern, with: working, options: .regularExpression)
        }
        return .init(role: element.role, label: normalized(element.label), value: normalized(element.value))
    }

    /// Bytes that differ between two bitmaps of the same size; every byte when the sizes differ.
    static func differingBytes(_ old: NSBitmapImageRep, _ new: NSBitmapImageRep) -> Int {
        guard old.pixelsWide == new.pixelsWide, old.pixelsHigh == new.pixelsHigh,
              old.bytesPerRow == new.bytesPerRow, old.bitsPerPixel == new.bitsPerPixel,
              let a = old.bitmapData, let b = new.bitmapData else { return Int.max }
        let count = old.bytesPerRow * old.pixelsHigh
        var differing = 0
        for index in 0..<count where a[index] != b[index] { differing += 1 }
        return differing
    }
}
