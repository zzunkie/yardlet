import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient
@testable import YardletRemote

extension RemoteHostWindowRenderingTests {
    /// ⌘K in another Mac's window lists the host's tasks and the commands the window carries out through the host, and
    /// leaves out what acts on this Mac alone. Drawn as `remote-palette-*.png`.
    func testCommandPaletteListsTheHostsTasksAndCommands() async throws {
        let folder = URL(filePath: "/tmp/remote-palette-render")
        let shown = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
                                  title: "Migrate the session index")
        let other = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
                                  title: "Review the release notes")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemotePaletteRender")))
        let host = AppModel(store: SessionStore(sessions: [shown, other], repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults), restoresIndexOnLaunch: false)
        _ = host.projects.ensureProject(forRoot: folder)
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
        try await waitUntil { model.hasSnapshot && model.taskActions && model.sidebar.sessions.count == 2 }
        model.select(.task(shown.id.uuidString))

        // The window's own Task and View menu commands for its shown task, its panels closed.
        var commands = YardletTaskCommandSet()
        commands.shownTaskID = shown.id
        commands.newTask = {}
        commands.stop = {}
        commands.panels = .init()
        commands.showArchivedTasks = {}
        let palette = RemoteCommandPalette(model: model, commands: commands, showsRail: true)
        XCTAssertEqual(palette.tasks.map(\.title), ["Review the release notes"])
        let titles = palette.items.map(\.title)
        for title in ["New task", "Hide session rail", "Show side panel", "Archived tasks", "Stop", "Mark task as read"] {
            XCTAssertTrue(titles.contains(L10n.string(title)), "\(title) in \(titles)")
        }
        for title in ["Import conversation…", "Harnesses", "Task Resource Usage", "Show in Finder"] {
            XCTAssertFalse(titles.contains(L10n.string(title)), "\(title) in \(titles)")
        }
        try await render("remote-palette", size: NSSize(width: 640, height: 560), titled: false) {
            CommandPaletteView(items: palette.items, tasks: palette.tasks, onSelect: { _ in })
                .background(ParityTheme.elevated)
        }
        await host.shutdown()
    }
}
