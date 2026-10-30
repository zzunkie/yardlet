import Foundation
import XCTest
@testable import YardletRemote
@testable import YardletRemoteFixtureSupport

/// The fixture server's tasks behave as the Mac's do: a task waiting on a request is running (the
/// stop button applies) and stopping it expires the request, a waiting task's attention carries a
/// short summary, and a message sent to a running task waits as a queued item until the turn ends.
/// The phone app's QA runs against it, so what it offers since 2026-10-27 (§15.13–§15.18) answers as
/// the contract says.
final class RemoteFixtureTests: XCTestCase {
    func testWaitingTasksRunAndStoppingExpiresTheirRequest() async throws {
        let fixture = RemoteFixtureBridge(speed: 50)
        let snapshot = await fixture.snapshot()
        for id in [RemoteFixtureBridge.ID.approval, RemoteFixtureBridge.ID.question] {
            let task = try XCTUnwrap(snapshot.tasks.first { $0.id == id })
            XCTAssertEqual(task.attention, .waiting)
            XCTAssertTrue(task.running, "A turn waiting on a request is running, as on the Mac")
        }
        XCTAssertEqual(snapshot.requestSummaries[RemoteFixtureBridge.ID.approval], "Bash: Run the migration tests")
        XCTAssertEqual(snapshot.requestSummaries[RemoteFixtureBridge.ID.question], "Which name should the release use?")

        let stop = await fixture.perform(.stopTurn(taskID: RemoteFixtureBridge.ID.question))
        XCTAssertNil(stop)
        let stopped = await fixture.snapshot().tasks.first { $0.id == RemoteFixtureBridge.ID.question }
        XCTAssertEqual(stopped?.running, false)
        XCTAssertEqual(stopped?.attention, .unread)
        let items = await fixture.conversation(of: RemoteFixtureBridge.ID.question)?.turns.last?.items ?? []
        XCTAssertEqual(items.first { $0.kind == .approval }?.status, "expired")
        XCTAssertEqual(items.first { $0.kind == .turn }?.status, "interrupted")
        let again = await fixture.perform(.stopTurn(taskID: RemoteFixtureBridge.ID.question))
        XCTAssertEqual(again?.code, .notRunning)
    }

