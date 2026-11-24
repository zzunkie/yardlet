import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Send Feedback's contract with the relay's `POST /v1/feedback` (relay/README.md): the fields sent and
/// nothing else, one id for every retry of one note, and what the sheet lists before sending. Renders go to
/// `.build/private-feedback-qa`, light and dark: `feedback-*` a note from the sidebar, `problem-*` a report
/// from an error card with an email added, `failed-*` after a failed send, `sent-*` after one went.
@MainActor
final class PrivateFeedbackTests: XCTestCase {
    private let problem = PrivateFeedbackContext.problem(
        surface: .localTask, harness: .claudeCode, failure: .init(kind: "actionFailed", code: "overloaded_error"),
        app: "0.11.16 (38)", macOS: "macOS 26.1")

    func testANoteCarriesOnlyItsTextTheVersionsTheScreenAndTheErrorsKind() throws {
        let submission = PrivateFeedbackSubmission(id: UUID(uuidString: "0F2C6F8E-6A39-4B53-9C6E-3B1D2E7C9A10")!,
                                                   context: problem, message: "The answer stopped", replyTo: nil)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(submission)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["id", "kind", "message", "context"])
        XCTAssertEqual(object["id"] as? String, "0f2c6f8e-6a39-4b53-9c6e-3b1d2e7c9a10")
        XCTAssertEqual(object["kind"] as? String, "problem")
        let context = try XCTUnwrap(object["context"] as? [String: Any])
        XCTAssertEqual(Set(context.keys), ["app", "surface", "macOS", "harness", "error"])
        XCTAssertEqual(context["surface"] as? String, "localTask")
        XCTAssertEqual(context["error"] as? [String: String], ["kind": "actionFailed", "code": "overloaded_error"])

