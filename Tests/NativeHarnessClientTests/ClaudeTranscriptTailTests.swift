import Foundation
import XCTest
@testable import NativeHarnessClient

/// A detached Claude task reads only the newest part of its saved transcript (`ClaudeTranscriptTail`,
/// docs/NATIVE_SESSION_STORAGE.md): 1 MiB at first, then further back each time the person asks for
/// earlier turns (doubled up to 8 MiB, then 8 MiB more each time) until the file's start, parsing only
/// what the reads had not covered. The first paint does not grow with the history; the entries keep
/// their IDs as the reads grow, and following the file reads only its newest part again.
@MainActor
final class ClaudeTranscriptTailTests: XCTestCase {
    private static let sessionID = "8F7C2A51-3E0B-4C47-9C2D-6A1B0E4F9D33"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "claude-tail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - The reader

    /// The read takes only the file's newest budget: a record at the start of a large transcript that
    /// the reader would refuse (another session's) is never parsed, while a read of the whole file
    /// refuses it. The turns read begin with a request, and the file holds earlier ones.
    func testTheFirstReadTakesOnlyTheNewestBudgetOfALargeTranscript() throws {
        let config = root.appending(path: "config")
        let file = try writeTranscript(in: config, turns: 600, poisoned: true)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        XCTAssertGreaterThan(size, 5 * ClaudeTranscriptTail.initialBytes, "a large transcript")

        var reader = ClaudeSubagentTranscriptReader(configDirectory: config)
        reader.maximumEntries = 2_000
        reader.maximumBytes = ClaudeTranscriptTail.initialBytes
        let tail = try XCTUnwrap(try reader.readConversation(sessionID: Self.sessionID))
        XCTAssertTrue(tail.hasEarlierRecords)
        XCTAssertTrue(tail.entries.first?.opensTurn == true, "the turn the read began inside is left out")
        let firstRequest = try XCTUnwrap(Self.requestNumbers(tail.entries).first)
        XCTAssertGreaterThan(firstRequest, 400, "only the newest turns")
        XCTAssertEqual(Self.requestNumbers(tail.entries).last, 600)
        XCTAssertLessThan(tail.entries.count, 300)

        reader.maximumBytes = 8 << 20
        XCTAssertThrowsError(try reader.readConversation(sessionID: Self.sessionID),
                             "a read that reaches the start parses the record the tail never touched")

        // Read in parts, the same: the newest part opens, and only the read that reaches the start refuses.
        var read = try XCTUnwrap(try reader.readNewest(sessionID: Self.sessionID, bytes: ClaudeTranscriptTail.initialBytes))
        XCTAssertEqual(read.entries, tail.entries)
        while read.window.bytes < 4 << 20 {
            read = try XCTUnwrap(try reader.readEarlier(read.window,
                                                        bytes: ClaudeTranscriptTail.budget(after: read.window.bytes)))
        }
        XCTAssertThrowsError(try reader.readEarlier(read.window, bytes: 8 << 20))
    }

    /// Entries keep the IDs they were read with as the reads grow: each read further back puts its
    /// turns before the ones shown, which stay as they were, and what the parts add up to is what one
    /// read of the same budget shows. The reads go on past 8 MiB to the file's start.
    func testEntriesKeepTheirIDsAsTheReadsGrow() throws {
        let config = root.appending(path: "config")
        let file = try writeTranscript(in: config, turns: 900)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        XCTAssertGreaterThan(size, 8 << 20, "past the old cap")
        var reader = ClaudeSubagentTranscriptReader(configDirectory: config)
        reader.maximumEntries = TranscriptBuilder.maximumEntryLimit
        var read = try XCTUnwrap(try reader.readNewest(sessionID: Self.sessionID, bytes: ClaudeTranscriptTail.initialBytes))
        var shown = read.entries
        var budgets = [read.window.bytes]
        while read.window.hasEarlierRecords {
            let next = ClaudeTranscriptTail.budget(after: read.window.bytes)
            read = try XCTUnwrap(try reader.readEarlier(read.window, bytes: next))
            XCTAssertEqual(read.window.bytes, next)
            XCTAssertFalse(read.entries.isEmpty, "\(next) bytes brought earlier turns")
            XCTAssertEqual(read.window.seamEntry, read.entries.first?.id, "the next read goes before these")
            shown = read.applied(to: shown)
            budgets.append(next)

            reader.maximumBytes = next
            let whole = try XCTUnwrap(try reader.readConversation(sessionID: Self.sessionID))
            XCTAssertEqual(shown, whole.entries, "\(next) bytes read in parts show what one read of them does")
            XCTAssertEqual(Set(shown.map(\.id)).count, shown.count, "no entry twice")
        }
        XCTAssertEqual(budgets, [1 << 20, 2 << 20, 4 << 20, 8 << 20, 16 << 20])
        XCTAssertEqual(Self.requestNumbers(shown), Array(1...900), "the whole conversation, in order")
        XCTAssertEqual(read.window.start, 0)
    }

    /// Nothing earlier is offered when the read reached the conversation's start, or when the entry
    /// limit of a read that is not in parts cut it.
    func testAConversationReadToItsStartHasNoEarlierRecords() throws {
        let config = root.appending(path: "config")
        try writeTranscript(in: config, turns: 20)
        var reader = ClaudeSubagentTranscriptReader(configDirectory: config)
        reader.maximumBytes = ClaudeTranscriptTail.initialBytes
        reader.maximumEntries = 2_000
        let whole = try XCTUnwrap(try reader.readConversation(sessionID: Self.sessionID))
        XCTAssertFalse(whole.hasEarlierRecords)
        XCTAssertEqual(Self.requestNumbers(whole.entries).first, 1)
        let newest = try XCTUnwrap(try reader.readNewest(sessionID: Self.sessionID, bytes: ClaudeTranscriptTail.initialBytes))
        XCTAssertFalse(newest.window.hasEarlierRecords)
        XCTAssertEqual(newest.entries, whole.entries)

        try writeTranscript(in: config, turns: 600)
        reader.maximumEntries = 50
        let limited = try XCTUnwrap(try reader.readConversation(sessionID: Self.sessionID))
        XCTAssertFalse(limited.hasEarlierRecords, "a larger read cannot show more past the entry limit")
    }