    func testAMessageToARunningTaskWaitsQueuedUntilTheTurnEnds() async throws {
        let fixture = RemoteFixtureBridge(speed: 50)
        let approval = RemoteFixtureBridge.ID.approval
        let sent = await fixture.perform(.sendMessage(taskID: approval, text: "Also update the changelog"))
        XCTAssertNil(sent)
        let afterSending = await fixture.conversation(of: approval)
        let queued = try XCTUnwrap(afterSending?.turns.last?.items.last)
        XCTAssertEqual(queued.kind, .user)
        XCTAssertEqual(queued.queued, true)
        XCTAssertEqual(queued.text, "Also update the changelog")

        let answer = await fixture.perform(.answerApproval(taskID: approval, requestID: "toolu_fixture_1", answer: .deny))
        XCTAssertNil(answer)
        let deadline = Date().addingTimeInterval(testWaitLimitSeconds)
        var taken: RemoteItem?
        while taken == nil, Date() < deadline {
            let items = await fixture.conversation(of: approval)?.turns.flatMap(\.items) ?? []
            if !items.contains(where: { $0.queued == true }) {
                taken = items.last { $0.kind == .user && $0.text == "Also update the changelog" }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let message = try XCTUnwrap(taken, "The queued message was not taken when the turn ended")
        XCTAssertNil(message.queued)
        XCTAssertNotEqual(message.id, queued.id)
    }

    func testTheFixtureAnswersWhatPhonesGainedOn20261027() async throws {
        let fixture = RemoteFixtureBridge(speed: 50)
        let snapshot = await fixture.snapshot()
        XCTAssertEqual(snapshot.followUp, .steer)
        let handoffTask = try XCTUnwrap(snapshot.tasks.first { $0.id == RemoteFixtureBridge.ID.handoff })
        XCTAssertEqual(handoffTask.attention, .waiting)
        XCTAssertEqual(handoffTask.pendingKind, "browserHandoff")
        XCTAssertEqual(snapshot.tasks.first { $0.id == RemoteFixtureBridge.ID.limit }?.indicator, .usageLimit)

        // A plan limit: the list, then continuing under another account settles the card and replies.
        let limit = RemoteFixtureBridge.ID.limit
        let accounts = try await fixture.limitAccounts(taskID: limit).get()
        XCTAssertEqual(accounts.first { $0.current == true }?.id, "fixture-home")
        let refused = await fixture.perform(.continueWithAccount(taskID: limit, accountID: "fixture-old"))
        XCTAssertEqual(refused?.code, .notAllowed, "A signed-out account is not offered")
        let armed = await fixture.perform(.setAutoContinue(taskID: limit, enabled: true))
        XCTAssertNil(armed)
        let armedCard = await fixture.conversation(of: limit)?.turns.last?.items.first { $0.kind == .error }
        XCTAssertEqual(armedCard?.autoContinue, true)
        let moved = await fixture.perform(.continueWithAccount(taskID: limit, accountID: "fixture-work"))
        XCTAssertNil(moved)
        let card = await fixture.conversation(of: limit)?.turns.flatMap(\.items).first { $0.errorKind == "usageLimit" }
        XCTAssertNil(card?.options)
        let continued = await fixture.snapshot().tasks.first { $0.id == limit }
        XCTAssertEqual(continued?.running, true)

        // A browser handoff answered from the phone.
        let declined = await fixture.perform(.answerHandoff(taskID: RemoteFixtureBridge.ID.handoff,
                                                            requestID: "handoff_fixture_1", answer: .decline))
        XCTAssertNil(declined)
        let answered = await fixture.snapshot().tasks.first { $0.id == RemoteFixtureBridge.ID.handoff }
        XCTAssertNotEqual(answered?.attention, .waiting)

        // Allow for the session is offered beside allow once; a queued message is sent now.
        let approval = RemoteFixtureBridge.ID.approval
        let request = await fixture.conversation(of: approval)?.turns.last?.items.last { $0.kind == .approval }
        XCTAssertEqual(request?.options, ["allowOnce", "allowForSession", "deny"])
        XCTAssertNotNil(request?.macNote)
        _ = await fixture.perform(.sendMessage(taskID: approval, text: "Also bump the version"))
        let afterSending = await fixture.conversation(of: approval)
        let queued = try XCTUnwrap(afterSending?.turns.last?.items.last { $0.queued == true })
        XCTAssertEqual(queued.options, ["sendNow", "stopAndSend", "remove"])
        let removed = await fixture.perform(.actOnQueued(taskID: approval, itemID: queued.id, action: .remove))
        XCTAssertNil(removed)
        let afterRemoving = await fixture.conversation(of: approval)
        XCTAssertEqual(afterRemoving?.turns.flatMap(\.items).contains { $0.queued == true }, false)

        // A new task on the harness and model the phone picked.
        let options = try await fixture.newTaskOptions(projectID: RemoteFixtureBridge.ID.yardlet, harness: "codex").get()
        XCTAssertEqual(options.harness.harness, "codex")
        XCTAssertEqual(options.worktree, false)
        let model = try XCTUnwrap(options.settings.first { $0.id == "model" }?.choices.last?.value)
        let wrong = await fixture.createTask(RemoteTaskStart(projectID: RemoteFixtureBridge.ID.yardlet, text: "Hi",
                                                             harness: "codex", settings: ["model": "nope"]))
        XCTAssertEqual(try? wrong.get(), nil)
        let created = try await fixture.createTask(RemoteTaskStart(projectID: RemoteFixtureBridge.ID.yardlet, text: "Add a toggle",
                                                                   harness: "codex", settings: ["model": model])).get()
        let started = await fixture.snapshot().tasks.first { $0.id == created }
        XCTAssertEqual(started?.harness, "codex")

        // Later the same day (§15.19, §15.20): every answer of the card, an MCP form, a secret answer, files.
        XCTAssertEqual(request?.choices?.first { $0.standing == true }?.id, "1")
        let form = RemoteFixtureBridge.ID.form
        let formItem = await fixture.conversation(of: form)?.turns.last?.items.last { $0.kind == .approval }
        XCTAssertEqual(formItem?.formFields?.map(\.id), ["repo", "private", "team"])
        let missing = await fixture.perform(.chooseAnswer(taskID: form, requestID: "form_fixture_1", choice: "1"))
        XCTAssertEqual(missing?.message, "Repository: Required")
        let submitted = await fixture.perform(.chooseAnswer(taskID: form, requestID: "form_fixture_1", choice: "1",
                                                            values: ["repo": .text("acme/billing")]))
        XCTAssertNil(submitted)
        let secretItem = await fixture.conversation(of: RemoteFixtureBridge.ID.secret)?.turns.last?.items.last { $0.kind == .approval }
        XCTAssertEqual(secretItem?.options, [RemoteProtocol.answerSecretOption], "Only a phone that masks it answers")
        XCTAssertEqual(secretItem?.questionSteps?.first?.secret, true)
        let filed = await fixture.perform(.sendMessage(taskID: RemoteFixtureBridge.ID.idle, text: "Read this",
                                                       files: [RemoteFile(url: URL(filePath: "/tmp/x/report.pdf"), name: "report.pdf")]))
        XCTAssertNil(filed)
    }
}
