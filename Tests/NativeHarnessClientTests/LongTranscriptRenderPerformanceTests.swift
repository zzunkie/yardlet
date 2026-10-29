import AppKit
import Observation
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// How long a long Claude task's transcript takes to draw (plan M9, D11): the first layout of the
/// conversation in an unshown window, a streamed answer growing, and a new request arriving, each the
/// main thread's time for one update. The renderer is measured with its 40-turn window and drawing
/// every turn. Runs only with `NHC_PERF_BENCH=1` (`NHC_PERF_BENCH_TURNS`, default 400 turns of five
/// entries; a Claude conversation read to its start keeps every entry its transcript holds) and
/// prints `[perf]` lines; `NHC_PERF_BENCH_VARIANTS` (`all,window`) picks the variants. Nothing is asserted about the times, which depend on the machine and its load.
@MainActor
final class LongTranscriptRenderPerformanceTests: XCTestCase {
    @Observable
    final class Feed {
        var entries: [TranscriptEntry]
        init(_ entries: [TranscriptEntry]) { self.entries = entries }
    }

    /// The renderer as it is measured: with its turn window, or drawing every turn.
    private struct Variant: Hashable {
        let name: String
        var turnWindowCount = ConversationTurnWindow.initialTurnCount

        static let window = Variant(name: "window")
        static let allTurns = Variant(name: "all", turnWindowCount: 100_000)
        static let all = [allTurns, window]
    }

    private struct Host: View {
        let feed: Feed
        let variant: Variant
        var body: some View {
            TaskConversationView(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/yardlet-perf"),
                                 entries: feed.entries, sessionStatus: .running,
                                 turnWindowCount: variant.turnWindowCount)
                .frame(width: 760, height: 900)
        }
    }

