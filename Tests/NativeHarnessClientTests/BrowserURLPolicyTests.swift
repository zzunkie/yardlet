import AppKit
import XCTest
@testable import NativeHarnessClient

final class BrowserURLPolicyTests: XCTestCase {
    func testOnlyTheAllowedSchemesPass() {
        for url in ["https://example.com", "HTTP://127.0.0.1:3000/", "file:///tmp/a.html", "about:blank", "data:text/html,hi"] {
            XCTAssertTrue(BrowserURLPolicy.isAllowed(url), url)
        }
        for url in ["javascript:alert(1)", "chrome://version", "devtools://devtools", "x-app://open", "blob:https://a.test/1",
                    "mailto:a@b.test", "not a url", ""] {
            XCTAssertFalse(BrowserURLPolicy.isAllowed(url), url)
        }
    }

    func testAddressInputResolves() throws {
        XCTAssertEqual(try BrowserURLPolicy.resolve("example.com/path"), "https://example.com/path")
        XCTAssertEqual(try BrowserURLPolicy.resolve("localhost:3000"), "http://localhost:3000")
        XCTAssertEqual(try BrowserURLPolicy.resolve("127.0.0.1:8080/x"), "http://127.0.0.1:8080/x")
        XCTAssertEqual(try BrowserURLPolicy.resolve("  http://example.com  "), "http://example.com")
        XCTAssertEqual(try BrowserURLPolicy.resolve("/tmp/page.html"), "file:///tmp/page.html")
        XCTAssertEqual(try BrowserURLPolicy.resolve("about:blank"), "about:blank")
        XCTAssertThrowsError(try BrowserURLPolicy.resolve("javascript:alert(1)")) {
            XCTAssertEqual($0 as? BrowserURLPolicy.AddressError, .blockedScheme("javascript"))
        }
        XCTAssertThrowsError(try BrowserURLPolicy.resolve("two words"))
        XCTAssertThrowsError(try BrowserURLPolicy.resolve(" "))
    }

    func testAddressFieldSearchesWhatIsNoAddress() throws {
        let search = { "https://www.google.com/search?q=" + $0 }
        for (typed, expected) in [("two words", search("two%20words")), ("yardlet", search("yardlet")), ("1.5", search("1.5")), ("c++ & go", search("c%2B%2B%20%26%20go")),
                                  ("날씨 서울", search("%EB%82%A0%EC%94%A8%20%EC%84%9C%EC%9A%B8")), ("?example.com", search("example.com")),
                                  ("example.com/path", "https://example.com/path"), ("localhost", "http://localhost"),
                                  ("localhost:3000", "http://localhost:3000"), ("192.168.0.10", "https://192.168.0.10"),
                                  ("네이버.kr", "https://네이버.kr"), ("https://a.test/x y", "https://a.test/x y"), ("~/a.html", try BrowserURLPolicy.resolve("~/a.html"))] {
            XCTAssertEqual(try BrowserURLPolicy.addressFieldURL(typed), expected, typed)
        }
        XCTAssertThrowsError(try BrowserURLPolicy.addressFieldURL("javascript:alert(1)"))
        XCTAssertThrowsError(try BrowserURLPolicy.addressFieldURL("?"))
    }
}

final class BrowserKeyCodeTests: XCTestCase {
    func testPhysicalKeysMapToChromiumKeyCodes() {
        XCTAssertEqual(BrowserKeyCodes.windowsKeyCode(forMacKeyCode: 0x00), 0x41)  // A
        XCTAssertEqual(BrowserKeyCodes.windowsKeyCode(forMacKeyCode: 0x1D), 0x30)  // 0
        XCTAssertEqual(BrowserKeyCodes.windowsKeyCode(forMacKeyCode: 0x2F), 0xBE)  // period
        XCTAssertEqual(BrowserKeyCodes.windowsKeyCode(forMacKeyCode: 0x24), 0x0D)  // Return
        XCTAssertEqual(BrowserKeyCodes.windowsKeyCode(forMacKeyCode: 0x7E), 0x26)  // Up
        XCTAssertEqual(BrowserKeyCodes.windowsKeyCode(forMacKeyCode: 0x7A), 0x70)  // F1
        XCTAssertEqual(BrowserKeyCodes.windowsKeyCode(forMacKeyCode: 0x5A), 0x83)  // F20
        XCTAssertEqual(BrowserKeyCodes.windowsKeyCode(forMacKeyCode: 0x38), 0x10)  // Shift
        XCTAssertEqual(BrowserKeyCodes.windowsKeyCode(forMacKeyCode: 0x37), 0x5B)  // Command
        XCTAssertEqual(BrowserKeyCodes.windowsKeyCode(forMacKeyCode: 0x52), 0x60)  // Keypad 0
        XCTAssertEqual(BrowserKeyCodes.windowsKeyCode(forMacKeyCode: 0x68), 0x15)  // Han/Yeong (Kana)
        XCTAssertEqual(BrowserKeyCodes.inputMethodProcessKey, 229)
        XCTAssertEqual(Set(BrowserKeyCodes.windowsKeyCodes.keys).count, BrowserKeyCodes.windowsKeyCodes.count)
    }

