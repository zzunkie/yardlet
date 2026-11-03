import Foundation
import Observation
import XCTest
@testable import NativeHarnessClient

/// The token counts Settings › Usage and the Home band show, read from transcripts shaped as Claude
/// Code 2.1 and Codex write them: each response once, a forked copy adding nothing, Codex's running
/// totals as differences with a subagent's replayed history left out, the providers' prices, and a
/// file read only past where it stopped. Then a long history: one new line costs one read of its
/// bytes and one publication, which only the views reading the counts observe.
@MainActor
final class TokenUsageLedgerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "token-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The real path, as the file system lists and reports the transcripts under it.
        root = TokenUsageLedger.Roots.canonical(folder)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var claudeRoot: URL { root.appending(path: "claude/projects", directoryHint: .isDirectory) }
    private var codexRoot: URL { root.appending(path: "codex/sessions", directoryHint: .isDirectory) }
    private var roots: TokenUsageLedger.Roots { TokenUsageLedger.Roots(claude: [claudeRoot], codex: [codexRoot]) }

    private func line(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self) + "\n"
    }

    /// As the transcripts write it: `2026-11-03T14:15:33.910Z`.
    private func timestamp(_ minutesAgo: Double) -> String {
        Date().addingTimeInterval(-minutesAgo * 60).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    /// An assistant line of Claude Code's: one content block of response `id` with its usage.
    private func claude(_ id: String, session: String, output: Int64, read: Int64 = 100_000, write1h: Int64 = 2_000,
                        model: String = "claude-opus-5-5", minutesAgo: Double = 5) throws -> String {
        try line(["type": "assistant", "sessionId": session, "cwd": "/work/app", "requestId": "req_\(id)",
                  "timestamp": timestamp(minutesAgo),
                  "message": ["id": id, "model": model, "role": "assistant", "content": [["type": "text", "text": "ok"]],
                              "usage": ["input_tokens": 4, "cache_read_input_tokens": read,
                                        "cache_creation_input_tokens": write1h, "output_tokens": output,
                                        "cache_creation": ["ephemeral_1h_input_tokens": write1h,
                                                           "ephemeral_5m_input_tokens": 0]]]])
    }

    private func write(_ text: String, to url: URL, appending: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if appending, let handle = try? FileHandle(forWritingTo: url) {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        } else {
            try Data(text.utf8).write(to: url)
        }
    }

    private func start(_ ledger: TokenUsageLedger) async throws -> SummaryBox {
        let box = SummaryBox()
        await ledger.start { summary in Task { @MainActor in box.summaries.append(summary) } }
        try await waitUntil { !box.summaries.isEmpty }
        return box
    }

    @MainActor final class SummaryBox {
        var summaries: [TokenUsageSummary] = []
        /// All 30 days, so a test run just after midnight counts the same.
        var counted: TokenUsageAmount {
            (summaries.last?.days ?? []).reduce(into: TokenUsageAmount()) { $0.add($1.amount) }
        }
    }

    func testCountsEachResponseOnceAndReadsOnlyWhatWasWritten() async throws {
        // One response written as two content blocks, the second with its final output; another
        // response; then a forked conversation that copies both and adds a third.
        let main = claudeRoot.appending(path: "-work-app/session-a.jsonl")
        try write(try claude("msg_1", session: "a", output: 5) + claude("msg_1", session: "a", output: 120)
                  + line(["type": "user", "sessionId": "a", "message": ["role": "user", "content": "next"]])
                  + claude("msg_2", session: "a", output: 80), to: main)
        let fork = claudeRoot.appending(path: "-work-app/session-b.jsonl")
        try write(try claude("msg_1", session: "b", output: 120) + claude("msg_2", session: "b", output: 80)
                  + claude("msg_3", session: "b", output: 40), to: fork)
        // A line still being written stays for the next read.
        let partial = try claude("msg_4", session: "b", output: 10)
        try write(String(partial.dropLast(20)), to: fork, appending: true)

        let ledger = TokenUsageLedger(directory: root.appending(path: "usage"), roots: roots, resolve: { _ in
            TokenUsageLedger.Attribution(accounts: ["a": "jordan@example.com"], defaults: [.claudeCode: "default"])
        })
        let box = try await start(ledger)
        var counted = box.counted
        XCTAssertEqual(counted.requests, 3)
        XCTAssertEqual(counted.output, 240)
        XCTAssertEqual(counted.cacheRead, 300_000)
        XCTAssertEqual(counted.cacheWrite, 6_000)
        // Opus 5.5 at the Anthropic table: reads $0.20, 1-hour writes $8, output $20, input $4 per million.
        XCTAssertEqual(counted.kindCost[.cacheRead]!, 0.06, accuracy: 1e-9)
        XCTAssertEqual(counted.kindCost[.cacheWrite]!, 0.048, accuracy: 1e-9)
        XCTAssertEqual(counted.kindCost[.output]!, 0.0048, accuracy: 1e-9)
        let accounts = box.summaries.last?.groups[.month]?[.account] ?? [:]
        XCTAssertEqual(accounts[TokenUsageSummary.Key(harness: .claudeCode, value: "jordan@example.com")]?.requests, 2)
        XCTAssertEqual(accounts[TokenUsageSummary.Key(harness: .claudeCode, value: "default")]?.requests, 1)

        // The rest of the line, then nothing new: the first read counts it, the second reads nothing.
        try write(String(partial.suffix(20)), to: fork, appending: true)
        await ledger.changed([fork.path])
        try await waitUntil { box.counted.requests == 4 }
        let published = box.summaries.count
        let before = await ledger.bytesRead
        await ledger.changed([fork.path, main.path])
        let after = await ledger.bytesRead
        XCTAssertEqual(after, before)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(box.summaries.count, published, "A read that counted nothing published a summary")
        counted = box.counted
        XCTAssertEqual(counted.output, 250)
        await ledger.stop()
    }

    func testCodexCountsItsRunningTotalsLeavingOutReplayedHistory() async throws {
        func count(_ ordinal: Int, input: Int64, cached: Int64, output: Int64) throws -> String {
            try line(["timestamp": timestamp(3), "ordinal": ordinal, "type": "event_msg",
                      "payload": ["type": "token_count", "info": [
                          "total_token_usage": ["input_tokens": input, "cached_input_tokens": cached,
                                                "cache_write_input_tokens": 0, "output_tokens": output],
                          "last_token_usage": ["input_tokens": input, "cached_input_tokens": cached,
                                               "cache_write_input_tokens": 0, "output_tokens": output]]]])
        }
        let rollout = codexRoot.appending(path: "2026/11/03/rollout-2026-11-03T10-00-00-thread-1.jsonl")
        try write(try line(["timestamp": timestamp(10), "ordinal": 0, "type": "session_meta",
                            "payload": ["id": "thread-1", "cwd": "/work/app", "subagent_history_start_ordinal": 4]])
                  // The parent's history, replayed with its own meta and counts.
                  + line(["timestamp": timestamp(30), "ordinal": 1, "type": "session_meta",
                          "payload": ["id": "parent", "cwd": "/elsewhere"]])
                  + count(2, input: 900_000, cached: 800_000, output: 9_000)
                  + line(["timestamp": timestamp(9), "ordinal": 5, "type": "turn_context",
                          "payload": ["model": "gpt-6-astra", "cwd": "/work/app"]])
                  + count(6, input: 900_000 + 100_000, cached: 800_000 + 90_000, output: 9_000 + 1_000)
                  // A count that only refreshed the limits repeats the totals.
                  + count(7, input: 900_000 + 100_000, cached: 800_000 + 90_000, output: 9_000 + 1_000)
                  // A long prompt: over 272K input tokens pays the long-context prices.
                  + count(8, input: 1_000_000 + 300_000, cached: 890_000 + 290_000, output: 10_000 + 2_000),
                  to: rollout)

        let ledger = TokenUsageLedger(directory: root.appending(path: "usage"), roots: roots, resolve: { _ in
            TokenUsageLedger.Attribution(defaults: [.codex: "jordan@example.com"])
        })
        let box = try await start(ledger)
        let counted = box.counted
        XCTAssertEqual(counted.requests, 2)
        XCTAssertEqual(counted.freshInput, 10_000 + 10_000)
        XCTAssertEqual(counted.cacheRead, 90_000 + 290_000)
        XCTAssertEqual(counted.output, 1_000 + 2_000)
        // GPT-6 Astra: $10 input, $1 cached, $50 output; over 272K, $20, $2 and $75.
        let standard: Double = 10_000 * 10 + 90_000 * 1 + 1_000 * 50
        let long: Double = 10_000 * 20 + 290_000 * 2 + 2_000 * 75
        XCTAssertEqual(try XCTUnwrap(counted.cost), (standard + long) / 1e6, accuracy: 1e-9)
        let models = box.summaries.last?.groups[.month]?[.model] ?? [:]
        XCTAssertEqual(Set(models.keys.map { (key: TokenUsageSummary.Key) in key.value }), ["gpt-6-astra"])
        await ledger.stop()
    }

    /// A long history (60,000 responses in 400 files) read once; then each new response costs one read of
    /// the bytes written and one publication, observed by what reads the counts (the band and the page)
    /// and not by what reads only whether counting is on (the window).
    func testALongHistoryCostsOnlyWhatChanged() async throws {
        var files: [URL] = []
        for file in 0..<400 {
            let url = claudeRoot.appending(path: "-work-app-\(file % 20)/session-\(file).jsonl")
            var text = ""
            for response in 0..<150 {
                text += try claude("msg_\(file)_\(response)", session: "s\(file)", output: 50,
                                   minutesAgo: Double(60 * 24 * (response % 20)) + 30)
            }
            try write(text, to: url)
            files.append(url)
        }
        // No watch: the test hands the ledger each change itself.
        let center = TokenUsageCenter(directory: root.appending(path: "usage"))
        let started = ContinuousClock.now
        center.setEnabled(true, roots: roots)
        try await waitUntil(timeout: .seconds(120)) { center.summary != nil }
        print("[token-usage] read 60,000 responses in \(ContinuousClock.now - started)")
        XCTAssertEqual(center.summary?.days.reduce(0) { $0 + $1.amount.requests }, 60_000)
        XCTAssertEqual(center.publications, 1)
        let ledger = try XCTUnwrap(center.ledger)
        let backfill = await ledger.bytesRead

        func counted() -> Int { center.summary?.days.reduce(0) { $0 + $1.amount.requests } ?? 0 }
        let before = counted()
        let counts = Invalidations { _ = center.summary }
        let switchOnly = Invalidations { _ = center.isEnabled }
        for step in 0..<5 {
            let added = try claude("msg_new_\(step)", session: "s7", output: 50, minutesAgo: 0)
            try write(added, to: files[7], appending: true)
            let before = await ledger.bytesRead
            // The watcher's batch, as FSEvents hands it over.
            await ledger.changed([files[7].path])
            let read = await ledger.bytesRead - before
            XCTAssertEqual(read, UInt64(added.utf8.count), "A new line read more than itself")
            try await waitUntil { center.publications == 2 + step }
        }
        // A line with no usage reads but publishes nothing.
        try write(try line(["type": "user", "sessionId": "s7", "message": ["role": "user", "content": "thanks"]]),
                  to: files[7], appending: true)
        await ledger.changed([files[7].path])
        try await Task.sleep(for: .milliseconds(200))
        counts.stop(); switchOnly.stop()
        print("[token-usage] backfill \(backfill) bytes; publications \(center.publications), invalidations \(counts.count)")
        XCTAssertEqual(center.publications, 6)
        XCTAssertEqual(counts.count, 5)
        XCTAssertEqual(switchOnly.count, 0)
        XCTAssertEqual(counted(), before + 5)

        // Off: reading stops and the counts are deleted.
        center.setEnabled(false, roots: roots)
        XCTAssertNil(center.summary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "usage").path))
    }
}
