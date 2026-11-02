import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The mailbox drawn in an unshown window with fixture accounts: the Mail word, the merged list, an
/// opened thread with an agent's draft, the accounts' folders and labels, and spam. Opening a thread
/// marks it read on its service; spam offers no agent.
@MainActor
final class MailboxRenderingTests: XCTestCase {
    func testTheMailboxListsEveryInboxAndOpensAThread() async throws {
        let model = try makeWindowModel()
        let fixture = MailFixture()
        let directory = try WindowlessRender.directory("mailbox-qa")
        for size in [NSSize(width: 1280, height: 800), NSSize(width: 920, height: 680)] {
            for appearance in WindowlessRender.Appearance.allCases {
                let transports = fixture.transports()
                model.mailbox.setEnabled(true)
                model.mailbox.setAccounts(transports.map { ($0.account, $0) })
                await model.mailbox.refresh()
                let host = WindowlessRender.Host(MainWindow(model: model)
                    .environment(\.colorScheme, appearance.colorScheme)
                    .frame(width: size.width, height: size.height), size: size, appearance: appearance)
                defer { host.close() }
                host.settle()
                let name = "\(Int(size.width))-\(appearance.suffix).png"

                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Mail")))
                let quoteRow = { host.accessibilityElements().first { $0.label.hasPrefix(MailFixture.haneul.displayName) } }
                await host.settle(until: { quoteRow() != nil })
                host.settle(passes: 6)
                try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "list-\(name)"))

                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: try XCTUnwrap(quoteRow()).label))
                await host.settle(until: { host.accessibilityElements().contains { $0.label == L10n.string("Ask an agent") } })
                host.settle(passes: 6)
                let gmail = try XCTUnwrap(transports.first)
                // Opening an unread thread marks it read on its service, and its row with it.
                try await waitUntil { await gmail.changes.contains { $0.0 == MailFixture.quoteThread && $0.1 == .read(true) } }
                await host.settle(until: { quoteRow()?.value.contains(L10n.string("Unread")) == false })
                host.settle(passes: 4)
                try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "thread-\(name)"))

                // The accounts and their folders, in the list's place.
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Mailboxes")))
                let labelsRow = { host.accessibilityElements().contains { $0.label == "거래처" } }
                await host.settle(until: labelsRow)
                host.settle(passes: 6)
                try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "folders-\(name)"))

                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Mail spam")))
                let spamRow = { host.accessibilityElements().first { $0.label == "보안 센터" } }
                await host.settle(until: { spamRow() != nil })
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: "보안 센터"))
                await host.settle(until: { host.accessibilityElements().contains { $0.label == L10n.string("Not spam") } })
                host.settle(passes: 6)
                XCTAssertFalse(host.accessibilityElements().contains { $0.label == L10n.string("Ask an agent") },
                               "Spam is not handed to an agent")
                try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "spam-\(name)"))
                host.close()
            }
        }
    }

    private func makeWindowModel() throws -> AppModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "yardlet-mailbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("MailboxShell")))
        let model = AppModel(
            store: SessionStore(sessions: [], repository: InMemorySessionRepository(sessions: [])),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue."),
            preferences: defaults,
            codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults),
            codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: defaults),
            codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults, keyPrefix: "history."),
            transcriptRepository: FileTranscriptRepository(directoryURL: root.appending(path: "transcripts")),
            sessionTitleResolver: { _ in nil }, sessionTitleRetryCount: 0, restoresIndexOnLaunch: false,
            browserClient: { nil })
        addTeardownBlock { await model.shutdown() }
        return model
    }
}

/// Two fictional accounts and their inboxes, dated from now so the list shows today's times.
struct MailFixture {
    static let work = MailAccount(id: UUID(uuidString: "6D3B0A6E-1F7A-4C52-9C55-6A2B8F0D1E01")!,
                                  address: "dana@acme.example", provider: .gmail)
    static let personal = MailAccount(id: UUID(uuidString: "6D3B0A6E-1F7A-4C52-9C55-6A2B8F0D1E02")!,
                                      address: "dana.park@example.com", provider: .gmail)
    static let me = MailAddress(name: "Dana Park", address: "dana@acme.example")
    static let haneul = MailAddress(name: "김하늘", address: "haneul@vendor.example")
    static let quoteThread = "thread-quote"

