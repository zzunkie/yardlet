import Foundation
import XCTest
@testable import NativeHarnessClient

/// The one follow-up queue Codex and Claude Code tasks share (plan B1): its order and each
/// provider's rule for moving messages, the pause an interrupt sets, the claim that keeps two
/// actions off one message, and the saved copies, which keep the keys and the form Codex's queue
/// has always had (plan A8), including the rule that a relaunch holds again what a provider held.
@MainActor
final class FollowUpQueueStoreTests: XCTestCase {
    private let task = UUID()

    func testMessagesGoInTheOrderTheyWereQueuedAndMoveByTheProvidersRule() {
        let (store, _, _) = makeStore()
        let first = queue("first", in: store)
        let second = queue("second", in: store)
        let third = queue("third", in: store)
        XCTAssertEqual(texts(store), ["first", "second", "third"])

        // Codex: Yardlet holds every message, so any of them moves anywhere.
        XCTAssertTrue(store.move(third, in: task, to: 0, policy: .codex))
        XCTAssertEqual(texts(store), ["third", "first", "second"])
        XCTAssertTrue(store.move(third, in: task, to: 99, policy: .codex))
        XCTAssertEqual(texts(store), ["first", "second", "third"])

        // Claude Code reads what it holds in order: those stay ahead and do not move.
        store.markSent(second, messageID: "m-2", first: false, in: task)
        XCTAssertEqual(texts(store), ["second", "first", "third"], "Written to the provider, after any it holds")
        XCTAssertEqual(store.queue(for: task).first?.providerMessageID, "m-2")
        XCTAssertFalse(store.move(second, in: task, to: 2, policy: .claudeCode))
        XCTAssertTrue(store.move(third, in: task, to: 0, policy: .claudeCode))
        XCTAssertEqual(texts(store), ["second", "third", "first"], "Not ahead of a message the provider holds")
        store.markSent(first, messageID: "m-1", first: true, in: task)
        XCTAssertEqual(texts(store), ["first", "second", "third"], "Sent to stop the turn: read first")
        XCTAssertEqual(store.sentItem(messageID: "m-1", in: task)?.id, first)
        XCTAssertNil(store.sentItem(messageID: "m-3", in: task))
    }

    func testAPauseHoldsOnlyAQueueWithThePersonsMessagesUntilResumeOrTheirLastLeaves() {
        let (store, repository, _) = makeStore()
        var ended: [UUID] = []
        store.pauseDidEnd = { ended.append($0) }
        XCTAssertFalse(store.pause(task), "Nothing to hold back")
        // Another task's message is not the person's to manage, and is not listed with the pause.
        let fromTask = queue(TaskMessage(senderID: UUID().uuidString, senderName: "Child", body: "Done").text(in: .yardlet),
                             in: store)
        XCTAssertFalse(store.pause(task), "None of the person's to hold back")
        let only = queue("held", in: store)
        XCTAssertTrue(store.pause(task))
        XCTAssertFalse(store.pause(task), "Already paused")
        XCTAssertTrue(store.isPaused(task))
        XCTAssertTrue(repository.isPaused(for: task))

        XCTAssertTrue(store.resume(task))
        XCTAssertFalse(store.resume(task))
        XCTAssertFalse(repository.isPaused(for: task))

        // The person's last message leaving ends the pause; what another task sent goes on.
        store.pause(task)
        store.remove(only, from: task)
        XCTAssertFalse(store.isPaused(task))
        XCTAssertFalse(repository.isPaused(for: task))
        XCTAssertEqual(ended, [task])
        store.remove(fromTask, from: task)
        XCTAssertEqual(ended, [task], "An empty queue has nothing to go on")

        let only2 = queue("held", in: store)
        store.pause(task)
        store.remove(only2, from: task)
        XCTAssertFalse(store.isPaused(task), "The next queued message starts a fresh queue")
        XCTAssertFalse(repository.isPaused(for: task))

        // A pause an earlier build saved over another task's message alone is let go.
        repository.save([QueuedFollowUp(draft: CodexComposerDraft(inputs: [.text(
            TaskMessage(senderID: UUID().uuidString, senderName: "Child", body: "Done").text(in: .yardlet))]))], for: task)
        repository.setPaused(true, for: task)
        let relaunched = FollowUpQueueStore(repository: repository)
        relaunched.load(for: [task])
        XCTAssertEqual(relaunched.queue(for: task).count, 1)
        XCTAssertFalse(relaunched.isPaused(task))
        XCTAssertFalse(repository.isPaused(for: task))
    }

