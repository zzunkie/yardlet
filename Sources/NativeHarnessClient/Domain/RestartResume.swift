import Foundation

/// Settings › General › "Continue running work after a restart". On by default, as both apps
/// do it without a setting: the Claude app after any quit, the Codex app after an update. Yardlet
/// continues both after any quit (decision of 2026-10-16: always, as the Claude app does).
enum RestartResumePreference {
    static let key = "Yardlet.continueWorkAfterRestart"

    static func isOn(in defaults: UserDefaults = .yardlet) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}

/// Why Yardlet quit, as the record says it. Only a quit to install an update (Install Update…, or
/// Sparkle's Install and Relaunch) sets `.update`.
enum RestartTrigger: String, Codable, Equatable, Sendable {
    case quit
    case update
}

/// What Yardlet wrote down while quitting about the tasks whose turn the quit cuts off. It lives
/// in Yardlet's own preferences, is read once at the next launch and then removed.
struct RestartResumeRecord: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let sessionID: UUID
        let harness: HarnessKind
        let providerSessionID: String
        let connection: ProviderConnection?
        /// The turn was waiting on the person (an approval or a question) rather than working.
        let wasWaitingForApproval: Bool
        /// Messages waited in the task's queue: the first of them is the next turn, sent once the
        /// task is back, rather than a continuation. Nil in records written before it.
        var sendsQueuedMessages: Bool? = nil
        /// How many times in a row Yardlet had already continued this turn while nobody opened the
        /// task. Nil for none, and in records written before it.
        var unseenContinuations: Int? = nil
        /// When the turn was cut off, for an entry a later quit carried over before Yardlet got to
        /// it. Nil when it was the record's own quit.
        var interruptedAt: Date? = nil
        /// The task's last activity before the quit, which orders the launch: reading the index
        /// back moves every cut-off task's time to the launch. Nil in records written before it.
        var lastActiveAt: Date? = nil
        /// The question the turn waited on the person to answer (Claude Code's `AskUserQuestion`),
        /// when that was all it waited on. The quit ended the call that asked it, so the next launch
        /// asks it again on its card, answered by the person's next message, instead of continuing
        /// the turn. Nil otherwise, and in records written before it.
        var question: PermissionRequest? = nil
        /// The same for a Codex turn: the `item/tool/requestUserInput` request it waited on, as
        /// Yardlet keeps a pending server request.
        var codexQuestion: CodexPendingServerRequest? = nil

        /// The question the turn waited on, whichever provider asked it.
        var cutOffQuestion: RestartQuestion? {
            question.map(RestartQuestion.request) ?? codexQuestion.map(RestartQuestion.codex)
        }
    }

    let trigger: RestartTrigger
    let recordedAt: Date
    let entries: [Entry]

    static let preferenceKey = "Yardlet.restartResumeRecord"

    static func load(from defaults: UserDefaults) -> Self? {
        guard let data = defaults.data(forKey: preferenceKey) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save(to defaults: UserDefaults) {
        guard !entries.isEmpty, let data = try? JSONEncoder().encode(self) else {
            defaults.removeObject(forKey: Self.preferenceKey)
            return
        }
        defaults.set(data, forKey: Self.preferenceKey)
    }

    static func remove(from defaults: UserDefaults) {
        defaults.removeObject(forKey: preferenceKey)
    }
}

