import AppKit
import Foundation
import SwiftTerm
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Continuing the turns a quit or an update cut off. Claude Code and Codex tasks follow the Claude
/// app's rules (any quit, a day, four at once), the choice for Codex (always, as the Claude app does)
/// over the Codex app's update-only 15 minutes, and Yardlet's adjustments of 2026-10-23: the rest
/// continue in turn rather than when opened, and a quit writes down an unseen continuation again a
/// few times. Each provider is still asked the way its own app asks it. What the quit writes down,
/// what the next launch continues and when, the setting that turns it off, each provider's
/// continuation on the wire, and the quit confirmation that says which tasks continue.
@MainActor
final class RestartResumeTests: XCTestCase {
    // MARK: - What the quit writes down

    func testTheQuitRecordsClaudeAndCodexTurnsByTheSameRules() {
        let claude = task(.claudeCode, status: .running)
        let waiting = task(.claudeCode, status: .waitingForApproval)
        let codex = task(.codex, status: .running)
        let codexWaiting = task(.codex, status: .waitingForApproval)
        let claudeQueued = task(.claudeCode, status: .running)
        let codexQueued = task(.codex, status: .running)
        let claudeUnseenTwice = task(.claudeCode, status: .running)
        let codexUnseenOnce = task(.codex, status: .running)
        let candidates: [RestartResumePolicy.Candidate] = [
            .init(session: claude),
            .init(session: waiting),
            .init(session: task(.claudeCode, status: .ready)),
            .init(session: task(.claudeCode, status: .completed)),
            .init(session: task(.claudeCode, status: .failed)),
            .init(session: task(.claudeCode, status: .running, providerSessionID: nil)),
            .init(session: claudeQueued, hasQueuedMessages: true),
            .init(session: task(.claudeCode, status: .running), stoppedByPerson: true),
            .init(session: claudeUnseenTwice, unseenContinuations: 2),
            .init(session: task(.claudeCode, status: .running), unseenContinuations: 3),
            .init(session: codex),
            .init(session: codexWaiting),
            .init(session: task(.codex, status: .running), isSubagentThread: true),
            .init(session: codexQueued, hasQueuedMessages: true),
            .init(session: task(.codex, status: .running), stoppedByPerson: true),
            .init(session: codexUnseenOnce, unseenContinuations: 1),
            .init(session: task(.codex, status: .running), unseenContinuations: 3),
            .init(session: task(.codex, status: .ready)),
            .init(session: task(.codex, status: .completed)),
            .init(session: task(.antigravityCLI, status: .running)),
            .init(session: task(.cursorAgent, status: .running)),
            .init(session: task(.openCode, status: .running)),
        ]

        let entries = RestartResumePolicy.entries(for: candidates, isOn: true)
        XCTAssertEqual(entries.map(\.sessionID), [claude.id, waiting.id, claudeQueued.id, claudeUnseenTwice.id,
                                                  codex.id, codexWaiting.id, codexQueued.id, codexUnseenOnce.id],
            "Any quit continues Claude Code and Codex tasks alike; subagent threads, stopped turns, a third unseen continuation and other harnesses aside")
        XCTAssertEqual(entries.map(\.wasWaitingForApproval), [false, true, false, false, false, true, false, false])
        XCTAssertEqual(entries.map(\.sendsQueuedMessages), [nil, nil, true, nil, nil, nil, true, nil],
            "A task with waiting messages sends the first of them as its next turn")
        XCTAssertEqual(entries.map(\.unseenContinuations), [nil, nil, nil, 2, nil, nil, nil, 1],
            "A turn Yardlet continued unseen is written down again with how many times in a row it has been")
        XCTAssertEqual(entries.map(\.interruptedAt), Array(repeating: nil, count: 8), "Cut off by this quit")
        XCTAssertEqual(entries.first?.lastActiveAt, claude.updatedAt, "Each keeps its last activity for the launch's order")
        XCTAssertEqual(entries.first?.providerSessionID, claude.providerSessionID)
        XCTAssertEqual(entries.first?.connection, claude.connection)
        XCTAssertEqual(entries[4].providerSessionID, codex.providerSessionID)

        XCTAssertTrue(RestartResumePolicy.entries(for: candidates, isOn: false).isEmpty,
            "The setting off writes nothing down")
    }

    func testTheRecordIsKeptInYardletsPreferencesAndAnEmptyOneIsRemoved() throws {
        let defaults = try suite()
        let entry = RestartResumeRecord.Entry(sessionID: UUID(), harness: .claudeCode, providerSessionID: "p",
            connection: nil, wasWaitingForApproval: false)
        let record = RestartResumeRecord(trigger: .update, recordedAt: Date(timeIntervalSince1970: 1_000), entries: [entry])
        record.save(to: defaults)
        XCTAssertEqual(RestartResumeRecord.load(from: defaults), record)
        RestartResumeRecord(trigger: .quit, recordedAt: Date(), entries: []).save(to: defaults)
        XCTAssertNil(defaults.object(forKey: RestartResumeRecord.preferenceKey), "Nothing to continue leaves no record")
        record.save(to: defaults)
        RestartResumeRecord.remove(from: defaults)
        XCTAssertNil(RestartResumeRecord.load(from: defaults))
        XCTAssertTrue(RestartResumePreference.isOn(in: defaults), "On unless turned off, as both apps behave")
        defaults.set(false, forKey: RestartResumePreference.key)
        XCTAssertFalse(RestartResumePreference.isOn(in: defaults))
    }

    // MARK: - What the next launch continues

    func testTheLaunchContinuesEveryCutOffTaskMostRecentFirstAndThoseWaitingOnThePersonWhenOpened() {
        let recordedAt = Date(timeIntervalSince1970: 1_000_000)
        // Claude tasks updated at +0…+4 and Codex tasks at +1.5 and +3.5, so the newest four mix both.
        let claude = (0..<5).map { index in
            task(.claudeCode, status: .ready, updatedAt: recordedAt.addingTimeInterval(Double(index)))
        }
        let codex = [1.5, 3.5].map { offset in
            task(.codex, status: .ready, updatedAt: recordedAt.addingTimeInterval(offset))
        }
        let waiting = task(.claudeCode, status: .ready, updatedAt: recordedAt.addingTimeInterval(10))
        let codexWaiting = task(.codex, status: .ready, updatedAt: recordedAt.addingTimeInterval(11))
        let sessions = claude + codex + [waiting, codexWaiting]
        for trigger in [RestartTrigger.quit, .update] {
            let record = RestartResumeRecord(trigger: trigger, recordedAt: recordedAt, entries:
                sessions.map { entry(for: $0, waiting: $0.id == waiting.id || $0.id == codexWaiting.id) })

            let soon = RestartResumePolicy.plan(for: record, sessions: sessions, now: recordedAt.addingTimeInterval(60), isOn: true)
            XCTAssertEqual(soon.atLaunch, [claude[4].id, codex[1].id, claude[3].id, claude[2].id, codex[0].id,
                                           claude[1].id, claude[0].id],
                "Every one of both, the most recent first, rather than four and the rest when opened (\(trigger))")
            let deadline = recordedAt.addingTimeInterval(RestartResumePolicy.maxAge)
            XCTAssertEqual(soon.whenOpened, [waiting.id: deadline, codexWaiting.id: deadline],
                "The ones that waited on the person continue when opened within the day")
            XCTAssertEqual(Set(soon.entries.keys), Set(sessions.map(\.id)))
            XCTAssertEqual(Set(soon.entries.values.map(\.interruptedAt)), [recordedAt],
                "Each keeps when its turn was cut off, for a later quit to carry over")

            // Reading the index back at launch moves every cut-off task's time to the launch, in no
            // particular order; the record's last activity still orders them.
            var recorded = record.entries
            for index in recorded.indices {
                recorded[index].lastActiveAt = sessions.first { $0.id == recorded[index].sessionID }?.updatedAt
            }
            let restored = sessions.reversed().enumerated().map { offset, session in
                var session = session
                session.updatedAt = recordedAt.addingTimeInterval(3_600 + Double(offset))
                return session
            }
            let relaunched = RestartResumePolicy.plan(
                for: RestartResumeRecord(trigger: trigger, recordedAt: recordedAt, entries: recorded),
                sessions: restored, now: recordedAt.addingTimeInterval(60), isOn: true)
            XCTAssertEqual(relaunched.atLaunch, soon.atLaunch)

            let later = RestartResumePolicy.plan(for: record, sessions: sessions, now: recordedAt.addingTimeInterval(20 * 60), isOn: true)
            XCTAssertEqual(later, soon, "Codex no longer gives up after the Codex app's 15 minutes")

            let nextDay = RestartResumePolicy.plan(for: record, sessions: sessions, now: recordedAt.addingTimeInterval(25 * 60 * 60), isOn: true)
            XCTAssertEqual(nextDay, RestartResumePolicy.Plan(), "Both give up after a day, as the Claude app")

            XCTAssertEqual(RestartResumePolicy.plan(for: record, sessions: sessions, now: recordedAt, isOn: false),
                RestartResumePolicy.Plan(), "The setting off continues nothing")
        }
    }

    func testTheLaunchContinuesOnlyTasksStillAsTheQuitLeftThem() {
        let recordedAt = Date()
        let moved = task(.claudeCode, status: .ready)
        var changedConversation = task(.claudeCode, status: .ready)
        var changedAccount = task(.claudeCode, status: .ready)
        let running = task(.claudeCode, status: .running)
        let record = RestartResumeRecord(trigger: .quit, recordedAt: recordedAt, entries:
            [moved, changedConversation, changedAccount, running].map { entry(for: $0) }
            + [entry(for: task(.claudeCode, status: .ready))])
        changedConversation.providerSessionID = "another"
        changedAccount.connection = ProviderConnection(id: "other", name: "Other", harness: .claudeCode,
            providerID: nil, homePath: "/tmp/other", credentialSelector: nil)
        let plan = RestartResumePolicy.plan(for: record, sessions: [moved, changedConversation, changedAccount, running],
            now: recordedAt, isOn: true)
        XCTAssertEqual(plan.atLaunch, [moved.id], "A changed conversation, account, a running task and a missing one stay")
        XCTAssertTrue(plan.whenOpened.isEmpty)
    }

    /// A quit before the last launch got to every task writes the rest down again, each still due a
    /// day after its turn was cut off (2026-10-22 22:50 and 22:52: two updates in a row).
    func testAQuitCarriesOverWhatTheLastLaunchHadNotContinuedYet() {
        let firstQuit = Date(timeIntervalSince1970: 1_000_000)
        let now = firstQuit.addingTimeInterval(120)
        let inLine = task(.claudeCode, status: .ready)
        let waitingOnPerson = task(.codex, status: .ready)
        let runningAgain = task(.claudeCode, status: .running)
        let stale = task(.claudeCode, status: .ready)
        let cutNow = task(.codex, status: .running)
        func carried(_ session: SessionRecord, at interruptedAt: Date, waiting: Bool = false,
                     unseen: Int? = nil) -> RestartResumeRecord.Entry {
            var entry = entry(for: session, waiting: waiting)
            entry.interruptedAt = interruptedAt
            entry.unseenContinuations = unseen
            return entry
        }
        let stillToContinue = [
            carried(inLine, at: firstQuit, unseen: 1),
            carried(waitingOnPerson, at: firstQuit, waiting: true),
            carried(runningAgain, at: firstQuit),
            carried(stale, at: now.addingTimeInterval(-RestartResumePolicy.maxAge)),
            carried(task(.claudeCode, status: .ready), at: firstQuit),
        ]
        let candidates = [inLine, waitingOnPerson, runningAgain, stale, cutNow].map { RestartResumePolicy.Candidate(session: $0) }

        let entries = RestartResumePolicy.entries(for: candidates, stillToContinue: stillToContinue, now: now, isOn: true)
        XCTAssertEqual(entries.map(\.sessionID), [runningAgain.id, cutNow.id, inLine.id, waitingOnPerson.id],
            "The turns cut off now, then those not continued yet; a day old or gone, they go")
        XCTAssertEqual(entries.map(\.interruptedAt), [nil, nil, firstQuit, firstQuit])
        XCTAssertEqual(entries[3].wasWaitingForApproval, true, "One that waits on the person still does")
        XCTAssertEqual(entries[2].unseenContinuations, 1, "The count goes with it")
        XCTAssertTrue(RestartResumePolicy.entries(for: candidates, stillToContinue: stillToContinue, now: now, isOn: false).isEmpty)

        // The next launch counts the day from the first quit for those, and from this one for the rest.
        let record = RestartResumeRecord(trigger: .update, recordedAt: now, entries: entries)
        let ready = [inLine, waitingOnPerson, runningAgain, cutNow].map { session in
            var session = session
            session.status = .ready
            return session
        }
        let plan = RestartResumePolicy.plan(for: record, sessions: ready, now: now.addingTimeInterval(60), isOn: true)
        XCTAssertEqual(Set(plan.atLaunch), [inLine.id, runningAgain.id, cutNow.id])
        XCTAssertEqual(plan.whenOpened, [waitingOnPerson.id: firstQuit.addingTimeInterval(RestartResumePolicy.maxAge)])
        XCTAssertEqual(plan.entries[cutNow.id]?.interruptedAt, now)
        let late = RestartResumePolicy.plan(for: record, sessions: ready,
            now: firstQuit.addingTimeInterval(RestartResumePolicy.maxAge + 1), isOn: true)
        XCTAssertEqual(Set(late.atLaunch), [runningAgain.id, cutNow.id], "The first quit's day is over for those it cut off")
        XCTAssertTrue(late.whenOpened.isEmpty)
    }

