import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

@MainActor
final class PersonalAgentRenderingTests: XCTestCase {
    func testTaskSectionStillShowsTheExistingWorkspace() async throws {
        let (model, task) = try makeWindowModel()
        let directory = try WindowlessRender.directory("personal-agent-qa")
        let size = NSSize(width: 1280, height: 800)
        let captures = try WindowlessRender.hostedInBothAppearances("tasks", in: directory, size: size) { appearance in
            MainWindow(model: model)
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height)
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
        XCTAssertEqual(model.store.selectedSessionID, task.id)
        let host = WindowlessRender.Host(MainWindow(model: model).frame(width: size.width, height: size.height), size: size)
        defer { host.close() }
        host.settle()
        XCTAssertTrue(model.isSessionVisible(task.id), "A window showing Tasks shows the selected task")
        let railTitles = [L10n.string("Show session rail"), L10n.string("Hide session rail")]
        let showsTaskRail = { host.accessibilityElements().contains { railTitles.contains($0.label) } }
        XCTAssertTrue(showsTaskRail(), "The shown task's header offers its session rail")
        // The words below Scheduled tasks switch the list to personal agents; Home and Scheduled tasks stay.
        XCTAssertTrue(Self.press(L10n.string("Personal agents"), in: host.hosting))
        let showsPersonalAgents = { host.accessibilityElements().contains { $0.label == "Dots" || $0.value == "Dots" } }
        await host.settle(until: showsPersonalAgents)
        try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "personal-section-window.png"))
        XCTAssertFalse(showsTaskRail(), "The hidden coding task's rail and panels stay off the personal-agent screen")
        // The selected task is hidden behind personal agents: its updates stay unread until Tasks come back.
        XCTAssertFalse(model.isSessionVisible(task.id))
        await model.store.markUnread(id: task.id)
        XCTAssertTrue(host.accessibilityElements().contains { $0.label == L10n.string("Scheduled tasks") })
        XCTAssertFalse(host.accessibilityElements().contains { $0.label == L10n.string("Back to tasks") })
        XCTAssertTrue(Self.press(L10n.string("Tasks"), in: host.hosting))
        await host.settle(until: { !showsPersonalAgents() })
        XCTAssertTrue(showsTaskRail())
        try await waitUntil { model.store.sessions.first { $0.id == task.id }?.hasUnreadUpdate == false }
        XCTAssertTrue(model.isSessionVisible(task.id))
        XCTAssertTrue(Self.press(L10n.string("Personal agents"), in: host.hosting))
        await host.settle(until: showsPersonalAgents)
        try await model.store.archiveSession(id: task.id)
        host.settle()
        XCTAssertTrue(showsPersonalAgents(),
                      "Removing the hidden coding task must not take over the personal-agent section.")
        model.showNewTaskFromMenuBar()
        await host.settle(until: { !showsPersonalAgents() })
        XCTAssertNil(model.store.selectedSessionID)
        XCTAssertTrue(Self.press(L10n.string("Personal agents"), in: host.hosting))
        await host.settle(until: showsPersonalAgents)
        _ = try await model.store.unarchiveSession(id: task.id)
        _ = await model.openTask(from: SystemNotificationTarget(sessionID: task.id))
        await host.settle(until: { !showsPersonalAgents() })
        XCTAssertEqual(model.store.selectedSessionID, task.id)
        host.close()
        try await waitUntil { !model.isSessionVisible(task.id) }
    }

    /// Switching to personal agents and back leaves the task list as it was left: scrolled where it was,
    /// the shown task's project still folded, the search still typed.
    func testTheTaskListComesBackAsItWasLeft() async throws {
        var folders: [String: URL] = [:]
        let (model, _) = try makeWindowModel { root in
            try ["alpha", "beta", "gamma"].flatMap { name in
                let folder = root.appending(path: name)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                folders[name] = folder
                return (1...20).map { index in
                    SessionRecord(harness: .codex, workspaceURL: folder,
                                  runtimeExecutableURL: URL(filePath: "/usr/bin/true"), title: "\(name) task \(index)")
                }
            }
        }
        for (name, folder) in folders { _ = model.projects.ensureProject(forRoot: folder, name: name) }
        let tasks = model.store.sessions.filter { $0.title.hasPrefix("alpha") }
        model.splits.activate(.session(tasks[0].id))
        let reader = RenderedPersonalAgentReader(agents: [], messages: [])
        let size = NSSize(width: 920, height: 480)
        let host = WindowlessRender.Host(MainWindow(model: model) { reader }.frame(width: size.width, height: size.height), size: size)
        defer { host.close() }
        host.settle(passes: 20)
        let header = L10n.format("Project %@", "alpha")
        let isFolded = { host.accessibilityElements().first { $0.label == header }?.value.contains(L10n.string("Collapsed")) == true }
        let searchField = { Self.textFields(in: host.hosting).first { $0.placeholderString == L10n.string("Search tasks") } }
        // The task list: the sidebar's scroll view, while its search field is there.
        let list = { () -> NSScrollView? in
            guard searchField() != nil else { return nil }
            return Self.scrollViews(in: host.hosting).first { $0.convert($0.bounds, to: nil).maxX < 400 }
        }
        func switchAndBack() async {
            XCTAssertTrue(Self.press(L10n.string("Personal agents"), in: host.hosting))
            await host.settle(until: { searchField() == nil })
            XCTAssertTrue(Self.press(L10n.string("Tasks"), in: host.hosting))
            await host.settle(until: { list() != nil })
        }

        XCTAssertTrue(Self.press(header, in: host.hosting))
        await host.settle(until: isFolded)
        let scroll = try XCTUnwrap(list())
        for _ in 0..<8 {
            guard let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -40, wheel2: 0, wheel3: 0),
                  let event = NSEvent(cgEvent: wheel) else { break }
            scroll.scrollWheel(with: event)
            host.settle(passes: 1)
        }
        host.settle(passes: 10)
        let offset = scroll.contentView.bounds.minY
        XCTAssertGreaterThan(offset, 40, "The list scrolled away from the shown task")
        await switchAndBack()
        await host.settle(until: { list().map { abs($0.contentView.bounds.minY - offset) < 1 } ?? false })
        XCTAssertTrue(isFolded(), "The shown task's project stays folded")
        XCTAssertEqual(model.store.selectedSessionID, tasks[0].id)

        // A task opened from elsewhere while personal agents show is where the list now is: going back
        // and forth again keeps it there, not where the list was left for the earlier task.
        XCTAssertTrue(Self.press(L10n.string("Personal agents"), in: host.hosting))
        await host.settle(until: { searchField() == nil })
        let other = try XCTUnwrap(model.store.sessions.first { $0.title == "beta task 1" })
        // Pin the new selection so it is already visible at the recreated list's top. This exercises
        // the initial 0-to-0 report that must not leave the earlier task's offset attached to it.
        await model.togglePinned(other)
        _ = await model.openTask(from: SystemNotificationTarget(sessionID: other.id))
        await host.settle(until: { list() != nil })
        host.settle(passes: 10)
        let revealed = try XCTUnwrap(list()).contentView.bounds.minY
        XCTAssertEqual(revealed, 0, accuracy: 1, "The new selection starts in the first viewport")
        await switchAndBack()
        await host.settle(until: { list().map { abs($0.contentView.bounds.minY - revealed) < 1 } ?? false })
        XCTAssertEqual(model.store.selectedSessionID, other.id)

        // A page another app opens with Yardlet, shown in a panel, brings the tasks back too.
        XCTAssertTrue(Self.press(L10n.string("Personal agents"), in: host.hosting))
        await host.settle(until: { searchField() == nil })
        model.openExternalLinks([try XCTUnwrap(URL(string: "https://example.test/page"))], elsewhere: { _ in
            XCTFail("The shown task's panel has room for the page")
        })
        await host.settle(until: { list() != nil })

        // Typed search stays typed.
        let field = try XCTUnwrap(searchField())
        field.stringValue = "beta"
        (field.delegate as? NSTextFieldDelegate)?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        host.settle(passes: 10)
        await switchAndBack()
        XCTAssertEqual(searchField()?.stringValue, "beta")
    }

    private static func textFields(in view: NSView) -> [NSTextField] {
        ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap { textFields(in: $0) }
    }

    func testSignInAndUnavailableStatesHaveReadableActions() throws {
        let directory = try WindowlessRender.directory("personal-agent-qa")
        for (name, failure) in [("sign-in", PersonalAgentFailure.signInRequired), ("unavailable", .accessDenied)] {
            let center = PersonalAgentCenter()
            center.showUnavailable(failure)
            let size = NSSize(width: 680, height: 530)
            let captures = try WindowlessRender.hostedInBothAppearances(name, in: directory, size: size) { appearance in
                PersonalAgentsContent(center: center, onRetry: {}, onAccounts: {})
                    .environment(\.colorScheme, appearance.colorScheme)
                    .frame(width: size.width, height: size.height)
            }
            for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
        }
    }

    func testNativeReaderAtNormalAndCompactWindowSizes() async throws {
        let (model, _) = try makeWindowModel()
        let agents = [
            PersonalAgent(id: .init(accountID: "example", userID: "person", agentID: "dot", roomID: "room"),
                          name: "Atlas", rootThreadID: "root", isPaused: false, isPrimary: true,
                          avatar: .init(location: "https://files.oaiusercontent.com/example-avatar", version: "v1"),
                          petID: "pet"),
            PersonalAgent(id: .init(accountID: "example", userID: "person", agentID: "dot-2", roomID: "room-2"),
                          name: "Juniper", rootThreadID: nil, isPaused: true, isPrimary: false)
        ]
        let messages: [PersonalAgentMessage] = [
            .init(id: "m1", author: .person, text: "Check the launch plan and tell me what needs a decision.",
                  createdAt: nil, isDeleted: false, attachments: []),
            .init(id: "m2", author: .agent, text: """
                There are two decisions left before launch.

                - Choose the release date after the final review.
                - Confirm who will publish the announcement.

                I have kept the draft ready for your review.
                """, createdAt: nil, isDeleted: false, attachments: []),
            .init(id: "m3", author: .person, text: "Keep the announcement as a draft for now.",
                  createdAt: nil, isDeleted: false, attachments: []),
            .init(id: "m4", author: .agent, text: "The announcement is still a draft. I will wait for your decision.",
                  createdAt: nil, isDeleted: false,
                  attachments: [.init(fileID: "file", name: "announcement-draft.md", type: "file")]),
            .init(id: "m5", author: .agent, text: L10n.string("This message cannot be displayed yet."), createdAt: nil,
                  isDeleted: false, attachments: [], isUnsupported: true)
        ]
        // Opening the dot elsewhere is handed to an opener that records it; nothing is opened.
        var opened: [URL] = []
        var webOpens = true
        var appLookups = 0
        let opener = PersonalAgentOriginalOpener(appLocation: { appLookups += 1; return nil },
                                                 openWeb: { opened.append($0); return webOpens },
                                                 openApp: { _, done in done(false) })
        let directory = try WindowlessRender.directory("personal-agent-surface-qa")
        for size in [NSSize(width: 1280, height: 800), NSSize(width: 920, height: 680)] {
            for appearance in WindowlessRender.Appearance.allCases {
                let reader = RenderedPersonalAgentReader(agents: agents, messages: messages)
                let window = MainWindow(model: model) { reader }
                    .environment(\.personalAgentOriginalOpener, opener)
                    .environment(\.colorScheme, appearance.colorScheme)
                    .frame(width: size.width, height: size.height)
                let host = WindowlessRender.Host(window, size: size, appearance: appearance)
                defer { host.close() }
                host.settle()
                let name = "\(Int(size.width))-\(appearance.suffix).png"
                try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "tasks-\(name)"))
                XCTAssertTrue(Self.press(L10n.string("Personal agents"), in: host.hosting))
                await host.settle(until: { host.accessibilityElements().contains { $0.label == "announcement-draft.md" } })
                // The details and the picture arrive on their own after the conversation.
                let showsActivity = { host.accessibilityElements().contains { $0.label.contains("Prepare the launch checklist") } }
                if size.width >= 1280 { await host.settle(until: showsActivity) }
                try await waitUntil { await reader.avatarReads > 0 }
                try await waitUntil { await reader.sheetReads > 0 }
                // Atlas plays its pet once the sheet is decoded; Juniper, with none, keeps its initial.
                await host.settle(until: { !Self.views(PersonalAgentSpriteView.self, in: host.hosting).isEmpty })
                host.settle(passes: 12)
                let capture = try host.capture()
                XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6))
                try WindowlessRender.writePNG(capture.bitmap, to: directory.appending(path: "personal-\(name)"))
                let visible = host.accessibilityElements(visibleOnly: true)
                for label in [L10n.string("Home"), L10n.string("Tasks"), "Atlas", "Juniper", L10n.string("Send message")] {
                    XCTAssertTrue(visible.contains { $0.label == label }, "\(label) is on screen at \(size)")
                }
                // The header's Open in Dots menu is there, not opened; a message Yardlet cannot show links
                // to the dot's own page, opened only when pressed.
                XCTAssertTrue(Self.hasMenu(titled: L10n.string("Open in Dots"), in: host.hosting), "Open in Dots at \(size)")
                XCTAssertGreaterThan(appLookups, 0, "The provider's app is looked up, not opened")
                XCTAssertTrue(opened.isEmpty)
                XCTAssertTrue(Self.press(L10n.string("Open This Dot on the Web"), in: host.hosting))
                XCTAssertEqual(opened, [DotsLinks.web(for: agents[0])!])
                opened = []
                let showsDetails = { host.accessibilityElements(visibleOnly: true).contains { $0.label == L10n.string("Dot details") } }
                if size.width >= 1280 {
                    XCTAssertTrue(showsDetails(), "A wide window keeps the dot's details beside the conversation")
                } else {
                    // A compact window keeps the conversation's width; the details come over it on request.
                    XCTAssertFalse(showsDetails())
                    XCTAssertTrue(Self.press(L10n.string("Show dot details"), in: host.hosting))
                    await host.settle(until: showsActivity)
                    host.settle(passes: 12)
                    try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "personal-details-\(name)"))
                    // The raised details close from their own button; the conversation and its editor stay.
                    XCTAssertTrue(Self.press(L10n.string("Hide dot details"), in: host.hosting))
                    await host.settle(until: { !showsDetails() })
                    let after = host.accessibilityElements(visibleOnly: true)
                    XCTAssertTrue(after.contains { $0.label == L10n.string("Send message") })
                    XCTAssertTrue(after.contains { $0.label == L10n.string("Show dot details") })
                }
                // A page that could not be handed on says so under the conversation.
                webOpens = false
                XCTAssertTrue(Self.press(L10n.string("Open This Dot on the Web"), in: host.hosting))
                let failure = L10n.string("Dots could not be opened.")
                await host.settle(until: { host.accessibilityElements().contains { $0.label == failure || $0.value == failure } })
                webOpens = true
                opened = []
            }
        }

        // Scrolling to the top of a long conversation reads the earlier page once, not before.
        let latest = (1...24).map { index in
            PersonalAgentMessage(id: "late-\(index)", author: index.isMultiple(of: 2) ? .agent : .person,
                                 text: "Message \(index) of the latest page.", createdAt: nil, isDeleted: false, attachments: [])
        }
        let older = [PersonalAgentMessage(id: "early", author: .agent, text: "An earlier reply.", createdAt: nil,
                                          isDeleted: false, attachments: [.init(fileID: "old", name: "older-notes.txt", type: "file")])]
        let reader = RenderedPersonalAgentReader(agents: agents, messages: latest, older: older)
        let size = NSSize(width: 1280, height: 800)
        let host = WindowlessRender.Host(MainWindow(model: model) { reader }.frame(width: size.width, height: size.height), size: size)
        defer { host.close() }
        host.settle()
        XCTAssertTrue(Self.press(L10n.string("Personal agents"), in: host.hosting))
        await host.settle(until: { host.accessibilityElements().contains { $0.label == "Juniper" } })
        host.settle(passes: 20)
        let readsBeforeScrolling = await reader.olderReads
        XCTAssertEqual(readsBeforeScrolling, 0, "The latest page at the bottom reads nothing earlier")
        let conversationScroll = try XCTUnwrap(Self.scrollViews(in: host.hosting).max {
            ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
        })
        let document = try XCTUnwrap(conversationScroll.documentView)
        // The wheel the person turns, handed to the conversation's scroll view, not posted to the system.
        for _ in 0..<40 {
            guard let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 200, wheel2: 0, wheel3: 0),
                  let event = NSEvent(cgEvent: wheel) else { break }
            conversationScroll.scrollWheel(with: event)
            host.settle(passes: 1)
        }
        await host.settle(until: { host.accessibilityElements().contains { $0.label == "older-notes.txt" } })
        host.settle(passes: 20)
        let readsAfterScrolling = await reader.olderReads
        XCTAssertEqual(readsAfterScrolling, 1, "Reaching the top reads one earlier page")
        XCTAssertTrue(host.accessibilityElements().contains { $0.label == "older-notes.txt" })
        try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "personal-earlier-page.png"))
    }

    /// The pet's frames play on the layer only while the view can be seen, and change over time as
    /// they play: two renders of the layer as Core Animation shows it, some time apart, differ.
    func testADotsPetPlaysOnlyWhileItCanBeSeen() async throws {
        let frames = try XCTUnwrap(PersonalAgentSpriteFrames(data: try Self.syntheticSheet()))
        XCTAssertEqual([frames.atlas.width, frames.atlas.height], [1_536, 416], "Only the idle and working rows are kept")
        XCTAssertNotNil(PersonalAgentSpriteFrames(data: try Self.syntheticSheet(rows: 9)), "The first version's nine rows are read")
        XCTAssertNil(PersonalAgentSpriteFrames(data: try Self.syntheticSheet(rows: 10)), "A sheet of another size is not read")
        XCTAssertNil(PersonalAgentSpriteFrames(data: Data("not an image".utf8)))
        // The idle cell's pet, 80 x 100 at (60, 90), is enlarged 1.5 times and centred in its frame, once for all frames.
        XCTAssertEqual(frames.placement, CGRect(x: 96 - 1.5 * 100, y: 104 - 1.5 * 140, width: 288, height: 312))

        let directory = try WindowlessRender.directory("dots-avatar-animation-qa")
        let view = PersonalAgentSpriteView(frame: NSRect(x: 0, y: 0, width: 96, height: 96))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        view.show(frames, motion: .idle)
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.isPlaying, "A window that is not on screen plays nothing")

        view.isOnScreen = { _ in true }
        view.updatePlayback()
        XCTAssertTrue(view.isPlaying)
        CATransaction.flush()
        let shown = { view.layer?.sublayers?.first?.presentation()?.contentsRect }
        let first = try XCTUnwrap(shown())
        let before = try Self.render(view)
        // The idle row's first frame is on screen for 1.68 s; the next one follows it.
        try await waitUntil { shown().map { $0 != first } ?? false }
        let after = try Self.render(view)
        XCTAssertNotEqual(before.tiffRepresentation, after.tiffRepresentation, "The picture on screen changed as it played")
        try WindowlessRender.writePNG(before, to: directory.appending(path: "idle-frame-1.png"))
        try WindowlessRender.writePNG(after, to: directory.appending(path: "idle-frame-2.png"))

        view.show(frames, motion: .working)
        XCTAssertTrue(view.isPlaying, "Another motion plays from its first frame")
        view.isHidden = true
        XCTAssertFalse(view.isPlaying, "A hidden view stops")
        view.isHidden = false
        XCTAssertTrue(view.isPlaying)
        view.isOnScreen = { _ in false }
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertFalse(view.isPlaying, "An inactive app, or a covered window, stops it")
        view.isOnScreen = { _ in true }
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertTrue(view.isPlaying)

        // In a list, the picture scrolled out of sight stops though its window is on screen, and plays again
        // scrolled back.
        let list = NSScrollView(frame: NSRect(x: 0, y: 0, width: 96, height: 96))
        let rows = NSView(frame: NSRect(x: 0, y: 0, width: 96, height: 600))
        list.documentView = rows
        window.contentView = list
        rows.addSubview(view)
        list.contentView.scroll(to: .zero)
        XCTAssertTrue(view.isPlaying)
        list.contentView.scroll(to: NSPoint(x: 0, y: 400))
        XCTAssertFalse(view.isPlaying, "A picture scrolled out of its list stops")
        list.contentView.scroll(to: .zero)
        XCTAssertTrue(view.isPlaying)
    }

    /// Pets playing in the window cost it nothing beyond their layers: in the list, the header and the
    /// details, while no message's picture plays, their frames change and no SwiftUI body is worked out
    /// again. The window is not shown, so the pictures are told they can be seen.
    func testPlayingPetsDrawNothingAgainAroundThem() async throws {
        let (model, _) = try makeWindowModel()
        let agent = PersonalAgent(id: .init(accountID: "example", userID: "person", agentID: "dot", roomID: "room"),
                                  name: "Atlas", rootThreadID: "root", isPaused: false, isPrimary: true,
                                  avatar: .init(location: "https://files.oaiusercontent.com/example-avatar", version: "v1"),
                                  petID: "pet")
        let reader = RenderedPersonalAgentReader(agents: [agent], messages: [
            .init(id: "m1", author: .agent, text: "The draft is ready.", createdAt: nil, isDeleted: false, attachments: []),
            .init(id: "m2", author: .agent, text: "I will wait for your review.", createdAt: nil, isDeleted: false, attachments: [])
        ])
        let size = NSSize(width: 1280, height: 800)
        let host = WindowlessRender.Host(MainWindow(model: model) { reader }.frame(width: size.width, height: size.height), size: size)
        defer { host.close() }
        host.settle()
        XCTAssertTrue(Self.press(L10n.string("Personal agents"), in: host.hosting))
        try await waitUntil { await reader.sheetReads > 0 }
        await host.settle(until: { Self.views(PersonalAgentSpriteView.self, in: host.hosting).count == 3 })
        let pets = Self.views(PersonalAgentSpriteView.self, in: host.hosting)
        XCTAssertFalse(pets.contains { $0.isPlaying }, "Nothing plays in a window that is not shown")
        try WindowlessRender.writePNG(host.capture().bitmap,
            to: try WindowlessRender.directory("dots-avatar-animation-qa").appending(path: "window-pets-held.png"))

        ViewBodyCensus.isEnabled = true
        ViewBodyCensus.reset()
        defer { ViewBodyCensus.isEnabled = false; ViewBodyCensus.reset() }
        for pet in pets {
            pet.isOnScreen = { _ in true }
            pet.updatePlayback()
        }
        XCTAssertTrue(pets.allSatisfy(\.isPlaying))
        CATransaction.flush()
        let shown = { pets.map { $0.layer?.sublayers?.first?.presentation()?.contentsRect } }
        let first = shown()
        try await waitUntil {
            host.settle(passes: 1, interval: 0.02)
            return zip(first, shown()).allSatisfy { $0 != $1 }
        }
        host.settle(passes: 10, interval: 0.02)
        XCTAssertEqual(ViewBodyCensus[.mainWindow], 0, "A playing pet drew the window again")
        XCTAssertEqual(ViewBodyCensus[.personalAgentAvatar], 0, "A playing pet worked out its picture again")
    }

    private static func views<View: NSView>(_ type: View.Type, in root: NSView) -> [View] {
        ((root as? View).map { [$0] } ?? []) + root.subviews.flatMap { views(type, in: $0) }
    }

    /// The layer tree as Core Animation shows it now, its playing frame included.
    private static func render(_ view: NSView) throws -> NSBitmapImageRep {
        let layer = try XCTUnwrap(view.layer?.presentation() ?? view.layer)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 192, pixelsHigh: 192,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap)).cgContext
        context.scaleBy(x: 2, y: 2)
        layer.render(in: context)
        return bitmap
    }

    /// A made-up pet sheet, eight 192 x 208 cells across: in each cell a shape coloured by its row, a
    /// little larger in each column, so every frame looks different. The idle cell's shape is 80 x 100
    /// at (60, 90) from the cell's top left.
    nonisolated static func syntheticSheet(rows: Int = 11) throws -> Data {
        let width = 1_536, height = rows * 208
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        for row in 0..<rows {
            for column in 0..<8 {
                let grow = CGFloat(column) * 4
                let top = CGFloat(row * 208) + 90 - grow
                let rect = NSRect(x: CGFloat(column * 192) + 60 - grow, y: CGFloat(height) - top - 100 - grow,
                                  width: 80 + 2 * grow, height: 100 + 2 * grow)
                NSColor(calibratedHue: CGFloat(row) / CGFloat(rows), saturation: 0.7, brightness: 0.9, alpha: 1).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 30, yRadius: 30).fill()
                NSColor.white.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.minX + 18 + grow, y: rect.maxY - 40, width: 14, height: 14)).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }

    func testUncertainDeliveryAndAttachmentPreviewRemainReadable() throws {
        let directory = try WindowlessRender.directory("personal-agent-qa")
        let center = PersonalAgentCenter()
        let agent = PersonalAgent(id: .init(accountID: "example", userID: "person", agentID: "dot", roomID: "room"),
                                  name: "Atlas", rootThreadID: nil, isPaused: false, isPrimary: true)
        center.useFixture(agents: [agent], messages: [.init(id: "file-message", author: .agent, text: "The draft is ready.",
            createdAt: nil, isDeleted: false, attachments: [.init(fileID: "file", name: "release-draft.txt", type: "file")])])
        let draft = try XCTUnwrap(center.conversation?.draft)
        draft.editor.text = "이 초안으로 진행해줘. 게시하기 전에는 확인을 받아줘."
        _ = draft.prepare()
        draft.failed(.deliveryUnknown, retry: false)
        let size = NSSize(width: 680, height: 620)
        let host = WindowlessRender.Host(PersonalAgentsContent(center: center, onRetry: {}, onAccounts: {}), size: size)
        host.settle()
        XCTAssertTrue(host.accessibilityElements().contains { $0.label == L10n.string("Edit message") },
                      "An uncertain send needs an explicit way back to editing.")
        host.close()
        let captures = try WindowlessRender.hostedInBothAppearances("delivery-uncertain", in: directory, size: size) { appearance in
            PersonalAgentsContent(center: center, onRetry: {}, onAccounts: {})
                .environment(\.colorScheme, appearance.colorScheme).frame(width: size.width, height: size.height)
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
        var preview: PersonalAgentPreviewFile? = try .init(download: .init(data: Data("A draft attachment for preview.".utf8), name: "../../release-draft.txt"))
        let url = try XCTUnwrap(preview?.url)
        XCTAssertEqual(url.lastPathComponent, "release-draft.txt")
        let attachmentCaptures = try WindowlessRender.hostedInBothAppearances("attachment", in: directory, size: size, passes: 80) { appearance in
            PersonalAgentAttachmentPreview(file: preview!, close: {})
                .environment(\.colorScheme, appearance.colorScheme).frame(width: size.width, height: size.height)
        }
        for capture in attachmentCaptures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
        preview = nil
        // The hosting view may briefly retain the preview; it owns the temporary copy.
    }

    /// A model with one coding task that shows in a rendered window.
    private func makeWindowModel(more: (URL) throws -> [SessionRecord] = { _ in [] }) throws -> (AppModel, SessionRecord) {
        let root = FileManager.default.temporaryDirectory.appending(path: "yardlet-personal-section-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("PersonalAgentShell")))
        let task = SessionRecord(harness: .codex, workspaceURL: root,
            runtimeExecutableURL: URL(filePath: "/usr/bin/true"), title: "Review the release draft")
        let sessions = [task] + (try more(root))
        let model = AppModel(
            store: SessionStore(sessions: sessions, repository: InMemorySessionRepository(sessions: sessions)),
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
        model.splits.activate(.session(task.id))
        return (model, task)
    }

    /// Whether a menu button titled `title` is under `view`. A menu names itself by its title, which
    /// `WindowlessRender.accessibilityElements` does not read once the label is empty.
    private static func hasMenu(titled title: String, in view: NSView) -> Bool {
        let attribute = "AXEnhancedUserInterface" as NSString
        _ = NSApplication.shared.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                                         with: NSNumber(value: true), with: attribute)
        defer {
            _ = NSApplication.shared.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                                             with: NSNumber(value: false), with: attribute)
        }
        func visit(_ node: AnyObject) -> Bool {
            for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                if (child.accessibilityRole?() ?? nil) == .menuButton, (child.accessibilityTitle?() ?? nil) == title { return true }
                if visit(child) { return true }
            }
            return false
        }
        return visit(view)
    }

    private static func press(_ label: String, in view: NSView) -> Bool {
        let attribute = "AXEnhancedUserInterface" as NSString
        _ = NSApplication.shared.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                                         with: NSNumber(value: true), with: attribute)
        defer {
            _ = NSApplication.shared.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                                             with: NSNumber(value: false), with: attribute)
        }
        func visit(_ node: AnyObject) -> AnyObject? {
            for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                if (child.accessibilityLabel?() ?? nil) == label { return child }
                if let found = visit(child) { return found }
            }
            return nil
        }
        return visit(view)?.accessibilityPerformPress?() ?? false
    }
}

