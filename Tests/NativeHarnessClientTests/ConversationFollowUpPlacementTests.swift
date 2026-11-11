import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient
@testable import YardletRemote

/// D13: where a message sent while a turn runs appears, as the Codex app shows it: the running turn
/// takes it (`turn/steer`), so it is part of that turn, drawn in the turn's work where the provider
/// took it rather than at the turn's top. When the turn ends on its answer and its work folds, a
/// message the person wrote stays in view where it was sent, as the Claude app leaves it (2026-10-31;
/// ChatGPT.app 26.1023 folds it with the work, `Tj`), while a message another task sent folds with the
/// work the answer followed. Every harness follows it by the one rule (`ConversationTurnLayout`): a
/// Codex steered message, and a Claude Code follow-up the CLI read at the running turn's next step
/// (`TranscriptEntry.joinsRunningTurn`).
@MainActor
final class ConversationFollowUpPlacementTests: XCTestCase {
    private let decoder = CodexTaskDecoder()
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private static let workspace = URL(filePath: "/tmp/yardlet-follow-up", directoryHint: .isDirectory)

    // MARK: - Engine

    func testACodexMessageSteeredAfterTheWorkBeganIsInTheWork() throws {
        let presentation = CodexConversationProjection.presentation(
            codexThread(finished: true), workspaceURL: Self.workspace, historySelection: nil
        )
        let turn = try XCTUnwrap(presentation.turns.first)
        XCTAssertEqual(turn.prompt.map(\.id), ["u1"])
        XCTAssertEqual(turn.work.map(\.id), ["m1", "c1", "u2", "m2"])
        XCTAssertEqual(turn.answers.map(\.id), ["a1"])
        XCTAssertEqual(turn.workKeptWhenFolded.map(\.id), ["u2"], "the person's message stays in view after the answer")

        // A message another task sent into the turn folds under the answer that followed it.
        let fromTask = TaskMessage(senderID: UUID().uuidString, senderName: "Coordinator", body: "Use Python instead")
        let sentByTask = try XCTUnwrap(CodexConversationProjection.presentation(
            codexThread(finished: true, followUp: fromTask.text(in: .yardlet)),
            workspaceURL: Self.workspace, historySelection: nil
        ).turns.first)
        XCTAssertNotNil(sentByTask.work.first { $0.id == "u2" }?.taskMessage)
        XCTAssertEqual(sentByTask.workKeptWhenFolded.map(\.id), [], "the answer followed the task's message, so it folds")

        // Messages sent before any work are the turn's request, however many.
        var opening = codexThread(finished: true)
        opening.thread?.turns[0].items.swapAt(1, 3)
        let request = try XCTUnwrap(CodexConversationProjection.presentation(
            opening, workspaceURL: Self.workspace, historySelection: nil
        ).turns.first)
        XCTAssertEqual(request.prompt.map(\.id), ["u1", "u2"])
        XCTAssertFalse(request.work.contains { $0.id == "u2" })
    }

    func testAClaudeFollowUpReadIntoTheRunningTurnStaysInThatTurn() throws {
        let entries = claudeEntries(finished: false)
        let presentation = TranscriptConversationProjection.presentation(
            from: entries, harness: .claudeCode, status: .running, latestTurnIsComplete: false
        )
        XCTAssertEqual(presentation.turns.count, 1)
        let turn = try XCTUnwrap(presentation.turns.first)
        XCTAssertEqual(turn.prompt.map(\.id), [entries[0].id.uuidString])
        XCTAssertEqual(turn.work.map(\.id), entries[1...].map(\.id.uuidString))
        XCTAssertEqual(turn.workKeptWhenFolded.map(\.id), [entries[3].id.uuidString], "no answer followed it yet")

        // Once the turn is over, its menu works on the latest message, the one read into it.
        let finished = claudeEntries(finished: true)
        let idle = try XCTUnwrap(TranscriptConversationProjection.presentation(
            from: finished, harness: .claudeCode, status: .ready, latestTurnIsComplete: true
        ).turns.first)
        XCTAssertEqual(idle.actions.editLatest?.entryID, finished[3].id)
        XCTAssertEqual(idle.actions.restoreFiles?.entryID, finished[3].id)
        XCTAssertEqual(idle.answers.map(\.id), [finished[5].id.uuidString])
        XCTAssertEqual(idle.workKeptWhenFolded.map(\.id), [finished[3].id.uuidString], "the person's message stays in view")

        // A message the provider did not read into a running turn still starts a turn of its own.
        var sequential = finished
        sequential[3].joinsRunningTurn = nil
        XCTAssertEqual(TranscriptConversationProjection.presentation(
            from: sequential, harness: .claudeCode, status: .ready, latestTurnIsComplete: true
        ).turns.count, 2)
    }