    func testTheLineStartsAFewAtATimeInOrder() {
        let ids = (0..<5).map { _ in UUID() }
        var line = RestartResumeLine(limit: 2)
        line.append(ids)
        line.append([ids[0]])
        XCTAssertEqual(line.waiting, ids, "A task is in line once")
        XCTAssertEqual(line.next(), ids[0])
        XCTAssertEqual(line.next(), ids[1])
        XCTAssertNil(line.next(), "No more than the limit start at once")
        XCTAssertEqual(line.starting, [ids[0], ids[1]])

        XCTAssertTrue(line.finishStarting(ids[1]))
        XCTAssertFalse(line.finishStarting(ids[1]))
        XCTAssertEqual(line.next(), ids[2], "A free place goes to the next in line")
        XCTAssertTrue(line.removeWaiting(ids[4]), "Opened first, it leaves the line")
        XCTAssertFalse(line.removeWaiting(ids[2]), "One already starting is not waiting")
        XCTAssertNil(line.next())
        line.finishStarting(ids[0])
        XCTAssertEqual(line.next(), ids[3])
        XCTAssertNil(line.next())
        XCTAssertTrue(line.waiting.isEmpty)
        XCTAssertEqual(RestartResumeLine().limit, 4, "Four at once, as the Claude app's launch pass")
    }

    // MARK: - Claude Code's session jobs

    /// What CLI 2.1.299 brings back on resuming a conversation (`xi`/`Mi`): each job
    /// whose call is among the records it resumes, or in the last compaction note, until a recurring
    /// one is a week old or a one-shot one's time has passed. A deleted, durable or failed one, and one
    /// a compaction note ended, never.
    func testTheCLIBringsBackTheSessionJobsOfTheRecordsItResumes() throws {
        let now = Date()
        let made = now.addingTimeInterval(-3_600)
        func pinned(_ date: Date) -> String {
            let parts = Calendar.current.dateComponents([.minute, .hour, .day, .month], from: date)
            return "\(parts.minute!) \(parts.hour!) \(parts.day!) \(parts.month!) *"
        }
        func job(_ call: String, _ id: String, cron: String = "7,22,37,52 * * * *", recurring: Bool = true,
                 durable: Bool = false, error: Bool = false, at date: Date) -> [[String: Any]] {
            [jobCall(call, input: ["cron": cron, "prompt": "Check the inbox", "recurring": recurring], at: date),
             jobResult(call, ["id": id, "humanSchedule": cron, "recurring": recurring, "durable": durable], error: error, at: date)]
        }
        func carried(_ id: String, daysAgo: Double) -> [String: Any] {
            ["id": id, "cron": "0 9 * * *", "prompt": "Morning", "recurring": true,
             "createdAt": (now.timeIntervalSince1970 - daysAgo * 86_400) * 1_000]
        }
        let note: [String: Any] = ["type": "session_cron_carry", "ended": ["noted"],
                                   "tasks": [carried("carried", daysAgo: 2), carried("carried-aged", daysAgo: 9)]]
        let carryNote: [String: Any] = ["type": "attachment", "timestamp": Self.timestamp(made), "attachment": note]
        let records = try savedRecords(
            job("c1", "recent", at: now.addingTimeInterval(-6 * 86_400))
                + job("c2", "aged", at: now.addingTimeInterval(-8 * 86_400))
                + job("c3", "deleted", at: made) + [jobCall("c4", name: "CronDelete", input: ["id": "deleted"], at: made)]
                + job("c5", "durable", durable: true, at: made)
                + job("c6", "failed", error: true, at: made)
                + job("c7", "ahead", cron: pinned(now.addingTimeInterval(86_400)), recurring: false, at: made)
                + job("c8", "passed", cron: pinned(now.addingTimeInterval(-1_800)), recurring: false,
                      at: now.addingTimeInterval(-7_200))
                + job("c9", "noted", at: made) + [carryNote],
            conversation: UUID().uuidString.lowercased()
        ).compactMap { ClaudeSubagentTranscriptReader.parseLine(Data($0.utf8)) }
        XCTAssertEqual(ClaudeSessionJobs.broughtBack(from: records, now: now).map(\.id), ["recent", "ahead", "carried"])

        // A running CLI holds those, and the `/loop` wakeup it armed since it started that has not fired
        // or been stopped; a stopped turn cancels it. The next run is the CLI's own while it is ahead,
        // else worked out from the cron: a match put off by the job's share of the gap (half of an hour
        // for `80000000`, 15 minutes).
        func wakeup(_ call: String, in seconds: TimeInterval, at date: Date) -> [[String: Any]] {
            [jobCall(call, name: "ScheduleWakeup", input: ["delaySeconds": seconds, "prompt": "/loop check", "reason": "r",
                                                          "noop": true], at: date),
             jobResult(call, ["scheduledFor": (date.timeIntervalSince1970 + seconds) * 1_000,
                              "clampedDelaySeconds": seconds, "wasClamped": false], at: date)]
        }
        let started = now.addingTimeInterval(-600)
        let reported = now.addingTimeInterval(240)
        let running = try savedRecords(
            [jobCall("h1", input: ["cron": "0 * * * *", "prompt": "Hourly", "recurring": true], at: started),
             jobResult("h1", ["id": "80000000", "humanSchedule": "Every hour", "recurring": true,
                              "nextFireAt": now.addingTimeInterval(-60).timeIntervalSince1970 * 1_000], at: started),
             jobCall("q1", input: ["cron": "*/15 * * * *", "prompt": "Quarter", "recurring": true], at: started),
             jobResult("q1", ["id": "quarter", "humanSchedule": "Every 15 minutes", "recurring": true,
                              "nextFireAt": reported.timeIntervalSince1970 * 1_000], at: started)]
                + wakeup("w0", in: 3_000, at: started.addingTimeInterval(-60)) + wakeup("w1", in: 900, at: now.addingTimeInterval(-300)),
            conversation: UUID().uuidString.lowercased()
        ).compactMap { ClaudeSubagentTranscriptReader.parseLine(Data($0.utf8)) }
        let held = ClaudeSessionJobs.held(in: running, now: now, runningSince: started)
        XCTAssertEqual(held.map(\.id), ["80000000", "quarter", "w1"], "the later wakeup takes the earlier one's place")
        XCTAssertEqual(held.last?.kind, .wakeup)
        func seconds(_ date: Date?) -> TimeInterval { date?.timeIntervalSince1970 ?? 0 }
        XCTAssertEqual(seconds(held.last?.nextRun(after: now)?.date), seconds(now.addingTimeInterval(600)), accuracy: 0.01)
        XCTAssertEqual(seconds(held[1].nextRun(after: now)?.date), seconds(reported), accuracy: 0.01)
        XCTAssertEqual(held[1].nextRun(after: now)?.isReported, true)
        let hour = Calendar.current.dateInterval(of: .hour, for: now)!.start
        let computed = hour.addingTimeInterval(900) > now ? hour.addingTimeInterval(900) : hour.addingTimeInterval(4_500)
        XCTAssertEqual(held[0].nextRun(after: now)?.date, computed, "a reported run that passed is worked out again")
        XCTAssertEqual(held[0].nextRun(after: now)?.isReported, false)
        XCTAssertEqual(seconds(held[0].endsAt), seconds(started.addingTimeInterval(7 * 86_400)), accuracy: 0.01)
        XCTAssertEqual(ClaudeSessionJobs.held(in: running, now: now, runningSince: nil).map(\.id), ["80000000", "quarter"],
                       "a wakeup lives in the process that armed it")
        let stop: [String: Any] = ["type": "user", "timestamp": Self.timestamp(now),
                                   "message": ["role": "user", "content": "[Request interrupted by user]"] as [String: Any]]
        let stopped = running + (try savedRecords([stop], conversation: "c")).compactMap {
            ClaudeSubagentTranscriptReader.parseLine(Data($0.utf8))
        }
        XCTAssertEqual(ClaudeSessionJobs.held(in: stopped, now: now, runningSince: started).map(\.id), ["80000000", "quarter"])

        XCTAssertEqual(ClaudeCron("*/15 9-17 * * 1-5")?.minutes, [0, 15, 30, 45])
        XCTAssertEqual(ClaudeCron("0 0 * * 7")?.daysOfWeek, [0], "7 is Sunday too")
        XCTAssertNil(ClaudeCron("60 * * * *"))
        XCTAssertNil(ClaudeCron("* * * *"))
    }

    // MARK: - Each provider's continuation

    func testClaudeIsSentTheClaudeAppsOwnWordsAsAnAutomaticMessage() throws {
        let frame = ClaudeProtocol.restartContinuation(sessionID: "s1")
        XCTAssertEqual(frame["type"]?.stringValue, "user")
        XCTAssertEqual(frame["message"]?["content"]?.stringValue,
            "The app was quit while you were working. Please continue from where you left off.")
        XCTAssertEqual(frame["origin"]?["kind"]?.stringValue, "auto-continuation")
        XCTAssertEqual(frame["session_id"]?.stringValue, "s1")
        XCTAssertNil(frame["uuid"], "Not a queued follow-up")
        XCTAssertNil(frame["priority"])

        // After a lost connection, the Claude app's own words too: "Try again", or its sleep message.
        XCTAssertEqual(ClaudeProtocol.restartContinuation(sessionID: "s1", after: .connection)["message"]?["content"]?
            .stringValue, "Try again")
        XCTAssertEqual(ClaudeProtocol.restartContinuation(sessionID: "s1", after: .sleep)["message"]?["content"]?
            .stringValue, "My computer went to sleep while you were working. Please continue from where you left off.")
        XCTAssertEqual(ClaudeProtocol.restartContinuation(sessionID: "s1", after: .connection)["origin"]?["kind"]?
            .stringValue, "auto-continuation")

        // Which ended turns are a lost connection, by Claude Code 2.1.299's own result: its connection
        // words, an API error without an HTTP status. Nothing else continues.
        func result(_ text: String, status: JSONValue? = nil, reason: String? = "api_error") -> JSONValue {
            var object: [String: JSONValue] = ["type": .string("result"), "subtype": .string("success"),
                                               "is_error": .bool(true), "result": .string(text)]
            if let reason { object["terminal_reason"] = .string(reason) }
            if let status { object["api_error_status"] = status }
            return .object(object)
        }
        let cuts: [(JSONValue, TurnCut?)] = [
            (result("API Error: Can't reach the API server — check your internet or DNS (ENOTFOUND)"), .connection),
            (result("API Error: No internet route — check your connection or VPN (ENETUNREACH)"), .connection),
            (result("API Error: Connection dropped (ECONNRESET)"), .connection),
            (result("API Error: Unable to connect to API. Check your internet connection", status: .null), .connection),
            (result("API Error: Request timed out. Check your internet connection and proxy settings"), .connection),
            (result("API Error: Connection to the API was lost (EPIPE). This is usually temporary — try again."), .connection),
            (result("API Error: Connection lost while your computer was asleep"), .sleep),
            (result("API Error: Unable to connect to API", reason: nil), .connection),
            (result("API Error: Unable to connect to API: SSL certificate has expired"), nil),
            (result("API Error: 500 Internal server error", status: .number(500)), nil),
            (result("API Error: Connection dropped (ECONNRESET)", status: .number(529)), nil),
            (result("Failed to authenticate. API Error: 401"), nil),
            (result("Claude AI usage limit reached", reason: "api_error"), nil),
            (result("", reason: "aborted_streaming"), nil),
            (result("Request timed out", reason: "aborted_tools"), nil),
        ]
        for (frame, cut) in cuts {
            XCTAssertEqual(ClaudeProtocol.turnCut(ofResult: frame), cut, "\(frame)")
        }
        // Which ended turns a retry may get past, as the Claude app 4.29 offers Try again on them: an API
        // error with no HTTP status, a 429 or a 5xx. Not a sign-in, a bad request, the turn limit, a stop,
        // or a failure that was no API error.
        let maxTurns = JSONValue.object(["type": .string("result"), "subtype": .string("error_max_turns"),
                                         "is_error": .bool(true), "terminal_reason": .string("max_turns")])
        let retryable: [(JSONValue, Bool)] = [
            (result("API Error: Connection dropped (ECONNRESET)"), true),
            (result("API Error: Unable to connect to API: SSL certificate has expired", status: .null), true),
            (result("API Error: Connection dropped (ECONNRESET)", reason: nil), true),
            (result("API Error: 500 Internal server error", status: .number(500)), true),
            (result("API Error: Repeated 529 Overloaded errors", status: .number(529)), true),
            (result("API Error: 429 Too many requests"), true),
            (result("Failed to authenticate. API Error: 401"), false),
            (result("API Error: 403 Request not allowed", status: .number(403)), false),
            (result("Prompt is too long", status: .number(400)), false),
            (result("Something broke", reason: nil), false),
            (result("", reason: "aborted_streaming"), false),
            (maxTurns, false),
        ]
        for (frame, transient) in retryable {
            XCTAssertEqual(ClaudeProtocol.endsTurnOnTransientError(frame), transient, "\(frame)")
        }
        // And Codex 0.163's: a request or stream that never reached the server, with no HTTP status.
        func codexError(_ info: JSONValue) -> JSONValue { .object(["message": .string("x"), "codexErrorInfo": info]) }
        XCTAssertTrue(CodexTurnErrorPresentation.isConnectionCut(codexError(.object([
            "responseStreamDisconnected": .object(["httpStatusCode": .null])]))))
        XCTAssertTrue(CodexTurnErrorPresentation.isConnectionCut(codexError(.object(["httpConnectionFailed": .object([:])]))))
        XCTAssertFalse(CodexTurnErrorPresentation.isConnectionCut(codexError(.object([
            "responseStreamDisconnected": .object(["httpStatusCode": .number(429)])]))), "The server's own answer")
        for other in ["serverOverloaded", "usageLimitExceeded", "unauthorized", "internalServerError", "sandboxError", "other"] {
            XCTAssertFalse(CodexTurnErrorPresentation.isConnectionCut(codexError(.string(other))), other)
        }
    }

