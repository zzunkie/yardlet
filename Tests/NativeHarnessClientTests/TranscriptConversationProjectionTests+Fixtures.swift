import Foundation
import XCTest
@testable import NativeHarnessClient

/// The common-transcript projection over every shared transcript the fixtures reach
/// (`TranscriptProjectionFixtures`), in every session context: nothing is lost or drawn twice, the
/// turn menu's rules land on the same entries, and the cache follows every step.
extension TranscriptConversationProjectionTests {
    /// Every entry is held by exactly one turn, in transcript order, and each turn is named by its
    /// first entry; an allowed request whose call has a card is the mark on that card instead.
    func testEveryFixtureEntryIsHeldOnceInTranscriptOrder() throws {
        var fixtures = try Self.fixtures()
        fixtures += TranscriptProjectionFixtures.builderSequences().map { ("request + " + $0.0, [TranscriptProjectionFixtures.request] + $0.1) }
        fixtures += try TranscriptProjectionFixtures.claudeSessionFrames().map {
            ("request + " + $0.0, [TranscriptProjectionFixtures.request] + $0.1)
        }
        #if DEBUG
        let source = ConversationFixtures.conversation().sessions[0]
        for fixture in try TranscriptProjectionFixtures.visualFixtures() {
            fixtures.append(("side chat of " + fixture.name,
                             SideChatContext(source: source, entries: fixture.entries).readingEntries))
            // In the context the fixture's own task gives it.
            assertHoldsEveryEntry(fixture.entries, fixture.name,
                                  context: (fixture.harness, fixture.status, fixture.latestTurnIsComplete))
        }
        // A context cut to its newest part can start with an answer, before any request.
        let first = try XCTUnwrap(TranscriptProjectionFixtures.visualFixtures().first)
        fixtures.append(("partial side chat",
                         SideChatContext(source: source, entries: first.entries, characterLimit: 40).readingEntries))
        #endif
        for (name, entries) in fixtures {
            for context in Self.contexts { assertHoldsEveryEntry(entries, name, context: context) }
        }
    }

    /// The recorded Send now run ends as two turns: the command's, and the read message's with both
    /// answers.
    func testTheClaudeSendNowRunEndsAsTwoTurns() throws {
        let snapshots = try TranscriptProjectionFixtures.sendNowFrames()
        let last = try XCTUnwrap(snapshots.last?.1)
        let presentation = TranscriptConversationProjection.presentation(
            from: last, harness: .claudeCode, status: .ready, latestTurnIsComplete: true
        )
        XCTAssertEqual(presentation.turns.count, 2)
        XCTAssertEqual(presentation.turns.last?.answers.count, 1)
        XCTAssertEqual(presentation.turns.last?.work.count, 1, "NOW_OK is commentary before the notification's answer")
    }

    /// The turn menu's edit and file restore, and the error card's "Edit request", land on the entries
    /// the rules name (written out here as the oracle, without the host's own "has the action" check,
    /// which stays with the actions): Claude edits its latest request while idle, never a bash
    /// command; file restore stays on the latest message; "Edit request" puts back the failed request
    /// `TranscriptRecoveryProjection.editableRequest` names.
    func testTheTurnMenuRulesLandOnTheSameEntriesInEveryFixture() throws {
        var offered = (edit: 0, restore: 0, failed: 0)
        for (name, entries) in try Self.fixtures() {
            for harness in [HarnessKind.claudeCode, .openCode] {
                for status in [SessionStatus.ready, .running, .waitingForApproval, .failed] {
                    let latestRequest = entries.last { if case .user = $0.content { true } else { false } }
                    let latestMessage = entries.last {
                        if case let .user(text, _) = $0.content { ClaudeBashMessage.parse(text) == nil } else { false }
                    }
                    var edit: [UUID: String] = [:], restore: Set<UUID> = [], failed: [UUID: String] = [:]
                    for entry in entries {
                        if harness == .claudeCode, status != .running, status != .waitingForApproval,
                           entry.id == latestRequest?.id, case let .user(text, _) = entry.content,
                           ClaudeBashMessage.parse(text) == nil {
                            edit[entry.id] = text
                        }
                        if harness == .claudeCode, entry.id == latestMessage?.id { restore.insert(entry.id) }
                        if let text = TranscriptRecoveryProjection.editableRequest(for: entry.id, entries: entries, status: status) {
                            failed[entry.id] = text
                        }
                    }
                    let presentation = TranscriptConversationProjection.presentation(
                        from: entries, harness: harness, status: status, latestTurnIsComplete: false
                    )
                    var newEdit: [UUID: String] = [:], newRestore: Set<UUID> = [], newFailed: [UUID: String] = [:]
                    for turn in presentation.turns {
                        if let target = turn.actions.editLatest {
                            XCTAssertEqual(target.entryID.uuidString, turn.id, "\(name): the turn's own request")
                            newEdit[target.entryID] = target.text
                        }
                        if let target = turn.actions.restoreFiles {
                            XCTAssertEqual(target.entryID.uuidString, turn.id, "\(name): the turn's own request")
                            newRestore.insert(target.entryID)
                        }
                        if let draft = turn.actions.failedRequestDraft, case let .error(error)? = turn.outcome,
                           let entryID = error.entryID {
                            XCTAssertEqual(draft.inputs.count, 1, name)
                            if case let .text(text, _)? = draft.inputs.first { newFailed[entryID] = text }
                        }
                    }
                    let label = "\(name) — \(harness.rawValue), \(status)"
                    XCTAssertEqual(newEdit, edit, label)
                    XCTAssertEqual(newRestore, restore, label)
                    XCTAssertEqual(newFailed, failed, label)
                    offered.edit += edit.count
                    offered.restore += restore.count
                    offered.failed += failed.count
                }
            }
        }
        XCTAssertGreaterThan(offered.edit, 0)
        XCTAssertGreaterThan(offered.restore, 0)
        XCTAssertGreaterThan(offered.failed, 0)
    }

