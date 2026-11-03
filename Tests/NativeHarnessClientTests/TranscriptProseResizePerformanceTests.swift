import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Windowless resize measurements. No provider events are published by this fixture.
@MainActor
final class TranscriptProseResizePerformanceTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NHC_PERF_BENCH"] == "1", "Set NHC_PERF_BENCH=1 to measure resizing")
    }

    private func text(_ source: String) -> TranscriptProseContainerView {
        let view = TranscriptProseContainerView()
        let blocks = TranscriptMarkdownDocument(source).blocks.enumerated().map {
            TranscriptProseBlock(block: $1, path: [$0])
        }
        view.update(blocks: blocks, style: TranscriptProseStyle())
        return view
    }
    /// Exercise real message layout separately from provider publications and row construction.
    func testLongMessageWidthChangesReportLayoutCost() throws {
        let source = (0..<1_000).map { index in
            "Paragraph \(index). " + String(repeating: "Words that wrap across the line as an answer does. ", count: 8)
        }.joined(separator: "\n\n")
        var finalHeights: [CGFloat] = []
        for live in [false, true] {
            let text = text(source)
            let initial = text.size(forWidth: 760)
            text.frame = NSRect(origin: .zero, size: initial)
            _ = NSApplication.shared
            let viewport = NSRect(x: 0, y: 0, width: 760, height: 700)
            let window = NSWindow(contentRect: viewport,
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let scroll = NSScrollView(frame: viewport)
            scroll.documentView = text
            window.contentView = scroll
            scroll.layoutSubtreeIfNeeded()
            let before = text.newWidthLayouts
            text.defersResizeForMeasurement = live
            text.viewWillStartLiveResize()
            var samples: [Double] = []
            for width in [720.0, 680, 640, 600, 560, 520, 560, 600, 640, 680, 600] {
                let start = CFAbsoluteTimeGetCurrent()
                let size = text.size(forWidth: width)
                text.frame = NSRect(origin: .zero, size: size)
                text.layoutSubtreeIfNeeded()
                samples.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
                XCTAssertEqual(text.laidOutHeight, ceil(size.height))
            }
            if live { XCTAssertEqual(text.newWidthLayouts, before) }
            let end = CFAbsoluteTimeGetCurrent()
            text.viewDidEndLiveResize()
            let final = text.size(forWidth: 600)
            text.frame = NSRect(origin: .zero, size: final)
            text.layoutSubtreeIfNeeded()
            let commit = (CFAbsoluteTimeGetCurrent() - end) * 1_000
            XCTAssertEqual(text.laidOutHeight, ceil(final.height))
            finalHeights.append(final.height)
            if live { XCTAssertEqual(text.newWidthLayouts - before, 1) }
            PerfBenchRecord.write("prose-width-\(live ? "deferred" : "immediate")", [
                "resizeMainMs": samples.reduce(0, +), "resizeWorstMs": samples.max() ?? 0,
                "finalMainMs": commit, "widthLayoutCount": Double(text.newWidthLayouts - before)
            ])
            print("[prose-width] live=\(live) paragraphs=1000 widths=11 layoutChanges=\(text.newWidthLayouts - before) mainMilliseconds=\(samples) commitMilliseconds=\(commit)")
        }
        XCTAssertEqual(finalHeights[0], finalHeights[1])
    }

    func testLongConversationWidthChangesReportLayoutCost() async throws {
        let entries = LongConversationFixture.claude(turns: 1_000, seed: "width-bench")
        let repetitions = max(1, Int(ProcessInfo.processInfo.environment["NHC_PERF_BENCH_REPEATS"] ?? "") ?? 1)
        let reverse = ProcessInfo.processInfo.environment["NHC_PERF_BENCH_ORDER"] == "reverse"
        let order = reverse ? "reverse" : "forward"
        let mode = ProcessInfo.processInfo.environment["NHC_PERF_BENCH_MODE"]
        let modes = mode == "baseline" ? [false] : mode == "candidate" ? [true] : reverse ? [true, false] : [false, true]
        for appearance in WindowlessRender.Appearance.allCases {
            for middle in [false, true] {
                for repetition in 0..<repetitions {
                    for live in modes {
                        let cleanup = try await measureConversation(entries: entries, appearance: appearance,
                            middle: middle, live: live, repetition: repetition, order: order)
                        await Task.yield()
                        try await waitUntil { cleanup.hostReleased() }
                        guard cleanup.hostReleased() else { return }
                        let cachedObjects = cleanup.remainingProseObjects()
                        cleanup.clearRows()
                        await Task.yield()
                        try await waitUntil { cleanup.remainingProseObjects() == 0 }
                        guard cleanup.remainingProseObjects() == 0 else { return }
                        print("[resize-cleanup] \(appearance.rawValue) middle=\(middle) live=\(live) round=\(repetition + 1): root released; \(cachedObjects) cached prose objects cleared and released")
                    }
                }
            }
        }
    }

    private struct CaseCleanup {
        let hostReleased: () -> Bool
        let remainingProseObjects: () -> Int
        let clearRows: () -> Void
    }

    private func measureConversation(entries: [TranscriptEntry], appearance: WindowlessRender.Appearance,
                                     middle: Bool, live: Bool, repetition: Int, order: String) async throws -> CaseCleanup {
        let position = TranscriptReadingPosition()
        if middle {
            position.bookmark = .init(anchorID: LongConversationFixture.claudeTurnID(seed: "width-bench", turn: 500),
                                      fraction: 0.4, followsLatest: false)
        }
        let renderState = ConversationRenderState()
        let view = ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode,
                                                           status: .ready, latestTurnIsComplete: true),
                                        readingPosition: position, actions: ConversationActions(), renderState: renderState)
            .environment(\.colorScheme, appearance == .light ? .light : .dark)
        let host = autoreleasepool {
            WindowlessRender.Host(view, size: NSSize(width: 760, height: 700), appearance: appearance)
        }
        defer { host.close(); ViewBodyCensus.isEnabled = false; ViewBodyCensus.reset() }
        await Task.yield()
        await host.settle(until: {
            guard let scroll = BlankFrameProbe.conversationScrollView(in: host.hosting),
                  (scroll.documentView?.bounds.height ?? 0) > 700 else { return false }
            if middle {
                return TranscriptProseRenderingTests.containers(in: host.hosting).contains {
                    $0.textView.string.contains("Done in turn 500")
                        && $0.convert($0.bounds, to: scroll.contentView).intersects(scroll.contentView.bounds)
                }
            }
            return abs((scroll.documentView?.bounds.maxY ?? 0) - scroll.contentView.bounds.maxY) <= 2
        })
        let scroll = try XCTUnwrap(BlankFrameProbe.conversationScrollView(in: host.hosting))
        let initialBookmark = position.bookmark
        let initialDistance = (scroll.documentView?.bounds.maxY ?? 0) - scroll.contentView.bounds.maxY
        ViewBodyCensus.isEnabled = true
        ViewBodyCensus.reset()
        let texts = TranscriptProseRenderingTests.containers(in: host.hosting)
        let inViewport = texts.filter { $0.convert($0.bounds, to: scroll.contentView).intersects(scroll.contentView.bounds) }.count
        print("[resize-visibility] appearance=\(appearance.rawValue) middle=\(middle) live=\(live) texts=\(texts.count) inScroll=\(texts.filter { $0.enclosingScrollView === scroll }.count) inViewport=\(inViewport)")
        for text in texts {
            text.defersResizeForMeasurement = live
            text.viewWillStartLiveResize()
        }
        var samples: [Double] = []
        var cpuSamples: [Double] = []
        var widthChanges: [Int] = []
        var lastWidthCount = texts.reduce(0) { $0 + $1.newWidthLayouts }
        let initialWidthCount = lastWidthCount
        func phase(_ stage: String) {
            guard let path = ProcessInfo.processInfo.environment["NHC_PERF_BENCH_PHASE_FILE"] else { return }
            let record: [String: Any] = ["pid": getpid(), "appearance": appearance.rawValue,
                "middle": middle, "live": live, "round": repetition + 1, "stage": stage]
            if let data = try? JSONSerialization.data(withJSONObject: record) {
                try? data.write(to: URL(filePath: path), options: .atomic)
            }
        }
        var load = [Double](repeating: 0, count: 3)
        _ = getloadavg(&load, 3)
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        let roundSuffix = "-\(order)-round-\(repetition + 1)"
        print("[resize-load] appearance=\(appearance.rawValue) middle=\(middle) live=\(live) round=\(repetition + 1) thermal=\(thermal) load=\(load)")
        phase("drag")
        for width in [720.0, 680, 640, 600, 560, 520, 560, 600, 640, 680, 720] {
            let start = CFAbsoluteTimeGetCurrent()
            let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            host.window.setContentSize(NSSize(width: width, height: 700))
            host.hosting.layoutSubtreeIfNeeded()
            cpuSamples.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu) / 1_000_000)
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
            let widthCount = texts.reduce(0) { $0 + $1.newWidthLayouts }
            widthChanges.append(widthCount - lastWidthCount)
            lastWidthCount = widthCount
        }
        phase("finish")
        if !live { XCTAssertFalse(texts.contains(where: \.isDeferringResize), "The control never enters deferred sizing") }
        let deferredTexts = texts.filter(\.isDeferringResize)
        let changedWidthTexts = deferredTexts.filter(\.deferredResizeChangesWidth).count
        let deferredRows = Set(deferredTexts.compactMap { text -> ObjectIdentifier? in
            var ancestor = text.superview
            while let view = ancestor {
                if view is ConversationPressSurface { return ObjectIdentifier(view) }
                ancestor = view.superview
            }
            return nil
        }).count
        let rowLayoutsBeforeFinish = ViewBodyCensus[.conversationRowLaidOut]
        let finishing = CFAbsoluteTimeGetCurrent()
        let finishingCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let releaseProbe = ResizeReleaseProbe()
        var callbackMilliseconds: [Double] = []
        for text in texts {
            let start = CFAbsoluteTimeGetCurrent()
            text.viewDidEndLiveResize()
            callbackMilliseconds.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
        }
        let callbacksWallMilliseconds = (CFAbsoluteTimeGetCurrent() - finishing) * 1_000
        var layoutMilliseconds: [Double] = []
        var layoutCPUMilliseconds: [Double] = []
        var loopMilliseconds: [Double] = []
        var loopCPUMilliseconds: [Double] = []
        func pumpRunLoop() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        // The same eight layout/run-loop passes as Host.settle(), timed separately.
        for _ in 0..<8 {
            let start = CFAbsoluteTimeGetCurrent()
            let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            host.hosting.layoutSubtreeIfNeeded()
            layoutCPUMilliseconds.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu) / 1_000_000)
            layoutMilliseconds.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
            let loopStart = CFAbsoluteTimeGetCurrent()
            let loopCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            pumpRunLoop()
            loopCPUMilliseconds.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - loopCPU) / 1_000_000)
            loopMilliseconds.append((CFAbsoluteTimeGetCurrent() - loopStart) * 1_000)
        }
        // Give geometry tasks that yield on the main actor a chance to finish before accepting
        // the reading position or closing this case. Their work remains inside the release probe.
        await Task.yield()
        await Task.yield()
        await host.settle(until: {
            let placed: Bool
            if middle {
                placed = position.bookmark.anchorID == initialBookmark.anchorID
                    && abs(position.bookmark.fraction - initialBookmark.fraction) <= 0.02
            } else {
                placed = abs((scroll.documentView?.bounds.maxY ?? 0) - scroll.contentView.bounds.maxY - initialDistance) <= 2
            }
            return placed && !host.hosting.needsLayout && texts.allSatisfy {
                abs($0.laidOutHeight - ceil($0.bounds.height)) <= 1
            }
        })
        releaseProbe.stop()
        let finishCPU = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - finishingCPU) / 1_000_000
        let finishWallMilliseconds = (CFAbsoluteTimeGetCurrent() - finishing) * 1_000
        print("[resize-release] appearance=\(appearance.rawValue) middle=\(middle) live=\(live) deferredTexts=\(deferredTexts.count) deferredRows=\(deferredRows) changedWidthTexts=\(changedWidthTexts) finishRowLayouts=\(ViewBodyCensus[.conversationRowLaidOut] - rowLayoutsBeforeFinish) callbacksMs=\(callbacksWallMilliseconds) maxCallbackMs=\(callbackMilliseconds.max() ?? 0) layoutMs=\(layoutMilliseconds) layoutCPUMs=\(layoutCPUMilliseconds) loopMs=\(loopMilliseconds) loopCPUMs=\(loopCPUMilliseconds) activeSegmentsMs=\(releaseProbe.durations)")
        let distance = (scroll.documentView?.bounds.maxY ?? 0) - scroll.contentView.bounds.maxY
        if middle {
            XCTAssertEqual(position.bookmark.anchorID, initialBookmark.anchorID)
            XCTAssertEqual(position.bookmark.fraction, initialBookmark.fraction, accuracy: 0.02)
        } else {
            XCTAssertEqual(distance, initialDistance, accuracy: 2, "Resizing keeps the conversation at its reading end")
        }
        for text in TranscriptProseRenderingTests.containers(in: host.hosting) {
            XCTAssertEqual(text.laidOutHeight, ceil(text.bounds.height), accuracy: 1, "The final height is exact")
        }
        try WindowlessRender.writePNG(host.capture().bitmap,
            to: WindowlessRender.directory("prose-width").appending(path: "\(appearance.rawValue)-middle-\(middle)-live-\(live)\(roundSuffix).png"))
        PerfBenchRecord.write("conversation-width-\(appearance.rawValue)-\(middle ? "middle" : "end")-\(live ? "deferred" : "immediate")\(roundSuffix)", [
            "resizeMainMs": samples.reduce(0, +), "resizeWorstMs": samples.max() ?? 0,
            "resizeCPUMs": cpuSamples.reduce(0, +), "resizeWorstCPUMs": cpuSamples.max() ?? 0,
            "widthLayoutCount": Double(lastWidthCount - initialWidthCount),
            "releaseWidthLayoutCount": Double(texts.reduce(0) { $0 + $1.newWidthLayouts } - lastWidthCount),
            "finishWallMs": finishWallMilliseconds, "releaseCPUMs": finishCPU,
            "releaseCallbacksMs": callbacksWallMilliseconds,
            "releaseMaxCallbackMs": callbackMilliseconds.max() ?? 0,
            "releaseMaxLayoutMs": layoutMilliseconds.max() ?? 0,
            "releaseMaxActiveMs": releaseProbe.durations.max() ?? 0,
            "releaseBusyMs": releaseProbe.durations.reduce(0, +),
            "deferredTextCount": Double(deferredTexts.count),
            "deferredRowCount": Double(deferredRows),
            "deferredChangedWidthCount": Double(changedWidthTexts),
            "releaseRowLayoutCount": Double(ViewBodyCensus[.conversationRowLaidOut] - rowLayoutsBeforeFinish),
            "rowLayoutCount": Double(ViewBodyCensus[.conversationRowLaidOut]),
            "rowBodyCount": Double(ViewBodyCensus[.conversationTurn])
        ])
        print("[conversation-width] appearance=\(appearance.rawValue) middle=\(middle) live=\(live) entries=\(entries.count) widths=11 rowLayouts=\(ViewBodyCensus[.conversationRowLaidOut]) rowBodies=\(ViewBodyCensus[.conversationTurn]) round=\(repetition + 1) widthChanges=\(widthChanges) mainMilliseconds=\(samples) mainCPUMilliseconds=\(cpuSamples) finishWallMilliseconds=\(finishWallMilliseconds) bottomDistance=\(distance) before=\(initialBookmark) after=\(position.bookmark)")
        let objects: [AnyObject] = TranscriptProseRenderingTests.containers(in: host.hosting).flatMap { text in
            var objects: [AnyObject] = [text, text.textView]
            if let layout = text.textView.textLayoutManager { objects.append(layout) }
            return objects
        }
        let released: [() -> Bool] = objects.map { object in
            weak var reference = object
            return { reference == nil }
        }
        return CaseCleanup(
            hostReleased: { [weak host, weak view = host.hosting, weak window = host.window] in
                host == nil && view == nil && window == nil
            },
            remainingProseObjects: { released.reduce(0) { $0 + ($1() ? 0 : 1) } },
            clearRows: { renderState.keep(turnIDs: [String]()) }
        )
    }
}

/// Continuous main-thread work ends only when the run loop waits. Include direct release/layout
/// calls before the first wait and between run-loop entries, so splitting the measurement into
/// explicit layout and run-loop calls cannot hide a longer uninterrupted interval.
@MainActor
private final class ResizeReleaseProbe {
    private var observers: [CFRunLoopObserver] = []
    private var started: UInt64? = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    private(set) var durations: [Double] = []

    init() {
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.endSegment() }
        }
        for observer in [wake, sleep].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }
    }

    private func endSegment() {
        if let started { durations.append(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started) / 1_000_000) }
        started = nil
    }

    func stop() {
        endSegment()
        for observer in observers { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observers = []
    }
}
