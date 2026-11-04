import Foundation
import XCTest
@testable import NativeHarnessClient
import YardletRemote
import YardletRemoteFixtureSupport

final class RemoteScheduleFixtureTests: XCTestCase {
    func testFixtureDefinitionsDecodeAndEditingKeepsHistory() async throws {
        let fixture = RemoteFixtureBridge(speed: 0.01)
        let snapshot = await fixture.snapshot()
        XCTAssertTrue(snapshot.scheduleEditing)
        let list = try await fixture.scheduledTasks().get()
        XCTAssertEqual(list.count, 4)
        let definitions = try list.map { try JSONDecoder().decode(ScheduledTask.self, from: XCTUnwrap($0.definition)) }
        XCTAssertEqual(definitions.map(\.name), list.map(\.name))
        XCTAssertTrue(definitions.allSatisfy { !$0.prompt.isEmpty && !$0.state.runs.isEmpty })
        let jobs = await fixture.sessionSchedules()
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(ClaudeSessionJob.self, from: XCTUnwrap(jobs.first?.job)).kind, .recurring)

        var edited = try XCTUnwrap(definitions.first)
        edited.name = "Updated morning check"
        edited.prompt = "Check all new reports."
        let data = try JSONEncoder().encode(edited)
        let declined = await fixture.saveScheduledTask(scheduleID: edited.id.uuidString, definition: data,
            settings: ["runLocation": "dangerFullAccess"], confirmed: false)
        if case .success = declined { XCTFail("Elevated permissions need confirmation") }
        let id = try await fixture.saveScheduledTask(scheduleID: edited.id.uuidString, definition: data,
            settings: ["runLocation": "dangerFullAccess"], confirmed: true).get()
        XCTAssertEqual(id, edited.id.uuidString)
        let savedList = try await fixture.scheduledTasks().get()
        let saved = try JSONDecoder().decode(ScheduledTask.self, from: XCTUnwrap(savedList.first?.definition))
        XCTAssertEqual(saved.name, edited.name)
        XCTAssertEqual(saved.state.runs, edited.state.runs)
        XCTAssertEqual(saved.destination.modelChoice?.permissionMode, "dangerFullAccess")
        let refused = await fixture.deleteScheduledTasks(scheduleIDs: [id], completedOnly: false, confirmed: false)
        XCTAssertEqual(refused?.code, .notAllowed)
        let deleted = await fixture.deleteScheduledTasks(scheduleIDs: [id], completedOnly: false, confirmed: true)
        XCTAssertNil(deleted)
        let remaining = try await fixture.scheduledTasks().get()
        XCTAssertFalse(remaining.contains { $0.id == id })
    }
    func testFixtureScheduleAccountsRefreshChoicesAndRejectUnknownAccounts() async throws {
        let fixture = RemoteFixtureBridge(speed: 0.01)
        let personal = try await fixture.scheduledTaskOptions(projectID: nil,
            harness: "codex", settings: [:]).get()
        XCTAssertEqual(personal.scheduleAccounts?.count, 2)
        XCTAssertEqual(personal.scheduleAccountID, "fixture-home")
        let work = try await fixture.scheduledTaskOptions(projectID: nil,
            harness: "codex", settings: [:], accountID: "fixture-work").get()
        XCTAssertEqual(work.scheduleAccountID, "fixture-work")
        XCTAssertNotEqual(personal.settings.first { $0.id == "model" }?.value,
                          work.settings.first { $0.id == "model" }?.value)
        let missing = await fixture.scheduledTaskOptions(projectID: nil,
            harness: "codex", settings: [:], accountID: "not-offered")
        if case .success = missing { XCTFail("An unavailable account must be refused") }

        let list = try await fixture.scheduledTasks().get()
        var schedule = try JSONDecoder().decode(ScheduledTask.self, from: XCTUnwrap(list.first?.definition))
        schedule.destination.accountID = "not-offered"
        let refused = await fixture.saveScheduledTask(scheduleID: schedule.id.uuidString,
            definition: try JSONEncoder().encode(schedule), settings: [:], confirmed: false)
        if case .success = refused { XCTFail("Saving cannot bypass the account catalog") }
        schedule.destination.accountID = "fixture-work"
        _ = try await fixture.saveScheduledTask(scheduleID: schedule.id.uuidString,
            definition: JSONEncoder().encode(schedule), settings: [:], confirmed: false).get()
        let savedList = try await fixture.scheduledTasks().get()
        let saved = try JSONDecoder().decode(ScheduledTask.self, from: XCTUnwrap(savedList.first?.definition))
        XCTAssertEqual(saved.destination.accountID, "fixture-work")
        XCTAssertEqual(saved.destination.modelChoice?.model, "gpt-6-astra")
        let reopened = try await fixture.scheduledTaskOptions(projectID: nil,
            harness: "codex", settings: [:], scheduleID: schedule.id.uuidString).get()
        XCTAssertEqual(reopened.scheduleAccountID, "fixture-work")
    }

}