    func transports() -> [FixtureMailTransport] {
        let spam = [
            single(Self.work.id, "thread-spam-1", from: MailAddress(name: "보안 센터", address: "security@acme-verify.example"),
                   date: at(daysAgo: 0, hour: 11, minute: 3), subject: "[긴급] 24시간 안에 계정을 확인하세요",
                   text: "아래 링크에서 계정을 확인하지 않으면 메일 사용이 중지됩니다.", isUnread: true),
            single(Self.work.id, "thread-spam-2", from: MailAddress(name: "Lucky Draw", address: "win@prize.example"),
                   date: at(daysAgo: 2, hour: 4, minute: 50), subject: "You won a $500 gift card",
                   text: "Claim your prize before Friday.", isUnread: true),
        ]
        let trash = [single(Self.work.id, "thread-trash-1", from: MailAddress(name: "Weekly Swift", address: "hello@weekly.example"),
                            date: at(daysAgo: 12, hour: 7, minute: 0), subject: "Issue 411: Faster builds",
                            text: "This week: build times and the new linker.")]
        return [FixtureMailTransport(account: Self.work, threads: workThreads(), spam: spam, trash: trash,
                                     labels: [("L1", "거래처"), ("L2", "거래처/견적"), ("L3", "채용")]),
                FixtureMailTransport(account: Self.personal, threads: personalThreads(),
                                     labels: [("P1", "여행"), ("P2", "영수증")])]
    }