    /// A compaction in the middle of the file does not end the conversation shown: reading further
    /// back crosses it to the turns before it, as the Claude app shows a saved conversation. It reads
    /// as one compaction marker after the turn it followed, its summary is not shown as a request,
    /// and the reads end at the file's start with the IDs one read of the whole file gives.
    func testACompactionInTheMiddleIsCrossedAsThePersonScrollsUp() throws {
        let config = root.appending(path: "config")
        try writeTranscript(in: config, turns: 600, compactedAfter: 300)
        var reader = ClaudeSubagentTranscriptReader(configDirectory: config)
        var read = try XCTUnwrap(try reader.readNewest(sessionID: Self.sessionID, bytes: ClaudeTranscriptTail.initialBytes))
        XCTAssertTrue(read.window.hasEarlierRecords)
        var shown = read.entries
        while read.window.hasEarlierRecords {
            read = try XCTUnwrap(try reader.readEarlier(read.window,
                                                        bytes: ClaudeTranscriptTail.budget(after: read.window.bytes)))
            shown = read.applied(to: shown)
        }
        XCTAssertEqual(Self.requestNumbers(shown), Array(1...600), "the turns before the compaction follow on above it")
        XCTAssertFalse(shown.contains { $0.content == .user(text: Self.compactSummary, images: nil) },
                       "the summary is the model's context, not a request")
        let markers = shown.indices.filter {
            if case .compaction = shown[$0].content { true } else { false }
        }
        XCTAssertEqual(markers.count, 1)
        let marker = try XCTUnwrap(markers.first)
        XCTAssertEqual(shown[marker].content,
                       .compaction(.init(phase: .completed, tokensBefore: 167_012, tokensAfter: 9_120)))
        XCTAssertEqual(shown[marker + 1].content, .user(text: Self.request(301), images: nil))
        guard case let .assistant(text, _) = shown[marker - 1].content else { return XCTFail("the turn before it") }
        XCTAssertTrue(text.hasPrefix("Answer 300."))

        reader.maximumBytes = 16 << 20
        reader.maximumEntries = TranscriptBuilder.maximumEntryLimit
        XCTAssertEqual(try XCTUnwrap(try reader.readConversation(sessionID: Self.sessionID)).entries, shown,
                       "the IDs one read of the whole file gives")
    }

    /// A transcript of more than 20,000 lines, which a read once refused, opens and reads to its
    /// start, its conversation keeping more than the 2,000 entries a read once kept.
    func testATranscriptOfMoreThan20000LinesOpensAndReadsToItsStart() async throws {
        let fixture = try makeFixture(turns: 12_000, answerWords: 2)
        let lines = try Data(contentsOf: fixture.file).reduce(0) { $1 == 10 ? $0 + 1 : $0 }
        XCTAssertEqual(lines, 24_000)
        let model = fixture.model, task = fixture.task
        await model.refreshConversationStatus(for: task)
        XCTAssertEqual(Self.requestNumbers(model.transcriptBySessionID[task.id] ?? []).last, 12_000)
        var asks = 0
        while model.hasEarlierClaudeHistory(task), asks < 10 {
            await model.readEarlierClaudeHistory(for: task)
            asks += 1
        }
        let read = model.transcriptBySessionID[task.id] ?? []
        XCTAssertEqual(Self.requestNumbers(read), Array(1...12_000))
        XCTAssertEqual(read.count, 24_000)
        XCTAssertFalse(model.hasEarlierClaudeHistory(task))
    }