    func testAClaimedMessageIsLeftAloneUntilItsActionFinishes() {
        let (store, _, _) = makeStore()
        let first = queue("first", in: store)
        queue("second", in: store)
        XCTAssertTrue(store.claim(first))
        XCTAssertFalse(store.claim(first), "A second send, withdrawal or edit waits")
        XCTAssertTrue(store.isClaimed(first))
        XCTAssertFalse(store.move(first, in: task, to: 1, policy: .codex))
        XCTAssertEqual(texts(store), ["first", "second"])

        store.finish(first)
        XCTAssertFalse(store.isClaimed(first))
        XCTAssertTrue(store.claim(first))
        store.finish(first)
        XCTAssertTrue(store.move(first, in: task, to: 1, policy: .codex))
        XCTAssertEqual(texts(store), ["second", "first"])
    }

    func testFailureRetryAndHoldingAgainKeepTheMessage() {
        let (store, _, _) = makeStore()
        let item = queue("message", in: store)
        XCTAssertFalse(store.retry(item, in: task), "Only a failed message is retried")

        store.markSent(item, messageID: "m-1", first: false, in: task)
        XCTAssertTrue(store.markFailed(item, message: "Refused", in: task))
        XCTAssertEqual(store.item(item, in: task)?.state, .failed)
        XCTAssertEqual(store.item(item, in: task)?.failureMessage, "Refused")
        XCTAssertNil(store.item(item, in: task)?.providerMessageID, "The provider no longer holds it")
        XCTAssertFalse(store.markFailed(UUID(), message: "Gone", in: task))

        XCTAssertTrue(store.retry(item, in: task))
        XCTAssertEqual(store.item(item, in: task)?.state, .pending)
        XCTAssertNil(store.item(item, in: task)?.failureMessage)

        store.markSent(item, messageID: "m-2", first: false, in: task)
        store.hold(item, in: task)
        XCTAssertEqual(store.item(item, in: task)?.state, .pending)
        XCTAssertNil(store.item(item, in: task)?.providerMessageID)

        store.markSent(item, messageID: "m-3", first: false, in: task)
        let other = queue("other", in: store)
        store.markSent(other, messageID: "m-4", first: false, in: task)
        store.holdAllSent(in: task)
        XCTAssertEqual(store.queue(for: task).map(\.state), [.pending, .pending], "Its runtime ended with them unread")
        XCTAssertTrue(store.queue(for: task).allSatisfy { $0.providerMessageID == nil })
    }

    func testTheSavedQueueKeepsItsKeysAndFormAndReadsBackAsItWas() throws {
        let (store, _, defaults) = makeStore(keyPrefix: nil)
        let image = CodexUserInput.localImage(URL(filePath: "/tmp/queued.png"), detail: .auto)
        let item = QueuedFollowUp(draft: CodexComposerDraft(inputs: [.text("Also update the README"), image]),
                                  enqueuedAt: Date(timeIntervalSince1970: 1_800_000_000), state: .sent,
                                  failureMessage: "earlier", providerMessageID: "held-1")
        store.append(item, to: task)
        store.append(QueuedFollowUp(draft: CodexComposerDraft(inputs: [.text("then this")])), to: task)
        store.pause(task)
        store.saveShellDeliveries([ClaudeShellDelivery(entryID: UUID(), text: "<bash-input>ls</bash-input>")], for: task)

        let saved = try XCTUnwrap(defaults.data(forKey: "NativeHarnessClient.codexQueue.\(task.uuidString)"))
        XCTAssertTrue(defaults.bool(forKey: "NativeHarnessClient.codexQueue.paused.\(task.uuidString)"))
        XCTAssertNotNil(defaults.data(forKey: "NativeHarnessClient.codexQueue.shell.\(task.uuidString)"))
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [[String: Any]])
        XCTAssertEqual(Set(objects[0].keys), ["id", "draft", "enqueuedAt", "state", "failureMessage", "providerMessageID"])
        XCTAssertEqual(objects[0]["state"] as? String, "sent")
        // The form an earlier launch wrote under the Codex name reads as the shared one.
        XCTAssertEqual(try JSONDecoder().decode([CodexQueuedSubmission].self, from: saved),
                       try JSONDecoder().decode([QueuedFollowUp].self, from: saved))