    func at(daysAgo: Int, hour: Int, minute: Int) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: .now)!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    private func workThreads() -> [MailThread] {
        let account = Self.work.id
        let messages = [
            message("q1", from: Self.haneul, to: [Self.me], date: at(daysAgo: 6, hour: 10, minute: 5),
                    subject: "견적서 회신 부탁드립니다",
                    text: "안녕하세요, 김하늘입니다.\n\n지난 미팅에서 말씀드린 연간 유지보수 견적서를 보내 드립니다. 검토해 보시고 궁금한 점이 있으면 알려 주세요."),
            message("q2", from: Self.me, to: [Self.haneul], date: at(daysAgo: 5, hour: 16, minute: 40),
                    subject: "Re: 견적서 회신 부탁드립니다",
                    text: "보내 주셔서 감사합니다. 내부 검토 뒤에 다시 연락드리겠습니다."),
            message("q3", from: Self.haneul, to: [Self.me], cc: [MailAddress(name: "이도윤", address: "doyun@vendor.example")],
                    date: at(daysAgo: 0, hour: 14, minute: 14), subject: "Re: 견적서 회신 부탁드립니다",
                    text: "안녕하세요.\n\n지난주 말씀드린 견적서의 수정본을 첨부합니다. 유지보수 범위에 모니터링을 더했고, 연간 금액은 그대로입니다.\n\n금요일까지 회신 주시면 다음 달 1일부터 시작할 수 있도록 일정을 맞추겠습니다.\n\n감사합니다.\n김하늘 드림",
                    attachments: [MailAttachment(id: "a1", name: "견적서_v3.pdf", size: 186_400, mimeType: "application/pdf")],
                    isUnread: true),
            message("q4", from: Self.me, to: [Self.haneul], date: at(daysAgo: 0, hour: 14, minute: 20),
                    subject: "Re: 견적서 회신 부탁드립니다",
                    text: "김하늘 님, 수정본 잘 받았습니다. 모니터링 범위를 더해 주셔서 감사합니다.\n내부 검토를 거쳐 목요일까지 회신드리겠습니다.",
                    isDraft: true),
        ]
        return [
            thread(account, Self.quoteThread, messages, isUnread: true, hasDraft: true),
            single(account, "thread-ci", from: MailAddress(name: "GitHub", address: "notifications@github.example"),
                   date: at(daysAgo: 0, hour: 13, minute: 2), subject: "[acme/web] CI passed for #312",
                   text: "All checks have passed on the pull request \"Speed up the dashboard query\".", isUnread: true),
            single(account, "thread-invite", from: MailAddress(name: "Jordan Lee", address: "jordan@acme.example"),
                   date: at(daysAgo: 1, hour: 18, minute: 30), subject: "Design review moved to Thursday",
                   text: "Moving the design review to Thursday 3pm so Mina can join. Same room."),
            single(account, "thread-report", from: MailAddress(name: "박서준", address: "seojun@acme.example"),
                   date: at(daysAgo: 3, hour: 9, minute: 12), subject: "10월 운영 지표 정리",
                   text: "10월 운영 지표를 정리해 공유드립니다. 신규 가입이 지난달보다 12% 늘었습니다.",
                   attachments: [MailAttachment(id: "a2", name: "10월_지표.xlsx", size: 42_100, mimeType: "application/vnd.ms-excel")]),
        ]
    }

    private func personalThreads() -> [MailThread] {
        let account = Self.personal.id
        return [
            single(account, "thread-bank", from: MailAddress(name: "예시은행", address: "notice@bank.example"),
                   date: at(daysAgo: 0, hour: 9, minute: 40), subject: "11월 카드 이용 대금 안내",
                   text: "11월 결제 예정 금액을 안내해 드립니다. 자세한 내역은 앱에서 확인하세요.", isUnread: true),
            single(account, "thread-trip", from: MailAddress(name: "Air Example", address: "booking@air.example"),
                   date: at(daysAgo: 2, hour: 20, minute: 15), subject: "Your trip to Jeju is confirmed",
                   text: "Booking reference K7Q2LM. Check in opens 24 hours before departure."),
            single(account, "thread-news", from: MailAddress(name: "Weekly Swift", address: "hello@weekly.example"),
                   date: at(daysAgo: 9, hour: 7, minute: 0), subject: "Issue 412: Observation in practice",
                   text: "This week: making observation cheap in long lists, and what changed in the toolchain."),
        ]
    }

    func message(_ id: String, from: MailAddress, to: [MailAddress], cc: [MailAddress] = [], date: Date,
                         subject: String, text: String, attachments: [MailAttachment] = [],
                         isDraft: Bool = false, isUnread: Bool = false) -> MailMessage {
        MailMessage(id: id, from: from, to: to, cc: cc, date: date, subject: subject,
                    snippet: String(text.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(90)),
                    text: text, html: nil, attachments: attachments, isDraft: isDraft, isUnread: isUnread)
    }

    func thread(_ account: UUID, _ id: String, _ messages: [MailMessage], isUnread: Bool = false,
                        hasDraft: Bool = false) -> MailThread {
        let sent = messages.filter { !$0.isDraft }
        let last = sent.last ?? messages[messages.count - 1]
        var senders: [MailAddress] = []
        for message in sent.reversed() where !senders.contains(message.from) { senders.append(message.from) }
        let summary = MailThreadSummary(
            id: MailThreadKey(accountID: account, threadID: id), subject: messages[0].subject, senders: senders,
            snippet: last.snippet, date: last.date, messageCount: sent.count, isUnread: isUnread, isStarred: false,
            hasAttachments: messages.contains { !$0.attachments.isEmpty }, hasDraft: hasDraft)
        return MailThread(summary: summary, messages: messages,
                          webURL: URL(string: "https://mail.example/thread/\(id)"))
    }

    func single(_ account: UUID, _ id: String, from: MailAddress, date: Date, subject: String, text: String,
                        attachments: [MailAttachment] = [], isUnread: Bool = false) -> MailThread {
        thread(account, id, [message(id + "-1", from: from, to: [Self.me], date: date, subject: subject, text: text,
                                     attachments: attachments, isUnread: isUnread)], isUnread: isUnread)
    }
}

