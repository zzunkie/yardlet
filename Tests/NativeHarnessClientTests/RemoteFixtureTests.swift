import AppKit
import Foundation
import XCTest
@testable import YardletRemote
@testable import YardletRemoteFixtureSupport

/// The fixture server's tasks behave as the Mac's do: a task waiting on a request is running (the
/// stop button applies) and stopping it expires the request, a waiting task's attention carries a
/// short summary, and a message sent to a running task waits as a queued item until the turn ends.
/// The phone app's QA runs against it, so what it offers since 2026-10-27 (§15.13–§15.18) answers as
/// the contract says, and so do its scheduled tasks (§15.21), a task's files (§15.22) and its browser tabs (§15.25), through
/// the server.
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

    /// §15.21 through the server: the list in the Mac's order and words, Pause and Resume, Run now (a skip while
    /// the task of its previous run works, `busy` while a run starts, then the run's own task), each command
    /// audited by its schedule, and the change event only on the connection that asked for the list.
    func testScheduledTasksRoundTripThroughTheServer() async throws {
        typealias ID = RemoteFixtureBridge.ID
        let clock = RemoteTestClock()
        let harness = try await ServerHarness(clock: clock, serving: RemoteFixtureBridge())
        let phone = try await harness.authenticatedPhone()
        let other = try await harness.authenticatedPhone()
        var sent = 0
        func ask(_ type: String, _ fields: String = "") async throws -> RemoteResponse {
            sent += 1
            // Time enough for the rate limits to let each request through.
            clock.advance(by: 3)
            await harness.send(#"{"id":"r\#(sent)","type":"\#(type)"\#(fields)}"#, on: phone)
            return try await phone.response("r\(sent)")
        }

        let snapshot = try await ask("snapshot")
        XCTAssertEqual(snapshot.scheduledTasks, true)
        let listing = try await ask("scheduledTasks")
        let listed = try XCTUnwrap(listing.schedules)
        XCTAssertEqual(listed.map(\.id), [ID.morningSchedule, ID.footerSchedule, ID.screenshotsSchedule, ID.reminderSchedule])
        let morning = listed[0]
        // The system's own time format, as the Mac's (it may put a narrow space before AM).
        XCTAssertTrue(morning.when.hasPrefix("Every day at 9:00"), morning.when)
        XCTAssertTrue(morning.enabled)
        XCTAssertFalse(morning.running)
        XCTAssertEqual(morning.status?.hasPrefix("Next run "), true)
        XCTAssertNotNil(morning.nextRunAt)
        XCTAssertEqual(morning.projectName, "Website")
        XCTAssertEqual(morning.harnessName, "Codex")
        XCTAssertNil(morning.canResume)
        XCTAssertEqual(morning.lastRun?.outcome, .started)
        XCTAssertEqual(morning.lastRun?.taskId, ID.history)
        XCTAssertEqual(morning.lastRun?.line.hasPrefix("Last run "), true)
        let footer = listed[1]
        XCTAssertEqual(footer.status, "Paused")
        XCTAssertEqual(footer.canResume, true)
        XCTAssertNil(footer.nextRunAt)
        XCTAssertEqual(footer.projectName, "Website", "The project of the task it continues")
        XCTAssertEqual(footer.harnessName, "Claude Code")
        let screenshots = listed[2]
        XCTAssertFalse(screenshots.enabled)
        XCTAssertEqual(screenshots.status, "Turned off after 3 failed starts")
        XCTAssertEqual(screenshots.canResume, true)
        XCTAssertEqual(screenshots.lastRun?.outcome, .failed)
        XCTAssertNil(screenshots.lastRun?.taskId)
        let reminder = listed[3]
        XCTAssertEqual(reminder.status, "Ran once")
        XCTAssertNil(reminder.canResume, "A one-off that ran is edited on the Mac, not resumed")
        XCTAssertNil(reminder.projectName, "A chat")
        XCTAssertEqual(reminder.lastRun?.taskId, ID.chat)

        let unknown = try await ask("runScheduledTask", #","scheduleId":"nope""#)
        XCTAssertEqual(unknown.error?.code, .notFound)
        let ended = try await ask("setScheduledTaskEnabled", #","scheduleId":"\#(ID.reminderSchedule)","enabled":true"#)
        XCTAssertEqual(ended.error?.code, .notAllowed)

        // Resume: the phone that asked for the list hears of it, and the list says it runs again.
        let resumed = try await ask("setScheduledTaskEnabled", #","scheduleId":"\#(ID.footerSchedule)","enabled":true"#)
        XCTAssertTrue(resumed.ok)
        var seq = try await phone.event(.schedulesChanged).seq ?? 0
        let afterResuming = try await ask("scheduledTasks")
        let running = try XCTUnwrap(afterResuming.schedules?[1])
        XCTAssertTrue(running.enabled)
        XCTAssertNil(running.canResume)
        XCTAssertEqual(running.status?.hasPrefix("Next run "), true)

        // Run now while the task of its previous run works: a skip, as on the Mac.
        let busy = try await ask("sendMessage", #","taskId":"\#(ID.history)","text":"Summarize the newest one too""#)
        XCTAssertTrue(busy.ok)
        let skip = try await ask("runScheduledTask", #","scheduleId":"\#(ID.morningSchedule)""#)
        XCTAssertTrue(skip.ok)
        let afterSkipping = try await ask("scheduledTasks")
        let skipped = try XCTUnwrap(afterSkipping.schedules?.first)
        XCTAssertEqual(skipped.lastRun?.outcome, .skipped)
        XCTAssertNil(skipped.lastRun?.taskId)
        XCTAssertEqual(skipped.lastRun?.line.hasSuffix(" · Skipped: the previous run is still going"), true)
        XCTAssertTrue(skipped.running, "The task of its latest started run works")

        // Run now that starts a task: busy while it starts, then the run's task is listed with it.
        let start = try await ask("runScheduledTask", #","scheduleId":"\#(ID.reminderSchedule)""#)
        XCTAssertTrue(start.ok)
        let again = try await ask("runScheduledTask", #","scheduleId":"\#(ID.reminderSchedule)""#)
        XCTAssertEqual(again.error?.code, .busy)
        var ran = reminder
        while ran.lastRun?.outcome != .started || ran.lastRun?.taskId == ID.chat {
            seq = try await phone.event(.schedulesChanged, after: seq).seq ?? seq
            let listing = try await ask("scheduledTasks")
            ran = try XCTUnwrap(listing.schedules?.last)
        }
        let task = try XCTUnwrap(ran.lastRun?.taskId)
        let started = try await ask("snapshot").tasks?.first { $0.id == task }
        XCTAssertEqual(started?.projectId, "chats")
        XCTAssertEqual(ran.status, "Ran once", "Run now does not make a one-off run on its own again")

        let audit = harness.audit.entries().filter { $0.type == "runScheduledTask" || $0.type == "setScheduledTaskEnabled" }
        XCTAssertEqual(audit.map(\.schedule), ["nope", ID.reminderSchedule, ID.footerSchedule, ID.morningSchedule,
                                               ID.reminderSchedule, ID.reminderSchedule])
        XCTAssertEqual(audit.map(\.result), ["notFound", "notAllowed", "ok", "ok", "ok", "busy"])
        XCTAssertTrue(audit.allSatisfy { $0.task == nil })
        // The connection that never asked for the list heard nothing of it.
        do {
            let heard = try await other.event(.schedulesChanged, timeout: 0.3)
            XCTFail("Unexpected \(heard)")
        } catch is TestChannel.TimedOut {}
    }

    /// §15.22 through the server: "Summarize the crash reports" lists a PDF it saved beside its folder and a PNG inside
    /// it, both read whole, and the text file its conversation names is read by the path the conversation writes; a file
    /// beside them that is neither, and another task's, are refused.
    func testATasksFilesOpenThroughTheServer() async throws {
        typealias ID = RemoteFixtureBridge.ID
        let fixture = RemoteFixtureBridge()
        defer { try? FileManager.default.removeItem(at: fixture.filesFolder) }
        let clock = RemoteTestClock()
        let harness = try await ServerHarness(clock: clock, serving: fixture)
        let phone = try await harness.authenticatedPhone()
        var sent = 0
        func ask(_ type: String, _ fields: String = "") async throws -> RemoteResponse {
            sent += 1
            clock.advance(by: 1)
            await harness.send(#"{"id":"r\#(sent)","type":"\#(type)"\#(fields)}"#, on: phone)
            return try await phone.response("r\(sent)")
        }
        func read(_ path: String, offset: Int = 0, task: String = ID.history) async throws -> RemoteResponse {
            try await ask("readFile", #","taskId":"\#(task)","path":"\#(path)","offset":\#(offset)"#)
        }

        let snapshot = try await ask("snapshot")
        XCTAssertEqual(snapshot.taskFiles, true)
        let listing = try await ask("taskOutputs", #","taskId":"\#(ID.history)""#)
        let outputs = try XCTUnwrap(listing.outputs)
        XCTAssertEqual(outputs.map(\.name), ["crash-summary.pdf", "crash-chart.png"])
        XCTAssertTrue(outputs.allSatisfy { $0.size != nil && $0.writtenAt != nil })
        let pdf = try await read(outputs[0].path)
        XCTAssertEqual(pdf.mediaType, "application/pdf")
        XCTAssertEqual(pdf.data?.count, outputs[0].size)
        XCTAssertEqual(pdf.data?.prefix(5), Data("%PDF-".utf8))
        let png = try await read(outputs[1].path)
        XCTAssertEqual(png.mediaType, "image/png")
        XCTAssertEqual(png.data?.prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        let notes = try await read("reports/crash-notes.txt")
        XCTAssertEqual(notes.mediaType, "text/plain")
        XCTAssertEqual(notes.data.map { String(decoding: $0, as: UTF8.self) }?.hasPrefix("Crash notes"), true)

        let beside = try await read("../Desktop/private-notes.txt")
        XCTAssertEqual(beside.error?.code, .notFound)
        let elsewhere = try await read(outputs[0].path, task: ID.idle)
        XCTAssertEqual(elsewhere.error?.code, .notFound, "Another task's output")
        let none = try await ask("taskOutputs", #","taskId":"\#(ID.idle)""#)
        XCTAssertEqual(none.outputs, [])
        let unknown = try await ask("taskOutputs", #","taskId":"nope""#)
        XCTAssertEqual(unknown.error?.code, .notFound)
    }

    /// The handoff task's sign-in tab through the server: a PNG of the page, a click into a field, typing and Tab, the
    /// password field's mark on the list, Sign in, and the handoff answered, each frame after the last was acknowledged.
    func testTheHandoffTasksSignInTabTakesInputThroughTheServer() async throws {
        typealias ID = RemoteFixtureBridge.ID
        let harness = try await ServerHarness(serving: RemoteFixtureBridge(speed: 50))
        let phone = try await harness.authenticatedPhone()
        var sent = 0
        func ask(_ type: String, _ fields: String = "") async throws -> RemoteResponse {
            sent += 1
            await harness.send(#"{"id":"r\#(sent)","type":"\#(type)"\#(fields)}"#, on: phone)
            return try await phone.response("r\(sent)")
        }
        // As a phone does: every frame is acknowledged as it arrives (§15.25), whichever it is, so the next can come.
        let acker = Task {
            var acknowledged: Set<Int> = []
            while !Task.isCancelled {
                for event in phone.events(.tabFrame) {
                    guard let number = event.frame, acknowledged.insert(number).inserted else { continue }
                    await harness.send(#"{"id":"ack\#(number)","type":"tabFrameAck","taskId":"\#(ID.handoff)","tabId":"\#(event.tabId ?? "")","frame":\#(number)}"#,
                                       on: phone)
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        defer { acker.cancel() }
        var seq = 0
        func frame() async throws -> RemoteEvent {
            let event = try await phone.event(.tabFrame, after: seq)
            seq = event.seq ?? seq
            return event
        }
        func input(_ input: String) async throws -> RemoteResponse {
            try await ask("tabInput", #","taskId":"\#(ID.handoff)","tabId":"\#(RemoteFixtureTabs.signInTab)","input":\#(input)"#)
        }

        let snapshot = try await ask("snapshot")
        XCTAssertEqual(snapshot.browserTabs, true)
        let conversation = try await ask("subscribeTask", #","taskId":"\#(ID.handoff)""#)
        XCTAssertEqual(conversation.items?.last?.tabId, RemoteFixtureTabs.signInTab, "the handoff names its tab")
        let watching = try await ask("watchTab", #","taskId":"\#(ID.handoff)","maxWidth":640"#)
        XCTAssertEqual(watching.tabId, RemoteFixtureTabs.signInTab)
        XCTAssertEqual(watching.tabs?.map(\.tabId), [RemoteFixtureTabs.docsTab, RemoteFixtureTabs.signInTab])
        XCTAssertEqual(watching.tabs?.last?.requestId, "handoff_fixture_1")
        XCTAssertEqual(watching.tabs?.last?.waiting, "handoff")

        let page = try await frame()
        XCTAssertEqual(page.mediaType, "image/png")
        XCTAssertEqual([page.width, page.height], [640, 400])
        XCTAssertEqual([page.viewportWidth, page.viewportHeight], [640, 400])
        let image = try XCTUnwrap(page.image)
        XCTAssertLessThan(image.count, 20_000, "a page of flat colors is a few kilobytes")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: image))
        XCTAssertEqual([bitmap.pixelsWide, bitmap.pixelsHigh], [640, 400])
        let header = try XCTUnwrap(bitmap.colorAt(x: 600, y: 20)?.usingColorSpace(.sRGB))
        XCTAssertEqual(Int((header.redComponent * 255).rounded()), 0x24, "the header bar")
        let button = try XCTUnwrap(bitmap.colorAt(x: 180, y: 245)?.usingColorSpace(.sRGB))
        XCTAssertEqual(Int((button.greenComponent * 255).rounded()), 0x88, "the Sign in button")

        let clicked = try await input(#"{"kind":"click","x":200,"y":145}"#)
        XCTAssertTrue(clicked.ok)
        let focused = try await frame()
        XCTAssertNotEqual(focused.image, page.image)
        _ = try await input(#"{"kind":"text","text":"octocat"}"#)
        _ = try await input(#"{"kind":"key","key":"Tab"}"#)
        let marked = try await phone.event(.browserTabsChanged)
        XCTAssertEqual(marked.tabs?.last?.passwordField, true, "a client masks what it types into the password field")
        _ = try await input(#"{"kind":"text","text":"hunter2"}"#)
        _ = try await input(#"{"kind":"click","x":300,"y":255}"#)
        try await waitFor { phone.events(.browserTabsChanged).last?.tabs?.last?.title == "New release · acme/web" }

        let done = try await ask("answerHandoff", #","taskId":"\#(ID.handoff)","requestId":"handoff_fixture_1","answer":"done""#)
        XCTAssertTrue(done.ok)
        try await waitFor { phone.events(.browserTabsChanged).last?.tabs?.last?.requestId == nil }
        let docs = try await ask("tabInput", #","taskId":"\#(ID.handoff)","tabId":"\#(RemoteFixtureTabs.docsTab)","input":{"kind":"click","x":1,"y":1}"#)
        XCTAssertEqual(docs.error?.code, .notAllowed, "input goes to the watched tab")

        // A phone's own size: the page is laid out at it while the phone watches.
        _ = try await ask("watchTab", #","taskId":"\#(ID.handoff)","viewport":{"width":390,"height":844,"mobile":true}"#)
        try await waitFor { phone.events(.tabFrame).last?.viewportWidth == 390 }
        XCTAssertEqual(phone.events(.tabFrame).last?.width, 390)

        // The static page's site asks for the camera and microphone, under a number past 2^53: answered on that tab once
        // it is watched, and only once.
        XCTAssertEqual(snapshot.tabPermissions, true)
        let asking = try XCTUnwrap(watching.tabs?.first?.permission)
        XCTAssertEqual(asking.permissions, ["camera", "microphone"])
        XCTAssertGreaterThan(asking.prompt, 1 << 53)
        XCTAssertEqual(watching.tabs?.first?.waiting, "permission")
        func answer(_ given: String) async throws -> RemoteResponse {
            try await ask("answerTabPermission",
                          #","taskId":"\#(ID.handoff)","tabId":"\#(RemoteFixtureTabs.docsTab)","prompt":\#(asking.prompt),"answer":"\#(given)""#)
        }
        let unwatched = try await answer("allow")
        XCTAssertEqual(unwatched.error?.code, .notAllowed, "the tab is not the one watched")
        _ = try await ask("watchTab", #","taskId":"\#(ID.handoff)","tabId":"\#(RemoteFixtureTabs.docsTab)""#)
        let allowed = try await answer("allow")
        XCTAssertTrue(allowed.ok)
        try await waitFor { phone.events(.browserTabsChanged).last?.tabs?.first?.permission == nil }
        let again = try await answer("block")
        XCTAssertEqual(again.error?.code, .notFound, "that prompt is no longer up")
    }

    private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(testWaitLimitSeconds)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Condition not met in time", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
