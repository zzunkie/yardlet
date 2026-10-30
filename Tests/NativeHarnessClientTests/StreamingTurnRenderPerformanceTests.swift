import AppKit
import Darwin
import Observation
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// What one streamed fragment costs the conversation when the running turn has already made many
/// calls, as a working Claude Code turn does. Each fragment redraws the running turn; before, every
/// item view of the turn held the whole turn and compared it on each update, every call's line was
/// drawn again with its fresh closures, comparing the turn walked every call before the part that
/// changed, and every call's input was parsed as JSON again, so a fragment cost grew with the calls.
///
/// The conversation is mounted in a test window that is never shown and laid out after every
/// fragment, as a shown window's display cycle lays it out.
///
/// Its limit is the main thread's time on an Apple silicon Mac, like the performance bench's budgets
/// (docs/PERFORMANCE_BENCH.md, "Budgets"), so it runs with `NHC_PERF_BENCH=1` and the bench, not in CI:
/// one build took 14 and then 16 ms a fragment on a CI runner, and 11 to 13 ms on a busy Mac.
@MainActor
final class StreamingTurnRenderPerformanceTests: XCTestCase {
    @Observable
    final class Feed {
        var entries: [TranscriptEntry]
        init(_ entries: [TranscriptEntry]) { self.entries = entries }
    }

    private struct Host: View {
        let feed: Feed
        var body: some View {
            TaskConversationView(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/qa"), entries: feed.entries,
                                 sessionStatus: .running)
                .frame(width: 900, height: 700)
        }
    }

    func testAFragmentOfATurnWithManyCallsStaysWithinItsBudget() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NHC_PERF_BENCH"] == "1",
                          "Set NHC_PERF_BENCH=1 to run the streaming turn budget")
        var entries = [TranscriptEntry(content: .user(text: "Fix the failing tests"))]
        for call in 0..<120 {
            entries.append(TranscriptEntry(content: .activity(HarnessActivity(
                id: "call-\(call)", kind: "Bash", title: "Bash", detail: "rg -n thing\(call) Sources",
                input: #"{"command":"rg -n thing\#(call) Sources","description":"Search the sources for thing \#(call)"}"#,
                output: "Sources/A.swift:\(call): thing"), state: .completed)))
            if call.isMultiple(of: 10) {
                entries.append(TranscriptEntry(content: .assistant(text: "Looking at part \(call).", isStreaming: false)))
            }
        }
        let answer = TranscriptEntry(content: .assistant(text: "Working", isStreaming: true))
        entries.append(answer)
        let feed = Feed(entries)
        let host = WindowlessRender.Host(Host(feed: feed), size: NSSize(width: 900, height: 700), appearance: .light)
        defer { host.close() }
        host.settle(passes: 20)

        let fragments = 80
        var text = "Working"
        let cpuStart = Self.mainThreadCPU()
        for fragment in 0..<fragments {
            text += " word\(fragment)"
            feed.entries[feed.entries.count - 1] = TranscriptEntry(
                id: answer.id, createdAt: answer.createdAt, content: .assistant(text: text, isStreaming: true))
            host.hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date())
        }
        let perFragment = (Self.mainThreadCPU() - cpuStart) / Double(fragments)
        print(String(format: "[streaming-turn] %d fragments, %.2f ms main-thread CPU each", fragments, perFragment * 1000))
        PerfBenchRecord.write("streaming-turn-fragment-120-calls", ["perFragmentMs": perFragment * 1000])
        // Measured in a debug build on a busy Mac: about 19 ms a fragment before, about 9 ms after.
        XCTAssertLessThan(perFragment, 0.015, "A fragment redrew more of the running turn than it changed")
    }

    private static func mainThreadCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let port = pthread_mach_thread_np(pthread_self())
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
            + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
    }
}