    /// The cache follows every step of every replayed sequence and keeps returning what a fresh
    /// projection makes, projecting again only the turns a step touched.
    func testTheCacheFollowsEveryStepOfEverySequence() throws {
        let sequences: [(String, [(String, [TranscriptEntry])])] = [
            ("builder", TranscriptProjectionFixtures.builderSequences()),
            ("Claude frames", try TranscriptProjectionFixtures.claudeSessionFrames()),
            ("send now", try TranscriptProjectionFixtures.sendNowFrames())
        ]
        for (name, snapshots) in sequences {
            for (harness, status) in [(HarnessKind.claudeCode, SessionStatus.running), (.openCode, .ready)] {
                let cache = ConversationProjectionCache()
                var turnCount = 0
                for (step, entries) in snapshots {
                    let cached = cache.transcript(entries, harness: harness, status: status, latestTurnIsComplete: false)
                    XCTAssertEqual(cached, TranscriptConversationProjection.presentation(
                        from: entries, harness: harness, status: status, latestTurnIsComplete: false
                    ), "\(name): \(step)")
                    turnCount += cached.turns.count
                }
                XCTAssertEqual(cache.counts.reused + cache.counts.projected, turnCount, name)
                XCTAssertGreaterThan(cache.counts.reused, 0, "\(name): unchanged turns are kept")
            }
        }
    }

    /// A turn keeps its latest plan. The builder replaces a turn's plan in place, so only a
    /// transcript put together elsewhere has two in one turn.
    func testATurnKeepsItsLatestPlan() {
        let request = TranscriptProjectionFixtures.request
        let first = TranscriptEntry(content: .plan("☐ Inspect"))
        let second = TranscriptEntry(content: .plan("☑ Inspect"))
        let answer = TranscriptEntry(content: .assistant(text: "Done.", isStreaming: false))
        let presentation = TranscriptConversationProjection.presentation(
            from: [request, first, second, answer], harness: .claudeCode, status: .ready, latestTurnIsComplete: true
        )
        XCTAssertEqual(presentation.turns.first?.plan?.source, .transcript(second))
        XCTAssertEqual(presentation.turns.first?.answers.map(\.id), [answer.id.uuidString])
    }