    func testTheContinuationReadsAsTheAppsNoticeNotThePersonsMessage() throws {
        func record(_ content: JSONValue, origin: String?) -> JSONValue {
            var object: [String: JSONValue] = ["type": .string("user"),
                "message": .object(["role": .string("user"), "content": content])]
            if let origin { object["origin"] = .object(["kind": .string(origin)]) }
            return .object(object)
        }
        let text = JSONValue.string(RestartContinuation.claudeText)
        XCTAssertTrue(ClaudeSubagentTranscriptReader.isClaudesOwnNotice(record(text, origin: "auto-continuation")))
        XCTAssertTrue(ClaudeSubagentTranscriptReader.isClaudesOwnNotice(record(text, origin: nil)))
        XCTAssertTrue(ClaudeSubagentTranscriptReader.isClaudesOwnNotice(record(.array([
            .object(["type": .string("text"), "text": text])]), origin: "auto-continuation")))
        XCTAssertFalse(ClaudeSubagentTranscriptReader.isClaudesOwnNotice(record(text, origin: "human")),
            "The person's own message stays theirs")
        XCTAssertFalse(ClaudeSubagentTranscriptReader.isClaudesOwnNotice(record(.string("Fix the CI failure"),
            origin: "auto-continuation")), "Other automatic messages keep their words")
        XCTAssertTrue(ClaudeSubagentTranscriptReader.isClaudesOwnNotice(record(.string("<task-notification/>"),
            origin: "task-notification")))
    }

    func testCodexStartsTheAppsEmptyUpdateTurnOnlyOnACutOffTurnThroughBothRoutes() async throws {
        for routed in [false, true] {
            let transport = FakeCodexTransport(responses: codexResponses(latest: "interrupted"))
            let adapter = codexAdapter(transport: transport, routed: routed)
            let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp"), initialPrompt: nil))
            let continuing = try XCTUnwrap(adapter as? any HarnessInterruptedTurnContinuing)
            let started = try await continuing.continueInterruptedTurn(in: handle, after: .quit)
            XCTAssertTrue(started)
            let requests = await transport.requests
            let start = try XCTUnwrap(requests.first { $0.method == "turn/start" })
            XCTAssertEqual(start.params["threadId"], .string("original"))
            XCTAssertEqual(start.params["input"], .array([]), "No words of Yardlet's own reach the model")
            XCTAssertEqual(start.params["turnTrigger"], .string("app_update_resume"))
            let active = await (adapter as? any CodexComposerProviding)?.activeTurnID(for: handle)
            XCTAssertEqual(active, "continued")
            await adapter.close(handle)
        }
        for (routed, latest, runtime) in [(false, "completed", "idle"), (true, "completed", "idle"),
                                          (false, "failed", "idle"), (true, "interrupted", "active")] {
            let transport = FakeCodexTransport(responses: codexResponses(latest: latest, runtime: runtime))
            let adapter = codexAdapter(transport: transport, routed: routed)
            let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp"), initialPrompt: nil))
            let continuing = try XCTUnwrap(adapter as? any HarnessInterruptedTurnContinuing)
            let started = try await continuing.continueInterruptedTurn(in: handle, after: .quit)
            XCTAssertFalse(started, "A turn that ended, or a thread still running, is left as it is (\(latest), \(runtime))")
            let starts = await transport.requests.filter { $0.method == "turn/start" }
            XCTAssertTrue(starts.isEmpty)
            await adapter.close(handle)
        }
    }

    // MARK: - Through the app model

    func testAClaudeTurnCutByAQuitContinuesAtTheNextLaunchWithANotice() async throws {
        let fixture = try ClaudeFixture()
        let cut = fixture.session(title: "Cut off", status: .running, updatedAt: Date())
        let finished = fixture.session(title: "Finished", status: .completed, updatedAt: Date().addingTimeInterval(-60))
        let repository = InMemorySessionRepository(sessions: [cut, finished])

        let before = fixture.model(store: SessionStore(sessions: [cut, finished], repository: repository))
        before.recordWorkForRestart(trigger: .quit)
        let record = try XCTUnwrap(RestartResumeRecord.load(from: fixture.defaults))
        XCTAssertEqual(record.trigger, .quit)
        XCTAssertEqual(record.entries.map(\.sessionID), [cut.id], "The finished task is not written down")
        await before.shutdown()

        let after = try await fixture.relaunch(repository: repository)
        XCTAssertEqual(after.store.sessions.first { $0.id == cut.id }?.status, .ready, "A relaunch leaves no turn running")
        await after.continueWorkInterruptedByRestart()
        XCTAssertNil(RestartResumeRecord.load(from: fixture.defaults), "The record is read once")
        let transport = try XCTUnwrap(fixture.transports.all.last)
        let sent = await transport.sentValues
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?["message"]?["content"]?.stringValue, RestartContinuation.claudeText)
        XCTAssertEqual(sent.first?["origin"]?["kind"]?.stringValue, "auto-continuation")
        let configuration = await transport.configuration
        XCTAssertEqual(configuration?.providerSessionID, cut.providerSessionID, "The same conversation is resumed")
        XCTAssertEqual(configuration?.resumesExistingSession, true)
        XCTAssertEqual(after.store.sessions.first { $0.id == cut.id }?.status, .running)
        XCTAssertEqual(after.store.sessions.first { $0.id == finished.id }?.status, .completed)
        XCTAssertEqual(after.restartResumeNoticeSessionIDs, [cut.id])
        XCTAssertFalse(after.transcriptBySessionID[cut.id]?.contains {
            if case .user = $0.content { return true }
            return false
        } ?? false, "The continuation is not shown as something the person sent")