    /// Last turn spans the whole turn, from its request, a message read into it included.
    func testLastTurnStartsAtTheTurnsRequest() throws {
        let edit = { (id: String, path: String) in
            TranscriptEntry(content: .activity(HarnessActivity(
                id: id, kind: "Write", title: "Write", input: path,
                diff: HarnessActivityDiff(path: path, oldText: nil, newText: "print(1)\n")
            ), state: .completed))
        }
        let request = TranscriptEntry(content: .user(text: "Port the script"))
        let entries = [
            request, edit("w1", "/tmp/yardlet-follow-up/a.py"),
            TranscriptEntry(content: .user(text: "Also b"), joinsRunningTurn: true), edit("w2", "/tmp/yardlet-follow-up/b.py")
        ]
        let diff = try XCTUnwrap(ConversationFileChangeProjection.lastTurnDiff(
            entries: entries, harness: .claudeCode, isRunning: false, workspaceURL: Self.workspace
        ))
        XCTAssertEqual(diff.turnID, request.id.uuidString)
        XCTAssertTrue(diff.text.contains("a.py") && diff.text.contains("b.py"), diff.text)
    }

    /// The saved transcript keeps its shape: the fact is written only for a message read into a
    /// running turn, and entries saved before it read as before.
    func testTheReadingCacheKeepsItsShape() throws {
        let plain = TranscriptEntry(content: .user(text: "Hi"))
        let plainJSON = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        XCTAssertFalse(plainJSON.contains("joinsRunningTurn"), plainJSON)
        let joined = TranscriptEntry(content: .user(text: "Also"), joinsRunningTurn: true)
        XCTAssertEqual(try JSONDecoder().decode(TranscriptEntry.self, from: JSONEncoder().encode(joined)), joined)
        let older = try JSONDecoder().decode(TranscriptEntry.self, from: Data(plainJSON.utf8))
        XCTAssertNil(older.joinsRunningTurn)
        var builder = TranscriptBuilder()
        builder.appendUser("Run it")
        builder.appendUser("Also this", joinsRunningTurn: true)
        XCTAssertEqual(builder.entries.map(\.joinsRunningTurn), [nil, true])
    }

    // MARK: - Drawn