        // A note from the sidebar: the app's version and the screen, no macOS version or agent.
        let note = PrivateFeedbackSubmission(id: UUID(), context: .feedback(surface: .home, app: "0.11.16 (38)"),
                                             message: "Hi", replyTo: "me@example.com")
        let noteObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(note)) as? [String: Any])
        XCTAssertEqual(noteObject["replyTo"] as? String, "me@example.com")
        XCTAssertEqual(noteObject["context"] as? [String: String], ["app": "0.11.16 (38)", "surface": "home"])
    }

    /// Only a provider's code goes, never the message around it.
    func testAnErrorsCodeIsReadWithoutItsMessage() {
        XCTAssertEqual(PrivateFeedbackContext.errorCode(in: #"API Error: 529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#),
                       "overloaded_error")
        XCTAssertEqual(PrivateFeedbackContext.errorCode(in: #"{"code":"rate_limit_exceeded","message":"/Users/alex/x"}"#),
                       "rate_limit_exceeded")
        XCTAssertEqual(PrivateFeedbackContext.errorCode(in: "Request failed with status code 401"), "401")
        XCTAssertNil(PrivateFeedbackContext.errorCode(in: "Could not open /Users/alex/Projects/app (exit code 1)"))
        XCTAssertNil(PrivateFeedbackContext.errorCode(in: #"{"code":"has a space /Users/alex"}"#))
        XCTAssertNil(PrivateFeedbackContext.errorCode(in: nil))
    }

    func testTheEndpointIsTheBuiltInRelays() {
        XCTAssertEqual(PrivateFeedbackClient.endpoint(forRelay: "wss://relay.example.test")?.absoluteString,
                       "https://relay.example.test/v1/feedback")
        XCTAssertEqual(PrivateFeedbackClient.endpoint(forRelay: "ws://127.0.0.1:8787/")?.absoluteString,
                       "http://127.0.0.1:8787/v1/feedback")
        XCTAssertNil(PrivateFeedbackClient.endpoint(forRelay: "relay.example.test"))
    }

    /// A failed send keeps the note and sends it again under the same id; a changed note is a new one.
    func testSendingAgainReusesTheNotesId() async throws {
        let posted = Posted()
        let client = PrivateFeedbackClient(endpoint: URL(string: "https://relay.example.test/v1/feedback")) { request in
            let status = await posted.record(request)
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        let form = PrivateFeedbackForm(context: problem, client: client)
        XCTAssertFalse(form.canSend)
        form.message = "  The answer stopped  "
        form.addsEmail = true
        form.email = "not an email"
        XCTAssertFalse(form.canSend, "An email that is not one")
        form.email = "me@example.com"
        await posted.answer(503)
        await form.send()
        guard case .failed = form.state else { return XCTFail("\(form.state)") }
        XCTAssertEqual(form.message, "  The answer stopped  ", "The note is kept")
        XCTAssertTrue(form.hasUnsentNote)
        await posted.answer(202)
        await form.send()
        XCTAssertEqual(form.state, .sent)
        XCTAssertFalse(form.hasUnsentNote)
        let bodies = Self.objects(await posted.bodyData)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0]["id"] as? String, bodies[1]["id"] as? String)
        XCTAssertEqual(bodies[0]["message"] as? String, "The answer stopped")
        XCTAssertEqual(bodies[0]["replyTo"] as? String, "me@example.com")
        let headers = await posted.contentTypes
        XCTAssertEqual(headers, ["application/json", "application/json"])

        let edited = PrivateFeedbackForm(context: problem, client: client)
        edited.message = "First"
        await posted.answer(503)
        await edited.send()
        edited.message = "First, and more"
        await posted.answer(202)
        await edited.send()
        let all = Self.objects(await posted.bodyData)
        XCTAssertNotEqual(all[2]["id"] as? String, all[3]["id"] as? String)

        let unconfigured = PrivateFeedbackForm(context: problem, client: PrivateFeedbackClient(endpoint: nil) { _ in
            XCTFail("Nothing is sent without an endpoint")
            throw URLError(.badURL)
        })
        unconfigured.message = "Hi"
        await unconfigured.send()
        XCTAssertEqual(unconfigured.state, .failed(L10n.string("This build of Yardlet cannot send feedback.")))
    }

    private static func objects(_ bodies: [Data]) -> [[String: Any]] {
        bodies.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// Cancel, the close button and ⌘W all ask before losing a note and wait while it is going; a send
    /// stopped by closing says nothing went wrong; a closed sheet lets go of its window and the note.
    func testClosingAsksFirstStopsTheSendAndLetsGoOfTheNote() async throws {
        let form = PrivateFeedbackForm(context: problem, client: .offline)
        XCTAssertTrue(form.mayClose(), "Nothing written")
        form.message = "Half a thought"
        XCTAssertFalse(form.mayClose())
        XCTAssertTrue(form.confirmsDiscard)

        let hanging = PrivateFeedbackForm(context: problem, client: PrivateFeedbackClient(
            endpoint: URL(string: "https://relay.example.test/v1/feedback")) { _ in
            try await Task.sleep(for: .seconds(60))
            throw URLError(.timedOut)
        })
        hanging.message = "Going"
        hanging.startSending()
        try await waitUntil { hanging.state == .sending }
        XCTAssertFalse(hanging.mayClose(), "Not while it is going")
        hanging.cancelSending()
        try await waitUntil { hanging.state == .editing }
        XCTAssertEqual(hanging.message, "Going")

        // Control characters the endpoint refuses are left out; tabs and line breaks stay.
        hanging.message = "a\u{0007}b\tc\nd\u{0085}"
        XCTAssertEqual(hanging.trimmedMessage, "ab\tc\nd")
        hanging.addsEmail = true
        hanging.email = "dä@example.com"
        XCTAssertFalse(hanging.emailIsValid, "Printable US-ASCII only, as the endpoint takes")

        // A parent that is never shown, so nothing comes onto the screen.
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: true)
        parent.alphaValue = 0
        weak var closedWindow: NSWindow?
        weak var closedForm: PrivateFeedbackForm?
        autoreleasepool {
            let shown = PrivateFeedbackWindow(form: PrivateFeedbackForm(context: problem, client: .offline), over: parent)
            closedWindow = shown.window
            closedForm = shown.form
            XCTAssertEqual(shown.window.title, L10n.string("Send Problem Report"))
            XCTAssertFalse(shown.window.styleMask.contains(.closable), "A sheet closes with Cancel")
            shown.form.message = "Unsent"
            XCTAssertFalse(shown.windowShouldClose(shown.window), "Asks first")
            XCTAssertTrue(shown.form.confirmsDiscard)
            shown.finish()
        }
        try await waitUntil { closedWindow == nil && closedForm == nil }
    }

    func testTheSheetListsWhatIsSentBeforeSending() throws {
        let directory = try WindowlessRender.directory("private-feedback-qa")
        XCTAssertEqual(problem.includedLines.map(\.label), [
            L10n.string("App version"), "macOS", L10n.string("Agent"), L10n.string("Screen"), L10n.string("Error"),
        ])
        XCTAssertEqual(problem.includedLines.last?.value, "actionFailed · overloaded_error")
        XCTAssertEqual(PrivateFeedbackContext.feedback(surface: .home, app: "1").includedLines.map(\.label),
                       [L10n.string("App version"), L10n.string("Screen")])

        let feedback = PrivateFeedbackForm(context: .feedback(surface: .home, app: "0.11.16 (38)"), client: .offline)
        let report = PrivateFeedbackForm(context: problem, client: .offline)
        report.message = "The answer stopped halfway and Retry did nothing."
        report.addsEmail = true
        report.email = "me@example.com"
        let failed = PrivateFeedbackForm(context: problem, client: .offline)
        failed.message = "The answer stopped halfway."
        let sent = PrivateFeedbackForm(context: problem, client: .accepting)
        sent.message = "Thanks"
        let exp = expectation(description: "sent")
        Task {
            await failed.send()
            await sent.send()
            exp.fulfill()
        }
        wait(for: [exp], timeout: testWaitLimitSeconds)

        for (name, form, height) in [("feedback", feedback, 400.0), ("problem", report, 470.0),
                                     ("failed", failed, 440.0), ("sent", sent, 200.0)] {
            let size = NSSize(width: PrivateFeedbackSheet.width, height: height)
            let captures = try WindowlessRender.hostedInBothAppearances(name, in: directory, size: size) { appearance in
                PrivateFeedbackSheet(form: form, close: {})
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, appearance.colorScheme)
            }
            XCTAssertTrue(captures.allSatisfy { WindowlessRender.drawsContent($0.bitmap, step: 6) }, name)
        }
    }
}

private actor Posted {
    private(set) var bodyData: [Data] = []
    private(set) var contentTypes: [String?] = []
    private var status = 202

    func answer(_ status: Int) { self.status = status }

    func record(_ request: URLRequest) -> Int {
        contentTypes.append(request.value(forHTTPHeaderField: "Content-Type"))
        if let body = request.httpBody { bodyData.append(body) }
        return status
    }
}

private extension PrivateFeedbackClient {
    static let offline = PrivateFeedbackClient(endpoint: URL(string: "https://relay.example.test/v1/feedback")) { _ in
        throw URLError(.notConnectedToInternet)
    }
    static let accepting = PrivateFeedbackClient(endpoint: URL(string: "https://relay.example.test/v1/feedback")) { request in
        (Data(), HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!)
    }
}
