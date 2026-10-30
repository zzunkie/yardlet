import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The main thread while the Files panel opens and scrolls large files: a 20 MB source file shown
/// whole, a 2 MB one with colors, and a 25 MB one shown from its beginning. The files are written
/// into `YARDLET_FILE_PREVIEW_QA_DIR` (a temporary folder without it) and removed afterwards; the
/// numbers go to `.build/file-preview-qa/main-thread.json`.
///
/// Main-thread time is measured two ways: a run loop observer times each stretch of work between
/// the run loop waking and sleeping (the panel's updates after the read), and the test times the
/// layout and drawing it asks for after each scroll.
@MainActor
final class WorkspaceFilePreviewPerformanceTests: XCTestCase {
    private final class MainThreadWork {
        private(set) var stretches: [Double] = []
        private var started: UInt64?
        private var observer: CFRunLoopObserver?

        func start() {
            let activities: CFRunLoopActivity = [.entry, .afterWaiting, .beforeWaiting, .exit]
            observer = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, 0) { [weak self] _, activity in
                guard let self else { return }
                let now = DispatchTime.now().uptimeNanoseconds
                if activity == .entry || activity == .afterWaiting {
                    started = now
                } else if let started {
                    stretches.append(Double(now - started) / 1e6)
                    self.started = nil
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }

        func stop() {
            if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            observer = nil
        }

        func record(_ milliseconds: Double) { stretches.append(milliseconds) }
        var longest: Double { stretches.max() ?? 0 }
        var total: Double { stretches.reduce(0, +) }
    }

    private struct Measurement: Codable {
        var file: String
        var bytes: Int
        var shownUTF16: Int
        var readMilliseconds: Double
        var openLongestMainMilliseconds: Double
        var openTotalMainMilliseconds: Double
        var scrollSteps: Int
        var scrollMeanMilliseconds: Double
        var scrollLongestMilliseconds: Double
        var jumpMilliseconds: [String: Double]
    }