    /// While the turn runs, the steered message is in the work after what came before it. Once the
    /// answer began and the work folds, the message stays where it was and parts the fold: the work
    /// before it folds under the turn header, the work after it on a line of its own under the
    /// message, which opens only that work; the header opens all of it. Each message sent into the
    /// turn parts it so. Codex and Claude Code draw the folded turn in the same pixels.
    func testTheMessageIsDrawnWhereItWasTakenAndPartsTheFold() throws {
        let directory = try WindowlessRender.directory("conversation-m12f-qa")
        let size = NSSize(width: 760, height: 900)
        let request = "Port the script to Swift", answer = "Ported to Python."
        for followUps in [Array(Self.followUps.prefix(1)), Self.followUps] {
            let count = followUps.count
            for stage in Stage.allCases {
                for appearance in WindowlessRender.Appearance.allCases {
                    let codexTimeline = ConversationTimeline(
                        source: .codex(codexThread(stage, followUps: followUps), workspaceURL: Self.workspace,
                                       historySelection: nil),
                        actions: ConversationActions(forkCodexTurn: { _ in })
                    )
                    let claudeTimeline = ConversationTimeline(source: .transcript(
                        entries: claudeEntries(stage, followUps: followUps), harness: .claudeCode,
                        status: stage == .finished ? .ready : .running, latestTurnIsComplete: stage == .finished
                    ), actions: claudeActions())
                    let codex = try ConversationDrawing.draw(codexTimeline, size: size, appearance: appearance)
                    let claude = try ConversationDrawing.draw(claudeTimeline, size: size, appearance: appearance)
                    for (harness, drawing) in [(HarnessKind.codex, codex), (.claudeCode, claude)] {
                        let name = "follow-up-\(count)-\(stage)-\(harness == .codex ? "codex" : "claude-code")"
                        try WindowlessRender.writePNG(
                            drawing.capture.bitmap, to: directory.appending(path: "\(name)-\(appearance.rawValue).png")
                        )
                        let texts = drawing.elements.map(\.description)
                        let joined = texts.joined(separator: "\n")
                        func position(_ text: String) throws -> Int {
                            try XCTUnwrap(texts.firstIndex { $0.contains(text) }, "\(name): \(text)\n\(joined)")
                        }
                        XCTAssertFalse(drawing.elements.contains { ConversationDrawing.isRailTurn($0.label) },
                                       "one turn, not two:\n\(joined)")
                        for followUp in followUps {
                            XCTAssertEqual(texts.filter { $0.contains(followUp.message) }.count, 1, joined)
                        }
                        let turn = try XCTUnwrap(presentation(stage, followUps: followUps, harness: harness).turns.first)
                        guard turn.foldsWork else {
                            // Not folded: everything in the order it happened.
                            XCTAssertNotEqual(stage, .finished, name)
                            let order = try ([request, "Reading the script first."] + followUps.map(\.message)).map(position)
                            XCTAssertEqual(order, order.sorted(), "\(name):\n\(joined)")
                            for followUp in followUps {
                                XCTAssertLessThan(try position(followUp.message), try position(followUp.reply), "\(name):\n\(joined)")
                            }
                            continue
                        }
                        // Folded: the request, the header's fold, then each message with the fold of
                        // the work after it under it, then the answer.
                        let stretches = ConversationDrawOrder.stretches(turn, harness: harness).dropFirst()
                        XCTAssertEqual(stretches.compactMap { $0.message?.id }, turn.work.filter(\.isPersonMessage).map(\.id), name)
                        let header = try XCTUnwrap(drawing.elements.firstIndex {
                            [$0.label, $0.value].contains { ConversationDrawing.isWorkTime($0) || $0 == L10n.string("Work details") }
                        }, joined)
                        var order = [try position(request), header]
                        var searchedFrom = header + 1
                        for followUp in followUps {
                            let message = try position(followUp.message)
                            let fold = try XCTUnwrap(drawing.elements[max(searchedFrom, message)...].firstIndex {
                                $0.label == L10n.string("Work details") && $0.value == L10n.string("Collapsed")
                            }, "\(name): the fold of the work after \(followUp.message)\n\(joined)")
                            order += [message, fold]
                            searchedFrom = fold + 1
                        }
                        order.append(try position(answer))
                        XCTAssertEqual(order, order.sorted(), "\(name), folded:\n\(joined)")
                        for hidden in ["Reading the script first."] + followUps.map(\.reply) {
                            XCTAssertFalse(joined.contains(hidden), "\(name) folds \(hidden):\n\(joined)")
                        }
                        // The phone folds the turn the Mac sends it alike (`RemoteTurnFold`).
                        let remote = RemoteConversationProjection.turn(turn, harness: harness, workspaceURL: nil).items
                        let folds = remote.first { $0.kind == .turn }?.foldsWork == true
                        let phone = RemoteTurnFold.rows(remote, folds: folds).map { row -> String in
                            guard case let .item(item) = row else { return "fold" }
                            return item.kind == .turn ? "header" : "\(item.kind.rawValue): \(item.text ?? "")"
                        }
                        XCTAssertEqual(phone, ["user: \(request)", "header"] + followUps.flatMap { ["user: \($0.message)", "fold"] }
                                       + ["assistant: \(answer)"], name)
                        let first = try XCTUnwrap(remote.first { $0.kind == .user && $0.text == followUps[0].message })
                        let opened = RemoteTurnFold.rows(remote, folds: folds, opened: [first.id])
                        XCTAssertTrue(opened.contains { if case let .item(item) = $0 { item.text == followUps[0].reply } else { false } },
                                      "\(name): the phone opens the work after the first message")
                        XCTAssertFalse(opened.contains { if case let .item(item) = $0 { item.text == "Reading the script first." } else { false } },
                                       "\(name): the phone keeps the work before it folded")
                        if stage == .answering {
                            XCTAssertLessThan(try position(answer), try position(L10n.string("Working")),
                                              "\(name): the live line under the answer\n\(joined)")
                        }
                    }
                    if stage == .finished {
                        XCTAssertEqual(ConversationDrawing.differingBytes(codex.capture.bitmap, claude.capture.bitmap), 0,
                                       "Codex and Claude Code draw the folded turn differently (\(count) messages)")
                        try openFolds(codexTimeline, followUps: followUps, size: size, appearance: appearance,
                                      directory: directory)
                    }
                }
            }
        }
    }