/// Fixed agents, one page of messages and their details; sending and downloading are not part of
/// these renders. The picture is drawn here, not a provider's.
private actor RenderedPersonalAgentReader: PersonalAgentClient {
    let values: [PersonalAgent]
    let page: [PersonalAgentMessage]
    let older: [PersonalAgentMessage]
    private(set) var olderReads = 0
    init(agents: [PersonalAgent], messages: [PersonalAgentMessage], older: [PersonalAgentMessage] = []) {
        values = agents; page = messages; self.older = older
    }
    func agents() async throws -> [PersonalAgent] { values }
    func messages(for agent: PersonalAgent, before: String?) async throws -> PersonalAgentPage {
        guard before != nil else { return .init(messages: page, before: older.isEmpty ? nil : page.first?.id) }
        olderReads += 1
        return .init(messages: older, before: nil)
    }
    func updates(for agent: PersonalAgent) async -> AsyncStream<PersonalAgentUpdate> { AsyncStream { $0.finish() } }
    func send(_ submission: PersonalAgentSubmission, to agent: PersonalAgent) async throws -> PersonalAgentMessage {
        throw PersonalAgentFailure.invalidResponse
    }
    func download(_ attachment: PersonalAgentAttachment, for agent: PersonalAgent) async throws -> PersonalAgentDownload {
        throw PersonalAgentFailure.invalidResponse
    }
    private(set) var avatarReads = 0
    private(set) var sheetReads = 0
    func pet(_ id: String, for agent: PersonalAgent) async throws -> PersonalAgentPet? {
        .init(id: id, location: "https://files.oaiusercontent.com/example-sheet", version: "1|example")
    }
    func spriteSheet(_ pet: PersonalAgentPet, for agent: PersonalAgent) async throws -> Data {
        defer { sheetReads += 1 }
        return try PersonalAgentRenderingTests.syntheticSheet()
    }
    func avatar(for agent: PersonalAgent) async throws -> Data {
        defer { avatarReads += 1 }
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSGradient(starting: .systemTeal, ending: .systemIndigo)?.draw(in: NSBezierPath(ovalIn: rect), angle: 45)
            return true
        }
        guard let tiff = image.tiffRepresentation, let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { throw PersonalAgentFailure.attachmentUnavailable }
        return data
    }
    func activity(for agent: PersonalAgent, cursor: String?) async throws -> PersonalAgentActivityPage {
        .init(items: [
            .init(id: "a1", title: "Prepare the launch checklist", status: .running, outcome: .unknown,
                  updatedAt: Date().addingTimeInterval(-300), preview: nil),
            .init(id: "a2", title: "Summarize the review notes", status: .completed, outcome: .succeeded,
                  updatedAt: Date().addingTimeInterval(-7_200), preview: "The notes are summarized.")
        ], cursor: nil)
    }
    func schedules(for agent: PersonalAgent) async throws -> [PersonalAgentSchedule] { [] }
    func computers(for agent: PersonalAgent) async throws -> [PersonalAgentComputer] {
        [.init(id: "cloud", name: "Cloud computer", isCloud: true, isAttached: true, availability: .unknown),
         .init(id: "studio", name: "Studio Mac", isCloud: false, isAttached: true, availability: .offline)]
    }
    func stop() async {}
}
