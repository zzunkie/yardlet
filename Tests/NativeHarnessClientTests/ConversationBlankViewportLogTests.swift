import Foundation
import XCTest
@testable import NativeHarnessClient

/// The blank-viewport diagnostic (`ConversationBlankViewportLog`): off unless its defaults key is on,
/// and when on, one line when a conversation has shown no turn for a moment and one when it shows
/// turns again, naming the task, its turns, where the viewport was and what happened last.
@MainActor
final class ConversationBlankViewportLogTests: XCTestCase {
    private var lines: [String] = []
    private var write: ((String) -> Void)?

    override func setUp() async throws {
        write = ConversationBlankViewportLog.write
        ConversationBlankViewportLog.write = { [weak self] in self?.lines.append($0) }
    }

    override func tearDown() async throws {
        if let write { ConversationBlankViewportLog.write = write }
    }

    func testItIsOffUnlessItsDefaultsKeyIsOnAndWritesToTheYardletLogs() {
        XCTAssertEqual(ConversationBlankViewportLog.defaultsKey, "Yardlet.debug.blankViewportLog")
        XCTAssertFalse(UserDefaults.yardlet.bool(forKey: ConversationBlankViewportLog.defaultsKey))
        XCTAssertEqual(ConversationBlankViewportLog.liveFileURL.path(percentEncoded: false),
                       FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
                           + "Library/Logs/Yardlet/blank-frames.log")
    }

    /// A test process's file writer appends to a file in the temporary folder, never to the
    /// person's `~/Library/Logs/Yardlet/blank-frames.log`, so a line a conversation writes after its
    /// test put the file writer back stays out of the real log.
    func testATestProcessNeverWritesToThePersonsLog() throws {
        XCTAssertTrue(ConversationBlankViewportLog.isTestProcess)
        let live = ConversationBlankViewportLog.liveFileURL
        let file = ConversationBlankViewportLog.fileURL
        XCTAssertNotEqual(file.standardizedFileURL, live.standardizedFileURL)
        XCTAssertTrue(file.path(percentEncoded: false)
            .hasPrefix(FileManager.default.temporaryDirectory.path(percentEncoded: false)), file.path())

        func stamp(_ url: URL) -> [FileAttributeKey: Any]? {
            try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        }
        let before = stamp(live)
        let line = "blank viewport began: task TEST-\(UUID().uuidString)"
        ConversationBlankViewportLog.appendToFile(line)
        ConversationBlankViewportLog.flush()
        let written = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(written.contains(line))
        let after = stamp(live)
        XCTAssertEqual(before?[.size] as? Int, after?[.size] as? Int, "The person's log is untouched")
        XCTAssertEqual(before?[.modificationDate] as? Date, after?[.modificationDate] as? Date)
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    func testAViewportWithNoTurnInViewIsWrittenDownWithItsTaskGeometryAndLastAction() async throws {
        let monitor = ConversationBlankViewportMonitor()
        monitor.conversationID = "TASK-1"
        monitor.observe(itemCount: 40)
        monitor.observe(TranscriptScrollMetrics(height: 32_659, viewport: CGSize(width: 355, height: 399),
                                                offset: 32_260, distance: 0), isFollowing: true)
        monitor.observe(visibleItems: 1)
        monitor.note("content height 32834 to 32659")
        monitor.observe(visibleItems: 0)
        // The line comes once the threshold has passed and the main actor gets to it, which on a
        // busy machine (CI runs four test processes on three cores) can be well after 120 ms.
        let deadline = ContinuousClock.now + .seconds(2)
        while lines.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(lines.count, 1, "\(lines)")
        let began = try XCTUnwrap(lines.first)
        for part in ["blank viewport began", "task TASK-1", "turns 40", "visible 0", "offset 32260",
                     "viewport 355x399", "content 32659", "following true", "last content height 32834 to 32659"] {
            XCTAssertTrue(began.contains(part), "\(part) in \(began)")
        }
        monitor.note("scrolled")
        monitor.observe(visibleItems: 2)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].hasPrefix("blank viewport ended after "), lines[1])
        XCTAssertTrue(lines[1].contains("last scrolled"), lines[1])
    }

    /// One layout pass can report no turn in view just before the next lays them out, in the same
    /// frame: nothing is written for that.
    func testAMomentWithoutTurnsInViewIsNotWrittenDown() async throws {
        let monitor = ConversationBlankViewportMonitor()
        monitor.observe(itemCount: 12)
        monitor.observe(TranscriptScrollMetrics(height: 9_000, viewport: CGSize(width: 600, height: 500),
                                                offset: 8_500, distance: 0), isFollowing: true)
        monitor.observe(visibleItems: 0)
        monitor.observe(visibleItems: 1)
        // Past the end of the content, too.
        monitor.observe(TranscriptScrollMetrics(height: 9_000, viewport: CGSize(width: 600, height: 500),
                                                offset: 9_100, distance: 0), isFollowing: true)
        monitor.observe(TranscriptScrollMetrics(height: 9_000, viewport: CGSize(width: 600, height: 500),
                                                offset: 8_500, distance: 0), isFollowing: true)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(lines, [])
        // An empty conversation is not a blank viewport.
        let empty = ConversationBlankViewportMonitor()
        empty.observe(itemCount: 0)
        empty.observe(visibleItems: 0)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(lines, [])
    }
}