    /// Reading a large transcript in parts: each request for earlier turns parses no more than a step
    /// of the file, the reads reach its start, and the parts show what one read of the whole file
    /// does, tool calls and their results included. The times and the memory the reads take are
    /// printed (`NHC_HISTORY_PAGING_SYNTHETIC_MB`, 24 MB; a whole read of each budget for comparison
    /// with `NHC_HISTORY_PAGING_DOUBLING=1`).
    func testALargeTranscriptReadsInBoundedParts() throws {
        let environment = ProcessInfo.processInfo.environment
        let megabytes = Int(environment["NHC_HISTORY_PAGING_SYNTHETIC_MB"] ?? "") ?? 24
        let config = root.appending(path: "config")
        let file = try writeToolTranscript(in: config, megabytes: megabytes)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        var reader = ClaudeSubagentTranscriptReader(configDirectory: config)

        let baseline = Footprint.current()
        let sampler = Footprint.Sampler()
        var times: [Double] = []
        var started = ContinuousClock.now
        var read = try XCTUnwrap(try reader.readNewest(sessionID: Self.sessionID, bytes: ClaudeTranscriptTail.initialBytes))
        let open = Self.milliseconds(since: started)
        var shown = read.entries
        while read.window.hasEarlierRecords {
            started = ContinuousClock.now
            var next = read
            repeat {
                let previousStart = next.window.start
                next = try XCTUnwrap(try reader.readEarlier(next.window,
                                                            bytes: ClaudeTranscriptTail.budget(after: next.window.bytes)))
                XCTAssertLessThanOrEqual(previousStart - next.window.start, Int64(ClaudeTranscriptTail.stepBytes),
                                         "a step parses no more than its bytes")
            } while next.entries.isEmpty && next.window.hasEarlierRecords
            times.append(Self.milliseconds(since: started))
            shown = next.applied(to: shown)
            read = next
        }
        let peak = sampler.stop()
        let retained = Footprint.current()
        XCTAssertEqual(read.window.start, 0)
        XCTAssertGreaterThan(times.count, (size >> 20) / (ClaudeTranscriptTail.stepBytes >> 20) - 1)
        let records = read.window.records.count
        let turns = shown.filter(\.opensTurn).count
        print(String(format: "[history-paging] synthetic %.1f MB, %d records, %d turns, %d entries: open %.0f ms, "
                     + "%d earlier requests max %.0f ms median %.0f ms total %.0f ms; footprint peak +%.0f MB, "
                     + "after +%.0f MB", Double(size) / 1_048_576, records, turns, shown.count, open, times.count,
                     times.max() ?? 0, times.sorted()[times.count / 2], times.reduce(0, +),
                     Double(Int64(peak) - Int64(baseline)) / 1_048_576,
                     Double(Int64(retained) - Int64(baseline)) / 1_048_576))

        reader.maximumEntries = TranscriptBuilder.maximumEntryLimit
        reader.maximumBytes = read.window.bytes
        started = ContinuousClock.now
        let whole = try XCTUnwrap(try reader.readConversation(sessionID: Self.sessionID))
        print(String(format: "[history-paging] synthetic whole read %.0f ms", Self.milliseconds(since: started)))
        XCTAssertEqual(shown, whole.entries, "the parts show what one read of the whole file does")
        XCTAssertTrue(shown.contains { if case .activity(_, .completed) = $0.content { true } else { false } })

        guard environment["NHC_HISTORY_PAGING_DOUBLING"] == "1" else { return }
        var budget = 16 << 20
        while true {
            reader.maximumBytes = budget
            let sampler = Footprint.Sampler()
            started = ContinuousClock.now
            _ = try reader.readConversation(sessionID: Self.sessionID)
            print(String(format: "[history-paging] synthetic plain read of %d MiB %.0f ms, footprint peak +%.0f MB",
                         budget >> 20, Self.milliseconds(since: started),
                         Double(Int64(sampler.stop()) - Int64(baseline)) / 1_048_576))
            guard budget < size else { break }
            budget *= 2
        }
    }

    // MARK: - The budget

    /// The budget doubles up to a step of 8 MiB and then grows by it, so no request for earlier
    /// turns parses more than a step however long the conversation is.
    func testTheBudgetDoublesToAStepAndThenGrowsByIt() {
        let tail = ClaudeTranscriptTail(providerSessionID: Self.sessionID)
        XCTAssertEqual(tail.bytes, 1_048_576)
        XCTAssertFalse(tail.hasEarlierHistory, "nothing read yet")
        var budgets = [tail.bytes]
        while budgets.count < 8 { budgets.append(ClaudeTranscriptTail.budget(after: budgets[budgets.count - 1])) }
        XCTAssertEqual(budgets.map { $0 >> 20 }, [1, 2, 4, 8, 16, 24, 32, 40])
        XCTAssertEqual(zip(budgets, budgets.dropFirst()).map { $1 - $0 }.max(), ClaudeTranscriptTail.stepBytes)
    }

    // MARK: - A detached task

    /// Opening reads the newest 1 MiB and offers earlier turns; asking for them reads further back,
    /// past the 8 MiB a read once stopped at, each read keeping the entries already shown, until the
    /// file's start, where the conversation stops offering earlier turns.
    func testADetachedTaskReadsItsHistoryAsThePersonAsksForIt() async throws {
        let fixture = try makeFixture(turns: 900)
        let model = fixture.model, task = fixture.task
        await model.refreshConversationStatus(for: task)
        let first = model.transcriptBySessionID[task.id] ?? []
        XCTAssertEqual(model.claudeTranscriptTailBySessionID[task.id]?.bytes, ClaudeTranscriptTail.initialBytes)
        XCTAssertTrue(model.hasEarlierClaudeHistory(task))
        XCTAssertEqual(Self.requestNumbers(first).last, 900)
        XCTAssertGreaterThan(Self.requestNumbers(first).first ?? 0, 700, "only the newest turns are read on open")

        var shown = first
        for budget in [2 << 20, 4 << 20, 8 << 20, 16 << 20] {
            XCTAssertTrue(model.hasEarlierClaudeHistory(task), "the file holds more before \(budget >> 1) bytes")
            await model.readEarlierClaudeHistory(for: task)
            let read = model.transcriptBySessionID[task.id] ?? []
            XCTAssertEqual(model.claudeTranscriptTailBySessionID[task.id]?.bytes, budget)
            XCTAssertGreaterThan(read.count, shown.count)
            XCTAssertEqual(Array(read.suffix(shown.count)), shown, "what was shown keeps its entries and IDs")
            shown = read
        }
        XCTAssertEqual(Self.requestNumbers(shown), Array(1...900), "the whole conversation")
        XCTAssertFalse(model.hasEarlierClaudeHistory(task), "the reads reached the file's start")
        await model.readEarlierClaudeHistory(for: task)
        XCTAssertEqual(model.transcriptBySessionID[task.id] ?? [], shown, "nothing more is read at the start")
        XCTAssertFalse(model.isAttached(task.id))
        let calls = await fixture.claude.calls
        XCTAssertEqual(calls, [], "reading started no Claude process")
    }