        let relaunched = FollowUpQueueStore(repository: UserDefaultsCodexQueueRepository(defaults: defaults))
        relaunched.load(for: [task, UUID()])
        let restored = relaunched.queue(for: task)
        XCTAssertEqual(restored.map(\.id), [item.id, store.queue(for: task)[1].id])
        XCTAssertEqual(restored.first?.draft, item.draft)
        XCTAssertEqual(restored.first?.enqueuedAt, item.enqueuedAt)
        XCTAssertEqual(restored.first?.failureMessage, "earlier")
        XCTAssertTrue(relaunched.isPaused(task))
        XCTAssertEqual(relaunched.savedShellDeliveries(for: task).map(\.text), ["<bash-input>ls</bash-input>"])

        // The follow-up setting saved under its earlier key is carried over, and Claude Code reads the same value.
        XCTAssertEqual(FollowUpMode.current(in: defaults), .steer)
        defaults.set("queue", forKey: "Yardlet.codexFollowUpMode")
        PreferenceKeyCarryOver.run(in: defaults)
        XCTAssertEqual(FollowUpMode.current(in: defaults), .queue)
    }

    func testARelaunchHoldsAgainWhatTheProviderHeldAndKeepsTheRest() {
        let (store, repository, defaults) = makeStore()
        repository.save([
            QueuedFollowUp(draft: CodexComposerDraft(inputs: [.text("held by the CLI")]), state: .sent,
                           providerMessageID: "cli-1"),
            QueuedFollowUp(draft: CodexComposerDraft(inputs: [.text("held by Yardlet")])),
            QueuedFollowUp(draft: CodexComposerDraft(inputs: [.text("refused")]), state: .failed, failureMessage: "No")
        ], for: task)
        let other = UUID()
        repository.setPaused(true, for: other)

        store.load(for: [task, other])
        XCTAssertEqual(store.queue(for: task).map(\.state), [.pending, .pending, .failed])
        XCTAssertTrue(store.queue(for: task).allSatisfy { $0.providerMessageID == nil })
        XCTAssertEqual(store.queue(for: task).last?.failureMessage, "No")
        XCTAssertFalse(store.isPaused(other), "A pause without messages holds nothing")
        // Loading changes nothing saved until the queue itself changes.
        XCTAssertEqual(UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue.").load(for: task).first?.state,
                       .sent)
    }

    func testAnEmptiedQueueLeavesNothingSavedAndLetsWhatWaitsBehindItGo() {
        let (store, repository, defaults) = makeStore()
        var emptied: [UUID] = []
        store.queueDidEmpty = { emptied.append($0) }
        let first = queue("first", in: store)
        let second = queue("second", in: store)
        store.remove(first, from: task)
        XCTAssertTrue(emptied.isEmpty)
        XCTAssertEqual(repository.load(for: task).map(\.id), [second])

        store.remove(second, from: task)
        XCTAssertEqual(emptied, [task])
        XCTAssertNil(defaults.data(forKey: "queue.\(task.uuidString)"))
        XCTAssertTrue(store.queue(for: task).isEmpty)
    }

    func testDiscardingATaskForgetsItsQueuePauseAndBashOutput() {
        let (store, repository, defaults) = makeStore()
        queue("first", in: store)
        store.pause(task)
        store.saveShellDeliveries([ClaudeShellDelivery(entryID: UUID(), text: "out")], for: task)
        store.discard(task)
        XCTAssertTrue(store.queue(for: task).isEmpty)
        XCTAssertFalse(store.isPaused(task))
        XCTAssertTrue(repository.load(for: task).isEmpty)
        XCTAssertFalse(repository.isPaused(for: task))
        XCTAssertTrue(repository.loadShellDeliveries(for: task).isEmpty)
        XCTAssertNil(defaults.data(forKey: "queue.shell.\(task.uuidString)"))
    }

    func testEachProviderKeepsItsOwnRulesAndWords() {
        XCTAssertEqual(FollowUpPolicy(harness: .codex), .codex)
        XCTAssertEqual(FollowUpPolicy(harness: .claudeCode), .claudeCode)
        // A harness that takes nothing while its turn runs holds every message for the next turn.
        XCTAssertEqual(FollowUpPolicy(harness: .cursorAgent), .afterTurn)
        XCTAssertEqual(FollowUpPolicy(harness: .antigravityCLI), .afterTurn)
        XCTAssertFalse(FollowUpPolicy.afterTurn.steers)
        XCTAssertNil(FollowUpPolicy.afterTurn.sendLabel)
        XCTAssertFalse(FollowUpPolicy.codex.holdsSentMessages)
        XCTAssertTrue(FollowUpPolicy.codex.canReorderSent)
        XCTAssertTrue(FollowUpPolicy.claudeCode.holdsSentMessages)
        XCTAssertFalse(FollowUpPolicy.claudeCode.canReorderSent)
        // The send that leaves the turn running, and the one action that stops it, named for it.
        XCTAssertEqual(FollowUpPolicy.codex.sendLabel, L10n.string("Send now"))
        XCTAssertEqual(FollowUpPolicy.claudeCode.sendLabel, L10n.string("Send now"))
        XCTAssertNil(FollowUpPolicy.afterTurn.sendHelp)
        XCTAssertEqual(FollowUpPolicy.claudeCode.stopAndSendLabel, L10n.string("Stop and send"))
        XCTAssertNil(FollowUpPolicy.codex.stopAndSendLabel)
        XCTAssertNil(FollowUpPolicy.afterTurn.stopAndSendLabel)
        XCTAssertEqual(FollowUpPolicy.codex.removeLabel, L10n.string("Delete queued message"))
        XCTAssertEqual(FollowUpPolicy.claudeCode.removeLabel, L10n.string("Remove from queue"))

        // Where Return and ⌘Return send a message while a turn runs, in each harness's words.
        XCTAssertEqual(FollowUpPolicy.codex.runningPlaceholder(preferred: .steer),
                       L10n.format("↩ %@ · ⌘↩ %@", L10n.string("Add to the running task"),
                                   L10n.string("Send when this turn ends")))
        XCTAssertEqual(FollowUpPolicy.claudeCode.runningPlaceholder(preferred: .steer),
                       L10n.format("↩ %@ · ⌘↩ %@", L10n.string("Deliver at the next step"),
                                   L10n.string("Send when this turn ends")))
        XCTAssertEqual(FollowUpPolicy.claudeCode.runningPlaceholder(preferred: .queue),
                       L10n.format("↩ %@ · ⌘↩ %@", L10n.string("Send when this turn ends"),
                                   L10n.string("Deliver at the next step")))
        XCTAssertEqual(FollowUpPolicy.afterTurn.runningPlaceholder(preferred: .steer),
                       L10n.format("↩ %@", L10n.string("Send when this turn ends")))
    }

    // MARK: - Helpers

    private func makeStore(
        keyPrefix: String? = "queue."
    ) -> (FollowUpQueueStore, UserDefaultsCodexQueueRepository, UserDefaults) {
        let suiteName = testDefaultsSuite("FollowUpQueueStoreTests")
        let defaults = UserDefaults(suiteName: suiteName)!
        let repository = keyPrefix.map { UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: $0) }
            ?? UserDefaultsCodexQueueRepository(defaults: defaults)
        return (FollowUpQueueStore(repository: repository), repository, defaults)
    }

    @discardableResult
    private func queue(_ text: String, in store: FollowUpQueueStore) -> UUID {
        let item = QueuedFollowUp(draft: CodexComposerDraft(inputs: [.text(text)]))
        store.append(item, to: task)
        return item.id
    }

    private func texts(_ store: FollowUpQueueStore) -> [String] {
        store.queue(for: task).map(\.draft.text)
    }
}