/// Which cut-off turns continue after Yardlet opens again.
/// Claude Code and Codex tasks follow the Claude app's rules, with Yardlet's adjustments below;
/// each provider is asked to continue the way its own app asks it.
///
/// - The Claude app (2.42304, `LocalSessionManager`): any quit, an update included, marks a session
///   whose turn was open (`interruptedByQuitAt`) unless messages wait in its queue. Yardlet keeps such
///   a task too and, instead of asking it to continue, sends its first waiting message, the turn the
///   person or another task already asked for (a parent waiting on its children would otherwise stay
///   stopped until someone opened it). At the next launch the app resumes up to four, the most
///   recent first, in the background; the rest, and one that was waiting on the person, when it is
///   opened. Older than a day, never. A turn the app itself resumed in the background is not
///   resumed again until someone has seen it.
/// - Yardlet's adjustments (2026-10-23, after quits that left tasks nobody opened stopped): every
///   cut-off turn continues from launch, the most recent first, with at most `launchLimit` starting
///   at once (`RestartResumeLine`); one waiting on the person still waits to be opened. A quit
///   writes down a turn Yardlet continued unseen too, up to `unseenContinuationLimit` times in a
///   row, and carries over what it had not continued yet. A crash writes nothing, as before.
/// - A turn that waited only on a question (2026-10-24: three tasks waiting on their questions read
///   as unread after an update, with no card) is not continued: the task waits for the person and
///   shows the question again (`Plan.questions`), and their answer goes as their next message, which
///   names the questions (`RestartQuestionAnswer`). Claude Code's `AskUserQuestion` and Codex's
///   `item/tool/requestUserInput` alike. The Claude app continues such a session once the person
///   looks at it, and the Codex app continues such a thread after an update as it continues any
///   (below); in both the model asks again, and neither shows the task waiting before then.
/// - The Codex app (26.1013, `update-resume-state-v1`) continues threads only after an update
///   install, within 15 minutes. Yardlet continues Codex tasks after any quit, by the rules above,
///   sharing the line with Claude Code tasks; subagent threads, which their parent's turn drives,
///   never.
/// - Other harnesses: their apps continue nothing, so neither does Yardlet.
enum RestartResumePolicy {
    /// The Claude app's `864e5` ms, counted from when the turn was cut off.
    static let maxAge: TimeInterval = 24 * 60 * 60
    /// At most this many continuations start at once: the Claude app's launch pass resumes four
    /// (`p>=4`); Yardlet continues the rest in turn rather than leaving them until opened.
    static let launchLimit = 4
    /// How long a continuation counts as starting when its provider shows no work yet, before the
    /// next one in line begins anyway.
    static let startWindow: Duration = .seconds(30)
    /// How many times in a row Yardlet continues a turn nobody has opened since. A quit after the
    /// last of them leaves the task stopped, so quitting again and again cannot keep it going unseen.
    static let unseenContinuationLimit = 3
    /// The harnesses whose cut-off turns continue.
    static let harnesses: Set<HarnessKind> = [.claudeCode, .codex]

    struct Candidate: Equatable, Sendable {
        let session: SessionRecord
        /// Messages wait in the task's queue (Yardlet's or the provider's).
        var hasQueuedMessages = false
        /// The person stopped the turn and the provider has not reported it stopped yet.
        var stoppedByPerson = false
        /// How many times in a row Yardlet has continued the running turn after a restart with
        /// nobody opening the task since; zero for a turn someone started or has seen.
        var unseenContinuations = 0
        /// A Codex subagent thread, which its parent's turn drives.
        var isSubagentThread = false
        /// The question the turn waits on, when it waits on nothing else. A Codex turn keeps running
        /// while it asks, so this, not the task's status, says it waits.
        var waitingQuestion: RestartQuestion? = nil
    }

    /// The entries a quit writes down, whatever made Yardlet quit: the turns it cuts off, then the
    /// entries of the last record Yardlet had not continued yet (`stillToContinue`, each with the
    /// moment its turn was cut off), until a day after that moment.
    static func entries(for candidates: [Candidate], stillToContinue: [RestartResumeRecord.Entry] = [],
                        now: Date = Date(), isOn: Bool) -> [RestartResumeRecord.Entry] {
        guard isOn else { return [] }
        let cutOff: [RestartResumeRecord.Entry] = candidates.compactMap { candidate in
            let session = candidate.session
            guard harnesses.contains(session.harness),
                  session.status == .running || session.status == .waitingForApproval,
                  let providerSessionID = session.providerSessionID, !providerSessionID.isEmpty,
                  !candidate.stoppedByPerson, candidate.unseenContinuations < unseenContinuationLimit,
                  !candidate.isSubagentThread else { return nil }
            // The waiting message is the next turn.
            var entry = RestartResumeRecord.Entry(sessionID: session.id, harness: session.harness,
                providerSessionID: providerSessionID, connection: session.connection,
                wasWaitingForApproval: session.status == .waitingForApproval,
                sendsQueuedMessages: candidate.hasQueuedMessages ? true : nil,
                unseenContinuations: candidate.unseenContinuations > 0 ? candidate.unseenContinuations : nil,
                lastActiveAt: session.updatedAt)
            switch candidate.waitingQuestion {
            case let .request(request)?: entry.question = request
            case let .codex(request)?: entry.codexQuestion = request
            case nil: break
            }
            return entry
        }
        // A task whose turn runs again was decided above; one that is gone is not carried over.
        let idle = Set(candidates.map(\.session).filter {
            $0.status != .running && $0.status != .waitingForApproval
        }.map(\.id))
        let carried = stillToContinue.filter { entry in
            guard idle.contains(entry.sessionID), let interruptedAt = entry.interruptedAt else { return false }
            return now < interruptedAt.addingTimeInterval(maxAge)
        }
        return cutOff + carried
    }

