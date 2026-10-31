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
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Personal agents")))
        let showsPersonalAgents = { host.accessibilityElements().contains { $0.label == "Dots" || $0.value == "Dots" } }
        await host.settle(until: showsPersonalAgents)
        try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "personal-section-window.png"))
        XCTAssertFalse(showsTaskRail(), "The hidden coding task's rail and panels stay off the personal-agent screen")
        // The selected task is hidden behind personal agents: its updates stay unread until Tasks come back.
        XCTAssertFalse(model.isSessionVisible(task.id))
        await model.store.markUnread(id: task.id)
        XCTAssertTrue(host.accessibilityElements().contains { $0.label == L10n.string("Scheduled tasks") })
        XCTAssertFalse(host.accessibilityElements().contains { $0.label == L10n.string("Back to tasks") })
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Tasks")))
        await host.settle(until: { !showsPersonalAgents() })
        XCTAssertTrue(showsTaskRail())
        try await waitUntil { model.store.sessions.first { $0.id == task.id }?.hasUnreadUpdate == false }
        XCTAssertTrue(model.isSessionVisible(task.id))
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Personal agents")))
        await host.settle(until: showsPersonalAgents)
        try await model.store.archiveSession(id: task.id)
        host.settle()
        XCTAssertTrue(showsPersonalAgents(),
                      "Removing the hidden coding task must not take over the personal-agent section.")
        model.showNewTaskFromMenuBar()
        await host.settle(until: { !showsPersonalAgents() })
        XCTAssertNil(model.store.selectedSessionID)
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Personal agents")))
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
            XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Personal agents")))
            await host.settle(until: { searchField() == nil })
            XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Tasks")))
            await host.settle(until: { list() != nil })
        }

        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: header))
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
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Personal agents")))
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
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Personal agents")))
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
                  attachments: [.init(fileID: "file", name: "announcement-draft.md", type: "file"),
                                .init(fileID: nil, name: "Launch brief", type: "link",
                                      url: URL(string: "https://example.com/launch-brief"))]),
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
                // Atlas's pet plays below, which it does only without Reduce Motion, whatever the Mac's own setting.
                let window = MainWindow(model: model) { reader }
                    .environment(\.personalAgentOriginalOpener, opener)
                    .environment(\.colorScheme, appearance.colorScheme)
                    .environment(\._accessibilityReduceMotion, false)
                    .frame(width: size.width, height: size.height)
                let host = WindowlessRender.Host(window, size: size, appearance: appearance)
                defer { host.close() }
                host.settle()
                let name = "\(Int(size.width))-\(appearance.suffix).png"
                try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "tasks-\(name)"))
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Personal agents")))
                await host.settle(until: { host.accessibilityElements().contains { $0.label == "announcement-draft.md" } })
                // The details and the picture arrive on their own after the conversation.
                let showsActivity = { host.accessibilityElements().contains { $0.label.contains("Prepare the launch checklist") } }
                // The Outputs read the root's work once shown: the report it cited and the chart it saved.
                let showsOutputs = { host.accessibilityElements().contains { $0.label == "launch-plan.pdf" } }
                if size.width >= 1280 { await host.settle(until: { showsActivity() && showsOutputs() }) }
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
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Open This Dot on the Web")))
                XCTAssertEqual(opened, [DotsLinks.web(for: agents[0])!])
                opened = []
                // A link the dot attached opens in the browser, from its message, not as a file.
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: "Launch brief"))
                XCTAssertEqual(opened, [URL(string: "https://example.com/launch-brief")!])
                opened = []
                let showsDetails = { host.accessibilityElements(visibleOnly: true).contains { $0.label == L10n.string("Dot details") } }
                if size.width >= 1280 {
                    XCTAssertTrue(showsDetails(), "A wide window keeps the dot's details beside the conversation")
                    for label in ["launch-plan.pdf", "launch-chart.png", "announcement-draft.md", L10n.string("Outputs")] {
                        XCTAssertTrue(visible.contains { $0.label == label }, "\(label) is among the Outputs at \(size)")
                    }
                    // A reading of a file that another dot's selection replaced shows nothing when it ends,
                    // and leaves the Outputs ready to open again.
                    if appearance == .light {
                        await reader.holdNextFile()
                        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: "launch-plan.pdf"))
                        try await waitUntil { await reader.hasPendingFile() }
                        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: "Juniper"))
                        await host.settle(until: { !host.accessibilityElements().contains { $0.label == "launch-plan.pdf" } })
                        await reader.releaseFile()
                        host.settle(passes: 12)
                        let refused = PersonalAgentFailure.verificationUnsupported.message
                        XCTAssertFalse(host.accessibilityElements().contains { $0.label == refused || $0.value == refused })
                        XCTAssertNil(host.window.attachedSheet)
                        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: "Atlas"))
                        await host.settle(until: showsOutputs)
                        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: "launch-plan.pdf"))
                        try await waitUntil { await reader.fileReads == 2 }
                        await host.settle(until: { host.accessibilityElements().contains { $0.label == refused || $0.value == refused } })
                    }
                } else {
                    // A compact window keeps the conversation's width; the details come over it on request.
                    XCTAssertFalse(showsDetails())
                    XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Show dot details")))
                    await host.settle(until: { showsActivity() && showsOutputs() })
                    host.settle(passes: 12)
                    try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "personal-details-\(name)"))
                    // The raised details close from their own button; the conversation and its editor stay.
                    XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Hide dot details")))
                    await host.settle(until: { !showsDetails() })
                    let after = host.accessibilityElements(visibleOnly: true)
                    XCTAssertTrue(after.contains { $0.label == L10n.string("Send message") })
                    XCTAssertTrue(after.contains { $0.label == L10n.string("Show dot details") })
                }
                // A page that could not be handed on says so under the conversation.
                webOpens = false
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Open This Dot on the Web")))
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
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Personal agents")))
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

    /// A task from the dot's Activity opens in place of the conversation and reads only its record:
    /// the newest turns first, earlier ones when asked, a failure where it happened. Going back finds
    /// the conversation where it was read, with its draft.
    func testAnActivityTaskReadsInPlaceOfTheConversation() async throws {
        let (model, _) = try makeWindowModel()
        let agents = [PersonalAgent(id: .init(accountID: "example", userID: "person", agentID: "dot", roomID: "room"),
                                    name: "Atlas", rootThreadID: "root", isPaused: false, isPrimary: true)]
        let conversation = (1...40).map { index in
            PersonalAgentMessage(id: "m\(index)", author: index.isMultiple(of: 2) ? .agent : .person,
                                 text: "Message \(index) about the launch plan.", createdAt: nil, isDeleted: false,
                                 attachments: index == 12 ? [.init(fileID: "f", name: "plan-notes.md", type: "file")] : [])
        }
        let task = "Prepare the launch checklist"
        let directory = try WindowlessRender.directory("personal-agent-activity-qa")
        for size in [NSSize(width: 1280, height: 800), NSSize(width: 920, height: 680)] {
            for appearance in WindowlessRender.Appearance.allCases {
                let reader = RenderedPersonalAgentReader(agents: agents, messages: conversation,
                    outputError: .init(stage: .contents, code: -32603, failure: .remoteFile))
                let host = WindowlessRender.Host(MainWindow(model: model) { reader }
                    .environment(\.colorScheme, appearance.colorScheme)
                    .frame(width: size.width, height: size.height), size: size, appearance: appearance)
                defer { host.close() }
                host.settle()
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Personal agents")))
                await host.settle(until: { host.accessibilityElements().contains { $0.label == L10n.string("Send message") } })
                let compact = size.width < 1280
                if compact { XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Show dot details"))) }
                await host.settle(until: { host.accessibilityElements().contains { $0.label == task } })
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: task))
                if compact {
                    XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Hide dot details")))
                }
                let back = L10n.format("Back to %@", "Atlas")
                await host.settle(until: { host.accessibilityElements().contains { $0.label == L10n.string("Load more history") } })
                // The newest turns' first items, each read on its own after the turns.
                let request = "Check launch item 12 and note what is left."
                await host.settle(until: { host.accessibilityElements().contains { $0.label.contains(request) || $0.value.contains(request) } })
                host.settle(passes: 20)
                let name = "\(Int(size.width))-\(appearance.suffix).png"
                var capture = try host.capture()
                XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6))
                try WindowlessRender.writePNG(capture.bitmap, to: directory.appending(path: "activity-initial-\(name)"))
                let visible = host.accessibilityElements(visibleOnly: true)
                XCTAssertTrue(visible.contains { $0.label == back }, "The way back is on screen at \(size)")
                // An output that does not open says why in the Outputs, where it was chosen, though the
                // task covers the conversation, and can be tried again there.
                do {
                    if compact { XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Show dot details"))) }
                    await host.settle(until: { host.accessibilityElements().contains { $0.label == "launch-plan.pdf" } })
                    XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: "launch-plan.pdf"))
                    let refused = PersonalAgentFailure.remoteFile.message
                    await host.settle(until: {
                        host.accessibilityElements(visibleOnly: true).contains { $0.label == refused || $0.value == refused }
                    })
                    host.settle(passes: 8)
                    let rows = Self.texts(in: host.hosting, of: host.window)
                    let fileRow = try XCTUnwrap(rows.first { $0.text == "launch-plan.pdf" })
                    let errorRow = try XCTUnwrap(rows.first { $0.text == refused })
                    let retryRow = try XCTUnwrap(rows.first { $0.text == L10n.string("Try again") })
                    let nextRow = try XCTUnwrap(rows.first { $0.text == "plan-notes.md" })
                    XCTAssertGreaterThanOrEqual(errorRow.frame.minY, fileRow.frame.maxY - 1)
                    XCTAssertGreaterThanOrEqual(retryRow.frame.minY, errorRow.frame.maxY - 1)
                    XCTAssertLessThanOrEqual(retryRow.frame.maxY, nextRow.frame.minY + 1,
                                             "The failure and retry stay below their file, before the next output")
                    try WindowlessRender.writePNG(try host.capture().bitmap, to: directory.appending(path: "activity-output-remote-error-\(name)"))
                    let reads = await reader.fileReads
                    XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Try again")))
                    try await waitUntil { await reader.fileReads == reads + 1 }
                    await host.settle(until: {
                        host.accessibilityElements(visibleOnly: true).contains { $0.label == refused || $0.value == refused }
                    })
                    XCTAssertNil(host.window.attachedSheet)
                    if !compact && appearance == .light {
                        // Newer results push the failed file past the initial three. It remains drawn
                        // with its retry, and Show more advances beyond that automatically revealed row.
                        let newMessage = PersonalAgentMessage(id: "new-outputs", author: .agent, text: "More results.",
                            createdAt: Date(), isDeleted: false, attachments: (1...3).map {
                                .init(fileID: "recent-\($0)", name: "recent-\($0).txt", type: "file")
                            })
                        await reader.setPage(conversation + [newMessage])
                        await reader.signalChange()
                        await host.settle(until: { host.accessibilityElements().contains { $0.label == "recent-3.txt" } })
                        let changed = host.accessibilityElements()
                        XCTAssertTrue(changed.contains { $0.label == "launch-plan.pdf" })
                        XCTAssertTrue(changed.contains { $0.label == refused || $0.value == refused })
                        XCTAssertFalse(changed.contains { $0.label == "plan-notes.md" })
                        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Show more")))
                        await host.settle(until: { host.accessibilityElements().contains { $0.label == "plan-notes.md" } })
                    }
                    if compact { XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Hide dot details"))) }
                }
                XCTAssertFalse(visible.contains { $0.label == L10n.string("Send message") }, "The record has no composer")
                // Earlier turns only when asked.
                let readsBefore = await reader.earlierTurnReads
                XCTAssertEqual(readsBefore, 0)
                ViewBodyCensus.reset()
                ViewBodyCensus.isEnabled = true
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Load more history")))
                try await waitUntil { await reader.earlierTurnReads == 1 }
                host.settle(passes: 30)
                ViewBodyCensus.isEnabled = false
                // The page and its turns' items draw the turns that arrived, not the ones already drawn.
                let redrawnTurns = ViewBodyCensus[.conversationTurn], timelines = ViewBodyCensus[.conversationTimeline]
                print("activity earlier page \(size) \(appearance): turns drawn \(redrawnTurns), timeline bodies \(timelines)")
                XCTAssertLessThanOrEqual(redrawnTurns, 12)
                capture = try host.capture()
                try WindowlessRender.writePNG(capture.bitmap, to: directory.appending(path: "activity-earlier-\(name)"))
                // A turn whose items fail says so; a task that cannot be read offers to try again.
                await reader.failHistory(items: ["t11"])
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Refresh task")))
                let partial = L10n.string("Some steps of this task could not be loaded.")
                await host.settle(until: { host.accessibilityElements().contains { $0.label == partial || $0.value == partial } })
                host.settle(passes: 20)
                try WindowlessRender.writePNG(try host.capture().bitmap, to: directory.appending(path: "activity-partial-\(name)"))
                await reader.failHistory(thread: true)
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Refresh task")))
                let failed = PersonalAgentFailure.unavailable.message
                await host.settle(until: { host.accessibilityElements().contains { $0.label == failed || $0.value == failed } })
                host.settle(passes: 12)
                try WindowlessRender.writePNG(try host.capture().bitmap, to: directory.appending(path: "activity-failed-\(name)"))
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: back))
                await host.settle(until: { host.accessibilityElements().contains { $0.label == L10n.string("Send message") } })
            }
        }
    }

    /// Reading a task and coming back leaves the conversation as it was: scrolled where the person
    /// read it, with the draft they were writing, its files, and the answer they were filling in.
    func testComingBackFromAnActivityTaskKeepsTheConversationsPlaceAndDraft() async throws {
        let (model, _) = try makeWindowModel()
        let agents = [PersonalAgent(id: .init(accountID: "example", userID: "person", agentID: "dot", roomID: "room"),
                                    name: "Atlas", rootThreadID: "root", isPaused: false, isPrimary: true)]
        var conversation = (1...60).map { index in
            PersonalAgentMessage(id: "m\(index)", author: index.isMultiple(of: 2) ? .agent : .person,
                                 text: "Message \(index) about the launch plan, long enough to take a line or two of the conversation.",
                                 createdAt: nil, isDeleted: false, attachments: [])
        }
        var form = PersonalAgentMessage(id: "form", author: .agent, text: "", createdAt: nil, isDeleted: false, attachments: [])
        form.inputRequest = try JSONDecoder().decode(JSONValue.self, from: Data(
            #"{"request_id":"form","thread_id":"thread","turn_id":null,"status":"pending","params":{"threadId":"thread","serverName":"codex_apps","mode":"form","message":"What should the team know?","requestedSchema":{"type":"object","properties":{"note":{"type":"string","title":"Note for the team","maxLength":80}},"required":[]},"_meta":null}}"#.utf8))
        conversation.append(form)
        // A thread whose reply asks a question of its own, answered in the replies dialog.
        conversation.append(PersonalAgentMessage(id: "venue-question", author: .agent, text: "Which venue should the launch use?",
                                                 createdAt: nil, isDeleted: false, attachments: []))
        var venue = PersonalAgentMessage(id: "venue", author: .agent, text: "", createdAt: nil, isDeleted: false, attachments: [])
        venue.replyToMessageID = "venue-question"
        venue.replyRootMessageID = "venue-question"
        venue.inputRequest = try JSONDecoder().decode(JSONValue.self, from: Data(
            #"{"request_id":"venue","thread_id":"thread","turn_id":null,"status":"pending","params":{"threadId":"thread","serverName":"codex_apps","mode":"form","message":"Where should it be?","requestedSchema":{"type":"object","properties":{"venue":{"type":"string","title":"Venue note","maxLength":80}},"required":[]},"_meta":null}}"#.utf8))
        conversation.append(venue)
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sources = [folder.appending(path: "plan-notes.txt"), folder.appending(path: "budget.csv")]
        for source in sources { try Data("synthetic".utf8).write(to: source) }
        let drafts = PersonalAgentDrafts()
        let reader = RenderedPersonalAgentReader(agents: agents, messages: conversation)
        let size = NSSize(width: 1280, height: 800)
        let host = WindowlessRender.Host(MainWindow(model: model, personalAgentDrafts: drafts) { reader }
            .frame(width: size.width, height: size.height), size: size)
        defer { host.close() }
        host.settle()
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Personal agents")))
        await host.settle(until: { host.accessibilityElements().contains { $0.label == "Prepare the launch checklist" } })
        host.settle(passes: 20)
        // Each field by the name it is read by; the composer is not whichever field comes first.
        let composerName = L10n.string("Message your dot…"), noteName = "Note for the team"
        func field(_ name: String) -> NSTextField? {
            Self.views(NSTextField.self, in: host.hosting).first {
                $0.isEditable && ($0.accessibilityLabel() == name || $0.placeholderString == name)
            }
        }
        // Typed into the render's own window, which is never the person's key window.
        func type(_ text: String, into field: NSTextField) throws {
            XCTAssertTrue(host.window.makeFirstResponder(field))
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.insertText(text, replacementRange: editor.selectedRange())
            host.settle(passes: 6)
        }
        await host.settle(until: { field(noteName) != nil })
        try type("Share the draft on Monday.", into: try XCTUnwrap(field(noteName)))
        // Files the draft holds: one uploaded, one still uploading. Nothing is picked or sent.
        let draft = try XCTUnwrap(drafts.opened.first)
        let ids = await draft.addFiles(sources.map { .init(url: $0) })
        XCTAssertEqual(ids.count, 2)
        let uploaded = PersonalAgentUploadedFile(fileID: "file-kept", name: "plan-notes.txt", mimeType: "text/plain", sizeBytes: 9)
        draft.setState(ids[0], .uploaded(uploaded))
        draft.setState(ids[1], .uploading)
        let states = draft.files.map(\.state)
        let chips = ["plan-notes.txt", "budget.csv, " + L10n.string("Uploading")]
        await host.settle(until: { chips.allSatisfy { chip in host.accessibilityElements().contains { $0.label == chip } } })
        let composer = try XCTUnwrap(field(composerName))
        try type("Keep this draft while I read the task.", into: composer)

        func conversationScroll() throws -> NSScrollView {
            try XCTUnwrap(Self.scrollViews(in: host.hosting).max {
                ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
            })
        }
        func wheel(_ amount: Int32, times: Int, in scroll: NSScrollView) {
            for _ in 0..<times {
                guard let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0),
                      let event = NSEvent(cgEvent: wheel) else { break }
                scroll.scrollWheel(with: event)
                host.settle(passes: 1)
            }
            host.settle(passes: 20)
        }
        let scroll = try conversationScroll()
        wheel(160, times: 6, in: scroll)
        let readAt = scroll.documentVisibleRect.minY
        let bottom = (scroll.documentView?.frame.height ?? 0) - scroll.documentVisibleRect.height
        XCTAssertGreaterThan(abs(bottom - readAt), 200, "The conversation is read away from its end")
        let before = try host.capture()
        // Opened while the person is still writing: the covered editor stops taking their typing.
        XCTAssertTrue(host.window.makeFirstResponder(composer))
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: "Prepare the launch checklist"))
        let back = L10n.format("Back to %@", "Atlas")
        await host.settle(until: { host.accessibilityElements().contains { $0.label == back } })
        host.settle(passes: 12)
        XCTAssertFalse(composer.isEnabled, "The conversation under the task takes no input")
        let responder = host.window.firstResponder
        XCTAssertFalse(responder === composer || (responder as? NSText)?.delegate === composer,
                       "The covered editor is not where typing goes")
        XCTAssertFalse(host.accessibilityElements().contains { $0.label == L10n.string("Send message") })
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: back))
        await host.settle(until: { host.accessibilityElements().contains { $0.label == L10n.string("Send message") } })
        host.settle(passes: 30)
        let returned = try conversationScroll()
        XCTAssertEqual(returned.documentVisibleRect.minY, readAt, accuracy: 2, "The conversation is where it was read")
        XCTAssertEqual(try XCTUnwrap(field(composerName)).stringValue, "Keep this draft while I read the task.")
        XCTAssertTrue(drafts.opened.first === draft)
        XCTAssertEqual(draft.files.map(\.id), ids)
        XCTAssertEqual(draft.files.map(\.state), states, "The files and their uploads are as they were")
        for chip in chips { XCTAssertTrue(host.accessibilityElements().contains { $0.label == chip }, chip) }
        let directory = try WindowlessRender.directory("personal-agent-activity-qa")
        try WindowlessRender.writePNG(before.bitmap, to: directory.appending(path: "conversation-before-activity.png"))
        try WindowlessRender.writePNG(try host.capture().bitmap, to: directory.appending(path: "conversation-after-activity.png"))
        // The answer being filled in is still there below.
        wheel(-400, times: 30, in: returned)
        await host.settle(until: { field(noteName) != nil })
        XCTAssertEqual(try XCTUnwrap(field(noteName)).stringValue, "Share the draft on Monday.")

        // The replies dialog open over the composer, its question's answer being typed: the task covers
        // both, the dialog takes no key, press or assistive action meanwhile, and comes back as it was.
        let close = L10n.string("Close replies"), venueName = "Venue note"
        XCTAssertTrue(Self.performCustomAction(L10n.string("Reply"), onElementContaining: "Which venue should the launch use?",
                                               in: host.hosting))
        await host.settle(until: { host.accessibilityElements().contains { $0.label == close } })
        let table = try XCTUnwrap(Self.views(PersonalAgentReplyTableView.self, in: host.hosting).first)
        func venueField() -> NSTextField? {
            Self.views(NSTextField.self, in: table).first {
                $0.isEditable && ($0.accessibilityLabel() == venueName || $0.placeholderString == venueName)
            }
        }
        await host.settle(until: { venueField() != nil })
        try type("Book the hall on the river.", into: try XCTUnwrap(venueField()))
        let typing = try XCTUnwrap(venueField())
        XCTAssertTrue(host.window.firstResponder === typing.currentEditor(), "The answer in the dialog is being typed")
        let composing = try XCTUnwrap(field(composerName)).stringValue
        let monitor = try XCTUnwrap(Self.views(PersonalAgentReplyPanelMonitor.MonitorView.self, in: host.hosting).first)
        // The thread read to its start, and the heights the list measured meanwhile told to it.
        await host.settle(until: { !Self.views(PersonalAgentReplyRowView.self, in: table).contains { $0.entry == .earlier } })
        await Task.yield()
        host.settle(passes: 6)
        let dialogBefore = try host.capture()
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: "Prepare the launch checklist"))
        await host.settle(until: { host.accessibilityElements().contains { $0.label == back } })
        host.settle(passes: 12)
        let dialogCovered = try host.capture()
        let covered = try XCTUnwrap(venueField(), "The dialog's rows stay under the task")
        XCTAssertFalse(covered.isEnabled, "The dialog's answer under the task takes no input")
        let typingTo = host.window.firstResponder
        XCTAssertFalse(typingTo === covered || (typingTo as? NSText)?.delegate === covered, "The covered answer is not where typing goes")
        XCTAssertFalse(host.accessibilityElements().contains {
            $0.label == close || $0.label == venueName || $0.value.contains("Book the hall")
        }, "Assistive apps read the task, not the dialog under it")
        // A press on the task is not a press outside the dialog.
        let pressOnTask = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 120, y: 15),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        monitor.observe(pressOnTask)
        // The dialog closes, if it does, once the main queue runs again: nothing to wait for but time.
        try await Task.sleep(for: .milliseconds(200))
        host.settle(passes: 6)
        XCTAssertFalse(Self.views(PersonalAgentReplyTableView.self, in: host.hosting).isEmpty, "The dialog stays open under the task")
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: back))
        await host.settle(until: { host.accessibilityElements().contains { $0.label == L10n.string("Send message") } })
        host.settle(passes: 12)
        XCTAssertTrue(host.accessibilityElements().contains { $0.label == close }, "The dialog is still open")
        let answer = try XCTUnwrap(venueField())
        XCTAssertTrue(answer.isEnabled, "The dialog takes input again")
        XCTAssertEqual(answer.stringValue, "Book the hall on the river.")
        XCTAssertEqual(try XCTUnwrap(field(composerName)).stringValue, composing)
        XCTAssertTrue(drafts.opened.first === draft)
        XCTAssertEqual(draft.files.map(\.state), states, "The files and their uploads are as they were")
        try WindowlessRender.writePNG(dialogBefore.bitmap, to: directory.appending(path: "replies-before-activity.png"))
        try WindowlessRender.writePNG(dialogCovered.bitmap, to: directory.appending(path: "replies-under-activity.png"))
        try WindowlessRender.writePNG(try host.capture().bitmap, to: directory.appending(path: "replies-after-activity.png"))
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
        // Pets play only without Reduce Motion, whatever the Mac's own setting.
        let host = WindowlessRender.Host(MainWindow(model: model) { reader }
            .environment(\._accessibilityReduceMotion, false)
            .frame(width: size.width, height: size.height), size: size)
        defer { host.close() }
        host.settle()
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Personal agents")))
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

        // A task from the Activity covers the conversation: its header's pet holds still, the others play.
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: "Prepare the launch checklist"))
        await host.settle(until: { Self.views(PersonalAgentSpriteView.self, in: host.hosting).count == 2 })
        let shownWithTask = Self.views(PersonalAgentSpriteView.self, in: host.hosting)
        XCTAssertTrue(shownWithTask.allSatisfy { view in pets.contains { $0 === view } && view.isPlaying })
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.format("Back to %@", "Atlas")))
        await host.settle(until: { Self.views(PersonalAgentSpriteView.self, in: host.hosting).count == 3 })
    }

    /// A dot at work plays its working row where its name is: in the list, the conversation's header
    /// and its details, while each message's picture stays still, as every picture does with Reduce
    /// Motion. The header says what the dot is doing. The window is not shown, so the room is told it
    /// is; a repeated working state does not restart the row.
    func testADotAtWorkPlaysItsWorkingRowWhereItsNameIs() async throws {
        try await renderDotAtWork(size: NSSize(width: 1280, height: 920), reduceMotion: [false, true])
    }

    /// In a compact window the details are not beside the conversation: the header and the list play
    /// the working row, and the header keeps its words beside its buttons.
    func testADotAtWorkInACompactWindow() async throws {
        try await renderDotAtWork(size: NSSize(width: 920, height: 680), reduceMotion: [false])
    }

    /// A room reports its work again and again; in a long conversation each new heading redraws the
    /// words in the header, and neither the conversation, its messages, the window nor any picture.
    func testANewHeadingRedrawsOnlyItsWordsInALongConversation() async throws {
        let (model, _) = try makeWindowModel()
        let agent = PersonalAgent(id: .init(accountID: "example", userID: "person", agentID: "dot", roomID: "room"),
                                  name: "Atlas", rootThreadID: "root", isPaused: false, isPrimary: true,
                                  avatar: .init(location: "https://files.oaiusercontent.com/example-avatar", version: "v1"),
                                  petID: "pet")
        let live = PersonalAgentLiveState(roomID: "room", subscriptionID: "subscription", revision: 1, threads: [
            .init(threadID: "root", streamState: .attached, turnID: "turn", turnStatus: .inProgress, isActive: true,
                  computerStatus: nil, activityType: "Working", activityLabel: "Reading the notes")])
        let messages = (0..<400).map { index in
            PersonalAgentMessage(id: "m\(index)", author: index.isMultiple(of: 2) ? .person : .agent,
                                 text: "Message \(index) of a long conversation about the launch.",
                                 createdAt: nil, isDeleted: false, attachments: [])
        }
        let shownBefore = PersonalAgentWindowVisibility.ReportingView.isOnScreen
        PersonalAgentWindowVisibility.ReportingView.isOnScreen = { _ in true }
        defer { PersonalAgentWindowVisibility.ReportingView.isOnScreen = shownBefore }
        ViewBodyCensus.isEnabled = true
        ViewBodyCensus.reset()
        defer { ViewBodyCensus.isEnabled = false; ViewBodyCensus.reset() }
        let size = NSSize(width: 1280, height: 920)
        let reader = RenderedPersonalAgentReader(agents: [agent], messages: messages, live: live)
        // The pictures play, as they do only without Reduce Motion, whatever the Mac's own setting.
        let host = WindowlessRender.Host(MainWindow(model: model) { reader }
            .environment(\._accessibilityReduceMotion, false)
            .frame(width: size.width, height: size.height), size: size)
        defer { host.close() }
        host.settle()
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Personal agents")))
        let shows = { (words: String) in host.accessibilityElements().contains { $0.label == words || $0.value == words } }
        await host.settle(until: { shows("Reading the notes") })
        try await waitUntil { await reader.sheetReads > 0 }
        await host.settle(until: { Self.views(PersonalAgentSpriteView.self, in: host.hosting).count == 3 })
        host.settle(passes: 12)
        // The counts are read where they are drawn: the content and the conversation, with the details
        // open beside it, were drawn to show at all.
        XCTAssertTrue(host.accessibilityElements().contains { $0.label == L10n.string("Dot details") })
        XCTAssertGreaterThan(ViewBodyCensus[.personalAgentContent], 0)
        XCTAssertGreaterThan(ViewBodyCensus[.personalAgentConversation], 0)
        XCTAssertGreaterThan(ViewBodyCensus[.personalAgentStatus], 0)
        await host.settle(until: { host.accessibilityElements().contains { $0.label == "launch-plan.pdf" } })
        XCTAssertGreaterThan(ViewBodyCensus[.personalAgentOutputs], 0)
        host.settle(passes: 6)

        ViewBodyCensus.reset()
        let headings = ["Checking the dates", "Comparing the drafts", "Writing the summary", "Reviewing the list",
                        "Sending nothing yet"]
        for heading in headings {
            await reader.repeatLive(label: heading)
            await host.settle(until: { shows(heading) })
            XCTAssertTrue(shows(heading), "The header shows \(heading)")
        }
        host.settle(passes: 6)
        XCTAssertGreaterThanOrEqual(ViewBodyCensus[.personalAgentStatus], headings.count, "Each heading drew the words")
        XCTAssertEqual(ViewBodyCensus[.personalAgentContent], 0, "A new heading drew the content again")
        XCTAssertEqual(ViewBodyCensus[.personalAgentConversation], 0, "A new heading drew the conversation again")
        XCTAssertEqual(ViewBodyCensus[.personalAgentOutputs], 0, "A new heading drew the Outputs again")
        XCTAssertEqual(ViewBodyCensus[.mainWindow], 0, "A new heading drew the window again")
        XCTAssertEqual(ViewBodyCensus[.personalAgentAvatar], 0, "A new heading with the same motion drew a picture again")
    }

    /// The Replies dialog opens over the composer from a message's replies in a long conversation and
    /// reads its thread there without drawing the conversation again. The draft's words and files and
    /// the room's place stay through opening and closing, and Escape closes it, except while an input
    /// method still composes a character.
    func testRepliesOpenOverTheComposerAndLeaveTheConversationAndDraftAsTheyWere() async throws {
        let (model, _) = try makeWindowModel()
        let agent = PersonalAgent(id: .init(accountID: "example", userID: "person", agentID: "dot", roomID: "room"),
                                  name: "Atlas", rootThreadID: nil, isPaused: false, isPrimary: true)
        func message(_ id: String, _ author: PersonalAgentMessage.Author, _ text: String, parent: String? = nil) -> PersonalAgentMessage {
            var value = PersonalAgentMessage(id: id, author: author, text: text, createdAt: nil, isDeleted: false, attachments: [])
            value.replyToMessageID = parent
            value.replyRootMessageID = parent == nil ? nil : "q"
            return value
        }
        var messages = (0..<396).map { index in
            message("m\(index)", index.isMultiple(of: 2) ? .person : .agent, "Message \(index) of a long conversation about the launch.")
        }
        messages += [message("q", .agent, "Which launch date should I put in the announcement?"),
                     message("m396", .person, "Also keep the press list as it is."),
                     message("a1", .person, "Keep the date we agreed in the review.", parent: "q"),
                     message("m397", .agent, "The press list stays as it is."),
                     message("a2", .agent, "The review agreed on the fourteenth. I will use that date.", parent: "a1"),
                     message("m398", .person, "Thanks."), message("m399", .agent, "You are welcome.")]
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let form = folder.appending(path: "launch-checklist.pdf")
        try Data("%PDF-1.4 synthetic".utf8).write(to: form)
        let count = PersonalAgentReplyIndicator.title(2)
        let close = L10n.string("Close replies")
        let directory = try WindowlessRender.directory("dots-replies-qa")
        defer { ViewBodyCensus.isEnabled = false; ViewBodyCensus.reset() }
        for size in [NSSize(width: 1280, height: 920), NSSize(width: 920, height: 680)] {
            for appearance in WindowlessRender.Appearance.allCases {
                let drafts = PersonalAgentDrafts()
                let reader = RenderedPersonalAgentReader(agents: [agent], messages: messages)
                let window = MainWindow(model: model, personalAgentDrafts: drafts) { reader }
                    .environment(\.colorScheme, appearance.colorScheme)
                    .frame(width: size.width, height: size.height)
                let host = WindowlessRender.Host(window, size: size, appearance: appearance)
                defer { host.close() }
                host.settle()
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Personal agents")))
                let shows = { (label: String) in host.accessibilityElements().contains { $0.label == label } }
                await host.settle(until: { shows(count) })
                let draft = try XCTUnwrap(drafts.opened.first)
                let words = "현장 확인 뒤에 날짜를 정하겠습니다."
                draft.editor.text = words
                let ids = await draft.addFiles([.init(url: form)])
                draft.setState(try XCTUnwrap(ids.first),
                               .uploaded(.init(fileID: "file", name: "launch-checklist.pdf", mimeType: "application/pdf", sizeBytes: 18)))
                host.settle(passes: 12)
                // The room is read a little way above its end; that place is kept.
                let scroll = try XCTUnwrap(Self.scrollViews(in: host.hosting).max {
                    ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
                })
                for _ in 0..<3 {
                    guard let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 60, wheel2: 0, wheel3: 0),
                          let event = NSEvent(cgEvent: wheel) else { break }
                    scroll.scrollWheel(with: event)
                    host.settle(passes: 1)
                }
                host.settle(passes: 12)
                let place = scroll.contentView.bounds.origin.y

                ViewBodyCensus.isEnabled = true
                ViewBodyCensus.reset()
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: count))
                await host.settle(until: { shows(close) })
                try await waitUntil { await reader.replyReads > 0 }
                host.settle(passes: 20)
                XCTAssertEqual(ViewBodyCensus[.personalAgentConversation], 0, "Opening the thread drew the conversation again")
                XCTAssertEqual(ViewBodyCensus[.mainWindow], 0, "Opening the thread drew the window again")
                let focused = try XCTUnwrap(host.window.firstResponder as? NSTextView, "The dialog's composer takes focus")
                XCTAssertEqual(focused.string, words)
                XCTAssertEqual(focused.selectedRange(), NSRange(location: (words as NSString).length, length: 0),
                               "Focus does not select the draft for the next key to replace")
                let capture = try host.capture()
                XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6))
                try WindowlessRender.writePNG(capture.bitmap,
                    to: directory.appending(path: "replies-\(Int(size.width))-\(appearance.suffix).png"))
                let visible = host.accessibilityElements(visibleOnly: true)
                for label in [close, L10n.string("Send message"), "launch-checklist.pdf"] {
                    XCTAssertTrue(visible.contains { $0.label == label }, "\(label) is on screen at \(size)")
                }
                XCTAssertTrue(visible.contains { $0.label.contains("The review agreed on the fourteenth") || $0.value.contains("The review agreed on the fourteenth") })
                XCTAssertEqual(draft.editor.text, words)
                XCTAssertEqual(draft.files.map(\.id), ids)
                XCTAssertEqual(scroll.contentView.bounds.origin.y, place, accuracy: 1, "The room behind keeps its place")

                // Escape while an input method composes belongs to it; the next one closes the dialog.
                let field = try XCTUnwrap(Self.views(NSTextField.self, in: host.hosting).first {
                    $0.isEditable && $0.placeholderString == L10n.string("Message your dot…")
                })
                XCTAssertTrue(host.window.makeFirstResponder(field))
                host.settle(passes: 4)
                let editor = try XCTUnwrap(host.window.firstResponder as? NSTextView)
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                editor.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
                try pressEscape(in: host)
                XCTAssertTrue(shows(close), "An Escape the input method takes leaves the dialog open")
                editor.insertText("", replacementRange: editor.markedRange())
                host.settle(passes: 4)
                try pressEscape(in: host)
                await host.settle(until: { !shows(close) })
                XCTAssertFalse(shows(close))
                host.settle(passes: 12)
                XCTAssertEqual(draft.editor.text, words, "Closing keeps the words")
                XCTAssertEqual(draft.files.map(\.id), ids, "Closing keeps the files")
                XCTAssertEqual(scroll.contentView.bounds.origin.y, place, accuracy: 1)
                XCTAssertEqual(ViewBodyCensus[.personalAgentConversation], 0, "Closing the thread drew the conversation again")
                XCTAssertTrue(shows(count), "The room's indicator stays")
                let sends = await reader.sends
                XCTAssertTrue(sends.isEmpty, "Opening, reading and closing send nothing")
                ViewBodyCensus.isEnabled = false
            }
        }
    }

    /// Every message a dot sends says when it was sent, also one that follows another of the dot's, in the
    /// room and in its Replies: just above the words, with its day including today, and nothing
    /// when the provider gave no time. The dot's name and picture stay on the first of a run.
    func testEachMessageOfADotSaysWhenItWasSentInTheRoomAndInReplies() async throws {
        let (model, _) = try makeWindowModel()
        let agent = PersonalAgent(id: .init(accountID: "example", userID: "person", agentID: "dot", roomID: "room"),
                                  name: "Atlas", rootThreadID: nil, isPaused: false, isPrimary: true)
        let today = Calendar.current.startOfDay(for: Date())
        func at(_ minutes: Int) -> Date { today.addingTimeInterval(Double(minutes) * 60) }
        func message(_ id: String, _ author: PersonalAgentMessage.Author, _ text: String, _ sent: Date?,
                     parent: String? = nil) -> PersonalAgentMessage {
            var value = PersonalAgentMessage(id: id, author: author, text: text, createdAt: sent, isDeleted: false, attachments: [])
            value.replyToMessageID = parent
            value.replyRootMessageID = parent == nil ? nil : "q"
            return value
        }
        let long = "The deposit clause asks for three months up front, which is more than the usual two. "
            + "The repair terms leave the boiler and the roof to us, and the notice period runs for ninety days. "
            + "I have marked each of these in the draft so the landlord can answer them in one reply."
        let messages = [
            message("d1", .agent, "I read the contract draft last night.", at(-120)),
            message("q", .agent, "Which clause should I raise with the landlord first?", at(9 * 60)),
            message("p1", .person, "Start with the deposit.", at(9 * 60 + 2)),
            message("r1", .agent, "The deposit clause comes first, then the repair terms.", at(9 * 60 + 3), parent: "q"),
            message("d2", .agent, long, at(9 * 60 + 5)),
            message("d3", .agent, "This note came without a time.", nil),
            message("r2", .agent, "I will draft the deposit question now.", at(9 * 60 + 7), parent: "r1"),
            message("r3", .agent, "This reply came without a time.", nil, parent: "r2"),
            message("p2", .person, "Thanks.", at(9 * 60 + 10))
        ]
        func time(_ minutes: Int) -> String {
            let date = at(minutes)
            return Calendar.current.isDateInToday(date)
                ? L10n.format("Today %@", date.formatted(date: .omitted, time: .shortened))
                : date.formatted(date: .abbreviated, time: .shortened)
        }
        let directory = try WindowlessRender.directory("dots-message-times-qa")
        for size in [NSSize(width: 1280, height: 920), NSSize(width: 920, height: 680)] {
            for appearance in WindowlessRender.Appearance.allCases {
                let reader = RenderedPersonalAgentReader(agents: [agent], messages: messages)
                let window = MainWindow(model: model) { reader }
                    .environment(\.colorScheme, appearance.colorScheme)
                    .frame(width: size.width, height: size.height)
                let host = WindowlessRender.Host(window, size: size, appearance: appearance)
                defer { host.close() }
                host.settle()
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Personal agents")))
                let count = PersonalAgentReplyIndicator.title(3)
                let shows = { (text: String) in host.accessibilityElements().contains { $0.label == text || $0.value == text } }
                await host.settle(until: { shows(count) && shows(time(9 * 60 + 5)) })
                host.settle(passes: 12)
                let name = "\(Int(size.width))-\(appearance.suffix).png"
                try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "room-\(name)"))

                // The room: d1 and r1 start a run; q (on a new day), d2 and r2 follow and keep their own time,
                // each between the message before and its own words.
                let room = try XCTUnwrap(Self.scrollViews(in: host.hosting).max {
                    ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
                })
                var rows = Self.texts(in: room, of: host.window)
                let sent: [(previous: String, text: String, time: String)] = [
                    ("I read the contract draft", "Which clause should I raise", time(9 * 60)),
                    ("Start with the deposit.", "The deposit clause comes first", time(9 * 60 + 3)),
                    ("The deposit clause comes first", "The deposit clause asks", time(9 * 60 + 5)),
                    ("This note came without a time.", "I will draft the deposit question", time(9 * 60 + 7))
                ]
                XCTAssertTrue(rows.contains { $0.text == time(-120) }, "Yesterday's message shows its day at \(size)")
                for (previous, text, label) in sent {
                    try Self.assertTime(label, between: previous, and: text, in: rows, at: size)
                }
                try Self.assertNothing(between: "The deposit clause asks", and: "This note came without a time.", in: rows)
                try Self.assertNothing(between: "I will draft the deposit question", and: "This reply came without a time.",
                                       in: rows)

                // Replies draws the thread with the same rows: q starts it, r1 and r2 follow with their times.
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: count))
                await host.settle(until: { shows(L10n.string("Close replies")) })
                try await waitUntil { await reader.replyReads > 0 }
                await host.settle(until: {
                    Self.views(PersonalAgentReplyTableView.self, in: host.hosting).first.map {
                        Self.texts(in: $0, of: host.window).contains { $0.text.hasPrefix("This reply came without a time.") }
                    } ?? false
                })
                host.settle(passes: 20)
                try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "replies-\(name)"))
                let table = try XCTUnwrap(Self.views(PersonalAgentReplyTableView.self, in: host.hosting).first)
                rows = Self.texts(in: table, of: host.window)
                try Self.assertTime(time(9 * 60 + 3), between: "Which clause should I raise",
                                    and: "The deposit clause comes first", in: rows, at: size)
                try Self.assertTime(time(9 * 60 + 7), between: "The deposit clause comes first",
                                    and: "I will draft the deposit question", in: rows, at: size)
                try Self.assertNothing(between: "I will draft the deposit question", and: "This reply came without a time.",
                                       in: rows)
            }
        }
    }

    /// The texts of the accessibility tree under `root`, each with its frame from `window`'s top-left.
    private static func texts(in root: NSView, of window: NSWindow) -> [(text: String, frame: NSRect)] {
        root.layoutSubtreeIfNeeded()
        return WindowlessRender.withAccessibilityTree {
            var found: [(text: String, frame: NSRect)] = []
            func visit(_ node: AnyObject) {
                for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                    let label = (child.accessibilityLabel?() ?? nil) ?? ""
                    let value = ((child.accessibilityValue?() as Any??) ?? nil) as? String ?? ""
                    if let screen = child.accessibilityFrame?(), screen.height > 0, !(label + value).isEmpty {
                        found.append((label.isEmpty ? value : label,
                                      NSRect(x: screen.minX - window.frame.minX, y: window.frame.maxY - screen.maxY,
                                             width: screen.width, height: screen.height)))
                    }
                    visit(child)
                }
            }
            visit(root)
            return found
        }
    }

    /// `time` is shown below the words that start with `previous` and above those that start with `text`.
    private static func assertTime(_ time: String, between previous: String, and text: String,
                                   in rows: [(text: String, frame: NSRect)], at size: NSSize, line: UInt = #line) throws {
        let top = try XCTUnwrap(rows.first { $0.text.hasPrefix(previous) }, "“\(previous)” at \(size)", line: line)
        let words = try XCTUnwrap(rows.first { $0.text.hasPrefix(text) }, "“\(text)” at \(size)", line: line)
        XCTAssertTrue(rows.contains { $0.text == time && $0.frame.minY >= top.frame.maxY - 1 && $0.frame.maxY <= words.frame.minY + 1 },
                      "\(time) above “\(text)” at \(size): \(rows.map(\.text))", line: line)
    }

    /// No text lies between the words that start with `upper` and those that start with `lower`.
    private static func assertNothing(between upper: String, and lower: String, in rows: [(text: String, frame: NSRect)],
                                      line: UInt = #line) throws {
        let top = try XCTUnwrap(rows.first { $0.text.hasPrefix(upper) }, line: line)
        let bottom = try XCTUnwrap(rows.first { $0.text.hasPrefix(lower) }, line: line)
        let between = rows.filter { $0.frame.minY >= top.frame.maxY - 1 && $0.frame.maxY <= bottom.frame.minY + 1 }
        XCTAssertTrue(between.isEmpty, "Nothing above “\(lower)”: \(between.map(\.text))", line: line)
    }

    /// A long thread opens at its end and reads nothing earlier until its top is scrolled into view, then
    /// once, keeping the reply being read in place; a reply that arrives while the person reads above
    /// offers New replies without moving, and one that arrives at the end is followed. Closed by its
    /// button or Escape, the dialog gives focus back where it was; closed by a press outside, it leaves
    /// focus with what that press chose. A reply's quote and the row's Reply action open their threads.
    func testALongThreadReadsEarlierRepliesAtItsTopAndFollowsNewOnesOnlyAtItsEnd() async throws {
        let (model, _) = try makeWindowModel()
        let agent = PersonalAgent(id: .init(accountID: "example", userID: "person", agentID: "dot", roomID: "room"),
                                  name: "Atlas", rootThreadID: nil, isPaused: false, isPrimary: true)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        func message(_ id: String, _ author: PersonalAgentMessage.Author, _ text: String, minute: Int,
                     parent: String? = nil, root: String = "q") -> PersonalAgentMessage {
            var value = PersonalAgentMessage(id: id, author: author, text: text, createdAt: start.addingTimeInterval(Double(minute) * 60),
                                             isDeleted: false, attachments: [])
            value.replyToMessageID = parent
            value.replyRootMessageID = parent == nil ? nil : root
            return value
        }
        // Replies of different lengths: a line, two, or a paragraph with a list.
        func words(_ first: String, _ index: Int) -> String {
            switch index % 3 {
            case 0: first + "\n\nIt needs the press list, the venue and the stream settled first:\n\n- Press list\n- Venue\n- Stream"
            case 1: first
            default: first + " The venue has confirmed the room, and the stream needs one more check before the date can be final."
            }
        }
        func reply(_ index: Int) -> PersonalAgentMessage {
            message("r\(index)", index.isMultiple(of: 2) ? .agent : .person,
                    words("Reply \(index) in the thread about the launch date.", index), minute: 100 + index,
                    parent: index == 1 ? "q" : "r\(index - 1)")
        }
        func step(_ index: Int) -> PersonalAgentMessage {
            message("s\(index)", index.isMultiple(of: 2) ? .agent : .person, words("Step \(index) of the plan.", index),
                    minute: 300 + index, parent: index == 1 ? "q2" : "s\(index - 1)", root: "q2")
        }
        var latestReply = reply(40)
        latestReply.replyPreview = .init(messageID: "r39", text: "Reply 39 in the thread about the launch date.",
                                         hasAttachments: false, isDeleted: false)
        let room = [message("m1", .person, "Please draft the announcement.", minute: 1),
                    message("q", .agent, "Which launch date should I put in the announcement?", minute: 2),
                    message("m2", .person, "Also keep the press list as it is.", minute: 3),
                    message("q2", .agent, """
                        Launch plan overview, for the review on Thursday.

                        The second part of the plan covers the venue, the guest list and the order of the talks, \
                        which the team agreed last week and which only the venue can still change.

                        The third part covers the stream: who runs it, which cameras it uses and how the recording \
                        reaches the press afterwards.

                        The fourth part covers the announcement itself and the press list that receives it.
                        """, minute: 4),
                    latestReply]
        let reader = RenderedPersonalAgentReader(agents: [agent], messages: room)
        await reader.setThreadPages(["": .init(messages: (21...40).map(reply), before: "c1"),
                                     "c1": .init(messages: (1...20).map(reply), before: nil)])
        await reader.setThreadPages(["": .init(messages: (21...40).map(step), before: "d1"),
                                     "d1": .init(messages: (1...20).map(step), before: nil)], root: "q2")
        let drafts = PersonalAgentDrafts()
        let size = NSSize(width: 920, height: 680)
        let host = WindowlessRender.Host(MainWindow(model: model, personalAgentDrafts: drafts) { reader }
            .frame(width: size.width, height: size.height), size: size)
        defer { host.close() }
        host.settle()
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Personal agents")))
        let labels = { host.accessibilityElements().map(\.label) }
        let shows = { (text: String) in host.accessibilityElements(visibleOnly: true).contains { $0.label.contains(text) || $0.value.contains(text) } }
        let indicators = Set([PersonalAgentReplyIndicator.title(nil)] + (0...60).map { PersonalAgentReplyIndicator.title($0) })
        let openThread = { host.hosting.pressAccessibilityElement(labelled: try XCTUnwrap(labels().first { indicators.contains($0) })) }
        let close = L10n.string("Close replies")
        await host.settle(until: { labels().contains { indicators.contains($0) } })
        // The dialog's list: a row for every reply read, a view only for those in view.
        let replyTable = { Self.views(NSTableView.self, in: host.hosting).first }

        // Opened at its end: nothing earlier is read.
        XCTAssertTrue(try openThread())
        await host.settle(until: { (replyTable()?.numberOfRows ?? 0) >= 21 })
        host.settle(passes: 30)
        var older = await reader.olderReplyReads
        XCTAssertEqual(older, 0, "A thread at its end reads nothing earlier")
        let panel = try XCTUnwrap(replyTable()?.enclosingScrollView)
        XCTAssertLessThan(Self.views(PersonalAgentReplyRowView.self, in: host.hosting).count, 21,
                          "Only the rows in view have views")
        let newReplies = L10n.string("New replies")

        // Reading a little above the end, a new reply moves nothing; New replies goes to it.
        // The wheel, as the person turns it, until well away from the end and not near the top.
        for _ in 0..<12 {
            let distance = (panel.documentView?.frame.height ?? 0) - panel.contentView.bounds.height - panel.contentView.bounds.origin.y
            guard distance < 250 else { break }
            guard let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 60, wheel2: 0, wheel3: 0),
                  let event = NSEvent(cgEvent: wheel) else { break }
            panel.scrollWheel(with: event)
            host.settle(passes: 2)
        }
        host.settle(passes: 12)
        let (early, earlyBefore) = try XCTUnwrap(Self.firstInView((21...40).map { "Reply \($0) in the thread" },
                                                                  panel: panel, in: host.hosting))
        await reader.setThreadPages(["": .init(messages: (21...41).map(reply), before: "c1"),
                                     "c1": .init(messages: (1...20).map(reply), before: nil)])
        await reader.signalChange()
        await host.settle(until: { labels().contains(newReplies) })
        host.settle(passes: 12)
        let earlyAfter = try XCTUnwrap(Self.offset(of: early, panel: panel, in: host.hosting))
        XCTAssertEqual(earlyAfter, earlyBefore, accuracy: 2, "\(early) stays where it was read as a new reply arrives")
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: newReplies))
        await host.settle(until: { shows("Reply 41 in the thread") })
        host.settle(passes: 12)
        XCTAssertFalse(labels().contains(newReplies))

        // The wheel to the top reads the earlier page once. Whatever was first in view as it was asked for
        // stays at the same height in the dialog once the earlier replies are laid out above it, without
        // another turn of the wheel.
        let qa = try WindowlessRender.directory("dots-replies-qa")
        await reader.holdReplies(before: "c1")
        for _ in 0..<80 {
            older = await reader.olderReplyReads
            guard older == 0 else { break }
            guard let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 80, wheel2: 0, wheel3: 0),
                  let event = NSEvent(cgEvent: wheel) else { break }
            panel.scrollWheel(with: event)
            host.settle(passes: 2)
        }
        try await waitUntil { await reader.hasPendingReplies() }
        host.settle(passes: 6)
        let candidates = ["Which launch date should I put"] + (21...41).map { "Reply \($0) in the thread" }
        let (read, before) = try XCTUnwrap(Self.firstInView(candidates, panel: panel, in: host.hosting))
        try WindowlessRender.writePNG(host.capture().bitmap, to: qa.appending(path: "long-thread-before-earlier.png"))
        await reader.releaseReplies()
        await host.settle(until: { !labels().contains(L10n.string("Loading earlier replies…")) })
        host.settle(passes: 30)
        older = await reader.olderReplyReads
        XCTAssertEqual(older, 1, "Reaching the top reads the earlier page once")
        // The start and 41 replies, with the top row kept blank while it is in view.
        XCTAssertTrue([42, 43].contains(replyTable()?.numberOfRows ?? 0), "The page read is in the list as it arrives")
        try WindowlessRender.writePNG(host.capture().bitmap, to: qa.appending(path: "long-thread-after-earlier.png"))
        let after = try XCTUnwrap(Self.offset(of: read, panel: panel, in: host.hosting), "\(read) is still drawn")
        XCTAssertEqual(after, before, accuracy: 2, "\(read) stays where it was read while earlier replies arrive above it")
        if read != candidates[0] {
            XCTAssertFalse(shows("Reply 1 in the thread"), "Reading the replies, the dialog does not jump to the thread's start")
        }

        // Reading above the end, a new reply offers New replies and moves nothing.
        let inView = (1...41).map { "Reply \($0) in the thread" }.filter(shows)
        XCTAssertFalse(inView.isEmpty)
        await reader.setThreadPages(["": .init(messages: (21...42).map(reply), before: "c1"),
                                     "c1": .init(messages: (1...20).map(reply), before: nil)])
        await reader.signalChange()
        await host.settle(until: { labels().contains(newReplies) })
        XCTAssertTrue(labels().contains(newReplies))
        host.settle(passes: 12)
        for reply in inView { XCTAssertTrue(shows(reply), "\(reply) stays in view when a new reply arrives") }
        XCTAssertFalse(shows("Reply 42 in the thread"), "The new reply waits below")
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: newReplies))
        await host.settle(until: { shows("Reply 42 in the thread") })
        host.settle(passes: 12)
        XCTAssertFalse(labels().contains(newReplies))
        // At the end, the next reply is followed.
        await reader.setThreadPages(["": .init(messages: (21...43).map(reply), before: "c1"),
                                     "c1": .init(messages: (1...20).map(reply), before: nil)])
        await reader.signalChange()
        await host.settle(until: { shows("Reply 43 in the thread") })
        XCTAssertTrue(shows("Reply 43 in the thread"), "Followed to the end; in view: \((1...43).filter { shows("Reply \($0) in the thread") }), "
                      + "at \(panel.contentView.bounds.origin.y) of \(panel.documentView?.frame.height ?? 0)")
        XCTAssertFalse(labels().contains(newReplies))

        // Focus goes back where it was on Close and on Escape, not over what a press outside chose.
        let field = try XCTUnwrap(Self.views(NSTextField.self, in: host.hosting).first {
            $0.isEditable && $0.placeholderString == L10n.string("Message your dot…")
        })
        let earlierField = NSTextField(frame: NSRect(x: 4, y: 4, width: 80, height: 22))
        let chosenField = NSTextField(frame: NSRect(x: 90, y: 4, width: 80, height: 22))
        host.hosting.addSubview(earlierField)
        host.hosting.addSubview(chosenField)
        func owner() -> NSResponder? {
            let responder = host.window.firstResponder
            if let editor = responder as? NSTextView, editor.isFieldEditor { return editor.delegate as? NSResponder }
            return responder
        }
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: close))
        await host.settle(until: { !labels().contains(close) })
        for closing in ["button", "escape", "outside"] {
            XCTAssertTrue(host.window.makeFirstResponder(earlierField))
            XCTAssertTrue(try openThread())
            await host.settle(until: { labels().contains(close) && owner() === field })
            XCTAssertTrue(owner() === field, "The dialog gives its composer focus (\(closing))")
            switch closing {
            case "button": XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: close))
            case "escape": try pressEscape(in: host)
            default:
                let monitor = try XCTUnwrap(Self.views(PersonalAgentReplyPanelMonitor.MonitorView.self, in: host.hosting).first)
                let press = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 120, y: 15),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                monitor.observe(press)
                // What the press lands on takes focus, as the window's own dispatch would give it.
                XCTAssertTrue(host.window.makeFirstResponder(chosenField))
            }
            await host.settle(until: { !labels().contains(close) })
            host.settle(passes: 6)
            XCTAssertFalse(labels().contains(close), closing)
            XCTAssertTrue(owner() === (closing == "outside" ? chosenField : earlierField), "Focus after closing by \(closing)")
        }
        earlierField.removeFromSuperview()
        chosenField.removeFromSuperview()

        // A reply's quote opens its thread replying to the quoted message; a row's Reply action replies to
        // the row. Each is checked by what Send would send to this fixture, never to a provider.
        let draft = try XCTUnwrap(drafts.opened.first)
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Reply to")))
        await host.settle(until: { labels().contains(close) })
        draft.editor.text = "Use the fourteenth."
        host.settle(passes: 4)
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Send message")))
        try await waitUntil { await reader.sends.count == 1 }
        var sends = await reader.sends
        XCTAssertEqual(sends.last?.replyTarget, .init(messageID: "r39", rootID: "q"))
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: close))
        await host.settle(until: { !labels().contains(close) })
        XCTAssertTrue(Self.performCustomAction(L10n.string("Reply"), onElementContaining: "Also keep the press list", in: host.hosting))
        await host.settle(until: { labels().contains(close) })
        draft.editor.text = "Keep it."
        host.settle(passes: 4)
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Send message")))
        try await waitUntil { await reader.sends.count == 2 }
        sends = await reader.sends
        XCTAssertEqual(sends.last?.replyTarget, .init(messageID: "m2", rootID: "m2"))

        // Reading a long first message as earlier replies are read keeps it where it was, though the
        // row offering them above it goes, rather than moving to its first reply.
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: close))
        await host.settle(until: { !labels().contains(close) })
        XCTAssertTrue(Self.performCustomAction(L10n.string("Reply"), onElementContaining: "Launch plan overview", in: host.hosting))
        await host.settle(until: { labels().contains(close) && shows("Step 40 of the plan") })
        host.settle(passes: 20)
        let longPanel = try XCTUnwrap(replyTable()?.enclosingScrollView)
        await reader.holdReplies(before: "d1")
        longPanel.contentView.scroll(to: NSPoint(x: 0, y: 60))
        longPanel.reflectScrolledClipView(longPanel.contentView)
        try await waitUntil { await reader.hasPendingReplies() }
        host.settle(passes: 6)
        let paragraph = "The second part of the plan covers the venue"
        let rootBefore = try XCTUnwrap(Self.offset(of: paragraph, panel: longPanel, in: host.hosting))
        try WindowlessRender.writePNG(host.capture().bitmap, to: qa.appending(path: "long-root-before-earlier.png"))
        await reader.releaseReplies()
        await host.settle(until: { !labels().contains(L10n.string("Loading earlier replies…")) })
        host.settle(passes: 30)
        try WindowlessRender.writePNG(host.capture().bitmap, to: qa.appending(path: "long-root-after-earlier.png"))
        let rootAfter = try XCTUnwrap(Self.offset(of: paragraph, panel: longPanel, in: host.hosting))
        XCTAssertEqual(rootAfter, rootBefore, accuracy: 2, "The first message being read stays where it was")
    }

    /// The reply list draws only the messages in view, each in a view of its own: an answer that arrives,
    /// a deletion and the option it chooses draw only the messages they change. A form scrolled out of
    /// view and back shows the words its request keeps, and a field being typed in keeps its control,
    /// selection and composition while its row is out of view, as the table keeps an edited row in use.
    func testReplyRowsDrawOnlyWhatChangedAndAFieldBeingTypedInKeepsItsComposition() async throws {
        let agent = PersonalAgent(id: .init(accountID: "example", userID: "person", agentID: "dot", roomID: "room"),
                                  name: "Atlas", rootThreadID: nil, isPaused: false, isPrimary: true)
        func reply(_ index: Int) -> PersonalAgentMessage {
            var value = PersonalAgentMessage(id: "r\(index)", author: index.isMultiple(of: 2) ? .agent : .person,
                                             text: "Thread reply \(index) about the launch.", createdAt: nil,
                                             isDeleted: false, attachments: [])
            value.replyToMessageID = "q"
            value.replyRootMessageID = "q"
            return value
        }
        let form = try JSONDecoder().decode(JSONValue.self, from: Data(
            #"{"request_id":"note","thread_id":"thread","turn_id":null,"status":"pending","params":{"threadId":"thread","serverName":"codex_apps","mode":"form","message":"Anything to add?","requestedSchema":{"type":"object","properties":{"note":{"type":"string","title":"Note for the team","maxLength":80},"owner":{"type":"string","title":"Who sends it","maxLength":80}},"required":[]},"_meta":null}}"#.utf8))
        var replies = (1...30).map(reply)
        replies[3].inputRequest = form
        replies[27].metadata = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"option_picker":{"options":["Monday","Tuesday"]}}"#.utf8))
        let root = PersonalAgentMessage(id: "q", author: .agent, text: "Which launch date should I put in the announcement?",
                                        createdAt: nil, isDeleted: false, attachments: [])
        let center = PersonalAgentCenter()
        center.useFixture(agents: [agent], messages: [root])
        let state = try XCTUnwrap(center.conversation)
        let thread = state.replies.thread("q")
        func read(_ messages: [PersonalAgentMessage]) {
            thread.ingest(messages, epoch: state.replies.beginRead())
            center.reconcileReplies(state)
            center.syncInputRequests(state, agent: agent)
        }
        read(replies)
        thread.cursor = .end
        // The form can be answered, as a read of its request would say.
        let request = try XCTUnwrap(state.requests["r4"])
        request.history = .none
        request.inspection = try DotsRequestInspection(.object(["elicitation": form, "can_respond": .bool(true),
            "runtime_status": .string("pending"), "request_fingerprint": .string("fingerprint")]))
        state.replies.focus = .init(rootID: "q", targetID: "q")
        let size = NSSize(width: 920, height: 680)
        let host = WindowlessRender.Host(PersonalAgentsContent(center: center, onRetry: {}, onAccounts: {})
            .frame(width: size.width, height: size.height), size: size)
        defer { host.close() }
        let labels = { host.accessibilityElements().map { $0.label + " " + $0.value } }
        let drawn = { (text: String) in labels().contains { $0.contains(text) } }
        let rowViews = { Self.views(PersonalAgentReplyRowView.self, in: host.hosting) }
        let row = { (id: String) in rowViews().first { $0.messageID == id } }
        await host.settle(until: { drawn("Thread reply 30 about") })
        host.settle(passes: 12)
        let table = try XCTUnwrap(Self.views(NSTableView.self, in: host.hosting).first)
        let panel = try XCTUnwrap(table.enclosingScrollView)
        XCTAssertEqual(table.numberOfRows, 31, "Every reply read is in the list with its start")
        XCTAssertLessThan(rowViews().count, 20, "Only the rows in view have views")
        XCTAssertNil(row("r4"), "A reply out of view has no view")
        ViewBodyCensus.isEnabled = true
        defer { ViewBodyCensus.isEnabled = false; ViewBodyCensus.reset() }

        // An answer to the option arrives: the question and the answer are drawn, no other message.
        ViewBodyCensus.reset()
        var answer = PersonalAgentMessage(id: "answer", author: .person, text: "Tuesday", createdAt: nil, isDeleted: false,
                                          attachments: [])
        answer.replyToMessageID = "r28"
        answer.replyRootMessageID = "q"
        answer.metadata = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"option_picker":{"selection":1}}"#.utf8))
        read([answer])
        await host.settle(until: { Self.isSelected("Tuesday", in: host.hosting) })
        host.settle(passes: 12)
        XCTAssertTrue(Self.isSelected("Tuesday", in: host.hosting), "The question shows the answer chosen")
        XCTAssertEqual(ViewBodyCensus[.personalAgentReplyRowGraph], 2, "Only the question and its answer were drawn again")
        XCTAssertLessThanOrEqual(ViewBodyCensus[.personalAgentReplyRowHosting], 1, "At most the answer's row took a new view")

        // A reply deleted since draws that reply alone again.
        ViewBodyCensus.reset()
        read([PersonalAgentMessage(id: "r29", author: .person, text: "", createdAt: nil, isDeleted: true, attachments: [])])
        await host.settle(until: { !drawn("Thread reply 29 about") })
        host.settle(passes: 12)
        XCTAssertTrue(drawn(L10n.string("Message deleted")))
        XCTAssertEqual(ViewBodyCensus[.personalAgentReplyRowGraph], 1, "Only the deleted reply was drawn again")

        // The form far above: its words are its request's, shown again after it leaves the view.
        func scroll(to y: CGFloat) {
            panel.contentView.scroll(to: NSPoint(x: 0, y: y))
            panel.reflectScrolledClipView(panel.contentView)
            host.settle(passes: 10)
        }
        let bottom = { max(0, table.frame.height - panel.contentView.bounds.height + 8) }
        scroll(to: -8)
        await host.settle(until: { row("r4") != nil })
        let words = "Send it after the review"
        request.formInput["note"] = .text(words)
        await host.settle(until: { drawn(words) })
        scroll(to: bottom())
        await host.settle(until: { row("r4") == nil })
        scroll(to: -8)
        await host.settle(until: { drawn(words) })
        XCTAssertTrue(drawn(words), "The form shows its words again")

        // Typing in the form's second field, mid-composition: its row scrolled out of view and back keeps
        // the same field, editor, selection and composition.
        let cell = try XCTUnwrap(row("r4"))
        let fields = Self.views(NSTextField.self, in: cell).filter(\.isEditable)
        XCTAssertEqual(fields.count, 2, "The form's two fields")
        let field = try XCTUnwrap(fields.last)
        XCTAssertTrue(host.window.makeFirstResponder(field))
        host.settle(passes: 4)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(editor === host.window.firstResponder)
        editor.insertText("Ana", replacementRange: NSRange(location: 0, length: 0))
        editor.setMarkedText("ㅁ", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = editor.markedRange(), selected = editor.selectedRange()
        func composition() -> String { editor.attributedSubstring(forProposedRange: editor.markedRange(), actualRange: nil)?.string ?? "" }
        XCTAssertEqual(composition(), "ㅁ")
        let hosting = cell.hosting
        func check(_ moment: String) {
            XCTAssertTrue(field.currentEditor() === host.window.firstResponder, "The same field is being edited \(moment)")
            XCTAssertTrue(field.window === host.window, "The field is still in the window \(moment)")
            XCTAssertTrue(field.currentEditor() === editor, moment)
            XCTAssertTrue(editor.hasMarkedText(), "The composition goes on \(moment)")
            XCTAssertEqual(editor.markedRange(), marked, moment)
            XCTAssertEqual(composition(), "ㅁ", moment)
            XCTAssertEqual(editor.selectedRange(), selected, moment)
            XCTAssertTrue(row("r4") === cell && cell.hosting === hosting, "The row keeps its view and hosting \(moment)")
            print("[R6a] \(moment): field kept \(field.currentEditor() === host.window.firstResponder), "
                  + "in window \(field.window === host.window), marked \(editor.markedRange()) '\(composition())', "
                  + "selected \(editor.selectedRange()), row view kept \(row("r4") === cell), views \(rowViews().count)")
        }
        scroll(to: bottom())
        check("out of view")
        XCTAssertLessThan(rowViews().count, 20, "Keeping the edited row keeps no others")
        scroll(to: -8)
        check("back in view")
        editor.unmarkText()
        host.window.makeFirstResponder(nil)
    }

    private static func isSelected(_ label: String, in view: NSView) -> Bool {
        WindowlessRender.withAccessibilityTree {
            func visit(_ node: AnyObject) -> Bool? {
                for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                    if (child.accessibilityLabel?() ?? nil) == label { return child.isAccessibilitySelected?() ?? false }
                    if let found = visit(child) { return found }
                }
                return nil
            }
            return visit(view) ?? false
        }
    }

    /// What a reply dialog costs as its thread grows, every reply read being in its list: opening it on
    /// a thread of 20, 200 and 500 replies (short lines, longer sentences and Markdown lists), one new
    /// reply at the end, one reply in view changed and one out of view changed; with 500, a new reply and
    /// changes in and out of view again while reading the middle. Each is the main thread's wall and CPU
    /// time and the process's CPU time through the update drawn, and for that update the messages
    /// prepared for drawing, the ones drawn again in their own hosting views, the hosting views made and
    /// those alive after. The replies arrive as a thread read hands them over; making them, waiting
    /// between updates and moving the list are left out. Runs only with `NHC_PERF_BENCH=1`
    /// (`NHC_PERF_BENCH_ROUNDS`, default 3) and prints `[perf]` lines; nothing is asserted about the times.
    func testBenchmarkAReplyDialogAsItsThreadGrows() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["NHC_PERF_BENCH"] == "1", "Set NHC_PERF_BENCH=1 to run the benchmark")
        let rounds = Int(environment["NHC_PERF_BENCH_ROUNDS"] ?? "") ?? 3
        let order = (environment["NHC_PERF_BENCH_SIZES"] ?? "20,200,500").split(separator: ",").compactMap { Int($0) }
        ViewBodyCensus.isEnabled = true
        defer { ViewBodyCensus.isEnabled = false; ViewBodyCensus.reset() }
        let before = PersonalAgentReplyRowHosting.alive
        for count in order {
            var samples: [String: PerfSamples] = [:]
            var names: [String] = []
            for round in 0...rounds {
                // Each round's window, dialog and views end with the round, before the next is measured.
                let taken = try autoreleasepool { try benchRound(count: count) }
                let ended = ContinuousClock.now
                try await waitUntil { PersonalAgentReplyRowHosting.alive == before }
                print("[perf] dots-replies-\(count) round \(round) ended: views alive \(PersonalAgentReplyRowHosting.alive - before) "
                      + "after \(ContinuousClock.now - ended)")
                guard round > 0 else { continue }
                for (name, sample) in taken {
                    if samples[name] == nil { names.append(name) }
                    samples[name, default: PerfSamples()].add(sample)
                }
            }
            for name in names {
                print("[perf] dots-replies-\(count) \(name) (\(rounds) rounds): " + (samples[name] ?? PerfSamples()).summary)
            }
        }
    }

    /// One round of the benchmark in a window of its own, closed when the round ends.
    private func benchRound(count: Int) throws -> [(String, PerfSamples.Sample)] {
        let (center, state, thread, agent) = try Self.replyFixture(count: count)
        _ = agent
        let size = NSSize(width: 920, height: 680)
        let host = WindowlessRender.Host(PersonalAgentsContent(center: center, onRetry: {}, onAccounts: {})
            .frame(width: size.width, height: size.height), size: size)
        defer { host.close() }
        host.settle(passes: 6)
        var taken: [(String, PerfSamples.Sample)] = []
        func take(_ name: String, _ change: () -> Void) {
            taken.append((name, PerfSamples.measure(host, change)))
            host.settle(passes: 6)
        }
        func change(_ message: PersonalAgentMessage) {
            thread.ingest([message], epoch: state.replies.beginRead())
            center.reconcileReplies(state)
        }
        take("open") { state.replies.focus = .init(rootID: "q", targetID: "q") }
        take("add one at the end") { change(Self.benchReply(count + 1)) }
        take("edit one in view") { change(Self.benchReply(count + 1, edit: " (edited)")) }
        take("edit one out of view") { change(Self.benchReply(count / 2, edit: " (edited)")) }
        if count == 500 {
            // Reading the middle of a thread whose 500 replies are all in the list; the list's rows are
            // the start then the replies in order, so row n shows reply n.
            let table = try XCTUnwrap(Self.views(NSTableView.self, in: host.hosting).first)
            let clip = try XCTUnwrap(table.enclosingScrollView?.contentView)
            clip.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: 250).minY))
            table.enclosingScrollView?.reflectScrolledClipView(clip)
            host.settle(passes: 10)
            let rows = table.rows(in: table.visibleRect)
            let shown = max(1, min(rows.location + rows.length / 2, count))
            take("reading the middle: add one") { change(Self.benchReply(count + 2)) }
            take("reading the middle: edit one in view") { change(Self.benchReply(shown, edit: " (edited)")) }
            take("reading the middle: edit one out of view") { change(Self.benchReply(10, edit: " (edited)")) }
        }
        return taken
    }

    /// The list's heights as the table has them: a row's height stays what the table was told until the
    /// table is told it changed, however other rows are measured meanwhile, and the estimate for rows not
    /// drawn yet does not grow as rows are drawn again at the same height or in another look. A message
    /// read partway that becomes short stays in view.
    func testTheReplyListKeepsTheHeightsItGaveTheTableAndTheMessageReadInViewAsRowsChange() throws {
        let (center, state, thread, _) = try Self.replyFixture(count: 200)
        let size = NSSize(width: 920, height: 680)
        let host = WindowlessRender.Host(PersonalAgentsContent(center: center, onRetry: {}, onAccounts: {})
            .frame(width: size.width, height: size.height), size: size)
        defer { host.close() }
        host.settle(passes: 6)
        state.replies.focus = .init(rootID: "q", targetID: "q")
        host.settle(passes: 12)
        let table = try XCTUnwrap(Self.views(NSTableView.self, in: host.hosting).first)
        let clip = try XCTUnwrap(table.enclosingScrollView?.contentView)
        let delegate = try XCTUnwrap(table.delegate)
        // Rows are the start, then the replies in order: row n shows reply n.
        func height(_ row: Int) -> CGFloat { table.rect(ofRow: row).height - table.intercellSpacing.height }
        var disagreements: [String] = []
        func agree(_ moment: String) {
            for row in 0..<table.numberOfRows {
                let told = delegate.tableView?(table, heightOfRow: row) ?? 0
                if abs(told - height(row)) > 0.01 {
                    disagreements.append("\(moment): row \(row) gives \(told), the table has \(height(row))")
                }
            }
        }
        // Checked between every turn of the run loop, where a height measured waits to be told.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.allActivities.rawValue, true, 0) { _, _ in
            MainActor.assumeIsolated { agree("between turns") }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        func change(_ message: PersonalAgentMessage) {
            thread.ingest([message], epoch: state.replies.beginRead())
            center.reconcileReplies(state)
            host.settle(passes: 8)
        }
        func reply(_ index: Int, _ text: String) -> PersonalAgentMessage { Self.benchReply(index, text: text) }
        clip.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: 100).minY))
        table.enclosingScrollView?.reflectScrolledClipView(clip)
        host.settle(passes: 10)
        agree("reading the middle")

        // The same reply edited again and again at the same height, then the list in another look and
        // back: a reply arriving out of view gets the same estimate after as before, within the heights drawn.
        let drawnRows = { Self.views(PersonalAgentReplyRowView.self, in: host.hosting).filter { $0.messageID.hasPrefix("r") } }
        let line = try XCTUnwrap(drawnRows().compactMap { Int($0.messageID.dropFirst()) }.filter { $0 % 3 == 1 }.min())
        change(Self.benchReply(201))
        let estimate = height(201)
        for round in 0..<10 { change(reply(line, "Reply \(line) in the thread" + (round.isMultiple(of: 2) ? "!" : "?"))) }
        change(Self.benchReply(202))
        XCTAssertEqual(height(202), estimate, accuracy: 0.5, "Drawing a reply again at its height leaves the estimate as it was")
        ViewBodyCensus.isEnabled = true
        defer { ViewBodyCensus.isEnabled = false; ViewBodyCensus.reset() }
        ViewBodyCensus.reset()
        host.window.appearance = NSAppearance(named: .darkAqua)
        host.settle(passes: 10)
        XCTAssertGreaterThan(ViewBodyCensus[.personalAgentReplyRowGraph], 0, "The rows in view are drawn in the other look")
        host.window.appearance = NSAppearance(named: .aqua)
        host.settle(passes: 10)
        change(Self.benchReply(203))
        let drawnHeights = drawnRows().map { height(table.row(for: $0)) }
        print("[R6b] estimate before \(estimate), after edits \(height(202)), after looks \(height(203)), "
              + "drawn \(drawnHeights.min() ?? 0)...\(drawnHeights.max() ?? 0)")
        XCTAssertGreaterThanOrEqual(height(203), (drawnHeights.min() ?? 0) - 0.5, "The estimate is one of the heights drawn, on average")
        XCTAssertLessThanOrEqual(height(203), (drawnHeights.max() ?? 0) + 0.5, "The estimate is one of the heights drawn, on average")

        // A reply in view grows, which changes the estimate: a row not drawn yet keeps the height it was given.
        let notDrawn = 150
        XCTAssertFalse(drawnRows().contains { $0.messageID == "r\(notDrawn)" })
        let given = height(notDrawn)
        change(reply(line, Array(repeating: "A longer reply that takes many lines in the list.", count: 30).joined(separator: "\n\n")))
        XCTAssertEqual(height(notDrawn), given, "A row not drawn keeps its height")
        XCTAssertEqual(delegate.tableView?(table, heightOfRow: notDrawn) ?? 0, given, accuracy: 0.01)

        // Reading 500 points into a long reply that then becomes short: that reply stays in view, and the
        // replies after it are enough for the view to stay anywhere.
        let long = 120
        func scroll(into row: Int, by distance: CGFloat) {
            clip.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: row).minY + distance))
            table.enclosingScrollView?.reflectScrolledClipView(clip)
            host.settle(passes: 10)
        }
        change(reply(long, Array(repeating: "A long reply read from its middle, line after line.", count: 60).joined(separator: "\n\n")))
        scroll(into: long, by: 0)
        XCTAssertGreaterThan(height(long), 900, "The long reply is drawn at its height")
        scroll(into: long, by: 500)
        XCTAssertEqual(clip.bounds.minY - table.rect(ofRow: long).minY, 500, accuracy: 1, "Reading 500 points into it")
        change(reply(long, "Short now."))
        let cell = try XCTUnwrap(drawnRows().first { $0.messageID == "r\(long)" }, "The reply is drawn")
        let drawnAt = cell.convert(cell.bounds, to: clip)
        let shown = drawnAt.intersection(clip.bounds)
        print("[R6b] the short reply: drawn at \(drawnAt), view \(clip.bounds), shown \(shown.height)")
        XCTAssertLessThan(cell.bounds.height, 100, "The reply is short now")
        XCTAssertEqual(shown.height, cell.bounds.height, accuracy: 0.5, "The reply that became short is in view, all of it")
        agree("at the end")
        XCTAssertEqual(disagreements.count, 0, disagreements.prefix(5).joined(separator: "\n"))
    }

    /// A reply dialog whose views are let go: a window's, once it closes, and a dialog's, once it closes
    /// with its window still shown. Each round ends its window and its references, then waits for what it
    /// made to be let go; the counts are printed as they are. Leaks found here are the
    /// product's: the test keeps no reference past its round.
    func testAReplyDialogLetsGoOfItsViewsWhenItClosesAndWhenItsWindowCloses() async throws {
        let before = PersonalAgentReplyRowHosting.alive
        struct Gone {
            weak var host: AnyObject?
            weak var window: NSWindow?
            weak var hosting: NSView?
            weak var controller: PersonalAgentReplyTableController?
            weak var row: PersonalAgentReplyRowHosting?
            weak var center: PersonalAgentCenter?
        }
        for round in 1...4 {
            let gone: Gone = try autoreleasepool {
                let (center, state, _, _) = try Self.replyFixture(count: 200)
                let host = WindowlessRender.Host(PersonalAgentsContent(center: center, onRetry: {}, onAccounts: {})
                    .frame(width: 920, height: 680), size: NSSize(width: 920, height: 680))
                host.settle(passes: 6)
                state.replies.focus = .init(rootID: "q", targetID: "q")
                host.settle(passes: 12)
                let table = try XCTUnwrap(Self.views(NSTableView.self, in: host.hosting).first)
                let gone = Gone(host: host, window: host.window, hosting: host.hosting,
                                controller: table.delegate as? PersonalAgentReplyTableController,
                                row: Self.views(PersonalAgentReplyRowView.self, in: host.hosting).first?.hosting, center: center)
                XCTAssertNotNil(gone.controller)
                XCTAssertNotNil(gone.row)
                host.close()
                return gone
            }
            let closed = ContinuousClock.now
            try await waitUntil {
                gone.host == nil && gone.window == nil && gone.hosting == nil && gone.controller == nil && gone.row == nil
                    && gone.center == nil && PersonalAgentReplyRowHosting.alive == before
            }
            print("[lifetime] window round \(round): views alive \(PersonalAgentReplyRowHosting.alive - before), "
                  + "host \(gone.host != nil), window \(gone.window != nil), hosting \(gone.hosting != nil), "
                  + "list \(gone.controller != nil), row \(gone.row != nil), center \(gone.center != nil), after \(ContinuousClock.now - closed)")
        }

        // The dialog opened and closed again in a window that stays: each closed dialog lets go of its list
        // and rows, and the views alive do not grow with the times it was opened.
        let (center, state, _, _) = try Self.replyFixture(count: 200)
        let host = WindowlessRender.Host(PersonalAgentsContent(center: center, onRetry: {}, onAccounts: {})
            .frame(width: 920, height: 680), size: NSSize(width: 920, height: 680))
        defer { host.close() }
        host.settle(passes: 6)
        let shown = PersonalAgentReplyRowHosting.alive
        for round in 1...4 {
            struct Closed { weak var controller: PersonalAgentReplyTableController?; weak var row: PersonalAgentReplyRowHosting? }
            let closed: Closed = try autoreleasepool {
                state.replies.focus = .init(rootID: "q", targetID: "q")
                host.settle(passes: 12)
                let table = try XCTUnwrap(Self.views(NSTableView.self, in: host.hosting).first)
                let closed = Closed(controller: table.delegate as? PersonalAgentReplyTableController,
                                    row: Self.views(PersonalAgentReplyRowView.self, in: host.hosting).first?.hosting)
                XCTAssertNotNil(closed.controller)
                state.replies.focus = nil
                host.settle(passes: 12)
                return closed
            }
            let ended = ContinuousClock.now
            try await waitUntil { closed.controller == nil && closed.row == nil && PersonalAgentReplyRowHosting.alive == shown }
            print("[lifetime] dialog round \(round): views alive \(PersonalAgentReplyRowHosting.alive - shown), "
                  + "list \(closed.controller != nil), row \(closed.row != nil), after \(ContinuousClock.now - ended)")
        }
    }

    private static let benchStart = Date(timeIntervalSince1970: 1_793_000_000)

    private static func benchReply(_ index: Int, edit: String = "", text written: String? = nil) -> PersonalAgentMessage {
        let text = if let written { written } else {
            switch index % 3 {
            case 0: "Reply \(index)\(edit): the plan needs three things settled first.\n\n- The press list\n- The venue\n- **The stream**, with `one more check`"
            case 1: "Reply \(index)\(edit) in the thread."
            default: "Reply \(index)\(edit): the venue has confirmed the room, and the stream needs one more check before the date can be final for everyone."
            }
        }
        var value = PersonalAgentMessage(id: "r\(index)", author: index.isMultiple(of: 2) ? .agent : .person, text: text,
                                         createdAt: benchStart.addingTimeInterval(Double(index) * 60), isDeleted: false, attachments: [])
        value.replyToMessageID = index == 1 ? "q" : "r\(index - 1)"
        value.replyRootMessageID = "q"
        return value
    }

    /// A dot whose thread `q` holds `count` replies, all read, its dialog not yet open.
    private static func replyFixture(count: Int) throws
        -> (PersonalAgentCenter, PersonalAgentConversation, PersonalAgentReplyThread, PersonalAgent) {
        let agent = PersonalAgent(id: .init(accountID: "example", userID: "person", agentID: "dot", roomID: "room"),
                                  name: "Atlas", rootThreadID: nil, isPaused: false, isPrimary: true)
        let root = PersonalAgentMessage(id: "q", author: .agent, text: "Which launch date should I put in the announcement?",
                                        createdAt: benchStart, isDeleted: false, attachments: [])
        let center = PersonalAgentCenter()
        center.useFixture(agents: [agent], messages: [root])
        let state = try XCTUnwrap(center.conversation)
        let thread = state.replies.thread("q")
        thread.ingest((1...count).map { benchReply($0) }, epoch: state.replies.beginRead())
        thread.cursor = .end
        center.reconcileReplies(state)
        return (center, state, thread, agent)
    }

    /// How far below the top of `panel` the top of the drawn text containing `text` is, read through the
    /// panel's own accessibility, so the same words in the room behind it do not count.
    private static func offset(of text: String, panel: NSScrollView, in view: NSView) -> CGFloat? {
        drawn(text, panel: panel, in: view)?.top
    }

    /// The same, with how tall the text is drawn.
    private static func drawn(_ text: String, panel: NSScrollView, in view: NSView) -> (top: CGFloat, height: CGFloat)? {
        guard let window = panel.window else { return nil }
        let area = window.convertToScreen(panel.convert(panel.bounds, to: nil))
        return WindowlessRender.withAccessibilityTree {
            func scrollArea(_ node: AnyObject) -> AnyObject? {
                for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                    // The panel's scroll area, inside its insets.
                    if (child.accessibilityRole?() ?? nil) == .scrollArea, let frame = child.accessibilityFrame?(),
                       abs(frame.minX - area.minX) < 2, abs(frame.width - area.width) < 2,
                       frame.minY >= area.minY - 1, frame.maxY <= area.maxY + 1 { return child }
                    if let found = scrollArea(child) { return found }
                }
                return nil
            }
            func frame(_ node: AnyObject) -> NSRect? {
                for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                    let label = (child.accessibilityLabel?() ?? nil) ?? ""
                    let value = ((child.accessibilityValue?() as Any??) ?? nil) as? String ?? ""
                    if label.contains(text) || value.contains(text), let found = child.accessibilityFrame?(), found.height > 0 {
                        return found
                    }
                    if let found = frame(child) { return found }
                }
                return nil
            }
            guard let root = scrollArea(view), let found = frame(root) else { return nil }
            return (area.maxY - found.maxY, found.height)
        }
    }

    /// The first of `candidates`, in order, drawn within `panel`'s visible height, with its offset.
    private static func firstInView(_ candidates: [String], panel: NSScrollView, in view: NSView) -> (String, CGFloat)? {
        for text in candidates {
            if let drawn = drawn(text, panel: panel, in: view), drawn.top + drawn.height > 0,
               drawn.top < panel.bounds.height { return (text, drawn.top) }
        }
        return nil
    }

    /// Performs the accessibility action `name` of the element that holds `text`, as an assistive app does.
    private static func performCustomAction(_ name: String, onElementContaining text: String, in view: NSView) -> Bool {
        WindowlessRender.withAccessibilityTree { customAction(name, onElementContaining: text, in: view) }
    }

    private static func customAction(_ name: String, onElementContaining text: String, in view: NSView) -> Bool {
        func holds(_ node: AnyObject) -> Bool {
            let label = (node.accessibilityLabel?() ?? nil) ?? ""
            let value = (node.accessibilityValue?() as Any??).flatMap { $0 } as? String ?? ""
            if label.contains(text) || value.contains(text) { return true }
            return ((node.accessibilityChildren?() ?? nil) ?? []).contains { holds($0 as AnyObject) }
        }
        func visit(_ node: AnyObject) -> NSAccessibilityCustomAction? {
            for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                if let action = ((child.accessibilityCustomActions?() ?? nil) ?? []).first(where: { $0.name == name }), holds(child) {
                    return action
                }
                if let found = visit(child) { return found }
            }
            return nil
        }
        guard let action = visit(view) else { return false }
        if let handler = action.handler { return handler() }
        guard let target = action.target as? NSObject, let selector = action.selector else { return false }
        _ = target.perform(selector, with: action)
        return true
    }

    private func pressEscape<Content: View>(in host: WindowlessRender.Host<Content>) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: host.window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        host.window.sendEvent(event)
        host.settle()
    }

    private func renderDotAtWork(size: NSSize, reduceMotion motions: [Bool]) async throws {
        let (model, _) = try makeWindowModel()
        let agent = PersonalAgent(id: .init(accountID: "example", userID: "person", agentID: "dot", roomID: "room"),
                                  name: "Atlas", rootThreadID: "root", isPaused: false, isPrimary: true,
                                  avatar: .init(location: "https://files.oaiusercontent.com/example-avatar", version: "v1"),
                                  petID: "pet")
        let live = PersonalAgentLiveState(roomID: "room", subscriptionID: "subscription", revision: 1, threads: [
            .init(threadID: "root", streamState: .attached, turnID: "turn", turnStatus: .inProgress, isActive: true,
                  computerStatus: nil, activityType: "Working", activityLabel: "**Checking the launch checklist**")])
        let messages: [PersonalAgentMessage] = [
            .init(id: "m1", author: .person, text: "Check the launch checklist before the review.",
                  createdAt: nil, isDeleted: false, attachments: []),
            .init(id: "m2", author: .agent, text: "I am going through it now and will note anything missing.",
                  createdAt: nil, isDeleted: false, attachments: [])
        ]
        let shownBefore = PersonalAgentWindowVisibility.ReportingView.isOnScreen
        PersonalAgentWindowVisibility.ReportingView.isOnScreen = { _ in true }
        defer { PersonalAgentWindowVisibility.ReportingView.isOnScreen = shownBefore }
        let directory = try WindowlessRender.directory("dots-live-state-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            for reduceMotion in motions {
                let reader = RenderedPersonalAgentReader(agents: [agent], messages: messages, live: live)
                let window = MainWindow(model: model) { reader }
                    .environment(\.colorScheme, appearance.colorScheme)
                    .environment(\._accessibilityReduceMotion, reduceMotion)
                    .frame(width: size.width, height: size.height)
                let host = WindowlessRender.Host(window, size: size, appearance: appearance)
                defer { host.close() }
                host.settle()
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Personal agents")))
                // A line of text names itself by its value.
                let heading = "Checking the launch checklist"
                let says = { host.accessibilityElements().contains { $0.label == heading || $0.value == heading } }
                await host.settle(until: says)
                XCTAssertTrue(says(), "The header says what the dot is doing")
                try await waitUntil { await reader.sheetReads > 0 }
                host.settle(passes: 6)
                let requests = await reader.liveRequests
                XCTAssertEqual(requests, 1, "The room is observed once on opening, not \(requests) times")
                try await waitUntil { await reader.sheetReads > 0 }
                let pets = { Self.views(PersonalAgentSpriteView.self, in: host.hosting) }
                if reduceMotion {
                    host.settle(passes: 12)
                    XCTAssertTrue(pets().isEmpty, "With Reduce Motion every picture is still")
                } else {
                    // The header, the list and, where they fit beside it, the details; the messages'
                    // pictures stay still.
                    let playing = size.width >= 1280 ? 3 : 2
                    await host.settle(until: { pets().count == playing })
                    XCTAssertEqual(pets().count, playing)
                    XCTAssertTrue(pets().allSatisfy { $0.motion == .working })
                    let pet = try XCTUnwrap(pets().first)
                    pet.isOnScreen = { _ in true }
                    pet.updatePlayback()
                    CATransaction.flush()
                    let layer = try XCTUnwrap(pet.layer?.sublayers?.first)
                    let started = try XCTUnwrap(layer.animation(forKey: "Yardlet.sprite"))
                    await reader.repeatLive()
                    try await waitUntil { await reader.liveRepeats == 1 }
                    host.settle(passes: 6)
                    CATransaction.flush()
                    XCTAssertTrue(layer.animation(forKey: "Yardlet.sprite") === started, "The same motion again does not restart it")
                }
                host.settle(passes: 6)
                let capture = try host.capture()
                XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6))
                try WindowlessRender.writePNG(capture.bitmap, to: directory.appending(
                    path: "working-\(Int(size.width))x\(Int(size.height))-\(appearance.suffix)\(reduceMotion ? "-reduce-motion" : "").png"))
            }
        }
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

    /// The dot's composer with a photo uploading, a document that failed and a photo ready, at both
    /// window sizes and in both appearances: thumbnails, names, progress, the failure and its Retry.
    func testComposerFilesShowTheirUploadsInTheWindow() async throws {
        let (model, _) = try makeWindowModel()
        let agent = PersonalAgent(id: .init(accountID: "example", userID: "person", agentID: "dot", roomID: "room"),
                                  name: "Atlas", rootThreadID: nil, isPaused: false, isPrimary: true)
        let messages: [PersonalAgentMessage] = [
            .init(id: "m1", author: .agent, text: "Send me the photos and the signed form when they are ready.",
                  createdAt: nil, isDeleted: false, attachments: [])
        ]
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func photo(_ name: String, _ from: NSColor, _ to: NSColor) throws -> URL {
            let image = NSImage(size: NSSize(width: 120, height: 90), flipped: false) { rect in
                NSGradient(starting: from, ending: to)?.draw(in: rect, angle: 30)
                return true
            }
            let data = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
                .representation(using: .png, properties: [:]))
            let url = folder.appending(path: name)
            try data.write(to: url)
            return url
        }
        let sources = [try photo("site-visit.png", .systemOrange, .systemPink),
                       folder.appending(path: "signed-application-form.pdf"),
                       try photo("floor-plan.png", .systemTeal, .systemBlue)]
        try Data("%PDF-1.4 synthetic".utf8).write(to: sources[1])
        let directory = try WindowlessRender.directory("personal-agent-uploads-qa")
        for size in [NSSize(width: 1280, height: 800), NSSize(width: 920, height: 680)] {
            for appearance in WindowlessRender.Appearance.allCases {
                let drafts = PersonalAgentDrafts()
                let reader = RenderedPersonalAgentReader(agents: [agent], messages: messages)
                let window = MainWindow(model: model, personalAgentDrafts: drafts) { reader }
                    .environment(\.colorScheme, appearance.colorScheme)
                    .frame(width: size.width, height: size.height)
                let host = WindowlessRender.Host(window, size: size, appearance: appearance)
                defer { host.close() }
                host.settle()
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Personal agents")))
                await host.settle(until: { !drafts.opened.isEmpty })
                let draft = try XCTUnwrap(drafts.opened.first)
                draft.editor.text = "현장 사진과 서명한 신청서입니다."
                let ids = await draft.addFiles(sources.map { .init(url: $0) })
                XCTAssertEqual(ids.count, 3)
                draft.setState(ids[0], .uploading)
                draft.setState(ids[1], .failed(.uploadFailed))
                draft.setState(ids[2], .uploaded(.init(fileID: "file", name: "floor-plan.png", mimeType: "image/png", sizeBytes: 1)))
                let retry = L10n.string("Retry upload")
                await host.settle(until: { host.accessibilityElements().contains { $0.label == retry } })
                // The thumbnails are decoded off the main thread; the capture waits for them.
                for file in draft.files where file.isImage { _ = await TranscriptImageThumbnails.shared.preview(for: file.copy) }
                host.settle(passes: 40)
                let capture = try host.capture()
                XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6))
                try WindowlessRender.writePNG(capture.bitmap,
                    to: directory.appending(path: "files-\(Int(size.width))-\(appearance.suffix).png"))
                let visible = host.accessibilityElements(visibleOnly: true)
                for label in [retry, L10n.string("Add files or photos"), L10n.string("Send message")] {
                    XCTAssertTrue(visible.contains { $0.label == label }, "\(label) is on screen at \(size)")
                }
                let labels = visible.map(\.label)
                XCTAssertTrue(labels.contains("signed-application-form.pdf, " + L10n.string("Upload failed")), "\(labels)")
                XCTAssertTrue(labels.contains("site-visit.png, " + L10n.string("Uploading")), "\(labels)")
                XCTAssertTrue(labels.contains("floor-plan.png"), "\(labels)")
                XCTAssertEqual(try Data(contentsOf: sources[1]), Data("%PDF-1.4 synthetic".utf8))
            }
        }
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

    /// A dot's requests where its messages ask them: a tool approval, a form, an option question, one
    /// whose status could not be read, and one Yardlet cannot answer. Pressing Deny and an option goes
    /// through the window's own answer paths, which here only record what would be sent.
    func testInputRequestsAndOptionQuestionsRenderAndAnswerInTheWindow() async throws {
        let (model, _) = try makeWindowModel()
        let agent = PersonalAgent(id: .init(accountID: "example", userID: "person", agentID: "dot", roomID: "room"),
                                  name: "Atlas", rootThreadID: nil, isPaused: false, isPrimary: true)
        func request(_ id: String, _ params: String) throws -> JSONValue {
            try JSONDecoder().decode(JSONValue.self, from: Data(
                #"{"request_id":"\#(id)","thread_id":"thread","turn_id":null,"status":"pending","params":{"threadId":"thread","serverName":"codex_apps","mode":"form",\#(params)}}"#.utf8))
        }
        func message(_ id: String, _ text: String, request: JSONValue? = nil, metadata: String? = nil) throws -> PersonalAgentMessage {
            var value = PersonalAgentMessage(id: id, author: .agent, text: text, createdAt: nil, isDeleted: false, attachments: [])
            value.inputRequest = request
            value.metadata = try metadata.map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
            return value
        }
        let messages: [PersonalAgentMessage] = [
            .init(id: "m1", author: .person, text: "Send the release notes to the team when they are ready.",
                  createdAt: nil, isDeleted: false, attachments: []),
            try message("m2", "The notes are ready. I need your approval to send them.", request: request("send",
                #""message":"Send the release notes to the team","requestedSchema":{"type":"object","properties":{},"required":[]},"_meta":{"codex_approval_kind":"mcp_tool_call","connector_id":"connector_example","connector_name":"Mail","tool_name":"send_email","tool_title":"Send email","tool_params":{"to":"team@example.com","subject":"Release notes"},"tool_params_display":[{"name":"to","display_name":"To","value":"team@example.com"},{"name":"subject","display_name":"Subject","value":"Release notes"}],"persist":["session","always"]}"#)),
            try message("m3", "", request: request("form",
                #""message":"When should the notes go out?","requestedSchema":{"type":"object","properties":{"day":{"type":"string","title":"Day","enum":["today","monday"],"enumNames":["Today","Monday"]},"note":{"type":"string","title":"Note for the team","maxLength":80}},"required":["day"]},"_meta":null"#)),
            try message("m4", "Which version should I publish?", metadata: #"{"option_picker":{"options":["2.1 as drafted","2.1 with the fixes"]}}"#),
            try message("m5", "", request: request("unknown",
                #""message":"Confirm the calendar change","requestedSchema":{"type":"object","properties":{},"required":[]},"_meta":null"#)),
            try message("m6", "", request: request("setup",
                #""message":"Connect your calendar","requestedSchema":{"type":"object","properties":{},"required":[]},"_meta":{"codex_approval_kind":"tool_suggestion","suggest_type":"install","suggest_reason":"Your dot needs your calendar to plan the launch.","tool_type":"connector","tool_id":"calendar","tool_name":"Calendar","install_url":"https://example.com"}"#))
        ]
        let directory = try WindowlessRender.directory("personal-agent-requests-qa")
        for size in [NSSize(width: 1280, height: 920), NSSize(width: 920, height: 920)] {
            for appearance in WindowlessRender.Appearance.allCases {
                let reader = RenderedPersonalAgentReader(agents: [agent], messages: messages, unreadable: ["m5"])
                let window = MainWindow(model: model) { reader }
                    .environment(\.colorScheme, appearance.colorScheme)
                    .frame(width: size.width, height: size.height)
                let host = WindowlessRender.Host(window, size: size, appearance: appearance)
                defer { host.close() }
                host.settle()
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Personal agents")))
                let shows = { (label: String) in host.accessibilityElements().contains { $0.label == label } }
                await host.settle(until: { shows(L10n.string("Allow once")) && shows(L10n.string("Check status")) })
                host.settle(passes: 12)
                let name = "\(Int(size.width))-\(appearance.suffix).png"
                try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "requests-\(name)"))
                try scrollToTop(host)
                try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "requests-top-\(name)"))
                for label in [L10n.string("Deny"), L10n.string("Always allow"), L10n.string("Allow this conversation"),
                              L10n.string("Submit"), "2.1 with the fixes", L10n.string("Status unknown"),
                              L10n.string("Can't be answered here")] {
                    XCTAssertTrue(shows(label), "\(label) at \(size)")
                }
                guard size.width == 1280, appearance == .light else { continue }
                // Deny cancels the tool call as the person's choice; the option replies with its exact text.
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Deny")))
                try await waitUntil { await reader.answers.count == 1 }
                let answer = await reader.answers.first
                XCTAssertEqual(answer?.json, .object(["action": .string("cancel"), "content": .null,
                    "_meta": .object(["codex_approval_cancellation_reason": .string("user")])]))
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: "2.1 with the fixes"))
                try await waitUntil { await reader.sends.count == 1 }
                let reply = await reader.sends.first
                XCTAssertEqual(reply?.text, "2.1 with the fixes")
                XCTAssertEqual(reply?.replyToMessageID, "m4")
                XCTAssertEqual(reply?.optionSelection, 1)
                await host.settle(until: { shows(L10n.string("Denied")) })
                host.settle(passes: 12)
                try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "requests-answered-\(name)"))
                try scrollToTop(host)
                try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "requests-answered-top-\(name)"))
            }
        }
    }

    /// An uncertain option answer whose question is then deleted keeps its request and is not sent
    /// again; the line above the editor asks before it stops waiting, and then another question can be
    /// answered. The confirmation is received by a prompt the render puts in, never an alert on screen.
    func testAWaitingAnswerToADeletedQuestionCanStillBeStopped() async throws {
        let (model, _) = try makeWindowModel()
        let agent = PersonalAgent(id: .init(accountID: "example", userID: "person", agentID: "dot", roomID: "room"),
                                  name: "Atlas", rootThreadID: nil, isPaused: false, isPrimary: true)
        func question(_ id: String, _ text: String, _ options: String) throws -> PersonalAgentMessage {
            var value = PersonalAgentMessage(id: id, author: .agent, text: text, createdAt: nil, isDeleted: false, attachments: [])
            value.metadata = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"option_picker":{"options":\#(options)}}"#.utf8))
            return value
        }
        let version = try question("version", "Which version should I publish?", #"["2.1 as drafted","2.1 with the fixes"]"#)
        let day = try question("day", "Which day should it go out?", #"["Today","Monday"]"#)
        let waiting = L10n.string("An answer to a question that is no longer shown could not be confirmed. It may already have arrived.")
        let directory = try WindowlessRender.directory("personal-agent-requests-qa")
        for size in [NSSize(width: 1280, height: 800), NSSize(width: 920, height: 800)] {
            for appearance in WindowlessRender.Appearance.allCases {
                let reader = RenderedPersonalAgentReader(agents: [agent], messages: [version, day])
                var asked: [@MainActor () -> Void] = []
                let prompt = PersonalAgentConfirmationPrompt { confirmation, confirm in
                    guard case .stopWaiting = confirmation else { return XCTFail("\(confirmation)") }
                    asked.append(confirm)
                }
                let window = MainWindow(model: model) { reader }
                    .environment(\.personalAgentConfirmationPrompt, prompt)
                    .environment(\.colorScheme, appearance.colorScheme)
                    .frame(width: size.width, height: size.height)
                let host = WindowlessRender.Host(window, size: size, appearance: appearance)
                defer { host.close() }
                host.settle()
                let shows = { (label: String) in host.accessibilityElements().contains { $0.label == label || $0.value == label } }
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Personal agents")))
                await host.settle(until: { shows("2.1 with the fixes") && shows("Monday") })
                await reader.loseNextSend()
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: "2.1 with the fixes"))
                await host.settle(until: { shows(L10n.string("Send the same answer again")) })
                // The question is deleted; the read that shows it is the person's own refresh.
                await reader.setPage([.init(id: "version", author: .agent, text: "", createdAt: nil, isDeleted: true, attachments: []), day])
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Refresh conversation")))
                await host.settle(until: { shows(waiting) })
                XCTAssertFalse(shows("2.1 with the fixes"), "The deleted question is not shown again")
                host.settle(passes: 12)
                let name = "\(Int(size.width))-\(appearance.suffix).png"
                try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "waiting-answer-deleted-question-\(name)"))
                guard size.width == 1280, appearance == .light else { continue }
                // Until the person stops waiting, the other question's options are shown but take no press.
                XCTAssertTrue(shows("Monday"))
                XCTAssertFalse(host.hosting.pressAccessibilityElement(labelled: "Monday"))
                // Stop waiting asks first; declining leaves the answer waiting.
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Stop waiting")))
                XCTAssertEqual(asked.count, 1)
                host.settle(passes: 6)
                XCTAssertTrue(shows(waiting), "Nothing stops waiting before the person confirms")
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Stop waiting")))
                XCTAssertEqual(asked.count, 2)
                asked.last?()
                await host.settle(until: { !shows(waiting) })
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: "Monday"))
                try await waitUntil { await reader.sends.count == 2 }
                let sends = await reader.sends
                XCTAssertEqual(sends.map(\.replyToMessageID), ["version", "day"])
                XCTAssertEqual(sends.last?.optionSelection, 1)
                XCTAssertNotEqual(sends[0].requestID, sends[1].requestID)
            }
        }

        // A stop that cannot be saved keeps the answer waiting and says the save failed.
        let folder = FileManager.default.temporaryDirectory.appending(path: "option-reply-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let writable = { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        let readOnly = { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path) }
        defer { try? writable(); try? FileManager.default.removeItem(at: folder) }
        let reply = PersonalAgentOptionReply(file: folder.appending(path: "stop.option-reply.json"))
        var submission = PersonalAgentSubmission(text: "2.1 with the fixes")
        submission.replyToMessageID = "version"
        submission.optionSelection = 1
        XCTAssertTrue(reply.prepare(submission))
        try readOnly()
        reply.discard(requestID: submission.requestID)
        XCTAssertEqual(reply.pending, submission)
        XCTAssertTrue(reply.storageFailed)
        try writable()

        // A first save that fails locks the options and says so; saving again after the disk recovers,
        // which sends nothing, lets them take an answer.
        let picker = try XCTUnwrap(version.metadata.flatMap(DotsOptionPicker.init(metadata:)))
        let fresh = PersonalAgentOptionReply(file: folder.appending(path: "first.option-reply.json"))
        try readOnly()
        XCTAssertFalse(fresh.prepare(submission))
        XCTAssertNil(fresh.pending)
        var chosen: [Int] = []
        let actions = PersonalAgentRequestActions(choose: { _, index in chosen.append(index) })
        let storage = WindowlessRender.Host(VStack(alignment: .leading, spacing: 12) {
            PersonalAgentOptionQuestion(messageID: "version", picker: picker, chosen: nil, isAnswered: false,
                                        reply: fresh, actions: actions)
            PersonalAgentOptionAnswerStatus(reply: fresh, showsQuestion: true, actions: actions)
        }.padding().frame(width: 680, alignment: .leading).background(ParityTheme.canvas)
            .environment(\.colorScheme, .light), size: NSSize(width: 680, height: 220), appearance: .light)
        defer { storage.close() }
        storage.settle()
        let storageText = PersonalAgentFailure.draftStorage.message
        XCTAssertTrue(storage.accessibilityElements().contains { $0.label == storageText || $0.value == storageText })
        XCTAssertFalse(storage.hosting.pressAccessibilityElement(labelled: "2.1 with the fixes"))
        try WindowlessRender.writePNG(storage.capture().bitmap, to: directory.appending(path: "option-answer-storage-failed-light.png"))
        try writable()
        XCTAssertTrue(storage.hosting.pressAccessibilityElement(labelled: L10n.string("Try again")))
        storage.settle()
        XCTAssertFalse(fresh.storageFailed)
        XCTAssertTrue(storage.hosting.pressAccessibilityElement(labelled: "2.1 with the fixes"))
        XCTAssertEqual(chosen, [1])

        // An answer file that cannot be read is said, not silently locked, and is kept as a backup only
        // after the person confirms; until then its bytes stay where they are.
        let broken = folder.appending(path: "broken.option-reply.json")
        try Data("not an answer".utf8).write(to: broken)
        let unreadable = PersonalAgentOptionReply(file: broken)
        XCTAssertTrue(unreadable.needsRecovery)
        var confirms: [@MainActor () -> Void] = []
        let prompt = PersonalAgentConfirmationPrompt { confirmation, confirm in
            XCTAssertEqual(confirmation, .keepUnreadableAnswer)
            confirms.append(confirm)
        }
        let recovery = WindowlessRender.Host(PersonalAgentOptionAnswerStatus(reply: unreadable, showsQuestion: true, actions: .init())
            .environment(\.personalAgentConfirmationPrompt, prompt).padding().frame(width: 680)
            .background(ParityTheme.canvas).environment(\.colorScheme, .dark),
            size: NSSize(width: 680, height: 90), appearance: .dark)
        defer { recovery.close() }
        recovery.settle()
        let unreadableText = L10n.string("A saved answer to a question could not be read. Keep it as a backup to answer questions again.")
        XCTAssertTrue(recovery.accessibilityElements().contains { $0.label == unreadableText || $0.value == unreadableText })
        try WindowlessRender.writePNG(recovery.capture().bitmap, to: directory.appending(path: "option-answer-unreadable-dark.png"))
        XCTAssertTrue(recovery.hosting.pressAccessibilityElement(labelled: L10n.string("Keep as a backup")))
        XCTAssertEqual(confirms.count, 1)
        XCTAssertEqual(try Data(contentsOf: broken), Data("not an answer".utf8), "Nothing is overwritten before confirming")
        confirms[0]()
        XCTAssertFalse(unreadable.needsRecovery)
        XCTAssertFalse(unreadable.storageFailed)
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("broken.option-reply.json.backup-") })
        XCTAssertEqual(try Data(contentsOf: backup), Data("not an answer".utf8))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int, 0o600)

        // Windows share an answer. A confirmation asked for answer A, still open when a read settles A and
        // another window starts answer B, lets B go on waiting: from either way to stop waiting.
        for showsQuestion in [false, true] {
            let shared = PersonalAgentOptionReply(file: folder.appending(path: "shared-\(showsQuestion).option-reply.json"))
            var first = PersonalAgentSubmission(text: "2.1 with the fixes")
            first.replyToMessageID = "version"
            first.optionSelection = 1
            XCTAssertTrue(shared.prepare(first))
            shared.failed(.deliveryUnknown, retry: false)
            var stale: [@MainActor () -> Void] = []
            let asks = PersonalAgentConfirmationPrompt { confirmation, confirm in
                XCTAssertEqual(confirmation, .stopWaiting(first.requestID))
                stale.append(confirm)
            }
            let content: AnyView = showsQuestion
                ? AnyView(PersonalAgentOptionQuestion(messageID: "version", picker: picker, chosen: nil, isAnswered: true,
                                                      reply: shared, actions: .init()))
                : AnyView(PersonalAgentOptionAnswerStatus(reply: shared, showsQuestion: false, actions: .init()))
            let window = WindowlessRender.Host(content.environment(\.personalAgentConfirmationPrompt, asks).padding()
                .frame(width: 680).background(ParityTheme.canvas).environment(\.colorScheme, .light),
                size: NSSize(width: 680, height: 220), appearance: .light)
            defer { window.close() }
            window.settle()
            XCTAssertTrue(window.hosting.pressAccessibilityElement(labelled: L10n.string("Stop waiting")))
            XCTAssertEqual(stale.count, 1)
            shared.accepted(first.requestID)
            var second = PersonalAgentSubmission(text: "Monday")
            second.replyToMessageID = "day"
            second.optionSelection = 1
            XCTAssertTrue(shared.prepare(second))
            stale[0]()
            XCTAssertEqual(shared.pending, second, "The later answer, its request and payload stay")
            let saved = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: folder.appending(path: "shared-\(showsQuestion).option-reply.json")))
            XCTAssertEqual(saved["pending"]?["requestID"]?.stringValue, second.requestID)
        }
    }

    /// Turns the conversation's wheel up to its first message, as the person scrolls.
    private func scrollToTop<Content: View>(_ host: WindowlessRender.Host<Content>) throws {
        let scroll = try XCTUnwrap(Self.scrollViews(in: host.hosting).max {
            ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
        })
        for _ in 0..<20 {
            guard let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 400, wheel2: 0, wheel3: 0),
                  let event = NSEvent(cgEvent: wheel) else { break }
            scroll.scrollWheel(with: event)
            host.settle(passes: 1)
        }
        host.settle(passes: 12)
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
        WindowlessRender.withAccessibilityTree {
            func visit(_ node: AnyObject) -> Bool {
                for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                    if (child.accessibilityRole?() ?? nil) == .menuButton, (child.accessibilityTitle?() ?? nil) == title { return true }
                    if visit(child) { return true }
                }
                return false
            }
            return visit(view)
        }
    }
}

