import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletRemote

@MainActor
final class RemoteNextStepHostTests: XCTestCase {
    func testSubtaskPageKeepsALargeLatestTurnInsteadOfReturningAnEmptyPanel() throws {
        var prompt = RemoteItem(id: "prompt", turnId: "latest", kind: .user)
        prompt.text = "Investigate the parser"
        var items = [prompt, RemoteItem(id: "header", turnId: "latest", kind: .turn)]
        for index in 0..<160 {
            var item = RemoteItem(id: "call-\(index)", turnId: "latest", kind: .activity)
            item.title = "Read parser input \(index)"
            item.detail = String(repeating: "x", count: 3000)
            items.append(item)
        }
        let latest = RemoteTurn(id: "latest", items: items)
        let page = RemoteSubtaskTranscript.window(RemoteConversation(turns: [latest], hasEarlier: false),
            omittedItemText: "Content omitted")
        XCTAssertEqual(page.items, items, "The latest complete turn may exceed both soft page limits")
        XCTAssertFalse(page.truncated)
        let older = RemoteTurn(id: "older", items: [RemoteItem(id: "old", turnId: "older", kind: .user)])
        let withEarlier = RemoteSubtaskTranscript.window(RemoteConversation(turns: [older, latest], hasEarlier: false),
            omittedItemText: "Content omitted")
        XCTAssertEqual(withEarlier.items, items)
        XCTAssertTrue(withEarlier.truncated, "An earlier omitted turn must be disclosed")
        let emptyTail = RemoteSubtaskTranscript.window(RemoteConversation(turns: [], hasEarlier: true),
            omittedItemText: "Content omitted")
        XCTAssertTrue(emptyTail.truncated, "A source truncation remains true even if its tail has no visible items")
    }

    func testSubtaskHardWireBudgetKeepsRecentItemsAndDisclosesAnOversizedItem() throws {
        var old = RemoteItem(id: "old", turnId: "only", kind: .user)
        old.text = String(repeating: "a", count: 3000)
        var huge = RemoteItem(id: "huge", turnId: "only", kind: .activity)
        huge.detail = String(repeating: "b", count: 20_000)
        var answer = RemoteItem(id: "answer", turnId: "only", kind: .assistant)
        answer.text = String(repeating: "c", count: 2000)
        let conversation = RemoteConversation(turns: [RemoteTurn(id: "only", items: [old, huge, answer])], hasEarlier: false)
        let result = RemoteSubtaskTranscript.window(conversation, omittedItemText: "Content omitted", maximumPayloadBytes: 4096)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.items.last, answer)
        XCTAssertTrue(result.items.contains { $0.kind == .notice && $0.text == "Content omitted" })
        XCTAssertFalse(result.items.contains { $0.id == old.id })
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(result).count, 4096)
        let single = RemoteSubtaskTranscript.window(
            RemoteConversation(turns: [RemoteTurn(id: "only", items: [huge])], hasEarlier: false),
            omittedItemText: "Content omitted", maximumPayloadBytes: 4096)
        XCTAssertEqual(single.items.count, 1)
        XCTAssertEqual(single.items.first?.text, "Content omitted")
        XCTAssertTrue(single.truncated)
    }

    func testRestoreRequiresAHostReceiptForTheSameListedTask() async throws {
        let session = SessionRecord(harness: .claudeCode,
            workspaceURL: URL(fileURLWithPath: "/tmp/remote-rewind-test", isDirectory: true),
            runtimeExecutableURL: URL(fileURLWithPath: "/tmp/claude"), title: "Rewind test", status: .completed)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteRewindReceipt")))
        let model = AppModel(store: SessionStore(sessions: [session], repository: InMemorySessionRepository(sessions: [session])),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults), restoresIndexOnLaunch: false)
        let bridge = AppModelRemoteBridge(model: model)
        for confirmed in [false, true] {
            let result = await bridge.fileRewind(taskID: session.id.uuidString, action: .restore,
                pointID: nil, receipt: UUID().uuidString, confirmed: confirmed, permit: RemoteFileWritePermit())
            guard case let .failure(error) = result else { return XCTFail("A client cannot invent a reviewed receipt") }
            XCTAssertEqual(error.code, .notAllowed)
        }
        let missing = await bridge.fileRewind(taskID: UUID().uuidString, action: .restore,
            pointID: nil, receipt: UUID().uuidString, confirmed: true, permit: RemoteFileWritePermit())
        guard case let .failure(error) = missing else { return XCTFail("An unlisted task must not be restored") }
        XCTAssertEqual(error.code, .notFound)
    }
}
