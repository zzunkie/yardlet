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