    struct Plan: Equatable, Sendable {
        /// Continued from launch in this order, the most recent first, at most `launchLimit`
        /// starting at once.
        var atLaunch: [UUID] = []
        /// Continued when the person opens the task, until the deadline.
        var whenOpened: [UUID: Date] = [:]
        /// Not continued: the task waits for the person's answer to the question its turn asked.
        var questions: [UUID: RestartQuestion] = [:]
        /// The record's entry for each task above, with the moment its turn was cut off, kept for
        /// the next quit to carry over until Yardlet has continued it.
        var entries: [UUID: RestartResumeRecord.Entry] = [:]
    }

    /// What the next launch does with a record: only tasks still exactly as they were written
    /// down (the same conversation, account and harness), not already running again, and cut off
    /// less than a day ago.
    static func plan(for record: RestartResumeRecord, sessions: [SessionRecord], now: Date = Date(), isOn: Bool) -> Plan {
        guard isOn else { return Plan() }
        var plan = Plan()
        var atLaunch: [(id: UUID, lastActiveAt: Date)] = []
        for var entry in record.entries {
            let interruptedAt = entry.interruptedAt ?? record.recordedAt
            let deadline = interruptedAt.addingTimeInterval(maxAge)
            guard now < deadline, harnesses.contains(entry.harness),
                  let session = sessions.first(where: { $0.id == entry.sessionID }),
                  session.harness == entry.harness, session.providerSessionID == entry.providerSessionID,
                  session.connection == entry.connection,
                  session.status != .running, session.status != .waitingForApproval else { continue }
            entry.interruptedAt = interruptedAt
            plan.entries[session.id] = entry
            if let question = entry.cutOffQuestion {
                plan.questions[session.id] = question
            } else if entry.wasWaitingForApproval {
                plan.whenOpened[session.id] = deadline
            } else {
                atLaunch.append((session.id, entry.lastActiveAt ?? session.updatedAt))
            }
        }
        plan.atLaunch = atLaunch.sorted { $0.lastActiveAt > $1.lastActiveAt }.map(\.id)
        return plan
    }
}

/// The continuations a launch starts in turn: the most recent first, at most `limit` starting at
/// once. One stops counting as starting once its provider shows work, after
/// `RestartResumePolicy.startWindow`, or at once when there was nothing to continue; the next in
/// line takes its place.
struct RestartResumeLine: Equatable, Sendable {
    var limit = RestartResumePolicy.launchLimit
    /// Not begun yet, in the order they begin.
    private(set) var waiting: [UUID] = []
    /// Begun, and their provider has shown no work yet.
    private(set) var starting: Set<UUID> = []

    mutating func append(_ ids: [UUID]) {
        for id in ids where !waiting.contains(id) && !starting.contains(id) { waiting.append(id) }
    }

    /// The next task to begin, now counted as starting, while fewer than `limit` are.
    mutating func next() -> UUID? {
        guard starting.count < limit, !waiting.isEmpty else { return nil }
        let id = waiting.removeFirst()
        starting.insert(id)
        return id
    }

    /// The task's continuation started, or there was nothing to start: its place is free. False
    /// when it was not starting.
    @discardableResult
    mutating func finishStarting(_ id: UUID) -> Bool {
        starting.remove(id) != nil
    }

    /// Takes a task out of line before it begins, as when the person opens it first. False when it
    /// was not waiting.
    @discardableResult
    mutating func removeWaiting(_ id: UUID) -> Bool {
        guard let index = waiting.firstIndex(of: id) else { return false }
        waiting.remove(at: index)
        return true
    }
}

/// What cut a turn short, which decides what its provider is sent to continue it, as the provider's
/// own app sends it.
enum TurnCut: String, Codable, Equatable, Sendable {
    /// Yardlet's quit ended the runtime mid-turn (`RestartResumePolicy`).
    case quit
    /// The provider could not reach its API, or lost it mid-response, and ended the turn on its own
    /// connection error (`ConnectionResumePolicy`).
    case connection
    /// The same, because the Mac slept mid-response: Claude Code's "Connection lost while your
    /// computer was asleep".
    case sleep
}

/// A provider that can continue a turn Yardlet's quit or a lost connection cut off, the way its own
/// desktop app does.
protocol HarnessInterruptedTurnContinuing: Actor {
    /// Starts the continuation. False when the provider's own record says the turn had not ended
    /// that way, so there is nothing to continue.
    func continueInterruptedTurn(in session: HarnessSessionHandle, after cut: TurnCut) async throws -> Bool
}

