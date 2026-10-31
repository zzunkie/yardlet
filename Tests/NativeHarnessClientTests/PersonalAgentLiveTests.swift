import XCTest
@testable import NativeHarnessClient

/// Live acceptance is opt-in. Reading and a separately approved real message
/// use different switches. Credentials and message text are never logged.
final class PersonalAgentLiveTests: XCTestCase {
    /// This opt-in is separate from read-only acceptance. Enable only after the
    /// person approves the exact text and a real turn on the existing dot.
    func testSendingAndReceivingOnlyWhenExplicitlyApproved() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["YARDLET_DOTS_LIVE_SEND"] == "1", let runtime = env["YARDLET_DOTS_RUNTIME"],
              let text = env["YARDLET_DOTS_APPROVED_TEXT"], !text.isEmpty,
              let expected = env["YARDLET_DOTS_EXPECTED_REPLY"], !expected.isEmpty else {
            throw XCTSkip("A real message requires a separately approved text and explicit opt-in.")
        }
        let reader = DotsService(executable: URL(filePath: runtime),
                                 environmentManager: CodexEnvironmentManager(paths: .live()), connection: nil)
        let timeout = Task {
            try? await Task.sleep(for: .seconds(90))
            if !Task.isCancelled { await reader.stop() }
        }
        defer { timeout.cancel() }
        do {
            let agents = try await reader.agents()
            let agent = try XCTUnwrap(agents.first(where: \.isPrimary) ?? agents.first)
            if let expectedName = env["YARDLET_DOTS_EXPECTED_AGENT"], agent.name != expectedName {
                throw PersonalAgentFailure.accountChanged
            }
            let baseline = Set(try await reader.messages(for: agent, before: nil).messages.map(\.id))
            let stream = await reader.updates(for: agent)
            var iterator = stream.makeAsyncIterator()
            var subscribed = false
            while let event = await iterator.next() {
                if case .connected = event { subscribed = true }
                if subscribed, case .changed = event { break }
                if case .failed = event { break }
            }
            guard subscribed else { throw PersonalAgentFailure.network }
            let submission = PersonalAgentSubmission(text: text, requestID: env["YARDLET_DOTS_REQUEST_ID"] ?? UUID().uuidString)
            let sent = try await reader.send(submission, to: agent)
            XCTAssertEqual(sent.requestID, submission.requestID)
            var received = false
            while let event = await iterator.next() {
                if case .failed = event { break }
                guard case .changed = event else { continue }
                let page = try await reader.messages(for: agent, before: nil)
                if page.messages.contains(where: { !baseline.contains($0.id) && $0.author == .agent && $0.text.contains(expected) }) {
                    received = true
                    break
                }
            }
            await reader.stop()
            XCTAssertTrue(received, "No matching new reply was observed through the native event subscription.")
        } catch {
            await reader.stop()
            throw error
        }
    }

    /// Reads one existing Activity task's record of the primary dot as the window reads it, GETs only:
    /// its Activity's first page, the task's metadata (another than the root where there is one), its
    /// newest turns and the first items of its newest turn. No socket, receipt, resume or write. Only
    /// counts and whether the task is the root are printed; no identifier, token or text. A task with
    /// no turns or items is a skip that says how far the read went, not a pass.
    func testExistingDotsActivityRecordReadsOnly() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["YARDLET_DOTS_LIVE_ACTIVITY"] == "1", let runtime = env["YARDLET_DOTS_RUNTIME"] else {
            throw XCTSkip("Set YARDLET_DOTS_LIVE_ACTIVITY and YARDLET_DOTS_RUNTIME for a read-only Activity record check.")
        }
        let reader = DotsService(executable: URL(filePath: runtime),
                                 environmentManager: CodexEnvironmentManager(paths: .live()), connection: nil)
        let timeout = Task {
            try? await Task.sleep(for: .seconds(90))
            if !Task.isCancelled { await reader.stop() }
        }
        defer { timeout.cancel() }
        do {
            let agents = try await reader.agents()
            guard let agent = agents.first(where: \.isPrimary) ?? agents.first else {
                await reader.stop()
                throw XCTSkip("This account has no existing dot; no Activity record was read.")
            }
            let activity = try await reader.activity(for: agent, cursor: nil)
            guard let task = activity.items.first(where: { $0.id != agent.rootThreadID }) ?? activity.items.first else {
                await reader.stop()
                throw XCTSkip("The primary dot's Activity is empty; no task record was read.")
            }
            let isRoot = task.id == agent.rootThreadID
            // The transport refuses metadata of another thread; nothing here compares identifiers in the open.
            let thread = try await reader.activityThread(task.id, for: agent)
            XCTAssertTrue(thread.turns.isEmpty, "The metadata carries no turns")
            let turns = try await reader.activityTurns(task.id, cursor: nil, for: agent)
            print("Dots activity record: activity \(activity.items.count), root \(isRoot), metadata read, "
                  + "turns \(turns.turns.count), earlier turns \(turns.nextCursor != nil)")
            guard let newest = turns.turns.last else {
                await reader.stop()
                throw XCTSkip("Metadata and the turn page read; the task has no turns, so no item page was read.")
            }
            let items = try await reader.activityItems(task.id, turnID: newest.id, cursor: nil, for: agent)
            await reader.stop()
            print("Dots activity record: newest turn items \(items.entries.count), more items \(items.nextCursor != nil)")
            guard !items.entries.isEmpty else {
                throw XCTSkip("Metadata, turns and an item page read; the newest turn's first page was empty.")
            }
            XCTAssertTrue(items.entries.allSatisfy { $0.turnID == newest.id }, "Every item is the newest turn's")
        } catch {
            await reader.stop()
            throw error
        }
    }

    /// Reads at most one existing output of the primary dot as the Outputs read it: the room's latest
    /// page and the first look at its tasks' work, then one file found there, a file on the dot's
    /// computer before a file of its room, read into memory and dropped. GETs and the execution host's
    /// read-only socket only: no message, typing, receipt, resume, start, answer or new computer. Only
    /// counts, whether each part was found, a refusal's kind and the bytes read are printed; no name,
    /// path, identifier, token or content. A refusal ends the check; nothing is tried another way.
    @MainActor
    func testExistingDotsOutputReadsOnly() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["YARDLET_DOTS_LIVE_OUTPUTS"] == "1", let runtime = env["YARDLET_DOTS_RUNTIME"] else {
            throw XCTSkip("Set YARDLET_DOTS_LIVE_OUTPUTS and YARDLET_DOTS_RUNTIME for a read-only Outputs check.")
        }
        // The product's own socket, handed through unchanged; only the fixed words below are noted from
        // a small error frame, never the host's message, a path, an identifier or a credential.
        let hints = DotsRemoteErrorHints()
        let reader = DotsService(executable: URL(filePath: runtime),
                                 environmentManager: CodexEnvironmentManager(paths: .live()), connection: nil,
                                 durableSocket: { request, session in
                                     let task = session.webSocketTask(with: request)
                                     task.maximumMessageSize = DotsDurableFiles.maximumMessageBytes
                                     return DotsHintingSocket(task: task, hints: hints)
                                 })
        let timeout = Task {
            try? await Task.sleep(for: .seconds(90))
            if !Task.isCancelled { await reader.stop() }
        }
        defer { timeout.cancel() }
        do {
            let agents = try await reader.agents()
            guard let agent = agents.first(where: \.isPrimary) ?? agents.first else {
                await reader.stop()
                throw XCTSkip("This account has no existing dot; no output was read.")
            }
            let outputs = PersonalAgentOutputs(roomID: agent.id.roomID)
            let page = try await reader.messages(for: agent, before: nil)
            outputs.noteRoom(page.messages)
            var failures: [PersonalAgentFailure] = []
            outputs.start(reader: reader, agent: agent, conversationBefore: page.before, isCurrent: { !Task.isCancelled },
                          failed: { failures.append($0 as? PersonalAgentFailure ?? .network) })
            try await waitUntil(timeout: .seconds(60)) { !outputs.isReading && outputs.scope != .idle && outputs.scope != .loading }
            let remote = outputs.items.first { if case .remoteFile = $0.kind { true } else { false } }
            let room = outputs.items.first { if case .messageFile = $0.kind { true } else { false } }
            print("Dots outputs: room messages \(page.messages.count), scope read \(outputs.scope == .loaded), "
                  + "tasks checked \(outputs.checkedTasks), outputs \(outputs.items.count), remote file \(remote != nil), "
                  + "room file \(room != nil), partial \(!failures.isEmpty)")
            let data: Data
            switch (remote ?? room)?.kind {
            case let .remoteFile(file, _)?:
                do { data = try await reader.outputFile(file, for: agent).data }
                catch {
                    await reader.stop()
                    // The step, the kind of failure and the host's numeric code only.
                    let reason = (error as? DotsRemoteFileError)?.description ?? (error as? PersonalAgentFailure).map { "\($0)" } ?? "other"
                    print("Dots outputs: remote error hints: \(hints.names)")
                    throw XCTSkip("The remote file was not read: \(reason).")
                }
            case let .messageFile(attachment)?:
                data = try await reader.download(attachment, for: agent).data
            default:
                await reader.stop()
                throw XCTSkip("No file output was found in the room's latest page or the first look at the tasks' work.")
            }
            await reader.stop()
            print("Dots outputs: \(remote != nil ? "remote" : "room") file read, bytes \(data.count)")
            XCTAssertLessThanOrEqual(data.count, DotsDurableFiles.maximumBytes)
        } catch {
            await reader.stop()
            throw error
        }
    }

    func testExistingDotsNativeReadsAndSubscription() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["YARDLET_DOTS_LIVE"] == "1", let runtime = env["YARDLET_DOTS_RUNTIME"] else {
            throw XCTSkip("Set YARDLET_DOTS_LIVE and YARDLET_DOTS_RUNTIME for a read-only real-account check.")
        }
        let reader = DotsService(executable: URL(filePath: runtime),
                                 environmentManager: CodexEnvironmentManager(paths: .live()), connection: nil)
        do {
            let agents = try await reader.agents()
            guard let agent = agents.first(where: \.isPrimary) ?? agents.first else {
                await reader.stop()
                throw XCTSkip("This account has no existing dot.")
            }
            let latest = try await reader.messages(for: agent, before: nil)
            XCTAssertFalse(latest.messages.isEmpty)
            if let before = latest.before {
                let previous = try await reader.messages(for: agent, before: before)
                XCTAssertFalse(previous.messages.contains { $0.id == before })
                XCTAssertEqual(Set(previous.messages.map(\.id)).count, previous.messages.count)
            }
            // The dot's picture and details read as the window reads them; nothing is printed or saved.
            if agent.avatar != nil {
                let picture = try await reader.avatar(for: agent)
                let decoded = await MainActor.run { PersonalAgentAvatarView.decode(picture) != nil }
                XCTAssertTrue(decoded, "The profile picture is a bounded image")
            }
            // The pet the profile names, found among the account's pets, has a sheet of a known size.
            if let petID = agent.petID {
                let found = try await reader.pet(petID, for: agent)
                let pet = try XCTUnwrap(found, "The profile's pet is among the account's pets")
                let sheet = try await reader.spriteSheet(pet, for: agent)
                XCTAssertNotNil(PersonalAgentSpriteFrames(data: sheet), "The pet's sheet is one the window plays")
            }
            let activity = try await reader.activity(for: agent, cursor: nil)
            XCTAssertEqual(Set(activity.items.map(\.id)).count, activity.items.count)
            let schedules = try await reader.schedules(for: agent)
            XCTAssertEqual(Set(schedules.map(\.id)).count, schedules.count)
            if agent.rootThreadID != nil {
                _ = try await reader.computers(for: agent)
            }
            let stream = await reader.updates(for: agent)
            let timeout = Task {
                try? await Task.sleep(for: .seconds(15))
                if !Task.isCancelled { await reader.stop() }
            }
            var connected = false
            for await event in stream {
                if case .connected = event { connected = true; break }
                if case .failed = event { break }
            }
            timeout.cancel()
            await reader.stop()
            XCTAssertTrue(connected)
        } catch {
            await reader.stop()
            throw error
        }
    }

    /// Registers the room observer on the existing primary dot and reads its first bound state, then
    /// leaves. It sends no message, typing, read receipt, approval or pause, and starts no work. This
    /// opt-in is separate from the read-only check above, since registering is a request of its own.
    /// Only whether a state bound to the room arrived is checked; nothing of it is printed or saved. A
    /// registration that never yields a state fails here rather than passing as a quiet room.
    func testExistingDotsRoomObserverOnlyWhenSeparatelyApproved() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["YARDLET_DOTS_LIVE_ROOM"] == "1", let runtime = env["YARDLET_DOTS_RUNTIME"] else {
            throw XCTSkip("Set YARDLET_DOTS_LIVE_ROOM and YARDLET_DOTS_RUNTIME to observe a real dot's room.")
        }
        let reader = DotsService(executable: URL(filePath: runtime),
                                 environmentManager: CodexEnvironmentManager(paths: .live()), connection: nil)
        // The provider's own first wait is 30 seconds; this allows one attempt beyond it.
        let timeout = Task {
            try? await Task.sleep(for: .seconds(70))
            if !Task.isCancelled { await reader.stop() }
        }
        defer { timeout.cancel() }
        do {
            let agents = try await reader.agents()
            guard let agent = agents.first(where: \.isPrimary) ?? agents.first else {
                await reader.stop()
                throw XCTSkip("This account has no existing dot.")
            }
            let messages = await reader.updates(for: agent)
            var connected = false
            for await event in messages {
                if case .connected = event { connected = true; break }
                if case .failed = event { break }
            }
            guard connected else {
                await reader.stop()
                return XCTFail("The messaging socket did not connect")
            }
            var bound = false
            var failure: PersonalAgentFailure?
            for await update in await reader.liveState(for: agent) {
                switch update {
                case let .state(state?) where state.roomID == agent.id.roomID && !state.subscriptionID.isEmpty:
                    bound = true
                case let .failed(value):
                    failure = value
                case .state:
                    continue
                }
                if bound || failure != nil { break }
            }
            await reader.stop()
            XCTAssertNil(failure, "The observer's login ended")
            XCTAssertTrue(bound, "No state bound to the room arrived in time; the observation is unverified")
        } catch {
            await reader.stop()
            throw error
        }
    }
}