    /// A turn longer than the doubled budget brings in no earlier turn by itself: asking for earlier
    /// turns reads further back until one arrives, so every ask shows more.
    func testAskingForEarlierTurnsReadsPastATurnLongerThanTheBudget() async throws {
        let fixture = try makeFixture(turns: 50, longTurn: 39)
        let model = fixture.model, task = fixture.task
        await model.refreshConversationStatus(for: task)
        XCTAssertEqual(Self.requestNumbers(model.transcriptBySessionID[task.id] ?? []), Array(40...50),
                       "the 1 MiB read begins inside the long turn")

        await model.readEarlierClaudeHistory(for: task)
        let read = model.transcriptBySessionID[task.id] ?? []
        XCTAssertEqual(model.claudeTranscriptTailBySessionID[task.id]?.bytes, 4 << 20,
                       "2 MiB still began inside the long turn")
        XCTAssertTrue(Self.requestNumbers(read).contains(39))
        XCTAssertLessThan(Self.requestNumbers(read).first ?? .max, 39)
    }

    /// A last turn longer than the first read is read in part, without its request. Reading earlier
    /// turns goes back to its request and puts the whole turn, with the turns before it, in place of
    /// that part rather than in front of it: no step of the turn shows twice, and the entries are the
    /// ones one read of the same bytes gives. Opening the task reads that far before it shows
    /// anything: the part alone drew a conversation shorter than its view, its latest message well
    /// above the composer.
    func testALastTurnLongerThanTheFirstReadReadsWholeInPlaceOfItsPart() async throws {
        let config = root.appending(path: "config")
        try writeTranscript(in: config, turns: 40, longTurn: 40)
        var reader = ClaudeSubagentTranscriptReader(configDirectory: config)
        let newest = try XCTUnwrap(try reader.readNewest(sessionID: Self.sessionID, bytes: ClaudeTranscriptTail.initialBytes))
        XCTAssertTrue(newest.window.hasEarlierRecords)
        XCTAssertTrue(Self.requestNumbers(newest.entries).isEmpty, "the read began inside the last turn")
        XCTAssertFalse(newest.entries.isEmpty)
        XCTAssertNil(newest.window.seamEntry)

        let earlier = try XCTUnwrap(try reader.readEarlierTurns(newest.window))
        XCTAssertEqual(earlier.replacesThrough, newest.entries.last?.id)
        let shown = earlier.applied(to: newest.entries)
        XCTAssertEqual(Self.requestNumbers(shown), Array(1...40))
        XCTAssertEqual(Set(shown.map(\.id)).count, shown.count, "no step twice")
        reader.maximumBytes = earlier.window.bytes
        reader.maximumEntries = TranscriptBuilder.maximumEntryLimit
        XCTAssertEqual(shown, try XCTUnwrap(try reader.readConversation(sessionID: Self.sessionID)).entries)

        // The task opens on the whole turn and the turns before it, never on the part.
        let fixture = try makeFixture(turns: 40, longTurn: 40)
        await fixture.model.refreshConversationStatus(for: fixture.task)
        XCTAssertEqual(fixture.model.transcriptBySessionID[fixture.task.id] ?? [], shown)
        XCTAssertFalse(fixture.model.hasEarlierClaudeHistory(fixture.task))
    }

    /// The newest read can begin inside a turn whose end is in it: a deploy turn's last command, the
    /// session's metadata lines Claude wrote before the answer, the final answer, and the background
    /// command's notice and Claude's reply to it, then the next request. That end shows above the next
    /// request rather than being left out (a real task lost two final reports this way, in the
    /// conversation and `read_task`), and a read further back puts the whole turn in its place.
    func testTheEndOfTheTurnTheFirstReadBeganInsideShowsAboveTheNextRequest() throws {
        let config = root.appending(path: "config")
        let (file, insideDeploy) = try writeNoticeTranscript(in: config)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        let reader = ClaudeSubagentTranscriptReader(configDirectory: config)

        let newest = try XCTUnwrap(try reader.readNewest(sessionID: Self.sessionID, bytes: size - insideDeploy))
        XCTAssertTrue(newest.window.hasEarlierRecords)
        XCTAssertEqual(Self.requestNumbers(newest.entries), [31], "the deploy turn's request is before the read")
        let texts = Self.assistantTexts(newest.entries)
        XCTAssertTrue(texts.contains(Self.deployAnswer), "the final answer the read holds is shown: \(texts)")
        XCTAssertTrue(texts.contains(Self.noticeReply), "and Claude's reply to the notice after it")
        XCTAssertLessThan(try XCTUnwrap(texts.firstIndex(of: Self.deployAnswer)),
                          try XCTUnwrap(texts.firstIndex(of: "Answer 31.")))
        XCTAssertNotNil(newest.window.partialEntry)
        // The conversation (and `read_task`, which reads the same presentation) shows the deploy turn's
        // end with its final answer as the answer, and the notice opening a turn of its own.
        let presentation = TranscriptConversationProjection.presentation(
            from: newest.entries, harness: .claudeCode, status: .ready, latestTurnIsComplete: true)
        func answers(_ turn: ConversationTurn) -> [String] {
            turn.answers.compactMap { if case let .answer(text, _) = $0.kind { text } else { nil } }
        }
        XCTAssertEqual(presentation.turns.count, 3)
        XCTAssertEqual(answers(presentation.turns[0]), [Self.deployAnswer], "the final report stays the answer")
        XCTAssertEqual(presentation.turns[1].prompt.first?.backgroundTaskNotice?.summary, Self.noticeSummary)
        XCTAssertEqual(answers(presentation.turns[1]), [Self.noticeReply])
        XCTAssertEqual(answers(presentation.turns[2]), ["Answer 31."])

        // A read further back puts the whole deploy turn, from its request, in place of its end.
        let earlier = try XCTUnwrap(try reader.readEarlierTurns(newest.window))
        XCTAssertEqual(earlier.replacesThrough, newest.window.partialEntry)
        let shown = earlier.applied(to: newest.entries)
        XCTAssertEqual(Self.requestNumbers(shown).suffix(2), [30, 31])
        XCTAssertEqual(Self.assistantTexts(shown).filter { $0 == Self.deployAnswer }.count, 1, "once")
        XCTAssertEqual(Set(shown.map(\.id)).count, shown.count, "no step twice")

        // Following the file again keeps the whole turn, the end the newest read holds included once.
        let followed = try XCTUnwrap(try reader.refreshConversation(sessionID: Self.sessionID, window: earlier.window,
                                                                    shown: shown, keeping: nil))
        XCTAssertEqual(Self.assistantTexts(followed.entries).filter { $0 == Self.deployAnswer }.count, 1)
        XCTAssertEqual(Self.requestNumbers(followed.entries).suffix(2), [30, 31])
    }

