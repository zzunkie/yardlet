import Foundation
import XCTest
@testable import NativeHarnessClient

final class GrokTranscriptSnapshotProjectionTests: XCTestCase {
    func testRepairsConcatenatedMessagesAndPlacesExistingCardsAtNativeBoundaries() throws {
        let fixture = try makeFixture(historyLines: [
            #"{"type":"system","content":"instructions"}"#,
            #"{"type":"user","prompt_index":0,"content":[{"type":"text","text":"<user_query>\nDoes it work?\n</user_query>"}]}"#,
            #"{"type":"assistant","content":"Inspecting.","tool_calls":[{"id":"tool-1","name":"read","arguments":{}}]}"#,
            #"{"type":"tool_result","tool_call_id":"tool-1","content":"ok"}"#,
            #"{"type":"assistant","content":"Testing.","tool_calls":[{"id":"tool-2","name":"execute","arguments":{}}]}"#,
            #"{"type":"tool_result","tool_call_id":"tool-2","content":"passed"}"#,
            #"{"type":"assistant","content":"Done.","tool_calls":[]}"#
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let user = TranscriptEntry(content: .user(text: "Does it work?"))
        let combined = TranscriptEntry(
            content: .assistant(text: "Inspecting.Testing.Done.", isStreaming: false)
        )
        let read = TranscriptEntry(content: .activity(
            HarnessActivity(id: "tool-1", kind: "read", title: "Read file", detail: nil),
            state: .completed
        ))
        let execute = TranscriptEntry(content: .activity(
            HarnessActivity(id: "tool-2", kind: "execute", title: "Run tests", detail: "swift test"),
            state: .completed
        ))
        let permission = TranscriptEntry(content: .permission(
            PermissionRequest(
                id: "permission-1",
                title: "Run tests",
                detail: "execute",
                command: "swift test"
            ),
            state: .allowed
        ))

        let repaired = try XCTUnwrap(GrokTranscriptSnapshotProjection.repairedEntries(
            providerSessionID: fixture.providerSessionID,
            existing: [user, combined, read, execute, permission],
            grokSessionsRoot: fixture.root
        ))

        XCTAssertEqual(repaired.map(\.content), [
            .user(text: "Does it work?"),
            .assistant(text: "Inspecting.", isStreaming: false),
            read.content,
            .assistant(text: "Testing.", isStreaming: false),
            execute.content,
            permission.content,
            .assistant(text: "Done.", isStreaming: false)
        ])
        XCTAssertEqual(repaired[1].id, combined.id)

        // A message at no time splits into messages at no time, not moments past it.
        let unrecorded = try XCTUnwrap(GrokTranscriptSnapshotProjection.repairedEntries(
            providerSessionID: fixture.providerSessionID,
            existing: [user, combined.made(at: TranscriptEntry.unrecordedTime), read, execute, permission],
            grokSessionsRoot: fixture.root
        ))
        XCTAssertEqual(unrecorded.filter { if case .assistant = $0.content { true } else { false } }.map(\.recordedAt),
                       [nil, nil, nil])
    }

    func testFailsClosedWhenProviderNarrativeDoesNotExactlyMatchSnapshot() throws {
        let fixture = try makeFixture(historyLines: [
            #"{"type":"user","prompt_index":0,"content":[{"type":"text","text":"<user_query>\nQuestion\n</user_query>"}]}"#,
            #"{"type":"assistant","content":"First.","tool_calls":[]}"#,
            #"{"type":"assistant","content":"Second.","tool_calls":[]}"#
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let repaired = GrokTranscriptSnapshotProjection.repairedEntries(
            providerSessionID: fixture.providerSessionID,
            existing: [
                TranscriptEntry(content: .user(text: "Question")),
                TranscriptEntry(content: .assistant(text: "Different.", isStreaming: false))
            ],
            grokSessionsRoot: fixture.root
        )

        XCTAssertNil(repaired)
    }

    func testFailsClosedWhenProviderSessionIDIsAmbiguousAcrossWorkspaces() throws {
        let fixture = try makeFixture(historyLines: [
            #"{"type":"user","prompt_index":0,"content":[{"type":"text","text":"<user_query>\nQuestion\n</user_query>"}]}"#,
            #"{"type":"assistant","content":"First.","tool_calls":[]}"#,
            #"{"type":"assistant","content":"Second.","tool_calls":[]}"#
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let duplicate = fixture.root
            .appending(path: "workspace-2", directoryHint: .isDirectory)
            .appending(path: fixture.providerSessionID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: duplicate, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: duplicate.appending(path: "chat_history.jsonl"))

        XCTAssertNil(GrokTranscriptSnapshotProjection.repairedEntries(
            providerSessionID: fixture.providerSessionID,
            existing: [],
            grokSessionsRoot: fixture.root
        ))
    }

    private func makeFixture(
        historyLines: [String]
    ) throws -> (root: URL, providerSessionID: String) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "GrokTranscriptSnapshotProjectionTests-\(UUID().uuidString)")
        let providerSessionID = UUID().uuidString
        let sessionDirectory = root
            .appending(path: "workspace-1", directoryHint: .isDirectory)
            .appending(path: providerSessionID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try Data((historyLines.joined(separator: "\n") + "\n").utf8).write(
            to: sessionDirectory.appending(path: "chat_history.jsonl")
        )
        return (root, providerSessionID)
    }
}
