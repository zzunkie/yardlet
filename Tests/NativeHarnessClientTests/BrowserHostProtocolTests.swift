import XCTest
@testable import NativeHarnessClient

/// The browser host contract is JSON on the wire; a host in another language (the CEF host, a
/// future WebView2 host) matches these shapes, so they are pinned here.
final class BrowserHostProtocolTests: XCTestCase {
    private func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    func testCommandsUseTheSingleKeyWireShape() throws {
        XCTAssertEqual(try json(BrowserHostCommand.mouse(tab: 3, input: BrowserMouseInput(
            kind: .down, x: 10, y: 20.5, button: .left, clickCount: 2, modifiers: [.shift, .leftButton]
        ))), #"{"mouse":{"input":{"button":"left","clickCount":2,"kind":"down","modifiers":18,"x":10,"y":20.5},"tab":3}}"#)
        XCTAssertEqual(try json(BrowserHostCommand.shutdown), #"{"shutdown":{}}"#)
        XCTAssertEqual(try json(BrowserHostCommand.close(tab: 1)), #"{"close":{"tab":1}}"#)
        XCTAssertEqual(try json(BrowserHostCommand.contextMenuResult(tab: 1, menu: 4, commandID: nil)),
                       #"{"contextMenuResult":{"menu":4,"tab":1}}"#)
        XCTAssertEqual(try json(BrowserHostCommand.composition(tab: 2, composition: .set(
            text: "한글", underlines: [BrowserCompositionUnderline(range: BrowserTextRange(location: 0, length: 2), isThick: false)],
            selection: BrowserTextRange(location: 2, length: 0), replacement: nil
        ))), #"{"composition":{"composition":{"set":{"selection":{"length":0,"location":2},"text":"한글","underlines":[{"isThick":false,"range":{"length":2,"location":0}}]}},"tab":2}}"#)
        XCTAssertEqual(try json(BrowserHostCommand.composition(tab: 2, composition: .cancel)),
                       #"{"composition":{"composition":{"cancel":{}},"tab":2}}"#)
        XCTAssertEqual(try json(BrowserHostCommand.open(tab: 1, url: "https://example.com", viewport: BrowserViewport(
            width: 400, height: 300, scale: 2, screenX: 10, screenY: 20
        ))), #"{"open":{"tab":1,"url":"https://example.com","viewport":{"height":300,"scale":2,"screenX":10,"screenY":20,"width":400}}}"#)
        XCTAssertEqual(try json(BrowserHostCommand.open(tab: 2, url: "about:blank", viewport: BrowserViewport(
            width: 400, height: 300, scale: 2), profile: BrowserTabProfile(key: "task-b", seedFrom: "task-a"))),
            #"{"open":{"profile":{"key":"task-b","seedFrom":"task-a"},"tab":2,"url":"about:blank","viewport":{"height":300,"scale":2,"screenX":0,"screenY":0,"width":400}}}"#)
        XCTAssertEqual(try json(BrowserHostCommand.open(tab: 3, url: "about:blank", viewport: BrowserViewport(
            width: 400, height: 300, scale: 2), profile: BrowserTabProfile(key: "task-c", follow: ["example.com"], fill: true))),
            #"{"open":{"profile":{"fill":true,"follow":["example.com"],"key":"task-c"},"tab":3,"url":"about:blank","viewport":{"height":300,"scale":2,"screenX":0,"screenY":0,"width":400}}}"#)
        XCTAssertEqual(try json(BrowserHostCommand.cookieDigest(request: 4, profile: nil, site: "example.com")),
                       #"{"cookieDigest":{"request":4,"site":"example.com"}}"#)
        XCTAssertEqual(try json(BrowserHostCommand.copyCookies(request: 5, from: "task-a", to: nil, domain: "example.com", replace: true)),
                       #"{"copyCookies":{"domain":"example.com","from":"task-a","replace":true,"request":5}}"#)
        XCTAssertEqual(try JSONDecoder().decode(BrowserHostEvent.self, from: Data(#"{"cookiesCopied":{"request":5,"count":33}}"#.utf8)),
                       .cookiesCopied(request: 5, count: 33))
    }

    func testTheViewportCarriesTheDisplayRefreshRateOnlyWhenKnown() throws {
        XCTAssertEqual(try json(BrowserHostCommand.resize(tab: 1, viewport: BrowserViewport(
            width: 400, height: 300, scale: 2, screenX: 10, screenY: 20, framesPerSecond: 120
        ))), #"{"resize":{"tab":1,"viewport":{"framesPerSecond":120,"height":300,"scale":2,"screenX":10,"screenY":20,"width":400}}}"#)
        XCTAssertEqual(try json(BrowserViewport.offscreenDefault), #"{"height":800,"scale":2,"screenX":0,"screenY":0,"width":1280}"#,
                       "a panel-less tab leaves the engine's default rate")
        XCTAssertEqual(try JSONDecoder().decode(BrowserHostEvent.self, from: Data(#"{"hidden":{"tab":4}}"#.utf8)), .hidden(tab: 4))
        XCTAssertEqual(BrowserHostEvent.hidden(tab: 4).tab, 4)
    }

    func testProductCommandsAndEventsKeepTheWireShape() throws {
        XCTAssertEqual(try json(BrowserHostCommand.zoom(tab: 1, action: .zoomIn)), #"{"zoom":{"action":"zoomIn","tab":1}}"#)
        XCTAssertEqual(try json(BrowserHostCommand.fileDialogResult(tab: 1, dialog: 5, paths: nil)),
                       #"{"fileDialogResult":{"dialog":5,"tab":1}}"#)
        XCTAssertEqual(try json(BrowserHostCommand.javaScriptDialogResult(tab: 1, dialog: 2, accepted: true, text: "x")),
                       #"{"javaScriptDialogResult":{"accepted":true,"dialog":2,"tab":1,"text":"x"}}"#)
        XCTAssertEqual(try json(BrowserHostCommand.drag(tab: 1, input: BrowserDragInput(
            phase: .enter, x: 1, y: 2, files: ["/tmp/a"], operations: 1, modifiers: []
        ))), #"{"drag":{"input":{"files":["/tmp/a"],"modifiers":0,"operations":1,"phase":"enter","x":1,"y":2},"tab":1}}"#)
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(BrowserHostEvent.self, from: Data(#"{"javaScriptDialog":{"tab":3,"dialog":{"id":1,"kind":"prompt","message":"Name?","defaultPrompt":"x","origin":"https://a.test","isReload":false}}}"#.utf8)),
                       .javaScriptDialog(tab: 3, dialog: BrowserJavaScriptDialog(id: 1, kind: .prompt, message: "Name?",
                                                                                defaultPrompt: "x", origin: "https://a.test", isReload: false)))
        XCTAssertEqual(try decoder.decode(BrowserHostEvent.self, from: Data(#"{"download":{"tab":3,"download":{"id":7,"state":"completed","fileName":"a.txt","path":"/d/a.txt","receivedBytes":5,"totalBytes":5}}}"#.utf8)),
                       .download(tab: 3, download: BrowserDownload(id: 7, state: .completed, fileName: "a.txt", path: "/d/a.txt",
                                                                   receivedBytes: 5, totalBytes: 5)))
        XCTAssertEqual(try decoder.decode(BrowserHostEvent.self, from: Data(#"{"navigationBlocked":{"tab":3,"url":"chrome://version"}}"#.utf8)).tab, 3)
        XCTAssertEqual(try decoder.decode(BrowserHostEvent.self, from: Data(#"{"tooltip":{"tab":3}}"#.utf8)), .tooltip(tab: 3, text: nil))
        // Other apps' addresses and a person's close.
        XCTAssertEqual(try json(BrowserHostCommand.requestClose(tab: 3)), #"{"requestClose":{"tab":3}}"#)
        XCTAssertEqual(try json(BrowserHostCommand.allowExternalApp(tab: 3, origin: "https://zoom.us", scheme: "zoommtg")),
                       #"{"allowExternalApp":{"origin":"https://zoom.us","scheme":"zoommtg","tab":3}}"#)
        let external = try decoder.decode(BrowserHostEvent.self, from: Data(
            #"{"externalApp":{"tab":3,"request":{"url":"tel:+1","origin":"https://a.test","userGesture":true,"remembered":false}}}"#.utf8))
        XCTAssertEqual(external, .externalApp(tab: 3, request: BrowserExternalAppRequest(
            url: "tel:+1", origin: "https://a.test", userGesture: true, remembered: false)))
        XCTAssertEqual(external.tab, 3)
        XCTAssertEqual(try decoder.decode(BrowserHostEvent.self, from: Data(#"{"newDocument":{"tab":3,"url":"https://a.test/"}}"#.utf8)),
                       .newDocument(tab: 3, url: "https://a.test/"))
        // The memory saver's discards, which the host's TabDiscarder answers by hand (BROWSER_HOST section 3, "Memory saver").
        XCTAssertEqual(try json(BrowserHostCommand.discard(tab: 3, urgent: false)), #"{"discard":{"tab":3,"urgent":false}}"#)
        XCTAssertEqual(try decoder.decode(BrowserHostEvent.self, from: Data(#"{"discarded":{"tab":3}}"#.utf8)), .discarded(tab: 3))
        XCTAssertEqual(try decoder.decode(BrowserHostEvent.self, from: Data(#"{"discardRefused":{"tab":3,"reason":"media"}}"#.utf8)),
                       .discardRefused(tab: 3, reason: "media"))
        // Chromium's own windows over their tabs (BROWSER_HOST section 3, "Chromium's windows and tabs").
        XCTAssertEqual(try json(BrowserHostCommand.presentChromiumWindows(placements: [
            BrowserChromiumWindowPlacement(window: 7, frame: BrowserRect(x: 10, y: 20, width: 300, height: 200), above: 3),
            BrowserChromiumWindowPlacement(window: 8, above: 3)
        ])), #"{"presentChromiumWindows":{"placements":[{"above":3,"frame":{"height":200,"width":300,"x":10,"y":20},"window":7},{"above":3,"window":8}]}}"#)
        XCTAssertEqual(try json(BrowserHostCommand.closeChromiumWindows(tabs: [4])), #"{"closeChromiumWindows":{"tabs":[4]}}"#)
        XCTAssertEqual(try json(BrowserHostCommand.closeChromiumWindows(tabs: nil)), #"{"closeChromiumWindows":{}}"#)
    }

    func testEventsDecodeFromHostJSON() throws {
        let decoder = JSONDecoder()
        func decode(_ text: String) throws -> BrowserHostEvent {
            try decoder.decode(BrowserHostEvent.self, from: Data(text.utf8))
        }
        XCTAssertEqual(try decode(#"{"ready":{"processID":42,"engine":"CEF","acceleratedPaint":true}}"#),
                       .ready(processID: 42, engine: "CEF", acceleratedPaint: true))
        XCTAssertEqual(try decode(#"{"frame":{"tab":1,"frame":{"layer":"popup","surface":77,"pixelWidth":110,"pixelHeight":146,"sequence":9,"paintedAt":123456789012,"source":"accelerated"}}}"#),
                       .frame(tab: 1, frame: BrowserFrame(layer: .popup, surface: 77, pixelWidth: 110, pixelHeight: 146,
                                                          sequence: 9, paintedAt: 123_456_789_012, source: "accelerated")))
        XCTAssertEqual(try decode(#"{"popup":{"tab":1}}"#), .popup(tab: 1, rect: nil))
        XCTAssertEqual(try decode(#"{"cursor":{"tab":1,"cursor":"text"}}"#), .cursor(tab: 1, cursor: .text))
        let menu = try decode(#"{"contextMenu":{"tab":1,"menu":{"id":2,"x":3,"y":4,"items":[{"commandID":110,"title":"Copy","isEnabled":true,"isChecked":false},{"title":"","isEnabled":true,"isChecked":false}]}}}"#)
        XCTAssertEqual(menu, .contextMenu(tab: 1, menu: BrowserContextMenu(id: 2, x: 3, y: 4, items: [
            BrowserContextMenuItem(commandID: 110, title: "Copy", isEnabled: true, isChecked: false),
            BrowserContextMenuItem(commandID: nil, title: "", isEnabled: true, isChecked: false)
        ])))
        XCTAssertEqual(menu.tab, 1)
        XCTAssertNil(try decode(#"{"terminated":{"reason":"signal 9"}}"#).tab)
        XCTAssertEqual(try decode(#"{"newWindow":{"tab":3,"url":"https://a.test/","background":true,"userGesture":true}}"#),
                       .newWindow(tab: 3, url: "https://a.test/", background: true, userGesture: true))
        let popup = try decode(#"{"popupOpened":{"tab":1073741824,"opener":3,"url":"https://b.test/","background":false}}"#)
        XCTAssertEqual(popup, .popupOpened(tab: 1 << 30, opener: 3, url: "https://b.test/", background: false))
        XCTAssertEqual(popup.tab, 1 << 30, "the event belongs to the new window's tab")
        let shown = try decode(#"{"chromiumWindow":{"isShown":true,"titles":["패스키 없음"]}}"#)
        XCTAssertEqual(shown, .chromiumWindow(isShown: true, titles: ["패스키 없음"]))
        XCTAssertEqual(try decode(#"{"chromiumWindow":{"isShown":false}}"#), .chromiumWindow(isShown: false, titles: nil))
        XCTAssertEqual(try decode(#"{"chromiumWindow":{"isShown":true,"titles":["로그인"],"kinds":["signIn"]}}"#),
                       .chromiumWindow(isShown: true, titles: ["로그인"], kinds: ["signIn"]))
        XCTAssertEqual(try decode(#"{"chromiumWindow":{"isShown":true,"titles":["패스키","Print"],"kinds":["passkey","print"],"ids":[41,42],"tabs":[3,-1]}}"#),
                       .chromiumWindow(isShown: true, titles: ["패스키", "Print"], kinds: ["passkey", "print"], ids: [41, 42], tabs: [3, -1]))
        XCTAssertNil(shown.tab, "the event goes to the client, which keeps each window's tab")
    }

    func testFrameReaderSplitsMessagesAcrossChunkBoundaries() throws {
        let first = try BrowserHostFraming.frame(BrowserHostCommand.close(tab: 1))
        let second = try BrowserHostFraming.frame(BrowserHostCommand.shutdown)
        let stream = first + second
        var reader = BrowserHostFrameReader()
        var bodies: [Data] = []
        for index in stream.indices {
            bodies += try reader.append(Data([stream[index]]))
        }
        let decoded = try bodies.map { try JSONDecoder().decode(BrowserHostCommand.self, from: $0) }
        XCTAssertEqual(decoded, [.close(tab: 1), .shutdown])
        XCTAssertEqual(first.prefix(4), Data([0, 0, 0, UInt8(first.count - 4)]))
    }

    func testFrameReaderRejectsAnImpossibleLength() {
        var reader = BrowserHostFrameReader()
        XCTAssertThrowsError(try reader.append(Data([0xFF, 0xFF, 0xFF, 0xFF])))
    }
}

@MainActor
final class BrowserHostClientTests: XCTestCase {
    private final class FakeConnection: BrowserHostConnection {
        var eventHandler: ((BrowserHostEvent) -> Void)?
        var sent: [BrowserHostCommand] = []
        var terminated = false

        func send(_ command: BrowserHostCommand) {
            sent.append(command)
            if command == .shutdown { eventHandler?(.terminated(reason: "exit status 0")) }
        }

        func terminate() {
            terminated = true
            eventHandler?(.terminated(reason: "signal 15"))
        }
    }

    private var connections: [FakeConnection] = []

    private func makeClient(grace: Duration = .milliseconds(50)) -> BrowserHostClient {
        BrowserHostClient(idleGrace: grace) { [unowned self] in
            let connection = FakeConnection()
            connections.append(connection)
            return connection
        }
    }

    private func viewport() -> BrowserViewport { BrowserViewport(width: 300, height: 200, scale: 2) }

    func testHostStartsColdStaysWarmWithinGraceAndEndsAfterIt() async throws {
        let client = makeClient()
        let first = try client.openTab(url: "about:blank", viewport: viewport())
        XCTAssertEqual(client.launchCount, 1)
        XCTAssertEqual(connections.last?.sent.first, .open(tab: first.id, url: "about:blank", viewport: viewport()))

        first.close()
        XCTAssertTrue(client.isHostRunning, "the host waits out the grace period")
        let warm = try client.openTab(url: "about:blank", viewport: viewport())
        XCTAssertEqual(client.launchCount, 1, "a tab opened within the grace period reuses the host")
        warm.close()

        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(client.isHostRunning)
        XCTAssertEqual(connections.last?.sent.last, .shutdown)

        _ = try client.openTab(url: "about:blank", viewport: viewport())
        XCTAssertEqual(client.launchCount, 2, "after the host ended the next tab starts it again")
    }

    func testTerminationReachesOpenTabsAndFailsPendingDevTools() async throws {
        let client = makeClient(grace: .seconds(60))
        let tab = try client.openTab(url: "about:blank", viewport: viewport())
        var received: [BrowserHostEvent] = []
        tab.eventHandler = { received.append($0) }
        let request = Task { try await tab.devTools.send("Runtime.evaluate", ["expression": .string("1")]) }
        try await Task.sleep(for: .milliseconds(20))
        connections.last?.eventHandler?(.terminated(reason: "signal 9"))
        XCTAssertEqual(received, [.terminated(reason: "signal 9")])
        XCTAssertEqual(client.openTabCount, 0)
        XCTAssertFalse(client.isHostRunning)
        do {
            _ = try await request.value
            XCTFail("the request should fail when the host dies")
        } catch let error as BrowserDevToolsError {
            XCTAssertEqual(error, .closed)
        }
    }

    func testDevToolsRepliesRouteByTabAndID() async throws {
        let client = makeClient(grace: .seconds(60))
        let tab = try client.openTab(url: "about:blank", viewport: viewport())
        let request = Task { try await tab.devTools.send("Browser.getVersion") }
        try await Task.sleep(for: .milliseconds(20))
        guard case .devTools(let tabID, let message) = connections.last?.sent.last else {
            return XCTFail("no DevTools command was sent")
        }
        XCTAssertEqual(tabID, tab.id)
        XCTAssertTrue(message.contains(#""method":"Browser.getVersion""#))
        connections.last?.eventHandler?(.devTools(tab: tab.id, message: #"{"id":1,"result":{"product":"Chrome/154"}}"#))
        let result = try await request.value
        XCTAssertEqual(result["product"]?.stringValue, "Chrome/154")
    }

    func testSessionTabIsReusedAndKeptWhileItsPanelIsOpen() async throws {
        let client = makeClient(grace: .milliseconds(150))
        let session = UUID()
        let tab = try client.openTab(forSession: session, url: "https://a.test", viewport: viewport())
        XCTAssertTrue(try client.openTab(forSession: session, url: "https://b.test", viewport: viewport()) === tab)
        XCTAssertEqual(connections.last?.sent.filter { if case .open = $0 { true } else { false } }.count, 1)
        client.attachPanel(to: tab)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(client.tab(forSession: session) === tab, "an open panel keeps its tab")

        client.detachPanel(from: tab)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(client.tab(forSession: session) === tab, "the tab outlives its panel, as the Codex app keeps a thread's page")
        XCTAssertTrue(client.isHostRunning)
        tab.close()
        XCTAssertNil(client.tab(forSession: session))
        XCTAssertTrue(tab.isClosed)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(client.isHostRunning, "the host ends the grace period after the last tab closes")
        XCTAssertTrue(connections.last?.sent.contains(.shutdown) == true)
    }

    func testAnUnwatchedAgentTabStaysUntilItsTaskClosesIt() async throws {
        let client = makeClient(grace: .milliseconds(100))
        let session = UUID()
        let tab = try client.openTab(forSession: session, url: "https://a.test", viewport: .offscreenDefault)
        var activity = 0
        tab.onAgentActivity = { activity += 1 }
        client.noteAgentActivity(forSession: session)
        XCTAssertEqual(activity, 1)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(client.tab(forSession: session) === tab, "no panel and no agent use do not close it")
        XCTAssertTrue(client.isHostRunning)
    }

    func testEventObserversAndThePanelHandlerAllReceiveEvents() throws {
        let client = makeClient(grace: .seconds(60))
        let tab = try client.openTab(forSession: UUID(), url: "https://a.test", viewport: viewport())
        var panel: [BrowserHostEvent] = []
        var agent: [BrowserHostEvent] = []
        tab.eventHandler = { panel.append($0) }
        let token = tab.addEventObserver { agent.append($0) }
        connections.last?.eventHandler?(.address(tab: tab.id, url: "https://a.test/next"))
        tab.removeEventObserver(token)
        connections.last?.eventHandler?(.title(tab: tab.id, title: "Next"))
        XCTAssertEqual(panel.count, 2)
        XCTAssertEqual(agent, [.address(tab: tab.id, url: "https://a.test/next")])
        XCTAssertEqual(tab.currentURL, "https://a.test/next")
    }
}