/// One update's cost, as the reply benchmark reads it: wall and main-thread CPU time, the process's CPU
/// time, and the rows the reply dialog drew.
@MainActor
private struct PerfSamples {
    struct Sample {
        let wall: Double, mainCPU: Double, processCPU: Double
        /// Messages prepared for drawing, drawn again in their own views, views made for them, and the
        /// views alive once the update is drawn.
        let prepared: Int, drawn: Int, made: Int, alive: Int
    }
    private var samples: [Sample] = []

    mutating func add(_ sample: Sample) { samples.append(sample) }

    /// `change` and the layout it causes, through the run loop's turn that draws it.
    static func measure<Content: View>(_ host: WindowlessRender.Host<Content>, _ change: () -> Void) -> Sample {
        ViewBodyCensus.reset()
        let wall = Date(), main = threadCPU(), process = processCPU()
        change()
        host.hosting.layoutSubtreeIfNeeded()
        // Heights measured as rows are drawn are noted in the same turn of the run loop.
        RunLoop.main.run(until: Date())
        host.hosting.layoutSubtreeIfNeeded()
        host.hosting.displayIfNeeded()
        return .init(wall: Date().timeIntervalSince(wall), mainCPU: threadCPU() - main, processCPU: processCPU() - process,
                     prepared: ViewBodyCensus[.personalAgentReplyRow], drawn: ViewBodyCensus[.personalAgentReplyRowGraph],
                     made: ViewBodyCensus[.personalAgentReplyRowHosting], alive: PersonalAgentReplyRowHosting.alive)
    }