/// A service that answers from fixture threads and remembers what the mailbox asked it to change.
actor FixtureMailTransport: MailAccountTransport {
    nonisolated let account: MailAccount
    private var threads: [String: MailThread]
    /// Where each thread is: `INBOX` unless placed in `SPAM`, `TRASH` or archived (`ALL`).
    private var places: [String: String] = [:]
    private let labels: [(id: String, path: String)]
    private(set) var changes: [(String, MailThreadChange)] = []
    private var history = 0
    private var arrived: [String] = []

    init(account: MailAccount, threads: [MailThread], spam: [MailThread] = [], trash: [MailThread] = [],
         labels: [(id: String, path: String)] = []) {
        self.account = account
        self.threads = Dictionary(uniqueKeysWithValues: (threads + spam + trash).map { ($0.summary.id.threadID, $0) })
        for thread in spam { places[thread.summary.id.threadID] = "SPAM" }
        for thread in trash { places[thread.summary.id.threadID] = "TRASH" }
        self.labels = labels
    }

    func folders() async throws -> [MailFolder] {
        let summaries = threads.values.map(\.summary)
        func unread(in place: String) -> Int {
            summaries.filter { (places[$0.id.threadID] ?? "INBOX") == place && $0.isUnread }.count
        }
        var folders = GmailMailTransport.systemFolders
        for index in folders.indices {
            switch folders[index].id {
            case "INBOX": folders[index].unreadCount = unread(in: "INBOX")
            case "SPAM": folders[index].unreadCount = unread(in: "SPAM")
            case "DRAFT": folders[index].unreadCount = summaries.filter(\.hasDraft).count
            default: break
            }
        }
        return folders + labels.map { label in
            let parts = label.path.split(separator: "/")
            return MailFolder(id: label.id, name: String(parts.last ?? ""), role: .label, depth: parts.count - 1)
        }
    }

    func inbox(pageToken: String?) async throws -> MailPage {
        page { (places[$0.id.threadID] ?? "INBOX") == "INBOX" }
    }

    func list(_ folder: MailFolder, pageToken: String?) async throws -> MailPage {
        switch folder.role {
        case .inbox: try await inbox(pageToken: pageToken)
        case .spam, .trash: page { places[$0.id.threadID] == folder.id }
        case .starred: page(\.isStarred)
        case .drafts: page(\.hasDraft)
        case .archive: page { !["SPAM", "TRASH"].contains(places[$0.id.threadID] ?? "INBOX") }
        case .sent, .label: page { _ in false }
        }
    }

    private func page(_ include: (MailThreadSummary) -> Bool) -> MailPage {
        MailPage(threads: threads.values.map(\.summary).filter(include).sorted { $0.date > $1.date }, nextPageToken: nil)
    }

    func search(_ query: String, pageToken: String?) async throws -> MailPage {
        let words = query.lowercased().split(separator: " ")
        let found = threads.values.filter { thread in
            let text = ([thread.summary.subject] + thread.messages.map(\.text)).joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        return MailPage(threads: found.map(\.summary).sorted { $0.date > $1.date }, nextPageToken: nil)
    }

    func thread(_ threadID: String) async throws -> MailThread {
        guard let thread = threads[threadID] else { throw MailFailure(kind: .unavailable, message: "No such thread") }
        return thread
    }

    /// A message that comes into the inbox: the next change says it arrived.
    func deliver(_ thread: MailThread) {
        threads[thread.summary.id.threadID] = thread
        history += 1
        arrived.append(thread.summary.id.threadID)
    }

    func changeCursor() async throws -> String { String(history) }

    /// Drafts saved, by ID.
    private(set) var drafts: [String: MailComposition] = [:]
    private(set) var sent: [String] = []

    func saveDraft(_ composition: MailComposition) async throws -> String {
        let id = composition.draftID ?? "draft-\(drafts.count + 1)"
        drafts[id] = composition
        return id
    }

    func sendDraft(_ draftID: String) async throws {
        drafts[draftID] = nil
        sent.append(draftID)
    }

    func discardDraft(_ draftID: String) async throws { drafts[draftID] = nil }

    func draftID(forMessage messageID: String) async throws -> String { "draft-of-\(messageID)" }

    func changes(since cursor: String) async throws -> MailChanges {
        let changed = cursor != String(history)
        defer { arrived = [] }
        return MailChanges(cursor: String(history), changed: changed, arrivedThreadIDs: changed ? arrived : [])
    }

    func change(_ threadID: String, _ change: MailThreadChange) async throws {
        changes.append((threadID, change))
        guard var thread = threads[threadID] else { return }
        switch change {
        case let .read(read): thread.summary.isUnread = !read
        case let .starred(starred): thread.summary.isStarred = starred
        case .archived: places[threadID] = "ALL"
        case .notSpam, .untrash: places[threadID] = nil
        }
        threads[threadID] = thread
    }
}