    func testBenchmarkALongClaudeTranscript() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["NHC_PERF_BENCH"] == "1", "Set NHC_PERF_BENCH=1 to run the benchmark")
        let turns = Int(environment["NHC_PERF_BENCH_TURNS"] ?? "") ?? 400
        let entries = Self.transcript(turns: turns)
        XCTAssertEqual(entries.count, turns * 5)
        let rounds = Int(environment["NHC_PERF_BENCH_ROUNDS"] ?? "") ?? 3
        let names = environment["NHC_PERF_BENCH_VARIANTS"].map { Set($0.split(separator: ",").map(String.init)) }
        let variants = Variant.all.filter { names?.contains($0.name) ?? true }
        // One round of each to warm up, then the measured rounds, alternating.
        for variant in variants { _ = try measure(variant, entries: entries) }
        var mounts: [Variant: Samples] = [:]
        var streams: [Variant: Samples] = [:]
        var requests: [Variant: Samples] = [:]
        for _ in 0..<rounds {
            for variant in variants {
                let result = try measure(variant, entries: entries)
                mounts[variant, default: Samples()].values.append(result.mount)
                streams[variant, default: Samples()].values += result.stream.values
                requests[variant, default: Samples()].values += result.request.values
            }
        }
        for variant in variants {
            let mount = mounts[variant] ?? Samples(), stream = streams[variant] ?? Samples()
            let request = requests[variant] ?? Samples()
            print("[perf] transcript-\(turns)x5 \(variant.name) (\(rounds) rounds): first layout median "
                  + "\(Self.ms(mount.median)) ms, stream update median \(Self.ms(stream.median)) ms "
                  + "(p90 \(Self.ms(stream.p90))), new request median \(Self.ms(request.median)) ms "
                  + "(p90 \(Self.ms(request.p90)))")
            PerfBenchRecord.write("claude-transcript-\(turns)x5-\(variant.name)", [
                "firstLayoutMs": mount.median * 1000, "streamUpdateMs": stream.median * 1000,
                "streamUpdateP90Ms": stream.p90 * 1000, "newRequestMs": request.median * 1000
            ])
        }

        // The projection's share of an update: projecting the transcript again through the renderer's
        // cache (one turn changes; the rest are kept).
        let cache = ConversationProjectionCache()
        var growing = entries
        _ = cache.transcript(growing, harness: .claudeCode, status: .running, latestTurnIsComplete: false)
        var projection = Samples()
        for step in 0..<30 {
            let last = growing.count - 1
            guard case let .assistant(text, _) = growing[last].content else { break }
            growing[last].content = .assistant(text: text + " \(step)", isStreaming: true)
            let begin = Date()
            _ = cache.transcript(growing, harness: .claudeCode, status: .running, latestTurnIsComplete: false)
            projection.values.append(Date().timeIntervalSince(begin))
        }
        print("[perf] transcript-\(turns)x5 projection per stream update: median \(Self.ms(projection.median)) ms "
              + "(p90 \(Self.ms(projection.p90))), turns reused \(cache.counts.reused), projected \(cache.counts.projected)")
        PerfBenchRecord.write("claude-transcript-\(turns)x5-projection", [
            "streamUpdateMs": projection.median * 1000, "streamUpdateP90Ms": projection.p90 * 1000
        ])
    }

    // MARK: - Measuring

    private struct Samples {
        var values: [Double] = []
        var median: Double { values.isEmpty ? 0 : values.sorted()[values.count / 2] }
        var p90: Double { values.isEmpty ? 0 : values.sorted()[min(values.count - 1, values.count * 9 / 10)] }
    }

    private func measure(
        _ variant: Variant, entries: [TranscriptEntry]
    ) throws -> (mount: Double, stream: Samples, request: Samples) {
        let feed = Feed(entries)
        let started = Date()
        let host = WindowlessRender.Host(Host(feed: feed, variant: variant), size: NSSize(width: 760, height: 900))
        defer { host.close() }
        host.hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date())
        host.hosting.layoutSubtreeIfNeeded()
        let mount = Date().timeIntervalSince(started)
        host.settle(passes: 6)

        var stream = Samples()
        for step in 0..<30 {
            let last = feed.entries.count - 1
            guard case let .assistant(text, _) = feed.entries[last].content else { break }
            let begin = Date()
            feed.entries[last].content = .assistant(text: text + " More streamed words \(step).", isStreaming: true)
            host.hosting.layoutSubtreeIfNeeded()
            stream.values.append(Date().timeIntervalSince(begin))
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        var request = Samples()
        for step in 0..<10 {
            let begin = Date()
            feed.entries.append(TranscriptEntry(content: .user(text: "Follow-up \(step)")))
            feed.entries.append(TranscriptEntry(content: .assistant(text: "Working on \(step)", isStreaming: true)))
            host.hosting.layoutSubtreeIfNeeded()
            request.values.append(Date().timeIntervalSince(begin))
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return (mount, stream, request)
    }

    /// `turns` Claude turns of five entries: a request, commentary, a tool call, thinking and an
    /// answer, the last turn still streaming its answer.
    private static func transcript(turns: Int) -> [TranscriptEntry] {
        var entries: [TranscriptEntry] = []
        for index in 1...turns {
            let isLast = index == turns
            entries += [
                TranscriptEntry(content: .user(text: "Request \(index): check the build and fix what fails")),
                TranscriptEntry(content: .assistant(text: "Running the tests for \(index).", isStreaming: false)),
                TranscriptEntry(content: .activity(HarnessActivity(
                    id: "tool-\(index)", kind: "Bash", title: "Bash", input: "swift test --filter Case\(index)",
                    output: "Test Suite passed\n" + String(repeating: "line\n", count: 8)
                ), state: .completed)),
                TranscriptEntry(content: .reasoning(text: "The failure in \(index) is the stale cache.", isStreaming: false)),
                TranscriptEntry(content: .assistant(
                    text: "## Result \(index)\n\nThe build passes after clearing the cache. `swift test` ran cleanly.",
                    isStreaming: isLast
                ))
            ]
        }
        return entries
    }

    private static func ms(_ seconds: Double) -> String {
        String(format: "%.1f", seconds * 1_000)
    }
}