    /// Following the file reads only its newest part and puts it in place of the turns shown from its
    /// first one on: the earlier turns the person brought in stay, and the new answer arrives.
    func testFollowingReadsOnlyTheNewestPart() async throws {
        let fixture = try makeFixture(turns: 400)
        let model = fixture.model, task = fixture.task
        await model.refreshConversationStatus(for: task)
        await model.readEarlierClaudeHistory(for: task)
        let widened = model.transcriptBySessionID[task.id] ?? []
        XCTAssertEqual(model.claudeTranscriptTailBySessionID[task.id]?.bytes, 2 << 20)

        model.detachedFollowInterval = .milliseconds(40)
        let follow = Task { await model.followDetachedConversation(for: task) }
        defer { follow.cancel() }
        try await Task.sleep(for: .milliseconds(150))
        let handle = try FileHandle(forWritingTo: fixture.file)
        try handle.seekToEnd()
        try handle.write(contentsOf: try JSONEncoder().encode(JSONValue.object(
            Self.assistant("Another app's answer.", uuid: "a-extra", parent: "a-400"))) + Data([10]))
        try handle.close()
        let followed = await eventually {
            (model.transcriptBySessionID[task.id] ?? []).contains {
                if case let .assistant(text, _) = $0.content { text == "Another app's answer." } else { false }
            }
        }
        XCTAssertTrue(followed)
        let after = model.transcriptBySessionID[task.id] ?? []
        XCTAssertEqual(Self.requestNumbers(after).first, Self.requestNumbers(widened).first,
                       "the earlier turns brought in stay")
        XCTAssertEqual(Array(after.prefix(widened.count - 1)), Array(widened.prefix(widened.count - 1)),
                       "with their IDs")
        XCTAssertEqual(model.claudeTranscriptTailBySessionID[task.id]?.bytes, 2 << 20)
        XCTAssertTrue(model.hasEarlierClaudeHistory(task))
    }

    /// Following a conversation whose last turn is longer than the newest read: the newest part meets
    /// the turns shown only at the turn's request, so the read goes back to it, and the turns the
    /// person brought in stay with their IDs; no step shows twice.
    func testFollowingALongLastTurnMeetsTheTurnsShownAtItsRequest() async throws {
        let fixture = try makeFixture(turns: 40, longTurn: 40)
        let model = fixture.model, task = fixture.task
        await model.refreshConversationStatus(for: task)
        await model.readEarlierClaudeHistory(for: task)
        let whole = model.transcriptBySessionID[task.id] ?? []
        XCTAssertEqual(Self.requestNumbers(whole), Array(1...40))

        model.detachedFollowInterval = .milliseconds(40)
        let follow = Task { await model.followDetachedConversation(for: task) }
        defer { follow.cancel() }
        try await Task.sleep(for: .milliseconds(150))
        let handle = try FileHandle(forWritingTo: fixture.file)
        try handle.seekToEnd()
        try handle.write(contentsOf: try JSONEncoder().encode(JSONValue.object(
            Self.assistant("Another app's answer.", uuid: "a-extra", parent: "a-40"))) + Data([10]))
        try handle.close()
        let followed = await eventually {
            (model.transcriptBySessionID[task.id] ?? []).contains {
                if case let .assistant(text, _) = $0.content { text == "Another app's answer." } else { false }
            }
        }
        XCTAssertTrue(followed)
        let after = model.transcriptBySessionID[task.id] ?? []
        XCTAssertEqual(Array(after.prefix(whole.count)), whole, "the turns shown stay, with their IDs")
        XCTAssertEqual(after.count, whole.count + 1)
        XCTAssertEqual(Set(after.map(\.id)).count, after.count)
        XCTAssertFalse(model.hasEarlierClaudeHistory(task))
    }

    /// A place the person was reading that the newest 1 MiB leaves out keeps them there: the read
    /// goes further back until it holds it.
    func testASavedPlaceBeforeTheNewestPartIsKept() async throws {
        let config = root.appending(path: "config")
        try writeTranscript(in: config, turns: 600)
        var reader = ClaudeSubagentTranscriptReader(configDirectory: config)
        reader.maximumEntries = 2_000
        reader.maximumBytes = 4 << 20
        let cached = try XCTUnwrap(try reader.readConversation(sessionID: Self.sessionID)).entries
        let place = try XCTUnwrap(cached.first { $0.content == .user(text: Self.request(200), images: nil) })
        let fixture = try makeFixture(turns: 600, cached: cached)
        let reading = fixture.model.taskWorkspaces.state(for: fixture.task.id).transcript
        reading.bookmark = TranscriptReadingBookmark(anchorID: place.id.uuidString, fraction: 0.25, followsLatest: false)

        await fixture.model.refreshConversationStatus(for: fixture.task)
        let read = fixture.model.transcriptBySessionID[fixture.task.id] ?? []
        XCTAssertTrue(read.contains { $0.id == place.id }, "the saved place is still in the conversation")
        XCTAssertEqual(reading.bookmark.anchorID, place.id.uuidString)
        XCTAssertGreaterThan(fixture.model.claudeTranscriptTailBySessionID[fixture.task.id]?.bytes ?? 0,
                             ClaudeTranscriptTail.initialBytes)
        XCTAssertLessThan(fixture.model.claudeTranscriptTailBySessionID[fixture.task.id]?.bytes ?? .max,
                          ClaudeTranscriptTail.placeBytes, "only as far back as the place")
    }

