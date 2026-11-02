import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient
@testable import YardletRemote
@testable import YardletRemoteFixtureSupport

/// The desktop remote drawn offscreen (never shown) in both appearances into `.build/remote-qa`, against
/// the fixture host on loopback (`LoopbackStack`): nothing runs a provider, and nothing is paired but the
/// fixture.
///
/// - `remote-connect-*.png`: File › Connect to Mac… with one paired Mac.
/// - `remote-host-approval-*.png`: the host's window on a task waiting on a Bash approval, with the host
///   card's answers.
/// - `remote-host-question-*.png`: a question with its options.
/// - `remote-host-answered-*.png`: the approval answered, the turn folded under its answer.
/// - `remote-host-lines-*.png`: the next turn waiting on an approval again, its file change's line opened with
///   its diff.
/// - `remote-host-new-*.png`: a new task with the host's project, harness and model menus.
/// - `remote-host-offline-*.png`: the host gone, its list and conversation kept under the banner.
@MainActor
final class RemoteHostWindowRenderingTests: XCTestCase {
    func testTheConnectWindowAndAHostWindowDraw() async throws {
        let directory = try WindowlessRender.directory("remote-qa")
        let stack = try await LoopbackStack(name: "Mac Studio")
        var stopped = false
        defer { if !stopped { stack.stop() } }
        let ticket = await stack.server.openPairing()
        let link = try XCTUnwrap(RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey, secret: ticket.secret,
                                                        name: "Mac Studio", hosts: ["127.0.0.1:\(stack.port)"]).url)
        let hosts = RemoteHostDirectory(store: RemoteHostStore(fileURL: nil), keys: RemoteMemoryClientKeys(),
                                        hello: RemoteHandshakeHello(name: "MacBook Air", platform: "macos", appVersion: "test"))
        let host = try await hosts.pair(link: link.absoluteString)
        let model = try XCTUnwrap(hosts.model(for: host.id))
        try await waitUntil { model.hasSnapshot }

        try await render("remote-connect", size: NSSize(width: 540, height: 420), titled: false) {
            RemoteConnectWindow(directory: hosts)
        } check: { elements in
            XCTAssertTrue(elements.contains { $0.label == L10n.string("Connection link") }, elements.description)
            XCTAssertTrue(elements.contains { $0.label == L10n.format("Open %@", "Mac Studio") }, elements.description)
        }

        let size = NSSize(width: 1280, height: 820)
        model.select(.task(RemoteFixtureBridge.ID.approval))
        let approval = try XCTUnwrap(model.conversations[RemoteFixtureBridge.ID.approval])
        try await waitUntil { approval.isLoaded }
        try await render("remote-host-approval", size: size, model: model, hosts: hosts) { elements in
            XCTAssertTrue(elements.contains { $0.label == "Allow" }, elements.description)
            XCTAssertTrue(elements.contains { $0.label == "Approve the index migration, Claude Code" }, elements.description)
        }

        model.select(.task(RemoteFixtureBridge.ID.question))
        let question = try XCTUnwrap(model.conversations[RemoteFixtureBridge.ID.question])
        try await waitUntil { question.isLoaded }
        try await render("remote-host-question", size: size, model: model, hosts: hosts)

        model.select(.task(RemoteFixtureBridge.ID.approval))
        let request = try XCTUnwrap(approval.presentation.turns.last?.requests.first)
        model.respond(taskID: RemoteFixtureBridge.ID.approval, requestID: request.id,
                      route: try XCTUnwrap(request.responses.last?.route))
        try await waitUntil { approval.presentation.turns.last?.status == .completed }
        let command = try XCTUnwrap(approval.presentation.turns.last?.work.first { item in
            if case let .tool(tool) = item.kind { return tool.isApproved }
            return false
        })
        model.loadDetail(RemoteFixtureBridge.ID.approval, itemID: command.id)
        try await waitUntil { approval.details[command.id] != nil }
        try await render("remote-host-answered", size: size, model: model, hosts: hosts)

        // The next turn waits on an approval again, its work in view: its lines opened with what they hold.
        try await waitUntil { approval.presentation.turns.last?.requests.isEmpty == false }
        let lines = try XCTUnwrap(approval.presentation.turns.last).work.filter { item in
            if case let .tool(tool) = item.kind { return tool.loadsDetailOnOpen }
            return false
        }
        XCTAssertFalse(lines.isEmpty)
        for line in lines { model.loadDetail(RemoteFixtureBridge.ID.approval, itemID: line.id) }
        try await waitUntil { lines.allSatisfy { approval.details[$0.id] != nil } }
        try await render("remote-host-lines", size: size, model: model, hosts: hosts, opensDetails: true)

        model.select(.newTask)
        try await render("remote-host-new", size: size, model: model, hosts: hosts)

        model.select(.task(RemoteFixtureBridge.ID.approval))
        await stack.server.shutdown(reason: "quitting")
        stack.stop()
        stopped = true
        try await waitUntil { if case .unreachable = model.connection { true } else { false } }
        try await render("remote-host-offline", size: size, model: model, hosts: hosts) { elements in
            XCTAssertTrue(elements.contains { $0.label == L10n.string("Try Again") }, elements.description)
        }
        hosts.close(host.id)
    }

    // MARK: - Helpers

    private func render(_ name: String, size: NSSize, model: RemoteHostModel, hosts: RemoteHostDirectory,
                        opensDetails: Bool = false,
                        check: ([WindowlessRender.AccessibilityElement]) -> Void = { _ in }) async throws {
        try await render(name, size: size, titled: true, title: model.name, subtitle: RemoteConnectionText.line(model.connection)) {
            RemoteHostView(model: model, directory: hosts)
                .environment(\.opensDetailsForReview, opensDetails)
        } check: { check($0) }
    }

    /// Draws the view in an unshown window of `size`, in both appearances; a titled window draws its title
    /// bar too, as the host's window shows its name and connection there.
    private func render<Content: View>(_ name: String, size: NSSize, titled: Bool, title: String = "", subtitle: String = "",
                                       @ViewBuilder content: () -> Content,
                                       check: ([WindowlessRender.AccessibilityElement]) -> Void = { _ in }) async throws {
        let directory = try WindowlessRender.directory("remote-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            let hosting = NSHostingView(rootView: content().environment(\.colorScheme, appearance.colorScheme))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: titled ? [.titled, .closable, .miniaturizable, .resizable] : [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance.appKitName)
            window.title = title
            window.subtitle = subtitle
            window.contentView = hosting
            defer {
                window.contentView = nil
                window.close()
            }
            // The main actor is given back between passes, so the views' tasks (a new task's menus) finish.
            for _ in 0..<20 {
                Self.turnRunLoop(hosting)
                await Task.yield()
                try await Task.sleep(for: .milliseconds(15))
            }
            let frame = titled ? (hosting.superview ?? hosting) : hosting
            let bitmap = try WindowlessRender.capture(frame)
            XCTAssertTrue(WindowlessRender.drawsContent(bitmap, step: 6))
            try WindowlessRender.writePNG(bitmap, to: directory.appending(path: "\(name)-\(appearance.suffix).png"))
            if appearance == .light { check(WindowlessRender.accessibilityElements(in: hosting)) }
        }
    }

    /// Lays the view out and turns the main run loop once, as `WindowlessRender.Host.settle` does.
    private static func turnRunLoop(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
}