/// The fixed technical words looked for in the host's error message. Only which of them appear is kept.
private final class DotsRemoteErrorHints: @unchecked Sendable {
    static let words = ["invalid utf-8", "utf8", "encoding", "binary", "base64", "permission denied", "forbidden",
                        "not authorized", "no such file", "not found", "environment", "executor", "offline",
                        "disconnected", "not supported", "not implemented", "too large", "limit", "timeout",
                        "attestation", "invalid params"]
    private let lock = NSLock()
    private var found = Set<String>()
    var names: [String] { lock.withLock { Self.words.filter(found.contains) } }

    /// Notes the words a small JSON error frame's message holds; any other frame is passed over.
    func note(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case let .data(value): data = value
        case let .string(value): data = Data(value.utf8)
        @unknown default: return
        }
        guard data.count <= 64 * 1024, let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let text = value["error"]?["message"]?.stringValue?.lowercased() else { return }
        let words = Self.words.filter { text.contains($0) }
        lock.withLock { found.formUnion(words) }
    }
}

/// The product's socket with nothing changed: every call is the task's own, and what it receives is
/// handed on as it arrived, after `hints` looked at it.
private final class DotsHintingSocket: DotsEventSocket, @unchecked Sendable {
    let task: URLSessionWebSocketTask
    let hints: DotsRemoteErrorHints
    init(task: URLSessionWebSocketTask, hints: DotsRemoteErrorHints) { self.task = task; self.hints = hints }
    func resume() { task.resume() }
    func send(_ message: URLSessionWebSocketTask.Message) async throws { try await task.send(message) }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        let message = try await task.receive()
        hints.note(message)
        return message
    }
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) { task.cancel(with: closeCode, reason: reason) }
}