    /// D2: a finished turn folds a call that failed or stopped with the rest of its work, as Codex
    /// does, and an earlier limit it went past (2026-10-23, the Codex app's fold for every harness). An
    /// error the turn ended on leaves it no answer, and work still going keeps it open.
    func testAFinishedTurnFoldsItsFailedAndStoppedCalls() {
        let request = TranscriptProjectionFixtures.request
        func call(_ id: String, _ state: TranscriptActivityState) -> TranscriptEntry {
            TranscriptEntry(content: .activity(HarnessActivity(id: id, kind: "Read", title: "Read"), state: state))
        }
        let answer = TranscriptEntry(content: .assistant(text: "Done.", isStreaming: false))
        let limit = TranscriptEntry(content: .usageLimit(HarnessRateLimit(status: .rejected)))
        for (name, entries) in [
            ("failed", [request, call("read", .failed), answer]), ("stopped", [request, call("read", .stopped), answer]),
            ("a limit gone past", [request, limit, call("read", .failed), answer])
        ] {
            let turn = TranscriptConversationProjection.presentation(
                from: entries, harness: .claudeCode, status: .ready, latestTurnIsComplete: true
            ).turns[0]
            XCTAssertTrue(turn.foldsWork, name)
            XCTAssertTrue(turn.showsHeader, name)
            if name == "a limit gone past" {
                XCTAssertNotNil(turn.outcome, "the limit card is the turn's, drawn above the fold")
            }
        }
        let error = TranscriptEntry(content: .error(message: "Failed", recoverable: true))
        for (name, entries) in [
            ("an error", [request, call("read", .failed), error]),
            ("a running call", [request, call("read", .running), answer])
        ] {
            let turn = TranscriptConversationProjection.presentation(
                from: entries, harness: .claudeCode, status: .ready, latestTurnIsComplete: true
            ).turns[0]
            XCTAssertFalse(turn.foldsWork, name)
        }
    }

    // MARK: - Fixtures

    private static let contexts: [(HarnessKind, SessionStatus, Bool)] = [HarnessKind.claudeCode, .openCode].flatMap { harness in
        [SessionStatus.ready, .running, .waitingForApproval, .failed].flatMap { status in
            [false, true].map { (harness, status, $0) }
        }
    }

    private static func fixtures() throws -> [(String, [TranscriptEntry])] {
        var fixtures = TranscriptProjectionFixtures.folding()
            + TranscriptProjectionFixtures.edgeCases()
            + TranscriptProjectionFixtures.builderSequences()
            + (try TranscriptProjectionFixtures.claudeSessionFrames())
            + (try TranscriptProjectionFixtures.sendNowFrames())
            + (try TranscriptProjectionFixtures.subagentReaderRecords())
        #if DEBUG
        fixtures += try TranscriptProjectionFixtures.visualFixtures().map { ($0.name, $0.entries) }
        #endif
        return fixtures
    }

    private func assertHoldsEveryEntry(
        _ entries: [TranscriptEntry], _ name: String, context: (HarnessKind, SessionStatus, Bool),
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let (harness, status, latestTurnIsComplete) = context
        let label = "\(name) — \(harness.rawValue), \(status), complete=\(latestTurnIsComplete)"
        let presentation = TranscriptConversationProjection.presentation(
            from: entries, harness: harness, status: status, latestTurnIsComplete: latestTurnIsComplete
        )
        let approved = TranscriptConversationProjection.approvedToolCallIDs(in: entries)
        let expected = entries.filter { entry in
            guard case let .permission(request, .allowed) = entry.content, request.structured == nil,
                  let toolCallID = request.toolCallID else { return true }
            return !approved.contains(toolCallID)
        }.map(\.id)
        let position = Dictionary(entries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var held: [UUID] = []
        for turn in presentation.turns {
            for item in turn.prompt + turn.notices + turn.work + turn.answers {
                guard case let .transcript(entry) = item.source, item.id == entry.id.uuidString else {
                    XCTFail("\(label): \(item.id) is not its transcript entry's ID", file: file, line: line)
                    continue
                }
            }
            let ids = Self.heldEntryIDs(turn).sorted { (position[$0] ?? .max) < (position[$1] ?? .max) }
            XCTAssertEqual(ids.first?.uuidString, turn.id, "\(label): a turn is named by its first entry",
                           file: file, line: line)
            held += ids
        }
        XCTAssertEqual(held, expected, label, file: file, line: line)
    }

    /// Every entry a turn holds: its prompt, plan, work and answers, its waiting requests and its
    /// outcome.
    private static func heldEntryIDs(_ turn: ConversationTurn) -> [UUID] {
        func entryID(_ source: ConversationItemSource?) -> UUID? {
            if case let .transcript(entry)? = source { return entry.id }
            return nil
        }
        var held = (turn.prompt + turn.notices + turn.work + turn.answers).compactMap { entryID($0.source) }
        if let plan = entryID(turn.plan?.source) { held.append(plan) }
        for request in turn.requests {
            if case let .transcript(entry) = request.source { held.append(entry.id) }
        }
        switch turn.outcome {
        case let .error(error)?: if let id = error.entryID { held.append(id) }
        case let .usageLimit(_, entryID)?: held.append(entryID)
        case nil: break
        }
        return held
    }
}