        // What the person sends next takes over from the notice.
        await after.send(HarnessUserInput(text: "Also update the docs"), to: try XCTUnwrap(after.store.sessions.first { $0.id == cut.id }))
        XCTAssertTrue(after.restartResumeNoticeSessionIDs.isEmpty)
        await after.shutdown()
    }

    func testTheSettingOffContinuesNothing() async throws {
        let fixture = try ClaudeFixture()
        let cut = fixture.session(title: "Cut off", status: .running, updatedAt: Date())
        // Nor does a task's CLI start again for the session jobs it would bring back.
        let jobs = fixture.session(title: "Inbox", status: .ready, updatedAt: Date())
        try fixture.save(savedRecords(sessionJob(at: Date()), conversation: jobs.providerSessionID!), for: jobs)
        let repository = InMemorySessionRepository(sessions: [cut, jobs])
        fixture.defaults.set(false, forKey: RestartResumePreference.key)
        let before = fixture.model(store: SessionStore(sessions: [cut, jobs], repository: repository))
        before.recordWorkForRestart(trigger: .update)
        XCTAssertNil(RestartResumeRecord.load(from: fixture.defaults))
        await before.shutdown()

        // A record written while it was on is dropped once it is off.
        RestartResumeRecord(trigger: .quit, recordedAt: Date(), entries: [entry(for: cut)]).save(to: fixture.defaults)
        let after = try await fixture.relaunch(repository: repository)
        await after.continueWorkInterruptedByRestart()
        XCTAssertNil(RestartResumeRecord.load(from: fixture.defaults))
        XCTAssertTrue(fixture.transports.all.isEmpty, "No provider is started")
        XCTAssertTrue(after.restartResumeNoticeSessionIDs.isEmpty)
        await after.shutdown()
    }

    /// Claude Code keeps a session job in its process alone, so a quit stops it until the CLI runs
    /// again (2026-10-24: a task waking every 15 minutes stayed asleep after two updates until the
    /// person wrote to it). The next launch starts, after the cut-off turns and with nothing sent, the
    /// CLI of each idle task whose saved conversation holds a job the CLI brings back.
    func testAnIdleClaudeTaskWithASessionJobStartsAgainAfterTheCutOffTurnsWithNothingSent() async throws {
        let fixture = try ClaudeFixture()
        let now = Date()
        let cut = fixture.session(title: "Cut off", status: .running, updatedAt: now)
        let jobs = fixture.session(title: "Inbox", status: .ready, updatedAt: now.addingTimeInterval(-60))
        let cancelled = fixture.session(title: "Cancelled", status: .ready, updatedAt: now.addingTimeInterval(-120))
        try fixture.save(savedRecords(sessionJob(at: now.addingTimeInterval(-3_600)),
                                      conversation: jobs.providerSessionID!), for: jobs)
        try fixture.save(savedRecords(sessionJob(at: now.addingTimeInterval(-3_600))
            + [jobCall("delete", name: "CronDelete", input: ["id": "inbox"], at: now.addingTimeInterval(-1_800))],
            conversation: cancelled.providerSessionID!), for: cancelled)
        let sessions = [cut, jobs, cancelled]
        let repository = InMemorySessionRepository(sessions: sessions)
        let before = fixture.model(store: SessionStore(sessions: sessions, repository: repository))
        before.recordWorkForRestart(trigger: .update)
        XCTAssertEqual(RestartResumeRecord.load(from: fixture.defaults)?.entries.map(\.sessionID), [cut.id])
        await before.shutdown()

        let after = try await fixture.relaunch(repository: repository)
        await after.continueWorkInterruptedByRestart()
        var started: [String?] = []
        for transport in fixture.transports.all { started.append(await transport.configuration?.providerSessionID) }
        XCTAssertEqual(started, [cut.providerSessionID, jobs.providerSessionID],
                       "The cut-off turn first, then the task with a job; a cancelled job brings nothing back")
        let relaunched = try await fixture.transport(for: jobs.providerSessionID!)
        let configuration = await relaunched.configuration
        XCTAssertEqual(configuration?.resumesExistingSession, true, "Its own conversation is resumed")
        let sent = await relaunched.sentValues
        XCTAssertTrue(sent.isEmpty, "Nothing is sent: the CLI brings its jobs back itself")
        XCTAssertEqual(after.store.sessions.first { $0.id == jobs.id }?.status, .ready)
        XCTAssertEqual(after.restartResumeNoticeSessionIDs, [cut.id], "Only a continued turn says it was continued")

        // What each running CLI holds, for its rail and the scheduled tasks list, read from its records.
        try await waitUntil { after.sessionJobs(of: jobs.id).map(\.id) == ["inbox"] }
        XCTAssertEqual(after.scheduledSessionJobs.map(\.session.id), [jobs.id])
        XCTAssertTrue(after.sessionJobs(of: cancelled.id).isEmpty, "A task whose CLI is not running holds none")

        // A turn that makes a job shows it once the turn ends; one that ends a job takes it away.
        let cutTransport = try await fixture.transport(for: cut.providerSessionID!)
        try fixture.save(savedRecords([jobCall("made", input: ["cron": "0 9 * * *", "prompt": "Morning", "recurring": true],
                                               at: Date()),
                                       jobResult("made", ["id": "morning", "humanSchedule": "Every day at 9:00 AM",
                                                          "recurring": true], at: Date())],
                                      conversation: cut.providerSessionID!), for: cut)
        try await finishTurn(on: cutTransport, calling: "CronCreate", input: ["cron": "0 9 * * *", "prompt": "Morning"])
        try await waitUntil { after.sessionJobs(of: cut.id).map(\.id) == ["morning"] }
        await after.send(HarnessUserInput(text: "Stop checking the inbox"),
                         to: try XCTUnwrap(after.store.sessions.first { $0.id == jobs.id }))
        try fixture.save(savedRecords(sessionJob(at: now.addingTimeInterval(-3_600))
            + [jobCall("stop", name: "CronDelete", input: ["id": "inbox"], at: Date())],
            conversation: jobs.providerSessionID!), for: jobs)
        try await finishTurn(on: relaunched, calling: "CronDelete", input: ["id": "inbox"])
        try await waitUntil { after.sessionJobs(of: jobs.id).isEmpty }
        XCTAssertEqual(after.scheduledSessionJobs.map(\.session.id), [cut.id])
        await after.shutdown()
    }

    /// The memory saver: with the setting off nothing ends. On, memory pressure ends the longest idle
    /// CLIs until two fewer than the Claude app's cap run, at most once a minute, and three hours off screen end every
    /// idle one; a task in a turn or on screen keeps its CLI. An ended task stays ready, and its next message resumes the
    /// same conversation in a new CLI, with only that message sent.
    func testTheMemorySaverEndsIdleCLIsAndTheNextMessageResumesTheConversation() async throws {
        let fixture = try ClaudeFixture()
        let now = Date()
        let tasks = (0..<6).map { index in
            fixture.session(title: "Task \(index)", status: .ready, updatedAt: now.addingTimeInterval(-600 + 60 * Double(index)))
        }
        let store = SessionStore(sessions: tasks, repository: InMemorySessionRepository(sessions: tasks))
        store.selectedSessionID = tasks[5].id
        let model = fixture.model(store: store)
        for task in tasks { await model.resume(task) }
        XCTAssertEqual(tasks.filter { model.isAttached($0.id) }.count, 6)
        try await store.updateSession(id: tasks[0].id, status: .running)
        // The Claude app's cap on a 16 GB Mac is 6, so pressure leaves 4 running.
        let memory: UInt64 = 16 << 30
        func attached() -> [Bool] { tasks.map { model.isAttached($0.id) } }

        fixture.defaults.set(false, forKey: MemorySaverPreference.key)
        await model.checkHarnessMemory(now: now.addingTimeInterval(4 * 3_600), pressure: .critical, physicalMemory: memory)
        XCTAssertEqual(attached(), Array(repeating: true, count: 6), "Off, nothing ends")
        fixture.defaults.set(true, forKey: MemorySaverPreference.key)

        await model.checkHarnessMemory(now: now.addingTimeInterval(120), pressure: .warning, physicalMemory: memory)
        XCTAssertEqual(attached(), [true, false, false, true, true, true],
                       "The longest idle end until four run; the one in a turn and the one on screen stay")
        await model.checkHarnessMemory(now: now.addingTimeInterval(150), pressure: .warning, physicalMemory: memory)
        XCTAssertEqual(attached(), [true, false, false, true, true, true], "One pressure sweep a minute")
        await model.checkHarnessMemory(now: now.addingTimeInterval(3 * 3_600 + 60), pressure: .normal, physicalMemory: memory)
        XCTAssertEqual(attached(), [true, false, false, false, false, true], "Three hours off screen end every idle one")

        let ended = try await fixture.transport(for: tasks[1].providerSessionID!)
        let stops = await ended.stopCount
        XCTAssertEqual(stops, 1)
        let idle = try XCTUnwrap(model.store.sessions.first { $0.id == tasks[1].id })
        XCTAssertEqual(idle.status, .ready, "Ended to save memory, not failed")
        await model.send(HarnessUserInput(text: "Next step"), to: idle)
        var processes: [FakeClaudeTransport] = []
        for transport in fixture.transports.all where await transport.configuration?.providerSessionID == idle.providerSessionID {
            processes.append(transport)
        }
        XCTAssertEqual(processes.count, 2)
        let resumed = try XCTUnwrap(processes.last)
        let configuration = await resumed.configuration
        XCTAssertEqual(configuration?.resumesExistingSession, true, "The same conversation resumes")
        let sent = await resumed.sentValues
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(model.isAttached(idle.id))
        await model.shutdown()
    }

    /// What keeps a task's CLI through the memory saver, also past three hours under critical pressure: an approval it
    /// waits on, a message waiting to go, a background shell, a session job, a child task still working. An idle task
    /// beside them ends, and its terminal's shell, which does not keep it, goes on.
    func testTheMemorySaverKeepsTheCLIOfATaskThatStillHasWork() async throws {
        let fixture = try ClaudeFixture()
        let now = Date()
        let tasks = (0..<6).map { fixture.session(title: "Task \($0)", status: .ready, updatedAt: now) }
        try fixture.save(savedRecords(sessionJob(at: now.addingTimeInterval(-60)), conversation: tasks[3].providerSessionID!),
                         for: tasks[3])
        var child = fixture.session(title: "Child", status: .running, updatedAt: now)
        child.parentTaskID = tasks[4].id
        let sessions = tasks + [child]
        let store = SessionStore(sessions: sessions, repository: InMemorySessionRepository(sessions: sessions))
        store.selectedSessionID = child.id
        let model = fixture.model(store: store)
        for task in tasks { await model.resume(task) }
        try await store.updateSession(id: tasks[0].id, status: .waitingForApproval)
        model.followUps.append(QueuedFollowUp(draft: CodexComposerDraft(inputs: [.text("Then this")])), to: tasks[1].id)
        let shell = try await fixture.transport(for: tasks[2].providerSessionID!)
        func frame(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
        await shell.emit(try frame(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_dev","name":"Bash","input":{"command":"npm run dev","run_in_background":true}}]}}"#))
        await shell.emit(try frame(#"{"type":"system","subtype":"task_started","task_id":"bdev","tool_use_id":"toolu_dev","description":"npm run dev","task_type":"local_bash","is_backgrounded":true}"#))
        await shell.emit(try frame(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_dev","content":"Running in the background"}]}}"#))
        await shell.emit(try frame(#"{"type":"result","subtype":"success","is_error":false,"result":"Started.","session_id":"s"}"#))
        let shellHome = FileManager.default.temporaryDirectory.appending(path: "restart-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: shellHome, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: shellHome) }
        let terminal = model.taskWorkspaces.state(for: tasks[5].id)
            .terminal(in: shellHome, launch: .isolatedZsh(in: shellHome), taskID: tasks[5].id)
        defer { terminal.stop() }
        _ = terminal.view {
            LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300),
                                     font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                     options: TerminalOptions(cursorStyle: .steadyBlock, scrollback: 100))
        }
        func keeps() -> [String?] {
            tasks.map { task in model.store.sessions.first { $0.id == task.id }.flatMap(model.memorySaverKeeps) }
        }
        try await waitUntil { keeps() == ["turn", "queued", "background", "schedule", "children", nil] }

        await model.checkHarnessMemory(now: now.addingTimeInterval(4 * 3_600), pressure: .critical, physicalMemory: 16 << 30)
        XCTAssertEqual(tasks.map { model.isAttached($0.id) }, [true, true, true, true, true, false])
        XCTAssertTrue(terminal.isRunning)
        await model.shutdown()
    }

    /// Claude Code's frames for a turn that calls one tool, then ends.
    private func finishTurn(on transport: FakeClaudeTransport, calling tool: String, input: [String: Any]) async throws {
        let call: [String: Any] = ["type": "tool_use", "id": "toolu_\(tool)", "name": tool, "input": input]
        let answer: [String: Any] = ["type": "tool_result", "tool_use_id": "toolu_\(tool)", "content": "Done."]
        for frame: [String: Any] in [
            ["type": "assistant", "parent_tool_use_id": NSNull(), "session_id": "s",
             "message": ["role": "assistant", "content": [call]] as [String: Any]],
            ["type": "user", "parent_tool_use_id": NSNull(), "session_id": "s",
             "message": ["role": "user", "content": [answer]] as [String: Any]],
            ["type": "result", "subtype": "success", "is_error": false, "result": "Done.", "session_id": "s"]
        ] {
            let data = try JSONSerialization.data(withJSONObject: frame)
            try await transport.emit(JSONDecoder().decode(JSONValue.self, from: data))
        }
    }

    /// A turn waiting on an approval continues once its task is opened, as the Claude app continues
    /// it once the person looks. One waiting on a question alone (2026-10-24 04:44: three tasks read
    /// as unread with no card after an update) waits for the person with that question asked again,
    /// and the answer goes as their next message, naming the questions: the call that asked is gone.
    func testATurnWaitingOnThePersonContinuesWhenOpenedAndAQuestionIsAskedAgain() async throws {
        let fixture = try ClaudeFixture()
        let other = fixture.session(title: "Other", status: .ready, updatedAt: Date())
        let waiting = fixture.session(title: "Needs approval", status: .waitingForApproval, updatedAt: Date().addingTimeInterval(-60))
        let asking = fixture.session(title: "Asks", status: .waitingForApproval, updatedAt: Date().addingTimeInterval(-120))
        let repository = InMemorySessionRepository(sessions: [other, waiting, asking])
        let before = fixture.model(store: SessionStore(sessions: [other, waiting, asking], repository: repository))
        let questions = [
            PermissionQuestion(question: "Which layout?", header: "Layout", options: [.init(label: "Side by side"),
                .init(label: "Stacked")], allowsCustomAnswer: true),
            PermissionQuestion(question: "Which checks run?", header: "Checks", options: [.init(label: "Unit"),
                .init(label: "UI")], allowsMultipleSelections: true, allowsCustomAnswer: true),
            PermissionQuestion(question: "Anything else?", options: [.init(label: "No")], allowsCustomAnswer: true),
        ]
        let question = PermissionRequest(id: "perm-question", title: "Claude has questions", detail: nil, command: nil,
                                         structured: .questions(questions), toolCallID: "toolu_ask")
        await before.accept(HarnessEventEnvelope(localSessionID: asking.id, sequence: 1,
                                                 payload: .permissionRequested(question)))
        before.recordWorkForRestart(trigger: .update)
        let entries = try XCTUnwrap(RestartResumeRecord.load(from: fixture.defaults)?.entries)
        XCTAssertEqual(entries.first { $0.sessionID == waiting.id }?.wasWaitingForApproval, true)
        XCTAssertNil(entries.first { $0.sessionID == waiting.id }?.question, "An approval is not a question")
        XCTAssertEqual(entries.first { $0.sessionID == asking.id }?.question, question)
        await before.shutdown()

        let after = try await fixture.relaunch(repository: repository, selecting: other.id)
        await after.continueWorkInterruptedByRestart()
        XCTAssertTrue(fixture.transports.all.isEmpty, "Nothing runs before the person is there")
        XCTAssertTrue(after.continuesWhenOpened(waiting.id))
        XCTAssertFalse(after.continuesWhenOpened(asking.id), "The question is asked again, not continued")
        let card = try XCTUnwrap(after.heldRequests(in: asking.id).first)
        XCTAssertEqual(card.form, .choices(questions))
        XCTAssertEqual(card.state, .pending)
        let askingTask = try XCTUnwrap(after.store.sessions.first { $0.id == asking.id })
        XCTAssertEqual(askingTask.status, .ready)
        XCTAssertEqual(TaskAttentionProjection.waitingRequest(of: askingTask, detail: after.taskAttentionDetails[asking.id]),
                       .input, "It waits for the person's answer, in the sidebar, the Dock and list_tasks")
        // A quit before the person answers asks it again at the next launch.
        after.recordWorkForRestart(trigger: .quit)
        XCTAssertEqual(RestartResumeRecord.load(from: fixture.defaults)?.entries.first { $0.sessionID == asking.id }?.question,
                       question)

        after.store.selectedSessionID = asking.id
        await after.respond(to: card.id, answer: .questions([
            PermissionQuestionAnswer(question: "Which layout?", selectedLabels: ["Side by side"]),
            PermissionQuestionAnswer(question: "Which checks run?", selectedLabels: ["Unit", "UI"], customAnswer: "lint"),
        ]), in: askingTask)
        try await waitUntil { await fixture.transports.all.last?.sentValues.isEmpty == false }
        let answer = await fixture.transports.all.last?.sentValues.first
        XCTAssertEqual(answer?["message"]?["content"]?.stringValue,
                       "Which layout?\nSide by side\n\nWhich checks run?\nUnit, UI, lint",
                       "The person's message names each question it answers; the skipped one is left out")
        XCTAssertNil(answer?["origin"], "The person's own message, not the app's")
        XCTAssertTrue(after.heldRequests(in: asking.id).isEmpty)
        XCTAssertEqual(after.store.sessions.first { $0.id == asking.id }?.status, .running)

        after.store.selectedSessionID = waiting.id
        try await waitUntil { after.store.sessions.first { $0.id == waiting.id }?.status == .running }
        // The task shows running as the continuation starts, a moment before its frame is written.
        try await waitUntil { await fixture.transports.all.count == 2 }
        try await waitUntil { await fixture.transports.all.last?.sentValues.isEmpty == false }
        let sent = await fixture.transports.all.last?.sentValues
        XCTAssertEqual(sent?.first?["message"]?["content"]?.stringValue, RestartContinuation.claudeText)
        XCTAssertFalse(after.continuesWhenOpened(waiting.id))
        let continued = await fixture.continuedConversations()
        XCTAssertEqual(continued, [waiting.providerSessionID ?? ""], "Only the approval's turn is continued")
        await after.shutdown()
    }

    func testAStoppedTurnIsNotContinuedAgainAndAnUnseenOneIsCounted() async throws {
        let fixture = try ClaudeFixture()
        let shown = fixture.session(title: "Shown", status: .ready, updatedAt: Date())
        let cut = fixture.session(title: "Cut off", status: .running, updatedAt: Date().addingTimeInterval(-60))
        let repository = InMemorySessionRepository(sessions: [shown, cut])
        RestartResumeRecord(trigger: .update, recordedAt: Date(), entries: [entry(for: cut)]).save(to: fixture.defaults)
        let after = try await fixture.relaunch(repository: repository, selecting: shown.id)
        await after.continueWorkInterruptedByRestart()
        XCTAssertEqual(after.store.sessions.first { $0.id == cut.id }?.status, .running)

        // Continued in the background and quit again before anyone looked: written down again, counted.
        after.recordWorkForRestart(trigger: .update)
        XCTAssertEqual(RestartResumeRecord.load(from: fixture.defaults)?.entries.map(\.unseenContinuations), [1])

        // Once the person has seen it, the count starts over …
        after.store.selectedSessionID = cut.id
        after.recordWorkForRestart(trigger: .update)
        XCTAssertEqual(RestartResumeRecord.load(from: fixture.defaults)?.entries.map(\.sessionID), [cut.id])
        XCTAssertEqual(RestartResumeRecord.load(from: fixture.defaults)?.entries.map(\.unseenContinuations), [nil])

        // … unless they stopped it, even before the provider confirms the stop.
        await after.interrupt(try XCTUnwrap(after.store.sessions.first { $0.id == cut.id }))
        XCTAssertEqual(after.store.sessions.first { $0.id == cut.id }?.status, .running)
        after.recordWorkForRestart(trigger: .update)
        XCTAssertNil(RestartResumeRecord.load(from: fixture.defaults))
        XCTAssertTrue(after.restartResumeNoticeSessionIDs.isEmpty, "Stopping takes over from the notice")
        await after.shutdown()
    }

    /// Every cut-off task continues without anyone opening it (2026-10-23 02:26: an update cut off
    /// more than four tasks, and a subtask and three tasks of other projects stayed stopped): four
    /// start at once, each next one once an earlier one's provider shows work or its start window
    /// passes, and one the person opens first, at once.
    func testCutOffTasksContinueInTurnWithFourStartingAtOnce() async throws {
        let fixture = try ClaudeFixture()
        let now = Date()
        let tasks = (0..<7).map { index in
            fixture.session(title: "Task \(index)", status: .running, updatedAt: now.addingTimeInterval(-60 * Double(index)))
        }
        let conversations = tasks.compactMap(\.providerSessionID)
        let shown = fixture.session(title: "Shown", status: .ready, updatedAt: now.addingTimeInterval(-3_600))
        let repository = InMemorySessionRepository(sessions: [shown] + tasks)
        let before = fixture.model(store: SessionStore(sessions: [shown] + tasks, repository: repository))
        before.recordWorkForRestart(trigger: .update)
        XCTAssertEqual(RestartResumeRecord.load(from: fixture.defaults)?.entries.count, 7)
        await before.shutdown()

        let after = try await fixture.relaunch(repository: repository, selecting: shown.id)
        let clock = ManualSleep()
        after.restartResumeSleep = { try await clock.sleep(for: $0) }
        await after.continueWorkInterruptedByRestart()
        var continued = await fixture.continuedConversations()
        XCTAssertEqual(continued, Array(conversations[0..<4]), "The four most recent start at once")
        XCTAssertEqual(after.restartResumeLine.waiting, Array(tasks[4...].map(\.id)), "The rest wait their turn, not to be opened")
        try await waitUntil { clock.waiting == 4 }
        XCTAssertEqual(clock.requested.first, RestartResumePolicy.startWindow)

        // The person opens the oldest: it continues now, ahead of the line.
        after.store.selectedSessionID = tasks[6].id
        try await waitUntil { await fixture.continuedConversations().count == 5 }
        continued = await fixture.continuedConversations()
        XCTAssertEqual(continued.last, conversations[6])
        XCTAssertEqual(after.restartResumeLine.waiting, [tasks[4].id, tasks[5].id])
        XCTAssertEqual(after.restartResumeLine.starting.count, 4, "Opened, it did not take a place in line")

        // The second task's provider shows work: its place goes to the next in line.
        try await fixture.transport(for: conversations[1]).emit(textDelta("Picking up the build."))
        try await waitUntil { await fixture.continuedConversations().count == 6 }
        continued = await fixture.continuedConversations()
        XCTAssertEqual(continued.last, conversations[4])
        XCTAssertEqual(after.restartResumeLine.waiting, [tasks[5].id])
        try await waitUntil { clock.waiting == 4 }

        // Another one's provider stays quiet for the whole start window: the last begins anyway.
        clock.elapseOldest()
        try await waitUntil { await fixture.continuedConversations().count == 7 }
        continued = await fixture.continuedConversations()
        XCTAssertEqual(continued.last, conversations[5])
        XCTAssertTrue(after.restartResumeLine.waiting.isEmpty)
        XCTAssertEqual(Set(continued), Set(conversations))
        for transport in fixture.transports.all {
            let continuations = await transport.sentValues.filter {
                $0["message"]?["content"]?.stringValue == RestartContinuation.claudeText
            }
            XCTAssertEqual(continuations.count, 1, "Each is asked once")
        }
        XCTAssertEqual(after.restartResumeNoticeSessionIDs, Set(tasks.map(\.id)))
        clock.elapseAll()
        await after.shutdown()
    }

    /// A second quit soon after the first writes down both the tasks Yardlet continued that nobody
    /// has opened yet and those still waiting their turn (2026-10-22 22:50 and 22:52: two updates
    /// in a row left three continued tasks, two of one project among them, stopped).
    func testASecondQuitWritesDownTheContinuedAndTheWaitingTasks() async throws {
        let fixture = try ClaudeFixture()
        let now = Date()
        let tasks = (0..<6).map { index in
            fixture.session(title: "Task \(index)", status: .running, updatedAt: now.addingTimeInterval(-60 * Double(index)))
        }
        let approval = fixture.session(title: "Needs approval", status: .waitingForApproval,
                                       updatedAt: now.addingTimeInterval(-600))
        let all = tasks + [approval]
        let shown = fixture.session(title: "Shown", status: .ready, updatedAt: now.addingTimeInterval(-3_600))
        let repository = InMemorySessionRepository(sessions: [shown] + all)
        let first = fixture.model(store: SessionStore(sessions: [shown] + all, repository: repository))
        first.recordWorkForRestart(trigger: .update, now: now)
        await first.shutdown()

        let second = try await fixture.relaunch(repository: repository, selecting: shown.id)
        let clock = ManualSleep()
        second.restartResumeSleep = { try await clock.sleep(for: $0) }
        await second.continueWorkInterruptedByRestart(now: now.addingTimeInterval(60))
        XCTAssertEqual(fixture.transports.all.count, 4)
        XCTAssertEqual(second.tasksContinuingAfterRestart(), Set(all.map(\.id)))
        second.recordWorkForRestart(trigger: .update, now: now.addingTimeInterval(120))
        let record = try XCTUnwrap(RestartResumeRecord.load(from: fixture.defaults))
        XCTAssertEqual(Set(record.entries.map(\.sessionID)), Set(all.map(\.id)), "Nothing is left stopped")
        let entries = Dictionary(uniqueKeysWithValues: record.entries.map { ($0.sessionID, $0) })
        for task in tasks[0..<4] {
            XCTAssertEqual(entries[task.id]?.unseenContinuations, 1, "Continued once unseen")
            XCTAssertNil(entries[task.id]?.interruptedAt, "Cut off again by this quit")
        }
        for task in tasks[4...] + [approval] {
            XCTAssertEqual(entries[task.id]?.interruptedAt, now, "Still due a day after the first quit")
            XCTAssertNil(entries[task.id]?.unseenContinuations)
        }
        XCTAssertEqual(entries[approval.id]?.wasWaitingForApproval, true)
        clock.elapseAll()
        await second.shutdown()

        // The next launch starts four again, the rest in line, the approval when opened.
        let third = try await fixture.relaunch(repository: repository, selecting: shown.id)
        let thirdClock = ManualSleep()
        third.restartResumeSleep = { try await thirdClock.sleep(for: $0) }
        await third.continueWorkInterruptedByRestart(now: now.addingTimeInterval(180))
        XCTAssertEqual(fixture.transports.all.count, 8)
        XCTAssertEqual(third.restartResumeLine.waiting, [tasks[4].id, tasks[5].id])
        XCTAssertTrue(third.continuesWhenOpened(approval.id))
        thirdClock.elapseAll()
        await third.shutdown()
    }

    /// Quitting again and again while nobody opens the task continues its turn three times in a row,
    /// then leaves it stopped.
    func testAnUnseenTurnContinuesAfterThreeQuitsInARowAndThenStaysStopped() async throws {
        let fixture = try ClaudeFixture()
        let cut = fixture.session(title: "Cut off", status: .running, updatedAt: Date())
        let shown = fixture.session(title: "Shown", status: .ready, updatedAt: Date().addingTimeInterval(-3_600))
        let repository = InMemorySessionRepository(sessions: [shown, cut])
        let first = fixture.model(store: SessionStore(sessions: [shown, cut], repository: repository))
        first.recordWorkForRestart(trigger: .quit)
        await first.shutdown()

        let limit = RestartResumePolicy.unseenContinuationLimit
        XCTAssertEqual(limit, 3)
        for count in 1...limit {
            let launch = try await fixture.relaunch(repository: repository, selecting: shown.id)
            await launch.continueWorkInterruptedByRestart()
            XCTAssertEqual(fixture.transports.all.count, count, "Continued after quit \(count)")
            XCTAssertEqual(launch.store.sessions.first { $0.id == cut.id }?.status, .running)
            launch.recordWorkForRestart(trigger: .quit)
            let entries = RestartResumeRecord.load(from: fixture.defaults)?.entries ?? []
            if count < limit {
                XCTAssertEqual(entries.map(\.unseenContinuations), [count])
            } else {
                XCTAssertTrue(entries.isEmpty, "A fourth time in a row is not written down")
                XCTAssertTrue(launch.tasksContinuingAfterRestart().isEmpty)
            }
            await launch.shutdown()
        }
        let last = try await fixture.relaunch(repository: repository, selecting: shown.id)
        await last.continueWorkInterruptedByRestart()
        XCTAssertEqual(fixture.transports.all.count, limit, "It stays stopped")
        XCTAssertEqual(last.store.sessions.first { $0.id == cut.id }?.status, .ready)

        // Opened once, the count starts over.
        last.store.selectedSessionID = cut.id
        await last.send(HarnessUserInput(text: "Carry on"), to: try XCTUnwrap(last.store.sessions.first { $0.id == cut.id }))
        last.store.selectedSessionID = shown.id
        last.recordWorkForRestart(trigger: .quit)
        XCTAssertEqual(RestartResumeRecord.load(from: fixture.defaults)?.entries.map(\.unseenContinuations), [nil])
        await last.shutdown()
    }

    /// The record is written only on the way out of a quit or an update, and the launch that reads it
    /// removes it. A crash or a forced quit never writes one, so nothing continues after it.
    func testNothingContinuesAfterACrash() async throws {
        let fixture = try ClaudeFixture()
        let cut = fixture.session(title: "Cut off", status: .running, updatedAt: Date())
        let repository = InMemorySessionRepository(sessions: [cut])
        RestartResumeRecord(trigger: .quit, recordedAt: Date(), entries: [entry(for: cut)]).save(to: fixture.defaults)
        let first = try await fixture.relaunch(repository: repository)
        await first.continueWorkInterruptedByRestart()
        XCTAssertEqual(fixture.transports.all.count, 1)
        XCTAssertEqual(first.store.sessions.first?.status, .running)
        XCTAssertNil(RestartResumeRecord.load(from: fixture.defaults), "Read once at launch")
        // Yardlet crashes here: `recordWorkForRestart` never runs. (Shut down only to release the fixture.)
        await first.shutdown()

        let next = try await fixture.relaunch(repository: repository)
        await next.continueWorkInterruptedByRestart()
        XCTAssertEqual(fixture.transports.all.count, 1, "No provider is started")
        XCTAssertEqual(next.store.sessions.first?.status, .ready)
        XCTAssertTrue(next.restartResumeNoticeSessionIDs.isEmpty)
        await next.shutdown()
    }

    func testACodexThreadCutByAnyQuitContinuesWithTheAppsEmptyTurnUnlessStoppedOrAsking() async throws {
        let root = try directory()
        let executable = root.appending(path: "codex")
        try Data("#!/bin/sh\nprintf 'codex-cli 0.163.0\\n'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let defaults = try suite()
        let session = SessionRecord(harness: .codex, workspaceURL: root, runtimeExecutableURL: executable,
            title: "Cut by a quit", status: .running, providerSessionID: "original", environmentScope: .yardlet)
        let repository = InMemorySessionRepository(sessions: [session])
        for trigger in [RestartTrigger.quit, .update] {
            let transport = FakeCodexTransport(responses: codexResponses(latest: "interrupted"))
            let adapter = codexAdapter(transport: transport, routed: true, executable: executable)
            func model(_ store: SessionStore) -> AppModel {
                AppModel(store: store, runtimeSelections: RuntimeSelectionStore(defaults: defaults),
                    registry: HarnessRegistry { _, _ in adapter },
                    codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults), preferences: defaults,
                    codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults),
                    codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: defaults),
                    codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults),
                    transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
                    restoresIndexOnLaunch: false)
            }
            try await repository.upsert(session)
            let before = model(SessionStore(sessions: [session], repository: repository))
            XCTAssertEqual(before.tasksContinuingAfterRestart(), [session.id])
            before.recordWorkForRestart(trigger: trigger)
            XCTAssertEqual(RestartResumeRecord.load(from: defaults)?.entries.map(\.sessionID), [session.id],
                "Yardlet continues a Codex thread after any quit, not only an update (\(trigger))")
            await before.shutdown()
            let store = SessionStore(repository: repository)
            try await store.restore()
            let after = model(store)
            await after.continueWorkInterruptedByRestart()
            let starts = await transport.requests.filter { $0.method == "turn/start" }
            XCTAssertEqual(starts.count, 1)
            XCTAssertEqual(starts.first?.params["input"], .array([]), "Still the Codex app's empty turn")
            XCTAssertEqual(starts.first?.params["turnTrigger"], .string("app_update_resume"))
            XCTAssertEqual(after.restartResumeNoticeSessionIDs, [session.id])
            let continued = try XCTUnwrap(after.store.sessions.first)
            XCTAssertEqual(continued.status, .running)

            // Once seen, the next quit would continue it again, unless the person stops it.
            after.store.selectedSessionID = session.id
            XCTAssertEqual(after.tasksContinuingAfterRestart(), [session.id])
            await after.interrupt(continued)
            XCTAssertTrue(after.tasksContinuingAfterRestart().isEmpty, "A Codex turn the person stopped stays stopped")
            after.recordWorkForRestart(trigger: trigger)
            XCTAssertNil(RestartResumeRecord.load(from: defaults))
            await after.shutdown()
        }

        // A thread waiting on its question (`item/tool/requestUserInput`; Codex keeps the turn running
        // while it asks) is not continued: the question is asked again on its card, and the answer
        // starts the next turn as the person's message, as a Claude question is.
        let askingDefaults = try suite()
        let asking = SessionRecord(harness: .codex, workspaceURL: root, runtimeExecutableURL: executable,
            title: "Asks", status: .running, providerSessionID: "original", environmentScope: .yardlet)
        let askingRepository = InMemorySessionRepository(sessions: [asking])
        // Each launch has an App Server of its own: the next one holds none of the last one's turns.
        let transport = FakeCodexTransport(responses: codexResponses(latest: "interrupted"))
        let relaunched = FakeCodexTransport(responses: codexResponses(latest: "interrupted"))
        func askingModel(_ store: SessionStore, _ transport: FakeCodexTransport) -> AppModel {
            let adapter = codexAdapter(transport: transport, routed: true, executable: executable)
            return AppModel(store: store, runtimeSelections: RuntimeSelectionStore(defaults: askingDefaults),
                registry: HarnessRegistry { _, _ in adapter },
                codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: askingDefaults), preferences: askingDefaults,
                codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: askingDefaults),
                codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: askingDefaults),
                codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: askingDefaults),
                transcriptRepository: UserDefaultsTranscriptRepository(defaults: askingDefaults),
                restoresIndexOnLaunch: false)
        }
        try await askingRepository.upsert(asking)
        let before = askingModel(SessionStore(sessions: [asking], repository: askingRepository), transport)
        await before.resume(asking)
        await transport.emit(method: "turn/started", params: .object(["threadId": .string("original"),
            "turn": .object(["id": .string("asking"), "status": .string("inProgress"), "items": .array([])])]))
        await transport.emitServerRequest(id: .string("input-1"), method: "item/tool/requestUserInput", params: .object([
            "threadId": .string("original"), "turnId": .string("asking"), "itemId": .string("item-ask"),
            "questions": .array([.object(["id": .string("q1"), "header": .string("Branch"),
                "question": .string("Which branch?"), "isOther": .bool(true),
                "options": .array([.object(["label": .string("main")]), .object(["label": .string("release")])])])])]))
        try await waitUntil {
            before.codexPresentationBySessionID[asking.id]?.serverRequestsByID.isEmpty == false
                && before.store.sessions.first?.status == .running
        }
        before.recordWorkForRestart(trigger: .update)
        let entry = try XCTUnwrap(RestartResumeRecord.load(from: askingDefaults)?.entries.first)
        XCTAssertEqual(entry.codexQuestion?.id, "s:input-1")
        XCTAssertFalse(entry.wasWaitingForApproval, "The turn ran while it asked; the question says it waits")
        await before.shutdown()

        let store = SessionStore(repository: askingRepository)
        try await store.restore()
        let after = askingModel(store, relaunched)
        await after.continueWorkInterruptedByRestart()
        let continuations = await relaunched.requests.filter { $0.method == "turn/start" }
        XCTAssertTrue(continuations.isEmpty, "No empty turn: the question waits for the person")
        let card = try XCTUnwrap(after.heldRequests(in: asking.id).first)
        XCTAssertEqual(card.id, "s:input-1")
        XCTAssertEqual(card.state, .pending)
        XCTAssertEqual(card.form, .freeText(CodexRequestResponseProjection.questions(entry.codexQuestion?.params)))
        let waitingTask = try XCTUnwrap(after.store.sessions.first)
        XCTAssertEqual(TaskAttentionProjection.waitingRequest(of: waitingTask, detail: after.taskAttentionDetails[asking.id]),
                       .input)
        await after.respondCodex(to: card.id, response: .toolUserInput(answers: ["q1": ["release"]]), in: waitingTask)
        var starts: [CodexRPCRequest] = []
        try await waitUntil {
            starts = await relaunched.requests.filter { $0.method == "turn/start" }
            return !starts.isEmpty
        }
        XCTAssertEqual(starts.count, 1)
        XCTAssertNotEqual(starts.first?.params["turnTrigger"], .string("app_update_resume"))
        XCTAssertEqual(starts.first?.params["input"]?.arrayValue?.first?["text"]?.stringValue, "Which branch?\nrelease",
                       "The person's message names the question it answers")
        XCTAssertTrue(after.heldRequests(in: asking.id).isEmpty)
        await after.shutdown()
    }

    /// A task cut off with messages waiting (another task's, or the person's queue) starts its next
    /// turn from the first of them once Yardlet is back, rather than staying stopped until opened.
    func testATaskCutOffWithAWaitingMessageSendsItAfterTheRestart() async throws {
        let root = try directory()
        let executable = root.appending(path: "codex")
        try Data("#!/bin/sh\nprintf 'codex-cli 0.163.0\\n'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let defaults = try suite()
        let session = SessionRecord(harness: .codex, workspaceURL: root, runtimeExecutableURL: executable,
            title: "Waiting on its child", status: .running, providerSessionID: "original", environmentScope: .yardlet)
        let repository = InMemorySessionRepository(sessions: [session])
        let transport = FakeCodexTransport(responses: codexResponses(latest: "interrupted"))
        let adapter = codexAdapter(transport: transport, routed: true, executable: executable)
        func model(_ store: SessionStore) -> AppModel {
            AppModel(store: store, runtimeSelections: RuntimeSelectionStore(defaults: defaults),
                registry: HarnessRegistry { _, _ in adapter },
                codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults), preferences: defaults,
                codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults),
                codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: defaults),
                codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults),
                transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
                restoresIndexOnLaunch: false)
        }
        try await repository.upsert(session)
        let before = model(SessionStore(sessions: [session], repository: repository))
        before.followUps.append(QueuedFollowUp(draft: CodexComposerDraft(inputs: [.text("Merged; rebase now.")])),
                                to: session.id)
        before.recordWorkForRestart(trigger: .quit)
        let entry = try XCTUnwrap(RestartResumeRecord.load(from: defaults)?.entries.first)
        XCTAssertEqual(entry.sessionID, session.id)
        XCTAssertEqual(entry.sendsQueuedMessages, true)
        await before.shutdown()

        let store = SessionStore(repository: repository)
        try await store.restore()
        let after = model(store)
        after.followUps.load(for: [session.id])
        await after.continueWorkInterruptedByRestart()
        var starts: [CodexRPCRequest] = []
        try await waitUntil {
            starts = await transport.requests.filter { $0.method == "turn/start" }
            return !starts.isEmpty
        }
        XCTAssertEqual(starts.count, 1)
        XCTAssertNotEqual(starts.first?.params["turnTrigger"], .string("app_update_resume"),
                          "The waiting message is the next turn, not the app's empty continuation")
        XCTAssertTrue("\(starts.first?.params["input"] ?? .null)".contains("Merged; rebase now."))
        await after.shutdown()
    }

    /// Messages Claude Code held unread when the quit ended it go in the order they were sent: the
    /// first starts the next turn, the rest join it at once, and a message sent after the restart
    /// comes after them (2026-10-23: after an update, a parent read its child's message sent after
    /// the restart before the one sent before it, which waited for the turn's end).
    func testMessagesClaudeHeldAtTheQuitGoInTheOrderTheyWereSent() async throws {
        let fixture = try ClaudeFixture()
        let parent = fixture.session(title: "Parent", status: .running, updatedAt: Date())
        let repository = InMemorySessionRepository(sessions: [parent])
        func held(_ text: String) -> QueuedFollowUp {
            QueuedFollowUp(draft: CodexComposerDraft(inputs: [.text(text)]), state: .sent,
                           providerMessageID: UUID().uuidString.lowercased())
        }
        UserDefaultsCodexQueueRepository(defaults: fixture.defaults).save(
            [held("Sort the sidebar first"), held("Waiting for the account switch")], for: parent.id)
        let before = fixture.model(store: SessionStore(sessions: [parent], repository: repository))
        before.followUps.load(for: [parent.id])
        before.recordWorkForRestart(trigger: .update)
        XCTAssertEqual(RestartResumeRecord.load(from: fixture.defaults)?.entries.first?.sendsQueuedMessages, true)
        await before.shutdown()

        let after = try await fixture.relaunch(repository: repository)
        after.followUps.load(for: [parent.id])
        XCTAssertEqual(after.followUps.queue(for: parent.id).map(\.waitsToBeSteered), [true, true])
        await after.continueWorkInterruptedByRestart()
        let transport = try await fixture.transport(for: parent.providerSessionID ?? "")
        try await waitUntil { await transport.sentValues.count == 2 }
        let child = TaskMessage(senderID: UUID().uuidString, senderName: "Passkey", body: "The profile is created")
        let delivery = await after.deliverTaskMessage(child, to: try XCTUnwrap(after.store.sessions.first))
        XCTAssertEqual(delivery, .steered)
        let sent = await transport.sentValues
        XCTAssertEqual(sent.count, 3)
        XCTAssertEqual(sent.first?["message"]?["content"]?.stringValue, "Sort the sidebar first")
        XCTAssertNil(sent.first?["priority"], "The first starts the turn")
        XCTAssertEqual(sent.dropFirst().first?["message"]?["content"]?.stringValue, "Waiting for the account switch")
        XCTAssertEqual(sent.dropFirst().map { $0["priority"]?.stringValue }, ["next", "next"],
                       "The rest join that turn at its next step, in the order they were sent")
        XCTAssertTrue(sent.last?["message"]?["content"]?.stringValue?.contains("The profile is created") == true)
        await after.shutdown()
    }

    // MARK: - After a lost connection

    /// The Mac slept mid-turn and woke offline: Claude Code's retries ran out and it ended the turn on
    /// its own connection error. The task reads as reconnecting, and once the network is back and the
    /// Claude app's minute has passed it continues with the Claude app's "Try again". A turn that
    /// failed on the server's own answer does not, nor does one cut while the setting is off.
    func testATurnALostConnectionCutOffContinuesOnceTheNetworkIsBack() async throws {
        let fixture = try ClaudeFixture()
        let cut = fixture.session(title: "Offline", status: .ready, updatedAt: Date())
        let refused = fixture.session(title: "Server error", status: .ready, updatedAt: Date())
        let repository = InMemorySessionRepository(sessions: [cut, refused])
        let model = fixture.model(store: SessionStore(sessions: [cut, refused], repository: repository))
        let clock = ManualSleep()
        model.connectionResumeSleep = { try await clock.sleep(for: $0) }
        func task(_ session: SessionRecord) -> SessionRecord? { model.store.sessions.first { $0.id == session.id } }
        func failure(_ text: String, status: JSONValue? = nil) -> JSONValue {
            var object: [String: JSONValue] = ["type": .string("result"), "subtype": .string("success"),
                "is_error": .bool(true), "terminal_reason": .string("api_error"), "result": .string(text)]
            if let status { object["api_error_status"] = status }
            return .object(object)
        }
        await model.send(HarnessUserInput(text: "Build the release"), to: cut)
        await model.send(HarnessUserInput(text: "Read the logs"), to: refused)
        let cutCLI = try await fixture.transport(for: cut.providerSessionID ?? "")
        let refusedCLI = try await fixture.transport(for: refused.providerSessionID ?? "")
        model.networkPathChanged(isSatisfied: false)
        await cutCLI.emit(failure("API Error: Can't reach the API server — check your internet or DNS (ENOTFOUND)"))
        await refusedCLI.emit(failure("API Error: 500 Internal server error", status: .number(500)))
        // Claude Code's error result reaches the task before the cut it reports with it.
        try await waitUntil {
            model.connectionResumes[cut.id] != nil && task(cut)?.status == .failed && task(refused)?.status == .failed
        }
        XCTAssertEqual(model.connectionResumes[cut.id]?.isWaiting, true)
        XCTAssertNil(model.connectionResumes[refused.id], "The server's own error is no lost connection")
        let waiting = try XCTUnwrap(task(cut))
        XCTAssertEqual(SidebarTaskIndicatorProjection.status(of: waiting, detail: model.taskAttentionDetails[cut.id]),
                       .reconnecting)
        XCTAssertEqual(TaskAttentionProjection.state(of: waiting, detail: model.taskAttentionDetails[cut.id]), .active,
                       "It needs nothing from the person")

        // The Claude app's minute passes while still offline: nothing goes.
        try await waitUntil { clock.waiting == 1 }
        XCTAssertGreaterThan(clock.requested.first ?? .zero, .seconds(59))
        clock.elapseAll()
        try await waitUntil { model.connectionResumes[cut.id]?.isDue == true }
        let sentOffline = await cutCLI.sentValues.count
        XCTAssertEqual(sentOffline, 1, "Only the request itself")

        // The network is back: the turn continues, as the Claude app continues it.
        model.networkPathChanged(isSatisfied: true)
        try await waitUntil { await cutCLI.sentValues.count == 2 }
        let continuation = await cutCLI.sentValues.last
        XCTAssertEqual(continuation?["message"]?["content"]?.stringValue, "Try again")
        XCTAssertEqual(continuation?["origin"]?["kind"]?.stringValue, "auto-continuation")
        XCTAssertEqual(task(cut)?.status, .running)
        XCTAssertEqual(model.connectionResumes[cut.id]?.isWaiting, false)
        XCTAssertEqual(model.connectionResumes[cut.id]?.continuations, 1)
        let refusedSent = await refusedCLI.sentValues.count
        XCTAssertEqual(refusedSent, 1)
        await cutCLI.emit(.object(["type": .string("result"), "subtype": .string("success"), "is_error": .bool(false),
                                   "result": .string("Done.")]))
        try await waitUntil { model.connectionResumes[cut.id] == nil && task(cut)?.status == .ready }

        // With the setting off, a cut turn stays as it ended.
        fixture.defaults.set(false, forKey: RestartResumePreference.key)
        await model.send(HarnessUserInput(text: "Now the notes"), to: try XCTUnwrap(task(cut)))
        await cutCLI.emit(failure("API Error: Connection dropped (ECONNRESET)"))
        try await waitUntil { task(cut)?.status == .failed }
        XCTAssertNil(model.connectionResumes[cut.id])
        await model.shutdown()
    }

    /// The same for Codex: a turn that failed on its own connection error continues once the network
    /// is back, with the Codex app's Resume (an empty turn, `resume_interrupted_task`).
    func testACodexTurnALostConnectionCutOffContinuesWithTheAppsResume() async throws {
        let root = try directory()
        let executable = root.appending(path: "codex")
        try Data("#!/bin/sh\nprintf 'codex-cli 0.163.0\\n'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let defaults = try suite()
        let session = SessionRecord(harness: .codex, workspaceURL: root, runtimeExecutableURL: executable,
            title: "Offline", status: .ready, providerSessionID: "original", environmentScope: .yardlet)
        let repository = InMemorySessionRepository(sessions: [session])
        let error = JSONValue.object(["message": .string("stream disconnected before completion: error sending request"),
            "codexErrorInfo": .object(["responseStreamDisconnected": .object(["httpStatusCode": .null])])])
        let transport = FakeCodexTransport(responses: codexResponses(latest: "failed", error: error))
        let adapter = codexAdapter(transport: transport, routed: true, executable: executable)
        try await repository.upsert(session)
        let model = AppModel(store: SessionStore(sessions: [session], repository: repository),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults), registry: HarnessRegistry { _, _ in adapter },
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults), preferences: defaults,
            codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults),
            codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: defaults),
            codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults),
            transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults), restoresIndexOnLaunch: false)
        let clock = ManualSleep()
        model.connectionResumeSleep = { try await clock.sleep(for: $0) }
        await model.resume(session)
        model.networkPathChanged(isSatisfied: false)
        await transport.emit(method: "turn/started", params: .object(["threadId": .string("original"),
            "turn": .object(["id": .string("cut"), "status": .string("inProgress"), "items": .array([])])]))
        await transport.emit(method: "turn/completed", params: .object(["threadId": .string("original"),
            "turn": .object(["id": .string("cut"), "status": .string("failed"), "items": .array([]), "error": error])]))
        try await waitUntil { model.connectionResumes[session.id]?.isWaiting == true }
        try await waitUntil { clock.waiting == 1 }
        clock.elapseAll()
        try await waitUntil { model.connectionResumes[session.id]?.isDue == true }
        let offline = await transport.requests.filter { $0.method == "turn/start" }
        XCTAssertTrue(offline.isEmpty)
        model.networkPathChanged(isSatisfied: true)
        var starts: [CodexRPCRequest] = []
        try await waitUntil {
            starts = await transport.requests.filter { $0.method == "turn/start" }
            return !starts.isEmpty
        }
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(starts.first?.params["turnTrigger"], .string("resume_interrupted_task"))
        XCTAssertEqual(starts.first?.params["input"], .array([]), "No words of Yardlet's own reach the model")
        await model.shutdown()
    }

    // MARK: - What the person sees

    func testTheNoticeAndTheSettingRender() throws {
        let directory = try WindowlessRender.directory("auto-resume-qa")
        let notices = TaskProviderNotices(resumedAfterRestart: true)
        XCTAssertTrue(ProviderNoticeLines.showsAnything(notices))
        XCTAssertFalse(ProviderNoticeLines.showsAnything(TaskProviderNotices()))
        // A turn a lost connection cut off says only its state word while it waits for the network.
        let reconnecting = TaskProviderNotices(reconnecting: true)
        XCTAssertTrue(ProviderNoticeLines.showsAnything(reconnecting))
        for (name, shown) in [("notice", notices), ("reconnecting", reconnecting)] {
            let captures = try WindowlessRender.hostedInBothAppearances(name, in: directory, size: NSSize(width: 820, height: 70)) { appearance in
                VStack(spacing: 8) {
                    ProviderNoticeLines(notices: shown)
                    RoundedRectangle(cornerRadius: ParityTheme.composerCornerRadius)
                        .fill(ParityTheme.input)
                        .frame(maxWidth: ParityTheme.contentWidth, minHeight: 36, maxHeight: 36)
                        .padding(.horizontal, 30)
                }
                .padding(.vertical, 8)
                .frame(width: 820, height: 70)
                .background(ParityTheme.canvas)
                .environment(\.colorScheme, appearance.colorScheme)
            }
            for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 4)) }
        }

        // Once the network is back the turn continues as one of its own, with no request of the person's,
        // and the error that ended the last one stays with it.
        let cutAt = Date(timeIntervalSince1970: 1_792_000_000)
        let continued = [
            TranscriptEntry(createdAt: cutAt, content: .user(text: "Build the release", images: nil)),
            TranscriptEntry(createdAt: cutAt.addingTimeInterval(30), content: .assistant(
                text: "Building the bundle now.", isStreaming: false)),
            TranscriptEntry(createdAt: cutAt.addingTimeInterval(240), content: .error(
                message: "API Error: Can't reach the API server — check your internet or DNS (ENOTFOUND)", recoverable: true)),
            TranscriptEntry(createdAt: cutAt.addingTimeInterval(900), content: .user(text: "", images: nil), origin: .provider),
            TranscriptEntry(createdAt: cutAt.addingTimeInterval(960), content: .assistant(
                text: "The build finished; the bundle is in dist/.", isStreaming: false)),
        ]
        for appearance in WindowlessRender.Appearance.allCases {
            let drawing = try ConversationDrawing.draw(
                ConversationTimeline(source: .transcript(entries: continued, harness: .claudeCode, status: .ready,
                                                         latestTurnIsComplete: true)),
                size: NSSize(width: 760, height: 560), appearance: appearance)
            try WindowlessRender.writePNG(drawing.capture.bitmap,
                                          to: directory.appending(path: "connection-continued-\(appearance.suffix).png"))
            let texts = drawing.elements.map(\.description).joined(separator: "\n")
            let error = try XCTUnwrap(texts.range(of: "Can't reach the API server"), texts)
            let answer = try XCTUnwrap(texts.range(of: "The build finished"), texts)
            XCTAssertLessThan(error.lowerBound, answer.lowerBound, "The error stays above the continuation:\n\(texts)")
        }

        let size = NSSize(width: 820, height: 620)
        try WindowlessRender.hostedInBothAppearances("settings-general", in: directory, size: size) { appearance in
            SettingsCenterView(notificationCenter: MenuBarQuietNotificationCenter())
                .environment(\.colorScheme, appearance.colorScheme)
        }
        let host = WindowlessRender.Host(SettingsCenterView(notificationCenter: MenuBarQuietNotificationCenter()), size: size)
        defer { host.close() }
        host.settle()
        let switches = host.accessibilityElements().filter { $0.role == NSAccessibility.Role.checkBox.rawValue }
        XCTAssertTrue(switches.contains { $0.label == L10n.string("Continue running work after a restart") },
            switches.description)
        XCTAssertTrue(switches.contains { $0.label == L10n.string("Memory saver") }, switches.description)

        // A question the quit cut off, asked again where its call was, in place of the row the CLI's
        // refusal written as it quit would draw.
        let start = Date(timeIntervalSince1970: 1_792_000_000)
        let entries = [
            TranscriptEntry(createdAt: start, content: .user(text: "Compare the settings screen with the two apps", images: nil)),
            TranscriptEntry(createdAt: start.addingTimeInterval(240), content: .assistant(
                text: "I've finished the review and the mock. There are six problems; I'll fix them one at a time.", isStreaming: false)),
            TranscriptEntry(createdAt: start.addingTimeInterval(244), content: .activity(HarnessActivity(
                id: "toolu_ask", kind: ClaudeAnswerableTool.askUserQuestion, title: "AskUserQuestion",
                outcome: .failed, output: "The user doesn't want to proceed with this tool use."), state: .failed)),
        ]
        let question = PermissionRequest(id: "perm-ask", title: "Claude has questions", detail: nil, command: nil,
            structured: .questions([PermissionQuestion(question: "What should I fix first?", header: "First fix", options: [
                .init(label: "1. Menu usage line (Recommended)", description: "Full address as the title, harness and amount left below"),
                .init(label: "2 and 3. One account, two folders", description: "Folder names on the connection line and usage group")],
                allowsCustomAnswer: true)]), toolCallID: "toolu_ask")
        let card = TranscriptConversationProjection.conversationRequest(
            question, state: .pending, entry: TranscriptEntry(content: .permission(question, state: .pending)))
        for appearance in WindowlessRender.Appearance.allCases {
            let drawing = try ConversationDrawing.draw(
                ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .ready,
                                                         latestTurnIsComplete: true),
                                     actions: ConversationActions(answer: { _, _ in }, heldRequests: [card])),
                size: NSSize(width: 760, height: 640), appearance: appearance)
            try WindowlessRender.writePNG(drawing.capture.bitmap,
                                          to: directory.appending(path: "question-again-\(appearance.suffix).png"))
            let texts = drawing.elements.map(\.description).joined(separator: "\n")
            XCTAssertTrue(texts.contains("What should I fix first?"), texts)
            XCTAssertTrue(texts.contains("1. Menu usage line (Recommended)"), texts)
            XCTAssertFalse(texts.contains("doesn't want to proceed"), "The cut-off call reads as its question:\n\(texts)")
        }
        // Answered in the window as any question card is: its route carries the picks to the app model,
        // which sends them as the person's message (above).
        var answered: [(String, PermissionStructuredAnswer)] = []
        let window = WindowlessRender.Host(
            ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .ready,
                                                     latestTurnIsComplete: true),
                                 actions: ConversationActions(answer: { answered.append(($0, $1)) }, heldRequests: [card]))
                .frame(width: 760, height: 640, alignment: .top), size: NSSize(width: 760, height: 640))
        defer { window.close() }
        window.settle()
        XCTAssertTrue(window.hosting.pressElement(labelled: L10n.string("Submit answers")),
                      window.accessibilityElements().map(\.description).joined(separator: "\n"))
        window.settle()
        XCTAssertEqual(answered.map(\.0), [card.id])
        XCTAssertEqual(answered.first?.1, .questions([PermissionQuestionAnswer(
            question: "What should I fix first?", selectedLabels: ["1. Menu usage line (Recommended)"])]))

        // A Codex question the quit cut off: its own card again, in place of the expired one the
        // stopped runtime left, and answered by the Codex card's route.
        let reducer = CodexTaskReducer()
        var codex = CodexTaskState.empty
        reducer.applySnapshot(.object(["id": .string("thread"), "status": .object(["type": .string("idle")]),
            "historyMode": .string("paginated"), "turns": .array([.object([
                "id": .string("asking"), "status": .string("interrupted"), "itemsView": .string("full"),
                "items": .array([
                    .object(["id": .string("request"), "type": .string("userMessage"),
                             "content": .array([.object(["type": .string("text"), "text": .string("Clean up the release branches")])])]),
                    .object(["id": .string("said"), "type": .string("agentMessage"),
                             "text": .string("There are two branches to clean up. Choose which one to merge into.")])])])])]), to: &codex)
        reducer.applyServerRequest(id: .string("input-1"), method: "item/tool/requestUserInput", params: .object([
            "threadId": .string("thread"), "turnId": .string("asking"), "itemId": .string("item-ask"),
            "questions": .array([.object(["id": .string("q1"), "header": .string("Branch"), "isOther": .bool(true),
                "question": .string("Which branch should I merge into?"),
                "options": .array([.object(["label": .string("main"), "description": .string("Ship right away")]),
                                   .object(["label": .string("release"), "description": .string("In the next release")])])])])]),
            sequence: 1, to: &codex)
        let codexCard = CodexRequestResponseProjection.request(try XCTUnwrap(codex.serverRequestsByID["s:input-1"]))
        reducer.endRuntime(in: &codex)
        let expired = L10n.string("Approval expired because the provider runtime stopped.")
        for appearance in WindowlessRender.Appearance.allCases {
            let drawing = try ConversationDrawing.draw(
                ConversationTimeline(source: .codex(codex, workspaceURL: URL(filePath: "/tmp"), historySelection: nil),
                                     actions: ConversationActions(heldRequests: [codexCard])),
                size: NSSize(width: 760, height: 640), appearance: appearance)
            try WindowlessRender.writePNG(drawing.capture.bitmap,
                                          to: directory.appending(path: "question-again-codex-\(appearance.suffix).png"))
            let texts = drawing.elements.map(\.description).joined(separator: "\n")
            XCTAssertTrue(texts.contains("Which branch should I merge into?"), texts)
            XCTAssertFalse(texts.contains(expired), "The expired card gives way to the question:\n\(texts)")
        }
        var codexAnswers: [(String, CodexServerRequestResponse)] = []
        let codexWindow = WindowlessRender.Host(
            ConversationTimeline(source: .codex(codex, workspaceURL: URL(filePath: "/tmp"), historySelection: nil),
                                 actions: ConversationActions(respondToCodexRequest: { codexAnswers.append(($0, $1)) },
                                                              heldRequests: [codexCard]))
                .frame(width: 760, height: 640, alignment: .top), size: NSSize(width: 760, height: 640))
        defer { codexWindow.close() }
        codexWindow.settle()
        XCTAssertTrue(codexWindow.hosting.pressElement(labelled: L10n.string("Send answer")),
                      codexWindow.accessibilityElements().map(\.description).joined(separator: "\n"))
        codexWindow.settle()
        XCTAssertEqual(codexAnswers.map(\.0), ["s:input-1"])
        XCTAssertEqual(codexAnswers.first?.1, .toolUserInput(answers: ["q1": ["main"]]))
    }

    // MARK: - Fixtures

    private func task(_ harness: HarnessKind, status: SessionStatus, providerSessionID: String? = "provider",
                      updatedAt: Date = Date()) -> SessionRecord {
        SessionRecord(harness: harness, workspaceURL: URL(filePath: "/tmp/restart-resume"),
            runtimeExecutableURL: URL(filePath: "/tmp/agent"), title: "Task", status: status, updatedAt: updatedAt,
            providerSessionID: providerSessionID.map { "\($0)-\(UUID().uuidString)" })
    }

    private func entry(for session: SessionRecord, waiting: Bool = false) -> RestartResumeRecord.Entry {
        RestartResumeRecord.Entry(sessionID: session.id, harness: session.harness,
            providerSessionID: session.providerSessionID ?? "", connection: session.connection, wasWaitingForApproval: waiting)
    }

    /// Claude Code's saved records (CLI 2.1.299), each the parent of the next, as one conversation's
    /// chain.
    private func savedRecords(_ records: [[String: Any]], conversation: String) throws -> [String] {
        var parent: String?
        return try records.map { record in
            var record = record
            let uuid = UUID().uuidString.lowercased()
            record["uuid"] = uuid
            record["parentUuid"] = parent ?? NSNull()
            record["sessionId"] = conversation
            parent = uuid
            return String(decoding: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), as: UTF8.self)
        }
    }

    /// The person's request for a recurring session job, Claude's `CronCreate` call, its result and
    /// Claude's answer.
    private func sessionJob(at date: Date) -> [[String: Any]] {
        let request: [String: Any] = ["role": "user", "content": "Check the inbox every 15 minutes."]
        let answer: [String: Any] = ["role": "assistant", "content": [["type": "text", "text": "Scheduled every 15 minutes."]]]
        return [["type": "user", "timestamp": Self.timestamp(date), "message": request],
                jobCall("create", input: ["cron": "7,22,37,52 * * * *", "prompt": "Check the inbox", "recurring": true], at: date),
                jobResult("create", ["id": "inbox", "humanSchedule": "7,22,37,52 * * * *", "recurring": true, "durable": false],
                          at: date),
                ["type": "assistant", "timestamp": Self.timestamp(date), "message": answer]]
    }

    private func jobCall(_ id: String, name: String = "CronCreate", input: [String: Any], at date: Date) -> [String: Any] {
        let call: [String: Any] = ["type": "tool_use", "id": id, "name": name, "input": input]
        let message: [String: Any] = ["role": "assistant", "content": [call]]
        return ["type": "assistant", "timestamp": Self.timestamp(date), "message": message]
    }

    private func jobResult(_ call: String, _ result: [String: Any], error: Bool = false, at date: Date) -> [String: Any] {
        let block: [String: Any] = ["type": "tool_result", "tool_use_id": call, "content": "Scheduled.", "is_error": error]
        let message: [String: Any] = ["role": "user", "content": [block]]
        return ["type": "user", "timestamp": Self.timestamp(date), "toolUseResult": result, "message": message]
    }

    private static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    private func suite() throws -> UserDefaults {
        let name = testDefaultsSuite("NativeHarnessClientTests.RestartResume")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        return defaults
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "restart-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func codexAdapter(transport: FakeCodexTransport, routed: Bool,
                              executable: URL = URL(filePath: "/tmp/codex")) -> any HarnessAdapter {
        let direct = CodexAdapter(executableURL: executable, transport: transport)
        return routed ? YHPCodexCompatibilityAdapter(adapter: direct, manifest: HarnessProtocolCompatibilityManifest.codex()) : direct
    }

    private func codexResponses(latest: String, runtime: String = "idle", error: JSONValue? = nil) -> [String: [JSONValue]] {
        var fields: [String: JSONValue] = ["id": .string("cut"), "status": .string(latest), "itemsView": .string("full"), "items": .array([
            .object(["id": .string("cut-user"), "type": .string("userMessage"), "content": .array([
                .object(["type": .string("text"), "text": .string("Build the release")])])])])]
        if let error { fields["error"] = error }
        let turn = JSONValue.object(fields)
        let thread = JSONValue.object(["thread": .object(["id": .string("original"),
            "status": .object(["type": .string(runtime)]), "historyMode": .string("paginated"), "turns": .array([turn])])])
        let page = JSONValue.object(["data": .array([turn]), "nextCursor": .null])
        return ["initialize": [.object(["platformOs": .string("macos")])],
                "thread/start": [thread], "thread/resume": [thread, thread],
                "thread/items/list": Array(repeating: .object(["data": .array([]), "nextCursor": .null]), count: 4),
                "thread/read": Array(repeating: thread, count: 4), "thread/turns/list": Array(repeating: page, count: 4),
                "turn/start": [.object(["turn": .object(["id": .string("continued")])])],
                "turn/interrupt": [.object([:])]]
    }

    /// A Claude stream frame with a piece of the answer: the provider showing work.
    private func textDelta(_ text: String) -> JSONValue {
        .object(["type": .string("stream_event"), "event": .object([
            "type": .string("content_block_delta"),
            "delta": .object(["type": .string("text_delta"), "text": .string(text)])])])
    }

    /// Stands in for the start window's clock: a wait ends only when the test lets its time pass, or
    /// when it is cancelled.
    private final class ManualSleep: @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
        private var durations: [Duration] = []

        var waiting: Int { lock.withLock { waiters.count } }
        var requested: [Duration] { lock.withLock { durations } }

        func sleep(for duration: Duration) async throws {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let cancelled = lock.withLock {
                        durations.append(duration)
                        guard !Task.isCancelled else { return true }
                        waiters.append((id, continuation))
                        return false
                    }
                    if cancelled { continuation.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                let waiter = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                    return waiters.remove(at: index).continuation
                }
                waiter?.resume(throwing: CancellationError())
            }
        }

        /// The longest-waiting sleep's time passes.
        func elapseOldest() {
            let waiter = lock.withLock { waiters.isEmpty ? nil : waiters.removeFirst() }
            waiter?.continuation.resume()
        }

        func elapseAll() {
            let all = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
                defer { waiters.removeAll() }
                return waiters.map(\.continuation)
            }
            all.forEach { $0.resume() }
        }
    }


    /// Claude tasks on Claude Code's production route (the YHP wrapper over `ClaudeAdapter`) with a
    /// fake CLI process, an account home of their own, and preferences of their own.
    private final class ClaudeFixture {
        let defaults: UserDefaults
        let root: URL
        let cli: URL
        let connection: ProviderConnection
        let transports = TransportLog()

        final class TransportLog: @unchecked Sendable {
            private let lock = NSLock()
            private var transports: [FakeClaudeTransport] = []
            func make() -> FakeClaudeTransport {
                let transport = FakeClaudeTransport()
                lock.withLock { transports.append(transport) }
                return transport
            }
            var all: [FakeClaudeTransport] { lock.withLock { transports } }
        }

        init() throws {
            defaults = UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests.RestartResume"))!
            root = FileManager.default.temporaryDirectory.appending(path: "restart-resume-\(UUID().uuidString)")
            let home = root.appending(path: "home")
            try FileManager.default.createDirectory(at: home.appending(path: "projects"), withIntermediateDirectories: true)
            try Data().write(to: home.appending(path: ".signed-in"))
            cli = root.appending(path: "claude-fixture")
            try Data("""
            #!/bin/sh
            if [ "$1" = "--version" ]; then echo '2.1.299 (Claude Code)'; exit 0; fi
            echo '{"loggedIn":true}'

            """.utf8).write(to: cli)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
            connection = ProviderConnection(id: "restart-home", name: "restart-home", harness: .claudeCode,
                providerID: nil, homePath: home.path, credentialSelector: nil)
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        func session(title: String, status: SessionStatus, updatedAt: Date) -> SessionRecord {
            SessionRecord(harness: .claudeCode, workspaceURL: root, runtimeExecutableURL: cli, title: title,
                titleOrigin: .manual, status: status, updatedAt: updatedAt,
                providerSessionID: UUID().uuidString.lowercased(), connection: connection)
        }

        /// Writes the task's saved conversation where its account's CLI keeps it.
        func save(_ records: [String], for session: SessionRecord) throws {
            let folder = root.appending(path: "home/projects/project")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data((records.joined(separator: "\n") + "\n").utf8)
                .write(to: folder.appending(path: "\(session.providerSessionID!).jsonl"))
        }

        @MainActor
        func model(store: SessionStore) -> AppModel {
            let transports = transports
            let model = AppModel(store: store,
                runtimeSelections: RuntimeSelectionStore(defaults: defaults),
                registry: HarnessRegistry { _, url in
                    YHPProviderCompatibilityAdapter(
                        adapter: ClaudeAdapter(executableURL: url, transportFactory: { _ in transports.make() }),
                        manifest: HarnessProtocolCompatibilityManifest.claude()
                    )
                },
                codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults),
                preferences: defaults,
                codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults),
                codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: defaults),
                codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults),
                transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
                restoresIndexOnLaunch: false)
            try? model.connections.save(connection)
            return model
        }

        /// The conversations Yardlet asked to continue, in the order their processes started.
        @MainActor
        func continuedConversations() async -> [String] {
            var conversations: [String] = []
            for transport in transports.all {
                let asked = await transport.sentValues.contains {
                    $0["message"]?["content"]?.stringValue == RestartContinuation.claudeText
                }
                if asked, let conversation = await transport.configuration?.providerSessionID {
                    conversations.append(conversation)
                }
            }
            return conversations
        }

        @MainActor
        func transport(for conversation: String) async throws -> FakeClaudeTransport {
            var found: FakeClaudeTransport?
            for transport in transports.all {
                if await transport.configuration?.providerSessionID == conversation { found = transport }
            }
            return try XCTUnwrap(found, "No process for \(conversation)")
        }

        /// The next launch: the index read back, which leaves no turn running, then the app model.
        @MainActor
        func relaunch(repository: InMemorySessionRepository, selecting selection: UUID? = nil) async throws -> AppModel {
            let store = SessionStore(repository: repository)
            try await store.restore()
            if let selection { store.selectedSessionID = selection }
            return model(store: store)
        }
    }
}

private extension NSView {
    /// Presses the first accessibility element labelled `label`, as an assistive app would.
    func pressElement(labelled label: String) -> Bool {
        let attribute = "AXEnhancedUserInterface" as NSString
        let app = NSApplication.shared
        let previous = (app.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: attribute)?
            .takeUnretainedValue() as? NSNumber)?.boolValue ?? false
        _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true),
                        with: attribute)
        defer {
            _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                            with: NSNumber(value: previous), with: attribute)
        }
        func visit(_ node: AnyObject) -> AnyObject? {
            for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                if (child.accessibilityLabel?() ?? nil) == label { return child }
                if let found = visit(child) { return found }
            }
            return nil
        }
        return visit(self)?.accessibilityPerformPress?() ?? false
    }
}