    var summary: String {
        func median(_ values: [Double]) -> String {
            String(format: "%.1f", values.isEmpty ? 0 : values.sorted()[values.count / 2] * 1_000)
        }
        func count(_ values: [Int]) -> Int { values.isEmpty ? 0 : values.sorted()[values.count / 2] }
        return "wall median \(median(samples.map(\.wall))) ms, main thread CPU median \(median(samples.map(\.mainCPU))) ms, "
            + "process CPU median \(median(samples.map(\.processCPU))) ms, messages prepared \(count(samples.map(\.prepared))), "
            + "drawn again \(count(samples.map(\.drawn))), views made \(count(samples.map(\.made))), "
            + "views alive \(count(samples.map(\.alive))) "
            + "(each round: \(samples.map { String(format: "%.1f", $0.mainCPU * 1_000) }.joined(separator: ", ")) ms main CPU)"
    }

    private static func threadCPU() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
    }

    private static func processCPU() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }
}

/// Fixed agents, one page of messages and their details; a send or an answer is only recorded, and
/// downloading is not part of these renders. The picture is drawn here, not a provider's.
private actor RenderedPersonalAgentReader: PersonalAgentClient {
    let values: [PersonalAgent]
    private(set) var page: [PersonalAgentMessage]
    let older: [PersonalAgentMessage]
    let live: PersonalAgentLiveState?
    let outputError: DotsRemoteFileError?
    /// Messages whose input request cannot be read, which then shows its status as unknown.
    let unreadable: Set<String>
    private(set) var olderReads = 0
    private(set) var answers: [DotsInputResult] = []
    private(set) var sends: [PersonalAgentSubmission] = []
    private var losesSend = false
    func loseNextSend() { losesSend = true }
    func setPage(_ messages: [PersonalAgentMessage]) { page = messages }
    init(agents: [PersonalAgent], messages: [PersonalAgentMessage], older: [PersonalAgentMessage] = [],
         live: PersonalAgentLiveState? = nil, unreadable: Set<String> = [], outputError: DotsRemoteFileError? = nil) {
        values = agents; page = messages; self.older = older; self.live = live; self.unreadable = unreadable
        self.outputError = outputError
    }
    private(set) var liveRequests = 0
    private(set) var liveRepeats = 0
    private var liveStream: AsyncStream<PersonalAgentLiveUpdate>.Continuation?
    func liveState(for agent: PersonalAgent) async -> AsyncStream<PersonalAgentLiveUpdate> {
        liveRequests += 1
        let pair = AsyncStream<PersonalAgentLiveUpdate>.makeStream()
        liveStream = pair.continuation
        pair.continuation.yield(.state(live))
        return pair.stream
    }
    /// The same work again a revision later, with other words for it when `label` is given.
    func repeatLive(label: String? = nil) {
        guard let live else { return }
        liveRepeats += 1
        var threads = live.threads
        if let label, let first = threads.first {
            threads[0] = .init(threadID: first.threadID, streamState: first.streamState, turnID: first.turnID,
                               turnStatus: first.turnStatus, isActive: first.isActive, computerStatus: first.computerStatus,
                               activityType: first.activityType, activityLabel: label)
        }
        liveStream?.yield(.state(.init(roomID: live.roomID, subscriptionID: live.subscriptionID,
                                       revision: live.revision + Int64(liveRepeats), threads: threads)))
    }
    func inspectRequest(in messageID: String, for agent: PersonalAgent) async throws -> DotsRequestInspection {
        guard !unreadable.contains(messageID), let request = page.first(where: { $0.id == messageID })?.inputRequest else {
            throw PersonalAgentFailure.network
        }
        return try DotsRequestInspection(.object(["elicitation": request, "can_respond": .bool(true),
            "runtime_status": .string("pending"), "request_fingerprint": .string("fingerprint")]))
    }
    func respond(_ result: DotsInputResult, fingerprint: String, in messageID: String,
                 for agent: PersonalAgent) async throws -> DotsResponseOutcome {
        answers.append(result)
        return .applied
    }
    func agents() async throws -> [PersonalAgent] { values }
    func messages(for agent: PersonalAgent, before: String?) async throws -> PersonalAgentPage {
        guard before != nil else { return .init(messages: page, before: older.isEmpty ? nil : page.first?.id) }
        olderReads += 1
        return .init(messages: older, before: nil)
    }
    private var changes: AsyncStream<PersonalAgentUpdate>.Continuation?
    func updates(for agent: PersonalAgent) async -> AsyncStream<PersonalAgentUpdate> {
        let pair = AsyncStream<PersonalAgentUpdate>.makeStream()
        changes = pair.continuation
        return pair.stream
    }
    /// What the room's subscription says when something in it changed.
    func signalChange() { changes?.yield(.changed) }
    private(set) var replyReads = 0
    private(set) var olderReplyReads = 0
    /// A thread's pages by cursor, "" for the latest; without them a thread is the page's messages
    /// that name it, all in one page. A held read answers when released.
    private var threadPages: [String: [String: PersonalAgentPage]] = [:]
    private var heldReplies: String?
    private var pendingReplies: CheckedContinuation<Void, Never>?
    func setThreadPages(_ pages: [String: PersonalAgentPage], root: String = "q") { threadPages[root] = pages }
    func holdReplies(before: String) { heldReplies = before }
    func hasPendingReplies() -> Bool { pendingReplies != nil }
    func releaseReplies() { pendingReplies?.resume(); pendingReplies = nil }
    func replies(to rootID: String, for agent: PersonalAgent, before: String?) async throws -> PersonalAgentPage {
        replyReads += 1
        if before != nil { olderReplyReads += 1 }
        if let pages = threadPages[rootID] {
            let key = before ?? ""
            if heldReplies == key {
                heldReplies = nil
                await withCheckedContinuation { pendingReplies = $0 }
            }
            guard let page = pages[key] else { throw PersonalAgentFailure.network }
            return page
        }
        return .init(messages: page.filter { $0.replyRootMessageID == rootID }, before: nil)
    }
    func send(_ submission: PersonalAgentSubmission, to agent: PersonalAgent) async throws -> PersonalAgentMessage {
        sends.append(submission)
        if losesSend { losesSend = false; throw PersonalAgentFailure.deliveryUnknown }
        var message = PersonalAgentMessage(id: "sent-" + submission.requestID, author: .person, text: submission.text,
                                           createdAt: nil, isDeleted: false, attachments: [], requestID: submission.requestID)
        message.replyToMessageID = submission.replyToMessageID
        message.metadata = submission.optionSelection.map { .object(["option_picker": .object(["selection": .integer(Int64($0))])]) }
        page.append(message)
        return message
    }
    func upload(_ file: PersonalAgentPreparedFile, to agent: PersonalAgent) async throws -> PersonalAgentUploadedFile {
        throw PersonalAgentFailure.uploadFailed
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

    // The record of "Prepare the launch checklist": twelve turns read five at a time, newest first; the
    // latest turn's items in two pages, with a file on the provider's computer and an item Yardlet
    // cannot draw.
    private var failsThread = false
    private var failingItems: Set<String> = []
    private(set) var earlierTurnReads = 0
    func failHistory(thread: Bool = false, items: Set<String> = []) { failsThread = thread; failingItems = items }
    func activityThread(_ threadID: String, for agent: PersonalAgent) async throws -> CodexThreadState {
        if failsThread { throw PersonalAgentFailure.unavailable }
        return try PersonalAgentActivityHistory.thread(.object(["thread": .object(["id": .string(threadID)])]), id: threadID)
    }
    func activityTurns(_ threadID: String, cursor: String?, for agent: PersonalAgent) async throws -> CodexTurnPage {
        if cursor != nil { earlierTurnReads += 1 }
        let end = cursor.flatMap(Int.init) ?? 12
        let start = max(1, end - 4)
        let started = Date().addingTimeInterval(-3_600).timeIntervalSince1970
        let turns = (start...end).reversed().map { index -> String in
            #"{"id":"t\#(index)","status":"completed","startedAt":\#(Int(started) + index * 60),"#
                + #""completedAt":\#(Int(started) + index * 60 + 42),"durationMs":42000,"items":[],"itemsView":"notLoaded"}"#
        }
        let next = start > 1 ? #""\#(start - 1)""# : "null"
        return try PersonalAgentActivityHistory.turnPage(
            JSONDecoder().decode(JSONValue.self, from: Data(#"{"data":[\#(turns.joined(separator: ","))],"nextCursor":\#(next),"backwardsCursor":null}"#.utf8)))
    }
    func activityItems(_ threadID: String, turnID: String, cursor: String?,
                       for agent: PersonalAgent) async throws -> CodexItemPage {
        if failingItems.contains(turnID) { throw PersonalAgentFailure.network }
        let index = Int(turnID.dropFirst()) ?? 0
        var items = [
            #"{"turnId":"\#(turnID)","item":{"id":"\#(turnID)-u","type":"userMessage","content":[{"type":"text","text":"Check launch item \#(index) and note what is left."}]}}"#,
            #"{"turnId":"\#(turnID)","item":{"id":"\#(turnID)-c","type":"commandExecution","command":"cat checklist.md","cwd":"/workspace","status":"completed","aggregatedOutput":"- [x] Draft\n- [ ] Review","exitCode":0}}"#,
            #"{"turnId":"\#(turnID)","item":{"id":"\#(turnID)-a","type":"agentMessage","phase":"final_answer","text":"Item \#(index) is checked.\n\n- The draft is ready.\n- The review is still open."}}"#
        ]
        var next = "null"
        if index == 12 {
            if cursor == nil {
                items = Array(items.prefix(2))
                next = #""more""#
            } else {
                items = [items[2],
                         #"{"turnId":"t12","item":{"id":"t12-v","type":"imageView","path":"/mnt/data/checklist.png"}}"#,
                         #"{"turnId":"t12","item":{"id":"t12-r","type":"realtimeSegment"}}"#]
            }
        }
        return try PersonalAgentActivityHistory.itemPage(
            JSONDecoder().decode(JSONValue.self, from: Data(#"{"data":[\#(items.joined(separator: ","))],"nextCursor":\#(next),"backwardsCursor":null}"#.utf8)),
            turnID: turnID)
    }

    // The dot's Outputs: one turn of its root that cites a report and saved a chart on its computer,
    // whose host refuses to read files for an app it cannot verify.
    private(set) var fileReads = 0
    private var holdsFile = false
    private var pendingFile: CheckedContinuation<Void, Never>?
    func holdNextFile() { holdsFile = true }
    func hasPendingFile() -> Bool { pendingFile != nil }
    func releaseFile() { pendingFile?.resume(); pendingFile = nil }
    func outputThreads(for agent: PersonalAgent) async throws -> [String] { agent.rootThreadID.map { [$0] } ?? [] }
    func outputThread(_ threadID: String, for agent: PersonalAgent) async throws -> CodexThreadState {
        try PersonalAgentActivityHistory.thread(.object(["thread": .object(["id": .string(threadID), "environments": .array([
            .object(["environmentId": .string("env"), "cwd": .string("/mnt/data")])])])]), id: threadID)
    }
    func outputTurns(_ threadID: String, cursor: String?, for agent: PersonalAgent) async throws -> CodexTurnPage {
        let done = Int(Date().addingTimeInterval(-7_200).timeIntervalSince1970)
        return try PersonalAgentActivityHistory.turnPage(JSONDecoder().decode(JSONValue.self, from: Data(
            #"{"data":[{"id":"o1","status":"completed","completedAt":\#(done)}],"nextCursor":null,"backwardsCursor":null}"#.utf8)))
    }
    func outputItems(_ threadID: String, turnID: String, cursor: String?,
                     for agent: PersonalAgent) async throws -> CodexItemPage {
        let items = [
            #"{"turnId":"o1","item":{"id":"o1-i","type":"imageGeneration","status":"completed","result":"","savedPath":"/mnt/data/launch-chart.png"}}"#,
            #"{"turnId":"o1","item":{"id":"o1-a","type":"agentMessage","phase":"final_answer","text":"The plan is in :codex-file-citation{path=\"launch-plan.pdf\"}."}}"#
        ]
        return try PersonalAgentActivityHistory.itemPage(JSONDecoder().decode(JSONValue.self, from: Data(
            #"{"data":[\#(items.joined(separator: ","))],"nextCursor":null,"backwardsCursor":null}"#.utf8)), turnID: turnID)
    }
    func outputFile(_ file: PersonalAgentRemoteFile, for agent: PersonalAgent) async throws -> PersonalAgentDownload {
        fileReads += 1
        if holdsFile {
            holdsFile = false
            await withCheckedContinuation { pendingFile = $0 }
        }
        if let outputError { throw outputError }
        throw PersonalAgentFailure.verificationUnsupported
    }

    func computers(for agent: PersonalAgent) async throws -> [PersonalAgentComputer] {
        [.init(id: "cloud", name: "Cloud computer", isCloud: true, isAttached: true, availability: .unknown),
         .init(id: "studio", name: "Studio Mac", isCloud: false, isAttached: true, availability: .offline)]
    }
    func stop() async {}
}