/// The words each provider is sent, exactly as its app sends them.
enum RestartContinuation {
    /// The Claude app's `gu` (`index.chunk-B5tintml.js`), sent in English as a user message with
    /// `origin: {kind: "auto-continuation"}`; the app does not translate it.
    static let claudeText = "The app was quit while you were working. Please continue from where you left off."
    /// The Claude app 3.1623.3's continuation of a turn its connection error ended, once its API
    /// answers again (`connectionRecoveryNoteTurnEnd`): "Try again", also `auto-continuation`.
    static let claudeAfterConnection = "Try again"
    /// The Claude app 3.1623.3's continuation of a turn the Mac's sleep cut off (`tryBeginSleepAutoResume`,
    /// and its sleep band's Continue). Yardlet sends it as `auto-continuation` too.
    static let claudeAfterSleep = "My computer went to sleep while you were working. Please continue from where you left off."
    /// Claude Code's provenance for a message the host sent on its own.
    static let claudeOrigin = "auto-continuation"
    /// The Claude app 4.29's retry of a turn an error ended (`retryLastTurn`, its `retryNudge`), which
    /// the person asks for on the error card: "Try again" in the app's language, sent as the person's
    /// message.
    static var claudeRetry: String { L10n.string("Retry message") }
    /// The Codex app's empty `turn/start` after an update (`COl`: `continuationInput: []`). Its
    /// app has no continuation after a plain quit, so that one is classified the same way: the
    /// app opened again and continued on its own.
    static let codexTurnTrigger = "app_update_resume"
    /// The Codex app 26.1016's Resume on a turn its connection failed (`resume_interrupted_task`):
    /// the same empty `turn/start` on the idle thread.
    static let codexResumeTrigger = "resume_interrupted_task"

    /// What Claude Code is sent after each cut.
    static func claudeText(after cut: TurnCut) -> String {
        switch cut {
        case .quit: claudeText
        case .connection: claudeAfterConnection
        case .sleep: claudeAfterSleep
        }
    }
}

/// When a turn its lost connection cut off continues on its own (2026-10-24): once
/// the network is back, at the Claude app's times after the cut (`YJ`: one, five and fifteen minutes,
/// so a network that is only coming up is not hit at once), up to three times in a row until the person
/// sends something. Only a cut the provider's own error names as the connection's continues
/// (`ClaudeProtocol.turnCut(ofResult:)`, `CodexTurnErrorPresentation.isConnectionCut`); a stop, a limit,
/// a sign-in or server error and a failed tool never do. The restart setting turns it off as well.
enum ConnectionResumePolicy {
    static let delays: [TimeInterval] = [60, 300, 900]
    static var limit: Int { delays.count }
}

/// A task whose turn a lost connection cut off: why, when, and how many times in a row Yardlet has
/// continued it since the person last sent anything.
struct ConnectionResume: Equatable, Sendable {
    var cut: TurnCut
    var cutAt: Date
    var continuations: Int
    /// Waiting for the network and its time to continue; false while the continuation runs.
    var isWaiting: Bool
    /// Its time has come (`dueAt`); it goes once the network is up.
    var isDue = false

    /// The earliest the next continuation goes.
    var dueAt: Date {
        cutAt.addingTimeInterval(ConnectionResumePolicy.delays[min(continuations, ConnectionResumePolicy.limit - 1)])
    }
}

/// A question a quit cut off, as its provider asked it: a request of the shared transcript (Claude
/// Code's `AskUserQuestion`), or a Codex server request (`item/tool/requestUserInput`).
enum RestartQuestion: Equatable, Sendable {
    case request(PermissionRequest)
    case codex(CodexPendingServerRequest)
}

/// The person's answer to a question a restart cut off, sent as their next message. The call that
/// asked it ended with the quit, so the message says which question each answer is for: each
/// question answered, its answer on the next line (several picks joined with ", ", the person's own
/// words as they wrote them), a blank line between questions. A skipped question is left out, and
/// with every question skipped there is nothing to send. A question the provider sent no words for
/// is its answer alone.
enum RestartQuestionAnswer {
    static func message(questions: [PermissionQuestion], answers: [PermissionQuestionAnswer]) -> String {
        message(questions.map { question in
            (question.question, answers.first { $0.question == question.question }?.values ?? [])
        })
    }

    /// Each question's words, if it has any, with what it was answered with, in the questions' order.
    static func message(_ answered: [(question: String?, values: [String])]) -> String {
        answered.compactMap { question, values -> String? in
            let values = values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !values.isEmpty else { return nil }
            let answer = values.joined(separator: ", ")
            guard let question = question?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty
            else { return answer }
            return question + "\n" + answer
        }.joined(separator: "\n\n")
    }
}