    /// An attached task keeps what its runtime streamed and takes the earlier turns a larger read
    /// finds before its first turn. Nothing is sent.
    func testAnAttachedTaskTakesEarlierTurnsBeforeItsFirst() async throws {
        let fixture = try makeFixture(turns: 400)
        let model = fixture.model, task = fixture.task
        await model.refreshConversationStatus(for: task)
        await model.resume(task)
        XCTAssertTrue(model.isAttached(task.id))
        let attached = model.transcriptBySessionID[task.id] ?? []
        XCTAssertTrue(model.hasEarlierClaudeHistory(task))

        await model.readEarlierClaudeHistory(for: task)
        let read = model.transcriptBySessionID[task.id] ?? []
        XCTAssertGreaterThan(read.count, attached.count)
        XCTAssertEqual(Array(read.suffix(attached.count)), attached)
        XCTAssertEqual(model.claudeTranscriptTailBySessionID[task.id]?.bytes, 2 << 20)
        let calls = await fixture.claude.calls
        XCTAssertEqual(calls, ["resume \(Self.sessionID)"], "nothing was sent")
    }

    func testReplacingTheEntriesBeforeAnEntryKeepsWhatFollowsIt() {
        let head = TranscriptEntry(content: .assistant(text: "the end of a turn read in part", isStreaming: false))
        let first = TranscriptEntry(content: .user(text: "Request 2"))
        var builder = TranscriptBuilder(entries: [head, first], limit: 4)
        builder.apply(.assistantDelta("streaming"))
        let streamedID = builder.entries.last?.id
        let earlier = [TranscriptEntry(content: .user(text: "Request 0")),
                       TranscriptEntry(content: .user(text: "Request 1")),
                       TranscriptEntry(content: .assistant(text: "Answer 1", isStreaming: false)),
                       TranscriptEntry(content: .assistant(text: "the whole turn's end", isStreaming: false))]
        builder.replaceEntries(before: first.id, with: earlier)
        XCTAssertEqual(builder.entries.count, 4, "the limit keeps the newest")
        XCTAssertEqual(builder.entries.map(\.content).prefix(2),
                       [.assistant(text: "Answer 1", isStreaming: false),
                        .assistant(text: "the whole turn's end", isStreaming: false)])
        XCTAssertEqual(builder.entries[2].id, first.id)
        XCTAssertEqual(builder.entries.last?.id, streamedID, "what streams after it stays")
        builder.apply(.assistantDelta(" on"))
        XCTAssertEqual(builder.entries.last?.content, .assistant(text: "streaming on", isStreaming: true))

        var unchanged = TranscriptBuilder(entries: [first])
        unchanged.replaceEntries(before: UUID(), with: earlier)
        XCTAssertEqual(unchanged.entries, [first])
    }

    // MARK: - Fixtures

    private struct Fixture {
        let model: AppModel
        let task: SessionRecord
        let claude: ClaudeRuntimeRecorder
        let file: URL
    }

