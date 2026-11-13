import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The calendar drawn in an unshown window with fictional accounts (`FakeCalendarService`): the section words with
/// the mailbox on and then the calendar too, what comes next and every calendar to show or hide, the week with
/// invitations not answered, overlapping meetings side by side, an all-day event and Yardlet's scheduled runs on their
/// layer, an invitation opened and accepted on its own service, the hand-off to an agent, and one day. While the
/// calendar shows it reads its days again as often as it is set to; once the window shows its tasks, it reads nothing.
/// Drawn under `.build/calendar-qa/`, with the sidebar at 240 and 351 points, in both appearances.
@MainActor
final class CalendarRenderingTests: XCTestCase {
    private var korean: Bool { L10n.string("Calendar") == "캘린더" }
    private func text(_ ko: String, _ en: String) -> String { korean ? ko : en }

    func testTheCalendarShowsItsWeekAndReadsOnlyWhileShown() async throws {
        let directory = try WindowlessRender.directory("calendar-qa")
        let language = korean ? "ko" : "en"
        for (size, sidebar) in [(NSSize(width: 1280, height: 820), 240.0), (NSSize(width: 1800, height: 1125), 351.0)] {
            for appearance in WindowlessRender.Appearance.allCases {
                SidebarWidth.store(sidebar, in: .yardlet)
                let model = try makeWindowModel()
                let services = fixture()
                model.mailbox.setEnabled(true)
                let host = WindowlessRender.Host(MainWindow(model: model)
                    .environment(\.colorScheme, appearance.colorScheme)
                    .frame(width: size.width, height: size.height), size: size, appearance: appearance)
                defer { host.close() }
                host.settle()
                let name = "\(language)-\(Int(sidebar))-\(appearance.suffix).png"
                // Three words with the mailbox on, four with the calendar too.
                try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "words-3-\(name)"))
                model.calendar.refreshInterval = .milliseconds(150)
                model.calendar.setEnabled(true)
                model.calendar.setAccounts(services.map { ($0.account, $0) })
                host.settle(passes: 6)
                try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "words-4-\(name)"))
                let reads = { services.map(\.reads).reduce(0, +) }
                XCTAssertEqual(reads(), 0, "On, the calendar reads nothing until it shows")

                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Calendar")))
                let ops = text("운영 회의", "Ops meeting")
                await host.settle(until: { host.accessibilityElements().contains { $0.label.hasPrefix(ops) } })
                // The Mac's Holidays calendar is hidden by the person.
                if let holidays = model.calendar.calendars.first(where: { $0.name == text("대한민국 공휴일", "Holidays") }) {
                    model.calendar.setShown(false, for: holidays)
                }
                host.settle(passes: 10)
                try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "week-\(name)"))
                let invitation = try XCTUnwrap(host.accessibilityElements().first { $0.label.hasPrefix(text("투자사 통화", "Investor call")) })
                XCTAssertEqual(invitation.value, L10n.string("Not replied"))
                XCTAssertTrue(host.accessibilityElements().contains { $0.label.hasPrefix(text("홍보 확인 · 오전", "Promotion check · morning")) },
                              "The scheduled runs' layer shows")

                // It keeps reading while it shows.
                let shown = reads()
                try await waitUntil { reads() > shown }

                // An invitation opened beside the week, accepted on its own service.
                XCTAssertTrue(host.hosting.pressAccessibilityElement { $0.hasPrefix(text("투자사 통화", "Investor call")) })
                await host.settle(until: { host.accessibilityElements().contains { $0.label == L10n.string("Accept invitation") } })
                host.settle(passes: 8)
                try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "event-\(name)"))
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Accept invitation")))
                await host.settle(until: { host.accessibilityElements().contains { [$0.label, $0.value].contains(L10n.string("You accepted this invitation.")) } })
                XCTAssertEqual(services[0].answers.count, 1)
                XCTAssertTrue(services[0].answers.first?.hasSuffix(" accepted") == true)

                // Handed to an agent: a new chat names the event and the tool that reads it, without its description.
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Hand to an agent…")))
                await host.settle(until: { model.composerDrafts.home.text.contains("calendar_get_event") })
                XCTAssertTrue(model.composerDrafts.home.text.contains("dana@acme.example"), model.composerDrafts.home.text)
                model.composerDrafts.home.text = ""
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Calendar")))
                await host.settle(until: { host.accessibilityElements().contains { $0.label.hasPrefix(ops) } })

                XCTAssertTrue(pressSegment(L10n.string("Calendar day"), in: host.hosting))
                await host.settle(until: { host.accessibilityElements().contains {
                    $0.role == "AXRadioButton" && $0.label == L10n.string("Calendar day") && $0.value == "1"
                } })
                host.settle(passes: 10)
                try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "day-\(name)"))

                // The window shows its tasks: the calendar stays on and reads nothing more.
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Tasks")))
                host.settle(passes: 6)
                try await Task.sleep(for: .milliseconds(200))
                let hidden = reads()
                try await Task.sleep(for: .milliseconds(450))
                XCTAssertEqual(reads(), hidden, "No screen shows the calendar, so nothing is read")
                XCTAssertTrue(model.calendar.isEnabled)
                host.close()
            }
        }
    }

    /// A segment of a segmented control, which carries its word as a title rather than a label.
    private func pressSegment(_ title: String, in root: NSView) -> Bool {
        WindowlessRender.withAccessibilityTree {
            func visit(_ node: AnyObject) -> AnyObject? {
                for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                    if child.accessibilityRole?() == .radioButton,
                       (child.accessibilityTitle?() ?? nil) == title || (child.accessibilityLabel?() ?? nil) == title { return child }
                    if let found = visit(child) { return found }
                }
                return nil
            }
            // A segment chooses itself when pressed but answers that it did not.
            guard let segment = visit(root) else { return false }
            _ = segment.accessibilityPerformPress?()
            return true
        }
    }

    /// Two Google accounts, a work one with a team calendar, and the Mac's iCloud calendars, this week.
    private func fixture() -> [FakeCalendarService] {
        let calendar = Calendar.autoupdatingCurrent
        let week = calendar.dateInterval(of: .weekOfYear, for: Date())!
        func day(_ index: Int) -> DateInterval {
            let start = calendar.date(byAdding: .day, value: index, to: week.start)!
            return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
        }
        let work = FakeCalendarService(account: CalendarAccount(id: UUID(), provider: .google, address: "dana@acme.example",
                                                                connectorSlug: "calendar"))
        let workCalendar = work.add("dana@acme.example", isPrimary: true, color: "#4A7BD0")
        let team = work.add(text("팀 일정", "Team"), color: "#3E9B6F")
        work.add(event: text("팀 주간 회의", "Weekly team meeting"), hour: 14, to: team, day: day(1))
        let ir = CalendarPerson(name: text("파트너사 IR 담당", "the partner's IR team"), email: "ir@partner.example")
        work.add(event: text("투자사 통화", "Investor call"), hour: 16.5, minutes: 30, to: workCalendar, day: day(1),
                 response: .needsAction, notes: text("3분기 실적과 다음 라운드 일정 논의", "Q3 numbers and the next round's timing"),
                 organizer: ir, attendees: [ir, CalendarPerson(email: "dana@acme.example", response: .needsAction),
                                            CalendarPerson(email: "lee@acme.example"), CalendarPerson(email: "kim@partner.example")],
                 conference: URL(string: "https://meet.google.com/abc-defg-hij"))
        work.add(event: text("운영 회의", "Ops meeting"), hour: 11, to: workCalendar, day: day(2))
        work.add(event: text("디자인 검토", "Design review"), hour: 14, to: team, day: day(2), response: .needsAction)
        work.add(event: text("파트너 미팅", "Partner meeting"), hour: 13, to: workCalendar, day: day(3))
        work.add(event: text("IR 자료 검토", "Review the IR deck"), hour: 11, to: workCalendar, day: day(4))
        work.add(event: text("채용 동기화", "Hiring sync"), hour: 11.5, to: team, day: day(4))
        work.add(event: "1:1", hour: 15, minutes: 45, to: team, day: day(4))
        work.add(event: text("주간 회고", "Weekly retro"), hour: 16, to: team, day: day(5))
        work.add(event: text("0.12 출시 목표", "0.12 release target"), hour: 0, to: workCalendar, day: day(5), allDay: true)

        let personal = FakeCalendarService(account: CalendarAccount(id: UUID(), provider: .google, address: "dana.park@example.com",
                                                                    connectorSlug: "calendar"))
        let own = personal.add("dana.park@example.com", isPrimary: true, color: "#C8643B")
        personal.add(event: text("저녁 약속", "Dinner"), hour: 19, minutes: 120, to: own, day: day(2))

        let mac = FakeCalendarService(account: CalendarAccount(id: UUID(), provider: .apple, connectorSlug: "apple_calendar"))
        let family = mac.add(text("가족", "Family"), source: "iCloud", color: "#8E5CC9")
        let holidays = mac.add(text("대한민국 공휴일", "Holidays"), source: "iCloud", color: "#8A8A8A")
        mac.add(event: text("가족 점심", "Family lunch"), hour: 12, minutes: 120, to: family, day: day(6))
        mac.add(event: text("개천절", "Holiday"), hour: 0, to: holidays, day: day(3), allDay: true)
        return [work, personal, mac]
    }

    /// Yardlet's schedules, made two weeks ago so the whole week shows their runs.
    private func schedules() -> [ScheduledTask] {
        let made = Date().addingTimeInterval(-14 * 86_400)
        let destination = ScheduleDestination(harness: .claudeCode)
        return [
            ScheduledTask(name: text("홍보 확인 · 오전", "Promotion check · morning"), prompt: "-",
                          trigger: .daily(ScheduleTime(hour: 10, minute: 0)), destination: destination, createdAt: made),
            ScheduledTask(name: text("설계 검토 매일 평가", "Design review daily check"), prompt: "-",
                          trigger: .weekly(days: ScheduleWeekday.weekdays, time: ScheduleTime(hour: 17, minute: 40)),
                          destination: destination, createdAt: made),
            ScheduledTask(name: text("홍보 확인 · 밤", "Promotion check · night"), prompt: "-",
                          trigger: .daily(ScheduleTime(hour: 22, minute: 0)), destination: destination, createdAt: made),
        ]
    }

    private func makeWindowModel() throws -> AppModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "yardlet-calendar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("CalendarShell")))
        let model = AppModel(
            store: SessionStore(sessions: [], repository: InMemorySessionRepository(sessions: [])),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue."),
            preferences: defaults,
            codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults),
            codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: defaults),
            codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults, keyPrefix: "history."),
            transcriptRepository: FileTranscriptRepository(directoryURL: root.appending(path: "transcripts")),
            scheduleRepository: InMemoryScheduledTaskRepository(snapshot: ScheduleSnapshot(schedules: schedules())),
            sessionTitleResolver: { _ in nil }, sessionTitleRetryCount: 0, restoresIndexOnLaunch: false)
        addTeardownBlock { await model.shutdown() }
        return model
    }
}