    /// The fold under the first message opens only the work after it, in place; the header then opens
    /// all the work, in the order it happened.
    private func openFolds(_ timeline: ConversationTimeline, followUps: [FollowUp], size: NSSize,
                           appearance: WindowlessRender.Appearance, directory: URL) throws {
        let name = "follow-up-\(followUps.count)-finished-codex"
        let host = WindowlessRender.Host(
            timeline.environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(ParityTheme.canvas),
            size: size, appearance: appearance
        )
        defer { host.close() }
        host.settle(passes: 10)
        // The header reads the work time, so the first "Work details" is the fold under the first message.
        XCTAssertTrue(host.hosting.pressButton(labeled: L10n.string("Work details")), name)
        host.settle(passes: 10)
        try WindowlessRender.writePNG(try host.capture().bitmap,
                                      to: directory.appending(path: "\(name)-message-opened-\(appearance.rawValue).png"))
        var texts = host.accessibilityElements().map(\.description)
        var joined = texts.joined(separator: "\n")
        XCTAssertFalse(joined.contains("Reading the script first."), "the work before the message stays folded:\n\(joined)")
        for later in followUps.dropFirst() {
            XCTAssertFalse(joined.contains(later.reply), "the work after a later message stays folded:\n\(joined)")
        }
        func positions(_ order: [String]) throws -> [Int] {
            try order.map { text in try XCTUnwrap(texts.firstIndex { $0.contains(text) }, "\(name): \(text)\n\(joined)") }
        }
        let opened = try positions([followUps[0].message, followUps[0].reply] + followUps.dropFirst().map(\.message)
                                   + ["Ported to Python."])
        XCTAssertEqual(opened, opened.sorted(), "\(name), the message's work opened:\n\(joined)")

        XCTAssertTrue(host.hosting.pressTurnHeader(), name)
        host.settle(passes: 10)
        try WindowlessRender.writePNG(try host.capture().bitmap,
                                      to: directory.appending(path: "\(name)-all-opened-\(appearance.rawValue).png"))
        texts = host.accessibilityElements().map(\.description)
        joined = texts.joined(separator: "\n")
        let all = try positions(["Port the script to Swift", "Reading the script first."]
                                + followUps.flatMap { [$0.message, $0.reply] } + ["Ported to Python."])
        XCTAssertEqual(all, all.sorted(), "\(name), all opened:\n\(joined)")
    }

    // MARK: - Fixtures

    private enum Stage: String, CaseIterable {
        /// The turn works on after the message, with no answer yet.
        case working
        /// The closing answer streams.
        case answering
        case finished
    }

    /// A message the person steers into the turn, what the provider wrote after reading it, and
    /// the command it ran after that, before the next message.
    private struct FollowUp {
        let message: String
        let reply: String
        let command: String
    }

    private static let followUps = [
        FollowUp(message: "Use Python instead", reply: "Switching to Python.", command: "python3 port.py"),
        FollowUp(message: "Keep the tests too", reply: "Porting the tests as well.", command: "python3 -m pytest")
    ]

    private func presentation(_ stage: Stage, followUps: [FollowUp], harness: HarnessKind) -> ConversationPresentation {
        harness == .codex
            ? CodexConversationProjection.presentation(codexThread(stage, followUps: followUps), workspaceURL: Self.workspace,
                                                       historySelection: nil)
            : TranscriptConversationProjection.presentation(
                from: claudeEntries(stage, followUps: followUps), harness: .claudeCode,
                status: stage == .finished ? .ready : .running, latestTurnIsComplete: stage == .finished
            )
    }

    /// A request, working notes, a command, a message steered in, and (once finished) the answer.
    private func codexThread(finished: Bool, followUp: String = "Use Python instead") -> CodexTaskState {
        codexThread(finished ? .finished : .working,
                    followUps: [FollowUp(message: followUp, reply: "Switching to Python.", command: "")])
    }

