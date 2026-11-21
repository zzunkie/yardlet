import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient
@testable import YardletRemote

extension RemoteHostWindowRenderingTests {
    /// The host's calendar in its window (§15.38): refused, and the window saying where to allow it, until the device has
    /// its Mail and Calendar permission; then the local calendar's sidebar and week over the host's accounts, read through
    /// the host. Drawn as `remote-calendar-permission-*.png`, `remote-calendar-*.png` and `local-calendar-*.png`.
    func testHostCalendarDrawsAsTheLocalOneOnceTheDeviceMayReadIt() async throws {
        let calendar = Calendar.autoupdatingCurrent
        let week = try XCTUnwrap(calendar.dateInterval(of: .weekOfYear, for: Date()))
        func day(_ index: Int) -> DateInterval {
            let start = calendar.date(byAdding: .day, value: index, to: week.start)!
            return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
        }
        let work = FakeCalendarService(account: CalendarAccount(id: UUID(), provider: .google, address: "dana@acme.example",
                                                                connectorSlug: "calendar"))
        let primary = work.add("dana@acme.example", isPrimary: true, color: "#4A7BD0")
        let team = work.add("Team", color: "#3E9B6F")
        work.add(event: "Weekly team meeting", hour: 14, to: team, day: day(1))
        work.add(event: "Investor call", hour: 16.5, minutes: 30, to: primary, day: day(1), response: .needsAction,
                 organizer: CalendarPerson(name: "Partner IR", email: "ir@partner.example"))
        work.add(event: "Ops meeting", hour: 11, to: primary, day: day(2))
        work.add(event: "Design review", hour: 14, to: team, day: day(3))

        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteCalendarRender")))
        let host = AppModel(store: SessionStore(sessions: [], repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults), preferences: defaults, restoresIndexOnLaunch: false)
        host.calendar.setEnabled(true)
        host.calendar.setAccounts([(work.account, work)])
        defer { host.calendar.setEnabled(false) }
        let stack = try await LoopbackStack(name: "Mac Studio", bridge: AppModelRemoteBridge(model: host))
        defer { stack.stop() }
        let ticket = await stack.server.openPairing()
        let link = try XCTUnwrap(RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey, secret: ticket.secret,
            name: "Mac Studio", hosts: ["127.0.0.1:\(stack.port)"]).url)
        let hosts = RemoteHostDirectory(store: RemoteHostStore(fileURL: nil), keys: RemoteMemoryClientKeys(),
            hello: RemoteHandshakeHello(name: "MacBook Air", platform: "macos", appVersion: "test"))
        let paired = try await hosts.pair(link: link.absoluteString)
        defer { hosts.close(paired.id) }
        let model = try XCTUnwrap(hosts.model(for: paired.id))

        // Without the permission the host says its calendar is on and nothing of it: a call is refused for the reason.
        try await waitUntil { model.mailCalendarState?.calendar == true }
        XCTAssertTrue(model.needsMailCalendarPermission)
        XCTAssertTrue(model.calendar.isEnabled)
        XCTAssertTrue(model.calendar.accounts.isEmpty)
        let refused = await model.response(to: .calendar(action: "accounts", data: nil))
        XCTAssertEqual(refused.error?.code, .notAllowed)
        XCTAssertEqual(refused.error?.reason, .mailCalendar)
        let call = RemoteRequest.calendar(action: "events", data: RemoteCalendarWire.encode(RemoteCalendarWire.Call(accountID: work.account.id)))
        XCTAssertEqual(try RemoteRequestEnvelope.decode(RemoteRequestEnvelope(id: "c", request: call).encoded()).get().request, call)
        XCTAssertEqual(call.requiredPermission, .mailCalendar)

        let shell = RemoteHostShell()
        shell.section = .calendar
        let size = NSSize(width: 1_280, height: 820)
        try await render("remote-calendar-permission", size: size, titled: true, title: model.name) {
            RemoteHostView(model: model, directory: hosts, shell: shell)
        } check: { elements in
            XCTAssertTrue(elements.description.contains(L10n.string("Mail and Calendar")), elements.description)
        }

        // Allowed on the host, the window reads the host's accounts and the week through it, the host's choices with them.
        try await stack.server.setPermission(.mailCalendar, allowed: true, for: try XCTUnwrap(model.host.deviceID))
        try await waitUntil { model.calendar.accounts == [work.account] }
        try await render("remote-calendar", size: size, titled: true, title: model.name,
                         ready: { elements in elements.contains { $0.label.hasPrefix("Ops meeting") } }) {
            RemoteHostView(model: model, directory: hosts, shell: shell)
        } check: { elements in
            XCTAssertTrue(elements.contains { $0.label.hasPrefix("Investor call") && $0.value == L10n.string("Not replied") },
                          elements.description)
            XCTAssertFalse(elements.contains { $0.label == L10n.string("Personal agents") }, elements.description)
        }

        // The same week in the host's own window, for comparison.
        let local = CalendarWindowState()
        try await render("local-calendar", size: NSSize(width: size.width - 240, height: size.height), titled: false,
                         ready: { elements in elements.contains { $0.label.hasPrefix("Ops meeting") } }) {
            CalendarWorkspace(center: host.calendar, window: local, schedules: [], titleBar: { AnyView($0) },
                              onOpenSchedule: { _ in }, onAskAgent: { _, _ in })
                .background(ParityTheme.canvas)
        }

        // An answer goes through the host to the account's service.
        let invitation = try XCTUnwrap(model.calendar.events(in: week).first { $0.title == "Investor call" })
        try await model.calendar.respond(to: invitation, .accepted)
        XCTAssertEqual(work.answers.count, 1)
        await host.shutdown()
    }
}
