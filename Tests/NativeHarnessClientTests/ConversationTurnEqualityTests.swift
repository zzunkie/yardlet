import XCTest
@testable import NativeHarnessClient

/// `ConversationTurn`'s own `==` compares its cheap parts first; it must still compare every part.
final class ConversationTurnEqualityTests: XCTestCase {
    func testEveryStoredPropertyIsCompared() {
        let turn = ConversationTurn(id: "turn", status: .running, timing: ConversationTurnTiming())
        XCTAssertEqual(Mirror(reflecting: turn).children.count, ConversationTurn.comparedPropertyCount,
                       "A property was added to ConversationTurn: compare it in its == and isUnchanged(from:)")
    }

    func testAChangeInAnyPartTellsTurnsApart() {
        let item = ConversationItem(id: "a", kind: .answer(text: "One", isStreaming: true), phase: .running,
                                    source: .transcript(TranscriptEntry(content: .assistant(text: "One", isStreaming: true))))
        var base = ConversationTurn(id: "turn", status: .running, timing: ConversationTurnTiming())
        base.work = [item, item]
        base.answers = [item]
        base.recordOrder = ["a"]
        XCTAssertEqual(base, base)
        XCTAssertTrue(base.isUnchanged(from: base))
        // The same turn in storage of its own is equal, and reads as changed to the quick comparison.
        var copied = base
        copied.work = base.work.map { $0 }
        XCTAssertEqual(copied, base)
        XCTAssertFalse(copied.isUnchanged(from: base))
        var changes: [(String, (inout ConversationTurn) -> Void)] = [
            ("status", { $0.status = .completed }),
            ("prompt", { $0.prompt = [item] }),
            ("notices", { $0.notices = [item] }),
            ("first call", { $0.work[0].phase = .completed }),
            ("last call", { $0.work[1].phase = .completed }),
            ("answers", { $0.answers[0].kind = .answer(text: "One two", isStreaming: true) }),
            ("hasWorkDetails", { $0.hasWorkDetails.toggle() }),
            ("hasMoreItems", { $0.hasMoreItems.toggle() }),
            ("showsHeader", { $0.showsHeader.toggle() }),
            ("recordOrder", { $0.recordOrder = ["b"] }),
        ]
        changes.append(("progress", { $0.progress = .reconnecting("Retrying") }))
        for (name, change) in changes {
            var changed = base
            change(&changed)
            XCTAssertNotEqual(base, changed, name)
            XCTAssertFalse(changed.isUnchanged(from: base), name)
        }
    }
}