    private func folder() throws -> URL {
        let base = ProcessInfo.processInfo.environment["YARDLET_FILE_PREVIEW_QA_DIR"].map { URL(filePath: $0) }
            ?? FileManager.default.temporaryDirectory
        let url = base.appending(path: "file-preview-performance-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Source-like lines of mixed length with Korean text and an occasional long line, about `bytes`.
    private func source(bytes: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let words = ["let", "var", "func", "return", "if", "guard", "value", "count", "index", "렌더", "파일", "// note",
                     "\"string\"", "42", "3.14", "self", "(", ")", "{", "}"]
        var lines: [String] = []
        var size = 0, number = 0
        while size < bytes {
            number += 1
            var line = String(repeating: "    ", count: Int.random(in: 0...3, using: &generator))
            line += (0..<Int.random(in: 0...14, using: &generator)).map { _ in words.randomElement(using: &generator)! }.joined(separator: " ")
            if number % 997 == 0 { line += " " + String(repeating: "x", count: Int.random(in: 200...900, using: &generator)) }
            lines.append(line)
            size += line.utf8.count + 1
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func measure(_ name: String, text: String, in root: URL) throws -> Measurement {
        try Data(text.utf8).write(to: root.appending(path: name))
        let state = WorkspaceFilesState()
        let host = WindowlessRender.Host(FilesPane(workspaceURL: root, state: state, onClose: {}),
                                         size: NSSize(width: 760, height: 620))
        defer { host.close() }
        host.settle(passes: 3)
        let work = MainThreadWork()
        work.start()
        let started = DispatchTime.now().uptimeNanoseconds
        state.open(.init(relativePath: name), in: root)
        let deadline = Date().addingTimeInterval(testWaitLimitSeconds)
        while state.isLoading, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
        XCTAssertFalse(state.isLoading, "\(name) was still loading after \(testWaitLimitSeconds) seconds")
        let read = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        work.record(time { host.hosting.layoutSubtreeIfNeeded(); host.window.displayIfNeeded() })
        work.stop()
        let open = (work.longest, work.total)
        let document = try XCTUnwrap(state.document, state.fileError ?? "not opened")

        let text = try XCTUnwrap(textView(in: host.hosting))
        let scroll = try XCTUnwrap(text.enclosingScrollView)
        func step(to y: CGFloat) -> Double {
            time {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                host.hosting.layoutSubtreeIfNeeded()
                host.window.displayIfNeeded()
            }
        }
        // A wheel's worth at a time, with the run loop turning between steps for the reading
        // position and the panel's update.
        let scrolling = MainThreadWork()
        scrolling.start()
        var steps: [Double] = []
        for index in 1...200 {
            steps.append(step(to: CGFloat(index) * 40))
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        }
        scrolling.stop()
        var jumps: [String: Double] = [:]
        jumps["middle"] = step(to: text.frame.height / 2)
        jumps["end"] = step(to: text.frame.height)
        jumps["start"] = step(to: 0)
        // A link to a line three quarters down, through the panel.
        let line = document.lineStarts.count * 3 / 4
        let link = MainThreadWork()
        link.start()
        state.open(.init(relativePath: name, line: line), in: root)
        for _ in 0..<3 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        link.record(time { host.hosting.layoutSubtreeIfNeeded(); host.window.displayIfNeeded() })
        link.stop()
        jumps["link to line \(line), longest"] = link.longest
        if let top = text.line(atY: scroll.contentView.bounds.minY), !document.isPartial {
            XCTAssertLessThanOrEqual(abs(document.line(atUTF16Offset: top.offset) - line), 40, "The link's line is in view")
        }
        let longestStep = max(steps.max() ?? 0, scrolling.longest)
        let bytes = try FileManager.default.attributesOfItem(atPath: root.appending(path: name).path)[.size] as? Int ?? 0
        return Measurement(file: name, bytes: bytes,
                           shownUTF16: document.utf16Length, readMilliseconds: read,
                           openLongestMainMilliseconds: open.0, openTotalMainMilliseconds: open.1,
                           scrollSteps: steps.count, scrollMeanMilliseconds: steps.reduce(0, +) / Double(steps.count),
                           scrollLongestMilliseconds: longestStep, jumpMilliseconds: jumps)
    }

    private func time(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    }

    private func textView(in view: NSView) -> WorkspaceFileTextView? {
        if let text = view as? WorkspaceFileTextView { return text }
        return view.subviews.lazy.compactMap(textView(in:)).first
    }

    func testLargeFilesOpenAndScrollWithoutHoldingTheMainThread() throws {
        let root = try folder()
        let large = source(bytes: WorkspaceFileService.wholeTextBytes - 64 * 1024)
        let head = large.utf8.prefix(WorkspaceFileService.highlightedBytes - 64 * 1024)
        let colored = String(large[..<head.lastIndex(of: 10)!])
        let results = [
            try measure("whole-20MB.swift", text: large, in: root),
            try measure("colored-2MB.swift", text: colored + "\n", in: root),
            try measure("beginning-25MB.swift", text: large + large.prefix(5 << 20), in: root)
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let report = try encoder.encode(results)
        try report.write(to: try WindowlessRender.directory("file-preview-qa").appending(path: "main-thread.json"))
        print(String(decoding: report, as: UTF8.self))
        for result in results {
            // Laying out the whole 20 MB file took 14 s; a frame is 16 ms.
            XCTAssertLessThan(result.openLongestMainMilliseconds, 250, result.file)
            XCTAssertLessThan(result.scrollMeanMilliseconds, 16, result.file)
            XCTAssertLessThan(result.scrollLongestMilliseconds, 100, result.file)
            // A read-only file moves its window: the first jump to the end took 3 s without it. An
            // editable file is TextKit 2's whole and pays for its lines on the way to the end.
            for (jump, milliseconds) in result.jumpMilliseconds {
                XCTAssertLessThan(milliseconds, result.file.hasPrefix("colored") ? 1_000 : 100, "\(result.file) \(jump)")
            }
        }
    }
}