    /// A saved, detached Claude task whose account's config holds a transcript of `turns` turns.
    private func makeFixture(turns: Int, cached: [TranscriptEntry]? = nil, longTurn: Int? = nil,
                             answerWords: Int = 480) throws -> Fixture {
        let config = root.appending(path: "config")
        let project = root.appending(path: "project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = try writeTranscript(in: config, turns: turns, workspace: project, longTurn: longTurn,
                                       answerWords: answerWords)
        let cli = root.appending(path: "claude")
        try Data("#!/bin/sh\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let account = ProviderConnection(id: "claude-tail", name: "tail@example.test", harness: .claudeCode,
                                         providerID: nil, homePath: config.path, credentialSelector: nil)
        let task = SessionRecord(harness: .claudeCode, workspaceURL: project, runtimeExecutableURL: cli,
            title: "Long", status: .completed, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000), providerSessionID: Self.sessionID,
            connection: account)
        let claude = ClaudeRuntimeRecorder()
        let suite = testDefaultsSuite("ClaudeTranscriptTail")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(
            store: SessionStore(sessions: [task], repository: InMemorySessionRepository(sessions: [task])),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry { _, _ in claude },
            modelCatalogs: HarnessModelCatalogStore(locations: HarnessModelSettingsLocations(
                claudeConfigDirectory: config, codexHome: root.appending(path: "codex-home"),
                codexYardletHome: root.appending(path: "codex-yardlet")), environment: [:]),
            initialTranscripts: cached.map { [task.id: $0] } ?? [:],
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults),
            preferences: defaults,
            transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
            sessionTitleResolver: { _ in nil },
            restoresIndexOnLaunch: false)
        addTeardownBlock { await model.shutdown() }
        return Fixture(model: model, task: task, claude: claude, file: file)
    }

    /// `turns` turns of about 10 KB each (`answerWords`), each a request and its answer, chained as
    /// Claude saves them. `poisoned` starts the file with another session's record, which a read
    /// refuses if it parses it.
    @discardableResult
    private func writeTranscript(in config: URL, turns: Int, workspace: URL? = nil, poisoned: Bool = false,
                                 compactedAfter: Int? = nil, longTurn: Int? = nil,
                                 answerWords: Int = 480) throws -> URL {
        let workspace = workspace ?? root.appending(path: "project")
        let folder = config.appending(path: "projects/\(ClaudeConversationCatalog.projectFolderName(for: workspace))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var data = Data()
        func append(_ record: [String: JSONValue]) throws {
            data.append(try JSONEncoder().encode(JSONValue.object(record)))
            data.append(10)
        }
        if poisoned {
            var other = Self.user(Self.request(0), uuid: "u-0", parent: nil)
            other["sessionId"] = .string("00000000-0000-4000-8000-000000000000")
            try append(other)
        }
        var parent: String?
        for index in 1...turns {
            if index == compactedAfter.map({ $0 + 1 }) {
                // As Claude saves a compaction: the boundary starts a chain of its own, linked to the
                // record before it only logically, and the summary the model goes on from follows it.
                try append(["type": .string("system"), "subtype": .string("compact_boundary"), "uuid": .string("compact"),
                            "parentUuid": .null, "logicalParentUuid": parent.map(JSONValue.string) ?? .null,
                            "sessionId": .string(Self.sessionID),
                            "compactMetadata": .object(["trigger": .string("auto"), "preTokens": .integer(167_012),
                                                        "postTokens": .integer(9_120)])])
                var summary = Self.user(Self.compactSummary, uuid: "summary", parent: "compact")
                summary["isCompactSummary"] = .bool(true)
                summary["isVisibleInTranscriptOnly"] = .bool(true)
                try append(summary)
                parent = "summary"
            }
            try append(Self.user(Self.request(index), uuid: "u-\(index)", parent: parent))
            parent = "u-\(index)"
            // A long turn: the agent's many steps, all after one request.
            for step in 0..<(index == longTurn ? 250 : 0) {
                try append(Self.assistant("Step \(step). " + String(repeating: "Words of the step. ", count: 520),
                                          uuid: "s-\(index)-\(step)", parent: parent!))
                parent = "s-\(index)-\(step)"
            }
            try append(Self.assistant("Answer \(index). " + String(repeating: "Words of the answer. ", count: answerWords),
                                      uuid: "a-\(index)", parent: parent!))
            parent = "a-\(index)"
        }
        let file = folder.appending(path: "\(Self.sessionID).jsonl")
        try data.write(to: file)
        return file
    }

    /// About `megabytes` of turns shaped like a long agent session's: a request, a command call, its
    /// long output (saved twice, in the result and in `toolUseResult`, as Claude does), and the answer.
    private func writeToolTranscript(in config: URL, megabytes: Int) throws -> URL {
        let workspace = root.appending(path: "project")
        let folder = config.appending(path: "projects/\(ClaudeConversationCatalog.projectFolderName(for: workspace))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = String(repeating: "Test Case passed (0.012 seconds) in the long command output.\n", count: 500)
        var data = Data()
        func append(_ record: [String: JSONValue]) throws {
            data.append(try JSONEncoder().encode(JSONValue.object(record)))
            data.append(10)
        }
        var parent: String?
        var index = 0
        while data.count < megabytes << 20 {
            index += 1
            try append(Self.user(Self.request(index), uuid: "u-\(index)", parent: parent))
            var call = Self.assistant("Running \(index).", uuid: "c-\(index)", parent: "u-\(index)")
            call["message"] = .object(["id": .string("m-c-\(index)"), "role": .string("assistant"), "content": .array([
                .object(["type": .string("tool_use"), "id": .string("tool-\(index)"), "name": .string("Bash"),
                         "input": .object(["command": .string("swift test --filter Case\(index)")])])])])
            try append(call)
            var result = Self.user("", uuid: "r-\(index)", parent: "c-\(index)")
            result["message"] = .object(["role": .string("user"), "content": .array([
                .object(["type": .string("tool_result"), "tool_use_id": .string("tool-\(index)"),
                         "content": .string(output)])])])
            result["toolUseResult"] = .object(["stdout": .string(output), "stderr": .string(""),
                                               "interrupted": .bool(false)])
            try append(result)
            try append(Self.assistant("Answer \(index). The tests pass.", uuid: "a-\(index)", parent: "r-\(index)"))
            parent = "a-\(index)"
        }
        let file = folder.appending(path: "\(Self.sessionID).jsonl")
        try data.write(to: file)
        return file
    }

    static let deployAnswer = "Deployed. The final report: every service runs the new build."
    static let noticeReply = "The local server started in the background was stopped; nothing else changed."
    static let noticeSummary = "Background command \"Run the local API server\" was stopped after reaching its time limit"

    /// Thirty turns, then a deploy turn shaped as Claude saved that real one: a command whose long
    /// output follows, the session's metadata lines written before the answer (`last-prompt` naming the
    /// command as its leaf), the final answer, the queue's lines, the notice that a background command
    /// finished (`origin.kind` "task-notification") and Claude's reply, then one more turn. Returns the
    /// file and an offset inside the deploy turn, after its request.
    private func writeNoticeTranscript(in config: URL) throws -> (URL, Int) {
        let workspace = root.appending(path: "project")
        let folder = config.appending(path: "projects/\(ClaudeConversationCatalog.projectFolderName(for: workspace))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var data = Data()
        func append(_ record: [String: JSONValue]) throws {
            data.append(try JSONEncoder().encode(JSONValue.object(record)))
            data.append(10)
        }
        var parent: String?
        for index in 1...29 {
            try append(Self.user(Self.request(index), uuid: "u-\(index)", parent: parent))
            try append(Self.assistant("Answer \(index).", uuid: "a-\(index)", parent: "u-\(index)"))
            parent = "a-\(index)"
        }
        try append(Self.user(Self.request(30), uuid: "u-30", parent: parent))
        let insideDeploy = data.count + 10
        var call = Self.assistant("Deploying.", uuid: "c-30", parent: "u-30")
        call["message"] = .object(["id": .string("m-c-30"), "role": .string("assistant"), "content": .array([
            .object(["type": .string("tool_use"), "id": .string("tool-30"), "name": .string("Bash"),
                     "input": .object(["command": .string("kubectl rollout status deploy/erp")])])])])
        try append(call)
        let session: JSONValue = .string(Self.sessionID)
        try append(["type": .string("last-prompt"), "lastPrompt": .string(Self.request(30)), "leafUuid": .string("c-30"),
                    "sessionId": session])
        try append(["type": .string("custom-title"), "customTitle": .string("Dashboard"), "sessionId": session])
        try append(["type": .string("agent-name"), "agentName": .string("Dashboard"), "sessionId": session])
        try append(["type": .string("mode"), "mode": .string("normal"), "sessionId": session])
        try append(["type": .string("atis-latch"), "atis": .string(""), "sessionId": session])
        try append(["type": .string("pr-link"), "sessionId": session, "prNumber": .integer(2444)])
        let output = String(repeating: "deployment \"erp\" successfully rolled out\n", count: 400)
        var result = Self.user("", uuid: "r-30", parent: "c-30")
        result["message"] = .object(["role": .string("user"), "content": .array([
            .object(["type": .string("tool_result"), "tool_use_id": .string("tool-30"), "content": .string(output)])])])
        try append(result)
        var answer = Self.assistant(Self.deployAnswer, uuid: "a-30", parent: "r-30")
        answer["message"] = .object(["id": .string("m-a-30"), "role": .string("assistant"), "stop_reason": .string("end_turn"),
                                     "content": .array([.object(["type": .string("text"), "text": .string(Self.deployAnswer)])])])
        try append(answer)
        try append(["type": .string("queue-operation"), "operation": .string("enqueue"), "sessionId": session])
        try append(["type": .string("queue-operation"), "operation": .string("dequeue"), "sessionId": session])
        var notice = Self.user("<task-notification>\n<task-id>bucifqmfp</task-id>\n<status>killed</status>\n"
                               + "<summary>\(Self.noticeSummary)</summary>\n</task-notification>", uuid: "n-30", parent: "a-30")
        notice["origin"] = .object(["kind": .string("task-notification")])
        try append(notice)
        try append(Self.assistant(Self.noticeReply, uuid: "nr-30", parent: "n-30"))
        try append(Self.user(Self.request(31), uuid: "u-31", parent: "nr-30"))
        try append(Self.assistant("Answer 31.", uuid: "a-31", parent: "u-31"))
        let file = folder.appending(path: "\(Self.sessionID).jsonl")
        try data.write(to: file)
        return (file, insideDeploy)
    }

    /// The assistant texts, in order.
    private static func assistantTexts(_ entries: [TranscriptEntry]) -> [String] {
        entries.compactMap { entry in
            guard case let .assistant(text, _) = entry.content else { return nil }
            return text
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
    }

    private static func request(_ index: Int) -> String { "Request \(index)" }

    private static let compactSummary = "This session is being continued from a previous conversation that ran out of context."

    private static func user(_ text: String, uuid: String, parent: String?) -> [String: JSONValue] {
        ["type": .string("user"), "uuid": .string(uuid), "parentUuid": parent.map(JSONValue.string) ?? .null,
         "sessionId": .string(sessionID), "isSidechain": .bool(false),
         "message": .object(["role": .string("user"), "content": .string(text)])]
    }

    private static func assistant(_ text: String, uuid: String, parent: String) -> [String: JSONValue] {
        ["type": .string("assistant"), "uuid": .string(uuid), "parentUuid": .string(parent),
         "sessionId": .string(sessionID),
         "message": .object(["id": .string("m-\(uuid)"), "role": .string("assistant"),
                             "content": .array([.object(["type": .string("text"), "text": .string(text)])])])]
    }

    /// The requests' numbers, in order.
    private static func requestNumbers(_ entries: [TranscriptEntry]) -> [Int] {
        entries.compactMap { entry in
            guard case let .user(text, _) = entry.content, text.hasPrefix("Request ") else { return nil }
            return Int(text.dropFirst("Request ".count))
        }
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

/// A Claude runtime that records what it is asked and streams nothing.
private actor ClaudeRuntimeRecorder: HarnessAdapter {
    nonisolated let kind = HarnessKind.claudeCode
    private(set) var calls: [String] = []

    func probeRuntime() async throws -> HarnessRuntimeDescriptor {
        HarnessRuntimeDescriptor(harness: kind, executableURL: URL(filePath: "/tmp/stub"), version: "stub",
                                 capabilities: .unavailable, fingerprint: "stub")
    }
    func createSession(_ request: CreateHarnessSessionRequest) async throws -> HarnessSessionHandle {
        calls.append("create")
        return HarnessSessionHandle(harness: kind, localSessionID: request.localSessionID,
                                    providerSessionID: UUID().uuidString, workspaceURL: request.workspaceURL)
    }
    func resumeSession(providerSessionID: String, localSessionID: UUID, workspaceURL: URL) async throws -> HarnessSessionHandle {
        calls.append("resume \(providerSessionID)")
        return HarnessSessionHandle(harness: kind, localSessionID: localSessionID, providerSessionID: providerSessionID,
                                    workspaceURL: workspaceURL)
    }
    func send(_ prompt: String, to session: HarnessSessionHandle) async throws { calls.append("send \(prompt)") }
    func interrupt(_ session: HarnessSessionHandle) async throws {}
    func respond(to permissionRequestID: String, decision: PermissionDecision, in session: HarnessSessionHandle) async throws {}
    func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> {
        AsyncStream { _ in }
    }
    func close(_ session: HarnessSessionHandle) async {}
}
