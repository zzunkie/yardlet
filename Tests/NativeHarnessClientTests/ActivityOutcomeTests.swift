import Foundation
import XCTest
@testable import NativeHarnessClient

final class ActivityOutcomeTests: XCTestCase {
    func testOldActivitiesDecodeAndFailureSurvivesStorageAndLaterSuccess() throws {
        let old = Data(#"{"id":"tool","kind":"read","title":"Read"}"#.utf8)
        var activity = try JSONDecoder().decode(HarnessActivity.self, from: old)
        XCTAssertNil(activity.outcome)
        activity.outcome = .failed
        let saved = try JSONEncoder().encode(activity)
        activity = try JSONDecoder().decode(HarnessActivity.self, from: saved)
        var builder = TranscriptBuilder()
        builder.appendUser("Read the folder")
        builder.apply(.activityCompleted(activity))
        builder.apply(.assistantMessageCompleted("The folder could not be read."))
        builder.apply(.turnCompleted)
        XCTAssertEqual(builder.entries[1].content, .activity(activity, state: .failed))
        XCTAssertEqual(TranscriptBuilder(entries: builder.entries).entries[1].content,
                       .activity(activity, state: .failed))
        let turn = TranscriptConversationProjection.presentation(
            from: builder.entries, harness: .claudeCode, status: .ready, latestTurnIsComplete: true
        ).turns[0]
        XCTAssertEqual(turn.work.map(\.phase), [.failed], "the call still reads as failed")
    }
}