    @MainActor
    func testModifierKeysBecomeKeyPressesAndReleases() throws {
        let view = BrowserHostView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        var sent: [BrowserHostCommand] = []
        view.tabID = 1
        view.sendCommand = { sent.append($0) }
        for (down, flags) in [(true, CGEventFlags.maskShift), (false, [])] {
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0x3C, keyDown: down))
            event.type = .flagsChanged
            event.flags = flags
            view.flagsChanged(with: try XCTUnwrap(NSEvent(cgEvent: event)))
        }
        guard sent.count == 2, case .key(_, let press) = sent[0], case .key(_, let release) = sent[1] else {
            return XCTFail("expected two key commands, got \(sent)")
        }
        XCTAssertEqual(press.kind, .rawDown)
        XCTAssertEqual(release.kind, .up)
        XCTAssertEqual(press.windowsKeyCode, 0x10)
        XCTAssertTrue(press.modifiers.contains(.isRight))
    }
}

/// The address field's suggestions rank as Chrome's omnibox does (docs/BROWSER_HOST.md, "Address suggestions").
@MainActor
final class BrowserAddressSuggestionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func history() -> BrowserAddressHistory {
        var clock = now.addingTimeInterval(-86_400)
        let history = BrowserAddressHistory(file: nil) { clock }
        for typed in [true, true, true, false, false, false] { history.noteVisit("https://github.com/", typed: typed) }
        history.noteTitle("GitHub", of: "https://github.com/")
        for _ in 0..<5 { history.noteVisit("https://github.com/octocat/hello-world", typed: false) }
        history.noteTitle("octocat/hello-world: Hello World", of: "https://github.com/octocat/hello-world")
        history.noteVisit("https://www.google.com/search?q=github%20copilot", typed: false)
        clock = now.addingTimeInterval(-10 * 86_400)
        history.noteVisit("https://user:secret@gist.github.com/x", typed: false)
        return history
    }

    private func rank(_ input: String, inline: Bool = true, remote: BrowserSearchSuggestions? = nil) -> [BrowserAddressSuggestion] {
        let history = history()
        return BrowserAddressRanking.suggestions(for: input, pages: Array(history.pages.values), searches: Array(history.searches.values),
                                                 remote: remote, allowsInline: inline, now: now)
    }

    func testTheFirstRowCompletesATypedHostThenSearchesThenPages() throws {
        let remote = try XCTUnwrap(BrowserSearchSuggestions.parse(Data("""
            )]}'
            ["gi",["gi","github","gitlab","https://github.com/"],["","","","GitHub"],[],{"google:suggesttype":["QUERY","QUERY","QUERY","NAVIGATION"],"google:suggestrelevance":[1300,600,560,800]}]
            """.utf8)))
        let rows = rank("gi", remote: remote)
        XCTAssertEqual(rows.map(\.fill), ["github.com", "gi", "github copilot", "github", "gitlab", "github.com/octocat/hello-world"])
        XCTAssertEqual(rows[0].destination, "https://github.com/")
        XCTAssertEqual(rows[0].inlineCompletion, "thub.com", "a host typed before completes inline")
        XCTAssertEqual(rows[0].title, "GitHub")
        XCTAssertTrue(rows[1].isVerbatim)
        XCTAssertTrue(rows[2].isFromHistory, "a past search")
        XCTAssertFalse(rows[3].isFromHistory)
        XCTAssertEqual(rows.dropFirst().map(\.inlineCompletion), Array(repeating: "", count: 5))
        XCTAssertFalse(rows.contains { $0.destination.contains("gist") }, "a page seen once 10 days ago is not suggested")

        let deleted = rank("gi", inline: false, remote: remote)
        XCTAssertEqual(deleted.map(\.fill), ["gi", "github copilot", "github", "gitlab", "github.com", "github.com/octocat/hello-world"],
                       "right after deleting, what was typed comes first")

        let path = rank("github.com/o")
        XCTAssertEqual(path.map(\.destination), ["https://github.com/o", "https://github.com/octocat/hello-world"],
                       "a page never typed does not complete an address")
        XCTAssertTrue(path[0].isVerbatim)
    }

    /// A new tab's start page offers one page per site, the site's most visited, the sites visited most first
    /// (docs/BROWSER_HOST.md, section 3, "Start page").
    func testTheStartPageOffersEachSiteVisitedMostByItsMostVisitedPage() {
        let history = history()
        history.noteVisit("https://www.github.com/settings", typed: false)
        history.noteVisit("http://localhost:3000/", typed: false)
        history.noteVisit("file:///tmp/report.html", typed: false)
        XCTAssertEqual(history.topSites(limit: 8).map(\.url),
                       ["https://github.com/", "http://localhost:3000/", "https://gist.github.com/x"],
                       "www. is the same site, a port is a site of its own, a file is no site")
        XCTAssertEqual(history.topSites(limit: 1).map(\.url), ["https://github.com/"])
        history.noteIcon(Data([1]), of: "https://github.com/octocat")
        history.noteIcon(Data(), of: "https://github.com/plain")
        XCTAssertEqual(history.icon(of: "https://www.github.com/"), Data([1]), "a page no tab showed has its site's icon")
        XCTAssertNil(history.icon(of: "https://github.com/plain"), "a page without an icon has none")
        history.remove(site: "https://github.com/")
        XCTAssertFalse(history.pages.keys.contains { $0.contains("github.com/") && !$0.contains("gist") },
                       "removing a site removes each of its pages")
    }

    func testHistoryScoresAsChromium() {
        XCTAssertEqual([0, 4, 5, 14, 31, 90, 91, 365, 400].map { BrowserAddressRanking.recencyScore(daysAgo: $0) },
                       [1, 1, 0.97, 0.7, 0.5, 0.3, 0.19, 0.1, 0.1])
        XCTAssertEqual([0, 1, 5, 9, 50, 90, 200].map(BrowserAddressRanking.relevance), [0, 625, 962, 1300, 1350, 1399, 1399])
        XCTAssertEqual(BrowserAddressRanking.urlTermScore("hub", url: "https://github.com/"), 2, "inside a word of the host")
        XCTAssertEqual(BrowserAddressRanking.urlTermScore("com", url: "https://github.com/"), 0, "the top-level domain")
        XCTAssertEqual(BrowserAddressRanking.urlTermScore("hello", url: "https://github.com/octocat/hello-world?tab=hello"), 13)
        XCTAssertEqual(BrowserAddressRanking.titleTermScore("날씨", title: "서울 날씨 - Google 검색"), 8)
        XCTAssertEqual(BrowserAddressRanking.titleTermScore("씨", title: "서울 날씨"), 0, "inside a word of the title")
    }

    func testSearchSuggestionsAskGoogleOnlyWhenOnAndNotForPrivateAddresses() async throws {
        for (text, asks) in [("gi", true), ("two words", true), ("?example.com/path", true), ("example.com", true),
                             ("http://example.com/x", true), ("https://example.com/private", false), ("localhost:3000", false),
                             ("/Users/me/a.html", false), ("user@example.com", false), ("example.com/?q=1", false),
                             ("file:///tmp/a", false)] {
            XCTAssertEqual(BrowserSearchSuggestService.mayAsk(about: text), asks, text)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeSuggestServer.self]
        FakeSuggestServer.requests = []
        var isOn = false
        let history = history()
        let autocomplete = BrowserAddressAutocomplete(history: { history }, service: BrowserSearchSuggestService(session: URLSession(configuration: configuration)),
                                                      suggestsSearches: { isOn }, korean: true, now: { self.now })
        autocomplete.update(typed: "gi", allowsInline: true)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(FakeSuggestServer.requests.isEmpty, "turned off, nothing is sent")
        XCTAssertFalse(autocomplete.rows.contains { $0.fill == "gitlab" })

        isOn = true
        autocomplete.update(typed: "gi", allowsInline: true)
        for _ in 0..<40 where !autocomplete.rows.contains(where: { $0.fill == "gitlab" }) { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(autocomplete.rows.contains { $0.fill == "gitlab" })
        let request = try XCTUnwrap(FakeSuggestServer.requests.first)
        let items = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.map(\.name), ["client", "ie", "oe", "hl", "q"])
        XCTAssertEqual(items.last?.value, "gi")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))

        autocomplete.move(by: -1)
        XCTAssertEqual(autocomplete.selection, autocomplete.rows.count - 1, "moving up from the first row wraps to the last")
        autocomplete.select(autocomplete.rows.firstIndex { $0.fill == "github copilot" } ?? 0)
        XCTAssertTrue(autocomplete.removeSelected())
        XCTAssertTrue(history.searches.isEmpty, "Shift-Delete removes a past search from the history")
        XCTAssertFalse(autocomplete.rows.contains { $0.fill == "github copilot" })
    }
}

/// Google's suggest service, as the tests need it.
final class FakeSuggestServer: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "www.google.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let body = Data("""
            )]}'
            ["gi",["github","gitlab"],["",""],[],{"google:suggesttype":["QUERY","QUERY"],"google:suggestrelevance":[600,560]}]
            """.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/javascript; charset=UTF-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