    /// A request, a working note and a command, then each message steered in with the note written
    /// after it and, before the next message, a command; then the closing answer, while it streams
    /// or once finished.
    private func codexThread(_ stage: Stage, followUps: [FollowUp]) -> CodexTaskState {
        var items: [JSONValue] = [
            user("u1", "Port the script to Swift"),
            commentary("m1", "Reading the script first."),
            command("c1", "cat script.sh")
        ]
        for (index, followUp) in followUps.enumerated() {
            items.append(user("u\(index + 2)", followUp.message))
            items.append(commentary("m\(index + 2)", followUp.reply))
            if index < followUps.count - 1 { items.append(command("c\(index + 2)", followUp.command)) }
        }
        if stage != .working {
            items.append(.object(["id": .string("a1"), "type": .string("agentMessage"), "text": .string("Ported to Python."),
                                  "phase": .string("final_answer")]))
        }
        var turn: [String: JSONValue] = [
            "id": .string("turn-1"), "status": .string(stage == .finished ? "completed" : "inProgress"), "items": .array(items)
        ]
        // The time Claude Code's entries of the same turn span, a second apart.
        if stage == .finished { turn["durationMs"] = .integer(Int64(2 + 3 * followUps.count) * 1_000) }
        var thread = decoder.thread(from: .object(["id": .string("thread-follow-up")]))!
        thread.turns = [decoder.turn(from: .object(turn), fallbackID: "turn-1")!]
        return CodexTaskState(thread: thread)
    }

    private func user(_ id: String, _ text: String) -> JSONValue {
        .object(["id": .string(id), "type": .string("userMessage"),
                 "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
    }

    private func commentary(_ id: String, _ text: String) -> JSONValue {
        .object(["id": .string(id), "type": .string("agentMessage"), "text": .string(text), "phase": .string("commentary")])
    }

    private func command(_ id: String, _ command: String) -> JSONValue {
        .object(["id": .string(id), "type": .string("commandExecution"), "command": .string(command),
                 "cwd": .string(Self.workspace.path), "status": .string("completed"), "commandActions": .array([]),
                 "aggregatedOutput": .string("ok\n"), "exitCode": .integer(0)])
    }

    /// The same turn as Claude Code records it: the follow-up the CLI read at the turn's next step
    /// joins the running turn.
    private func claudeEntries(finished: Bool) -> [TranscriptEntry] {
        claudeEntries(finished ? .finished : .working, followUps: Array(Self.followUps.prefix(1)))
    }

    private func claudeEntries(_ stage: Stage, followUps: [FollowUp]) -> [TranscriptEntry] {
        var seconds = 0.0
        func next(_ content: TranscriptEntryContent, joins: Bool? = nil) -> TranscriptEntry {
            defer { seconds += 1 }
            return TranscriptEntry(createdAt: start.addingTimeInterval(seconds), content: content, joinsRunningTurn: joins)
        }
        func bash(_ id: String, _ command: String) -> TranscriptEntry {
            next(.activity(HarnessActivity(id: id, kind: "Bash", title: "Bash", input: command, output: "ok\n"),
                           state: .completed))
        }
        var entries = [
            next(.user(text: "Port the script to Swift")),
            next(.assistant(text: "Reading the script first.", isStreaming: false)),
            bash("toolu_bash", "cat script.sh")
        ]
        for (index, followUp) in followUps.enumerated() {
            entries.append(next(.user(text: followUp.message), joins: true))
            let isLast = index == followUps.count - 1
            entries.append(next(.assistant(text: followUp.reply, isStreaming: stage == .working && isLast)))
            if !isLast { entries.append(bash("toolu_bash_\(index)", followUp.command)) }
        }
        if stage != .working {
            entries.append(next(.assistant(text: "Ported to Python.", isStreaming: stage == .answering)))
        }
        return entries
    }

    private func claudeActions() -> ConversationActions {
        var actions = ConversationActions(rewind: ConversationRewindActions(
            beginCodexEdit: { _ in }, beginClaudeEdit: { _ in }, cancelEdit: {}, loadFilePoints: { [] },
            previewFiles: { _ in throw CancellationError() }, restoreFiles: { _ in throw CancellationError() }
        ))
        actions.branch = { _ in }
        return actions
    }
}
