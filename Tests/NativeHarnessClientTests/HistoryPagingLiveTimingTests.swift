import Foundation
import XCTest
@testable import NativeHarnessClient

/// Opt-in: `NHC_HISTORY_PAGING_LIVE=1` times opening a detached conversation against the person's
/// real history, the whole-history read it replaced next to the paged one. Read-only: Codex through
/// the product route (the YHP Codex adapter over the App Server adapter) with `initialize`,
/// `thread/list`, `thread/read` and `thread/turns/list` only, started in `yardlet-sandbox`
/// (`NHC_HISTORY_PAGING_SANDBOX`); Claude through the transcript reader, opening and then reading
/// each conversation to its start as scrolling up does. It prints only counts, sizes, milliseconds
/// and megabytes: no IDs, titles or conversation text. The test writes nothing, and sends no turn,
/// resume, login or account change.
@MainActor
final class HistoryPagingLiveTimingTests: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// Each thread is read on a fresh App Server, so one read never waits behind another: the newest
    /// page and an earlier one, as opening and scrolling up read them, then the whole thread, as
    /// opening read it before. `NHC_HISTORY_PAGING_THREADS` threads (20), each request given
    /// `NHC_HISTORY_PAGING_TIMEOUT` seconds (120; the app gives 30).
    func testLiveCodexOpeningTimes() async throws {
        guard environment["NHC_HISTORY_PAGING_LIVE"] == "1" else { throw XCTSkip("Set NHC_HISTORY_PAGING_LIVE=1") }
        let binary = URL(filePath: environment["NHC_CODEX_LIVE_BINARY"] ?? "/opt/homebrew/bin/codex")
        let sandbox = environment["NHC_HISTORY_PAGING_SANDBOX"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop/workspace/yardlet-sandbox").path
        var isDirectory: ObjCBool = false
        guard FileManager.default.isExecutableFile(atPath: binary.path),
              FileManager.default.fileExists(atPath: sandbox, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw XCTSkip("Needs the Codex CLI and the sandbox folder")
        }
        let timeout = Duration.seconds(Int(environment["NHC_HISTORY_PAGING_TIMEOUT"] ?? "") ?? 120)
        // Every App Server starts in the sandbox, never in a temporary folder.
        let previous = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(sandbox))
        defer { FileManager.default.changeCurrentDirectoryPath(previous) }
        let workspace = URL(filePath: sandbox)
        func appServer() -> (YHPCodexCompatibilityAdapter, CodexProcessTransport) {
            let transport = CodexProcessTransport(executableURL: binary, requestTimeout: timeout)
            return (YHPCodexCompatibilityAdapter(adapter: CodexAdapter(executableURL: binary, transport: transport),
                                                 manifest: HarnessProtocolCompatibilityManifest.codex()), transport)
        }

        let (lister, listing) = appServer()
        let listed = try await lister.interactiveThreadsPage(cursor: nil, limit: 100)
        await listing.stop()
        let threads = Array(listed.threads.prefix(Int(environment["NHC_HISTORY_PAGING_THREADS"] ?? "") ?? 20))
        print("codex threads", listed.threads.count, "timed", threads.count)

        var rows: [(turns: Int?, whole: Double?, newest: Double?, earlier: Double??)] = []
        for thread in threads {
            let (paged, pagedTransport) = appServer()
            let newest = try? await Self.milliseconds {
                let state = try await paged.readThreadPresentation(threadID: thread.id,
                                                                   newestTurns: CodexThreadPaging.newestTurns)
                _ = CodexConversationProjection.presentation(state, workspaceURL: workspace, historySelection: nil)
                return state.thread?.turnsNextCursor
            }
            var earlier: Double?? = nil
            if let cursor = newest?.value {
                earlier = try? await Self.milliseconds {
                    try await paged.readThreadTurns(threadID: thread.id, cursor: cursor,
                                                    limit: CodexThreadPaging.earlierTurns).turns.count
                }.ms
            }
            await pagedTransport.stop()
            let (whole, wholeTransport) = appServer()
            let read = try? await Self.milliseconds {
                let state = try await whole.readThreadPresentation(threadID: thread.id, newestTurns: nil)
                _ = CodexConversationProjection.presentation(state, workspaceURL: workspace, historySelection: nil)
                return state.thread?.turns.count ?? 0
            }
            await wholeTransport.stop()
            rows.append((read?.value, read?.ms, newest?.ms, earlier))
        }
        func ms(_ value: Double?) -> String { value.map { String(format: "%8.1f ms", $0) } ?? "  timed out" }
        for row in rows.sorted(by: { ($0.whole ?? .infinity) > ($1.whole ?? .infinity) }) {
            print("codex turns", row.turns.map { String(format: "%4d", $0) } ?? "   ?",
                  "| whole read", ms(row.whole), "| newest \(CodexThreadPaging.newestTurns) turns", ms(row.newest),
                  "| earlier page", row.earlier.map(ms) ?? "       -")
        }
        let both = rows.filter { $0.whole != nil && $0.newest != nil }
        print(String(format: "codex over %d threads: whole %.1f ms, newest %.1f ms; whole timed out %d, newest timed out %d",
                     both.count, both.reduce(0) { $0 + ($1.whole ?? 0) }, both.reduce(0) { $0 + ($1.newest ?? 0) },
                     rows.filter { $0.whole == nil }.count, rows.filter { $0.newest == nil }.count))
    }

    func testLiveClaudeOpeningTimes() throws {
        guard environment["NHC_HISTORY_PAGING_LIVE"] == "1" else { throw XCTSkip("Set NHC_HISTORY_PAGING_LIVE=1") }
        let config = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
        let projects = config.appending(path: "projects")
        var files: [(id: String, size: Int)] = []
        for folder in (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
            for file in (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey])) ?? []
            where file.pathExtension == "jsonl" {
                let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
                guard values?.isSymbolicLink != true, let size = values?.fileSize,
                      UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil else { continue }
                files.append((file.deletingPathExtension().lastPathComponent, size))
            }
        }
        // The largest, and the largest a read before this change took whole (under 8 MiB).
        let sorted = files.sorted { $0.size > $1.size }
        let count = Int(environment["NHC_HISTORY_PAGING_THREADS"] ?? "") ?? 12
        let largest = Array(sorted.prefix(count)) + Array(sorted.filter { $0.size <= 8 << 20 }.prefix(count / 2))
        print("claude transcripts", files.count, "over 1 MiB", files.filter { $0.size > 1 << 20 }.count,
              "over 8 MiB", files.filter { $0.size > 8 << 20 }.count, "timed", largest.count)
        var reader = ClaudeSubagentTranscriptReader(configDirectory: config)
        reader.maximumEntries = 2_000
        for file in largest {
            var times: [String] = []
            for bytes in [8 << 20, ClaudeTranscriptTail.initialBytes, 2 << 20, 4 << 20] {
                reader.maximumBytes = bytes
                let read = try Self.milliseconds { try reader.readConversation(sessionID: file.id) }
                times.append(String(format: "%d MiB %7.1f ms %4d entries%@", bytes >> 20, read.ms,
                                    read.value?.entries.count ?? 0, read.value?.hasEarlierRecords == true ? " +" : ""))
            }
            print(String(format: "claude %6.1f MB | ", Double(file.size) / 1_048_576) + times.joined(separator: " | "))
        }
    }

    /// Reading the largest transcripts to their start as the person scrolls up: opening (the newest
    /// 1 MiB) and then every request for earlier turns, each going on until a turn arrives, as the
    /// app asks. `NHC_HISTORY_PAGING_THREADS` transcripts (4) from the largest, and the one nearest
    /// `NHC_HISTORY_PAGING_NEAR_MB` (66). Each is read in a fresh pass; the footprint is the test
    /// process's, sampled while it reads. `NHC_HISTORY_PAGING_DOUBLING=1` also times one read of each
    /// doubled budget from 16 MiB to the whole file (what growing the read without an index costs),
    /// and the parse of the newest 8 MiB with the Codable decoder the reader used before.
    func testLiveClaudeEarlierHistoryTimes() throws {
        guard environment["NHC_HISTORY_PAGING_LIVE"] == "1" else { throw XCTSkip("Set NHC_HISTORY_PAGING_LIVE=1") }
        let config = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
        let files = Self.claudeTranscripts(in: config.appending(path: "projects"))
        let count = Int(environment["NHC_HISTORY_PAGING_THREADS"] ?? "") ?? 4
        let near = Double(environment["NHC_HISTORY_PAGING_NEAR_MB"] ?? "") ?? 66
        var chosen = Array(files.prefix(count))
        if let nearest = files.min(by: { abs(Double($0.size) / 1e6 - near) < abs(Double($1.size) / 1e6 - near) }),
           !chosen.contains(where: { $0.id == nearest.id }) {
            chosen.append(nearest)
        }
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        print(String(format: "claude transcripts %d, over 8 MiB %d, timed %d; load average %.1f %.1f %.1f", files.count,
                     files.filter { $0.size > 8 << 20 }.count, chosen.count, load[0], load[1], load[2]))
        var reader = ClaudeSubagentTranscriptReader(configDirectory: config)
        for file in chosen {
            let baseline = Footprint.current()
            let sampler = Footprint.Sampler()
            let open = try Self.milliseconds {
                try reader.readNewest(sessionID: file.id, bytes: ClaudeTranscriptTail.initialBytes)
            }
            guard var read = open.value else { continue }
            // Kept as the conversation keeps them.
            var entries = read.entries
            var requests: [Double] = []
            // The slowest request, and how many steps it took (a turn longer than a step takes several).
            var slowest: (ms: Double, steps: Int) = (0, 0)
            while read.window.hasEarlierRecords {
                let request = try Self.milliseconds { try reader.readEarlierTurns(read.window) }
                guard let next = request.value else { break }
                requests.append(request.ms)
                if request.ms > slowest.ms {
                    var budget = read.window.bytes
                    var steps = 0
                    while budget < next.window.bytes { budget = ClaudeTranscriptTail.budget(after: budget); steps += 1 }
                    slowest = (request.ms, steps)
                }
                entries = next.entries + entries
                read = next
            }
            print(String(format: "         slowest request %.0f ms over %d steps of up to %d MiB", slowest.ms,
                         slowest.steps, ClaudeTranscriptTail.stepBytes >> 20))
            let peak = sampler.stop()
            let turns = entries.filter(\.opensTurn).count
            let sorted = requests.sorted()
            print(String(format: "claude %6.1f MB | open %6.1f ms | %3d earlier requests: median %6.1f ms, p90 %6.1f ms, "
                         + "max %7.1f ms, total %8.1f ms | %5d turns, %6d entries, %6d records | footprint peak +%.0f MB, "
                         + "after +%.0f MB", Double(file.size) / 1_048_576, open.ms, requests.count,
                         sorted.isEmpty ? 0 : sorted[sorted.count / 2],
                         sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, sorted.count * 9 / 10)], sorted.last ?? 0,
                         requests.reduce(0, +), turns, entries.count, read.window.records.count,
                         Double(Int64(peak) - Int64(baseline)) / 1_048_576,
                         Double(Int64(Footprint.current()) - Int64(baseline)) / 1_048_576))
            let text = entries.reduce(0) { $0 + Self.textBytes(of: $1) }
            entries = []
            read = ClaudeTranscriptRead(entries: [], window: read.window)
            let withoutEntries = Footprint.current()
            malloc_zone_pressure_relief(nil, 0)
            let relieved = Footprint.current()
            print(String(format: "         entries' text %.0f MB; footprint without the entries +%.0f MB, "
                         + "after malloc relief +%.0f MB", Double(text) / 1_048_576,
                         Double(Int64(withoutEntries) - Int64(baseline)) / 1_048_576,
                         Double(Int64(relieved) - Int64(baseline)) / 1_048_576))
        }

        guard environment["NHC_HISTORY_PAGING_DOUBLING"] == "1" else { return }
        reader.maximumEntries = TranscriptBuilder.maximumEntryLimit
        // A plain read holds the whole budget's parsed lines at once, which for the largest is most of
        // a gigabyte: only files up to `NHC_HISTORY_PAGING_DOUBLING_MAX_MB` (100).
        let largestPlain = (Int(environment["NHC_HISTORY_PAGING_DOUBLING_MAX_MB"] ?? "") ?? 100) << 20
        for file in chosen where file.size <= largestPlain {
            var budget = 16 << 20
            var times: [String] = []
            while true {
                reader.maximumBytes = budget
                let baseline = Footprint.current()
                let sampler = Footprint.Sampler()
                let read = try? Self.milliseconds { try reader.readConversation(sessionID: file.id) }
                times.append(String(format: "%d MiB %@ peak +%.0f MB", budget >> 20,
                                    read.map { String(format: "%.0f ms", $0.ms) } ?? "refused",
                                    Double(Int64(sampler.stop()) - Int64(baseline)) / 1_048_576))
                guard budget < file.size else { break }
                budget *= 2
            }
            print(String(format: "claude %6.1f MB plain reads | ", Double(file.size) / 1_048_576)
                  + times.joined(separator: " | "))
        }
        // The parse alone, the newest 8 MiB of the largest: the Codable decoder against the reader's.
        guard let largest = chosen.first, let handle = FileHandle(forReadingAtPath: largest.path) else { return }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(0, largest.size - (8 << 20))))
        let lines = (try handle.readToEnd() ?? Data()).split(separator: 10).dropFirst().map { Data($0) }
        let codable = Self.milliseconds { lines.compactMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }.count }
        let foundation = Self.milliseconds { lines.compactMap(ClaudeSubagentTranscriptReader.parseLine).count }
        print(String(format: "parse of the newest 8 MiB, %d lines: Codable %.0f ms, reader %.0f ms",
                     lines.count, codable.ms, foundation.ms))
    }

    /// The UTF-8 bytes of the text an entry holds, roughly what it keeps in memory.
    private static func textBytes(of entry: TranscriptEntry) -> Int {
        switch entry.content {
        case let .user(text, _), let .assistant(text, _), let .reasoning(text, _), let .plan(text),
             let .error(text, _, _):
            return text.utf8.count
        case let .activity(activity, _):
            let diff = activity.diff.map { diff in
                (diff.oldText?.utf8.count ?? 0) + (diff.newText?.utf8.count ?? 0) + (diff.unified?.utf8.count ?? 0)
            } ?? 0
            return (activity.input?.utf8.count ?? 0) + (activity.output?.utf8.count ?? 0)
                + (activity.detail?.utf8.count ?? 0) + diff
        default:
            return 0
        }
    }

    /// The person's Claude transcripts under `projects`, largest first; links are not followed.
    private static func claudeTranscripts(in projects: URL) -> [(id: String, size: Int, path: String)] {
        var files: [(id: String, size: Int, path: String)] = []
        for folder in (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
            for file in (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey])) ?? []
            where file.pathExtension == "jsonl" {
                let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
                guard values?.isSymbolicLink != true, let size = values?.fileSize,
                      UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil else { continue }
                files.append((file.deletingPathExtension().lastPathComponent, size, file.path))
            }
        }
        return files.sorted { $0.size > $1.size }
    }

    private static func milliseconds<T>(_ work: () async throws -> T) async rethrows -> (value: T, ms: Double) {
        let start = ContinuousClock.now
        let value = try await work()
        let elapsed = ContinuousClock.now - start
        return (value, Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15)
    }

    private static func milliseconds<T>(_ work: () throws -> T) rethrows -> (value: T, ms: Double) {
        let start = ContinuousClock.now
        let value = try work()
        let elapsed = ContinuousClock.now - start
        return (value, Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15)
    }
}
