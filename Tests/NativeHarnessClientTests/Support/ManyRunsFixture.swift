import Foundation
@testable import NativeHarnessClient

/// A heavy week of Yardlet schedules, shaped like a person's who keeps agents at work all day: one every hour, one
/// every three hours and one every six, nearly fifty daily or weekday ones bunched around 9-10 and 18-21, weekly ones on
/// Monday, and one-off runs over the coming days. A week of it is about 600 runs, some 75 a day. Names are made up.
enum ManyRunsFixture {
    /// The one-off runs, as (days after today, hour, minute, name); today's are in the evening.
    static func onceRuns(_ words: (String, String) -> String) -> [(day: Int, hour: Int, minute: Int, name: String)] {
        [(0, 19, 26, words("측정 72h · 안경 릴스", "Measure 72h · glasses reel")),
         (0, 20, 16, words("측정 d7 · 단일 이미지", "Measure d7 · single image")),
         (1, 8, 52, words("아침 점검 첫 실행 확인", "Check the first morning run")),
         (1, 9, 20, words("측정 d7 · 방콕 글", "Measure d7 · Bangkok post")),
         (1, 9, 25, words("측정 h72 · 성과 글", "Measure h72 · results post")),
         (1, 10, 30, words("청구 후속 점검", "Billing follow-up")),
         (1, 14, 0, words("운영 확인 #2627", "Ops check #2627")),
         (1, 21, 18, words("측정 72h · 월렛 릴스", "Measure 72h · wallet reel")),
         (2, 9, 18, words("측정 h72 · 통화 글", "Measure h72 · currency post")),
         (2, 10, 0, words("백업 스냅숏 정리", "Tidy backup snapshots")),
         (2, 19, 55, words("겨울 캐러셀 게시", "Post the winter carousel")),
         (3, 10, 3, words("알림 문구 점검", "Check the notice copy")),
         (4, 10, 30, words("블로그 32번 게시", "Publish blog post 32"))]
    }

    /// - Parameters:
    ///   - today: the day the one-off runs are counted from.
    ///   - made: when every schedule was made, before the week shown.
    static func schedules(today: Date, made: Date, words: (String, String) -> String,
                          calendar: Calendar = .current) -> [ScheduledTask] {
        var list: [ScheduledTask] = []
        func add(_ name: String, _ trigger: ScheduleTrigger) {
            list.append(ScheduledTask(name: name, prompt: "-", trigger: trigger,
                                      destination: ScheduleDestination(harness: .claudeCode), createdAt: made))
        }
        func at(_ hour: Int, _ minute: Int = 0) -> ScheduleTime { ScheduleTime(hour: hour, minute: minute) }
        func clock(_ hour: Int, _ minute: Int) -> String { String(format: "%02d:%02d", hour, minute) }

        let anchor = calendar.startOfDay(for: made)
        add(words("소셜 답글 확인 (매시)", "Social replies (hourly)"), .interval(hours: 1, anchor: anchor.addingTimeInterval(20 * 60), days: []))
        add(words("공개 이슈 응대", "Public issues"), .interval(hours: 3, anchor: anchor, days: []))
        add(words("끝난 세션 정리", "Tidy finished sessions"), .interval(hours: 6, anchor: anchor, days: []))

        let kinds = [("DM 점검", "DM check"), ("문의 메일 확인", "Support inbox"), ("성장 점검", "Growth check"),
                     ("게시", "Post"), ("홍보 채널 확인", "Promo channels"), ("저장소 PR 확인", "Repository PRs"),
                     ("활동 점검", "Activity check"), ("게시 측정", "Post metrics")]
        let daily: [(Int, Int)] = [(7, 0), (7, 30), (8, 30), (8, 30), (8, 57), (9, 0), (9, 0), (9, 30), (9, 30), (9, 30),
                                   (9, 43), (10, 0), (10, 0), (10, 0), (11, 0), (11, 40), (12, 0), (12, 6), (13, 0), (14, 0),
                                   (15, 0), (16, 0), (17, 0), (17, 40), (18, 0), (18, 0), (18, 30), (19, 0), (19, 30), (20, 0),
                                   (20, 30), (21, 0), (21, 0), (21, 30), (22, 0), (22, 37), (23, 0), (23, 30), (6, 30), (7, 15),
                                   (8, 0), (10, 30), (11, 20), (13, 30), (15, 30), (16, 30), (19, 15), (20, 45)]
        for (index, time) in daily.enumerated() {
            let kind = kinds[index % kinds.count]
            let name = words(kind.0, kind.1) + " " + clock(time.0, time.1)
            add(name, index % 5 == 1 ? .weekly(days: ScheduleWeekday.weekdays, time: at(time.0, time.1)) : .daily(at(time.0, time.1)))
        }
        for (hour, minute, ko, en) in [(6, 0, "블로그 소재 모으기", "Gather blog topics"), (9, 0, "주간 기억 정리", "Weekly memory"),
                                       (9, 0, "주간 지표 정리", "Weekly metrics"), (10, 0, "상류 점검", "Upstream check"),
                                       (10, 0, "파일 주간 점검", "Weekly file check")] {
            add(words(ko, en), .weekly(days: [.monday], time: at(hour, minute)))
        }
        add(words("공모전 찾기", "Find contests"), .weekly(days: [.monday, .thursday], time: at(8)))
        add(words("주말 활동 점검", "Weekend activity"), .weekly(days: [.saturday, .sunday], time: at(12)))

        let start = calendar.startOfDay(for: today)
        for run in onceRuns(words) {
            let day = calendar.date(byAdding: .day, value: run.day, to: start)!
            add(run.name, .once(calendar.date(bySettingHour: run.hour, minute: run.minute, second: 0, of: day)!))
        }
        return list
    }

    /// Each schedule with what it ran today before `now`, as the desk reads them: one started run at each slot.
    static func ranToday(_ schedules: [ScheduledTask], now: Date, calendar: Calendar = .current) -> [(ScheduledTask, Date)] {
        let start = calendar.startOfDay(for: now)
        return schedules.compactMap { schedule in
            var schedule = schedule
            var cursor = start.addingTimeInterval(-0.001)
            var runs: [ScheduledTaskRun] = []
            while let slot = schedule.trigger.nextSlot(after: cursor, calendar: calendar), slot <= now {
                runs.append(ScheduledTaskRun(slot: slot, at: slot, trigger: .scheduled, outcome: .started))
                cursor = slot
            }
            schedule.state.runs = runs
            return schedule.trigger.nextSlot(after: now, calendar: calendar).map { (schedule, $0) }
        }
    }
}
