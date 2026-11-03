#if DEBUG
import AppKit
import CoreImage
import Foundation
import IOSurface
import SwiftUI

/// QA for a tab shown again after it was hidden (docs/BROWSER_HOST.md §3 "Drawing (power)" and "Memory saver"),
/// against the real browser host and the real panel, run by `run-check.sh … --ui-fixture-browser-check-only=idle-return`.
/// The task's panel shows a page in one color edge to edge (`/idle`), and the page is hidden and shown again the ways
/// an idle panel is: its window covered (the view hidden), resized meanwhile, the panel closed and opened again with a
/// new view (the side panel showed another tab, or the task's views were built anew), at another size, the tab
/// discarded by the memory saver meanwhile, the task's views out of the window while another task shows (and back
/// before the window is on screen), Chromium's GPU process ended and started again (as after the Mac sleeps), and last
/// a new panel opened off screen on a tab the agent used a moment ago, which its engine still draws. Chromium is told
/// memory is critical while the tab is hidden, which drops what it kept of a hidden page's drawing. Each time a frame
/// must reach the panel and show the page's color, not the panel's white. Checks land in `result.json`, and each shown
/// page as `<step>.png`.
@MainActor
final class BrowserHostIdleReturnQA {
    private let output: URL
    private let base: String
    /// The task the QA window shows, whose browser panel the steps open and close.
    private let session: UUID
    private var record: [String: JSONValue] = [:]
    private var checks: [JSONValue] = []
    private var events: [String: Int] = [:]
    private let frames = FrameCount()
    private var client: BrowserHostClient { MacBrowserHost.shared.client }

    init(output: URL, base: String, panelSession: UUID) {
        self.output = output
        self.base = base
        session = panelSession
    }

    func run() async {
        try? FileManager.default.createDirectory(at: output.appending(path: "markers"), withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(3))
        // On, as in the app by default, with Chrome's hours: only the steps' own requests discard.
        client.isMemorySaverOn = true
        guard let controller = await openPanel(), let tab = controller.tab else { return await finish() }
        tab.addEventObserver { [weak self] event in
            switch event {
            case .hidden: self?.events["hidden", default: 0] += 1
            case .discarded: self?.events["discarded", default: 0] += 1
            case .pageCrashed: self?.events["crashed", default: 0] += 1
            default: break
            }
        }
        controller.addressInput = base + "idle?n=1"
        controller.submitAddress()
        let painted = await waitUntil(.seconds(15)) { controller.title == "Idle 1" && Self.showsPage(controller.view) }
        check("the panel shows the page", painted, describe(controller))
        save(controller.view, as: "shown")

        await occludeAndReturn(controller, tab)
        await resizeWhileHidden(controller, tab)
        await reopen(tab, step: "reopened", discarding: false)
        await reopen(tab, step: "reopened-resized", discarding: false, resizing: true)
        await reopen(tab, step: "reopened-discarded", discarding: true)
        await parkAndReturn(tab, coveredOnReturn: false)
        await parkAndReturn(tab, coveredOnReturn: true)
        await reopenAfterGPURestart(tab)
        // Last: the agent's use keeps the tab drawn for the agent's window (`--ui-fixture-browser-agent-visible`).
        await agentTabOpenedOffScreen(tab)
        await finish()
    }

    // MARK: Steps

    /// The window is covered, miniaturized or on another space while the Mac idles: the tab hides and Chromium drops its
    /// drawing; back on screen, the panel paints the page again.
    private func occludeAndReturn(_ controller: BrowserHostPaneController, _ tab: BrowserTab) async {
        guard let view = controller.view else { return }
        let hidden = events["hidden", default: 0]
        view.isHidden = true
        let hid = await waitUntil(.seconds(5)) { self.events["hidden", default: 0] > hidden }
        await dropHiddenDrawing(tab)
        let before = frames.count
        view.isHidden = false
        let shown = await waitUntil(.seconds(5)) { self.frames.count > before && Self.showsPage(view) }
        check("occluded and back: the panel paints the page again", hid && shown,
              "hidden \(hid), " + describe(controller, framesSince: before))
        save(view, as: "occluded-and-back")
    }

    /// The window is resized while it is covered (the Mac's displays come back from sleep at another size): the tab
    /// is resized while hidden, and back on screen the panel paints the page at its new size.
    private func resizeWhileHidden(_ controller: BrowserHostPaneController, _ tab: BrowserTab) async {
        guard let view = controller.view, let window = view.window else { return }
        let hidden = events["hidden", default: 0]
        view.isHidden = true
        let hid = await waitUntil(.seconds(5)) { self.events["hidden", default: 0] > hidden }
        await dropHiddenDrawing(tab)
        resize(window)
        try? await Task.sleep(for: .seconds(1))
        let before = frames.count
        view.isHidden = false
        let shown = await waitUntil(.seconds(5)) { self.frames.count > before && Self.showsPage(view) && Self.fits(view) }
        check("resized while occluded: the panel paints the page at its new size", hid && shown,
              "hidden \(hid), " + describe(controller, framesSince: before))
        save(view, as: "resized-while-occluded")
    }

    /// The agent used the tab a moment ago, so its engine still draws it, when the panel opens off screen (its window
    /// covered) with a new view and then comes on screen.
    private func agentTabOpenedOffScreen(_ tab: BrowserTab) async {
        guard let hosting = BrowserHostPaneController.current?.view.flatMap(Self.taskHosting) else {
            return check("agent's tab opened off screen: the panel paints the page", false, "no task hosting view")
        }
        await closePanel()
        _ = await waitUntil(.seconds(5)) { !tab.isShown }
        client.noteAgentActivity(on: tab)
        hosting.isHidden = true
        guard let controller = await openPanel(waitingForFrame: false), let view = controller.view else {
            hosting.isHidden = false
            return
        }
        let attachedOffScreen = tab.isPanelAttached && tab.visiblePanelCount == 0
        try? await Task.sleep(for: .seconds(1))
        let before = frames.count
        hosting.isHidden = false
        let shown = await waitUntil(.seconds(5)) { self.frames.count > before && Self.showsPage(view) }
        check("agent's tab opened off screen: the panel paints the page once on screen", attachedOffScreen && shown,
              "attached off screen \(attachedOffScreen), " + describe(controller, framesSince: before))
        save(view, as: "agent-tab-opened-off-screen")
        await tab.endAgentEmulation()
    }

    /// The panel is closed while the tab stays (the side panel shows another tab, or the task's views are let go), and
    /// opens again later with a new view, white until a frame arrives; with `discarding`, the memory saver discarded the
    /// tab meanwhile, and showing it loads the page again.
    private func reopen(_ tab: BrowserTab, step: String, discarding: Bool, resizing: Bool = false) async {
        let hidden = events["hidden", default: 0]
        let window = BrowserHostPaneController.current?.view?.window
        await closePanel()
        let hid = await waitUntil(.seconds(5)) { self.events["hidden", default: 0] > hidden && !tab.isShown }
        await dropHiddenDrawing(tab)
        var discarded = true
        if discarding { discarded = await discard(tab) }
        if resizing, let window { resize(window) }
        guard let controller = await openPanel(waitingForFrame: false), let view = controller.view else { return }
        let before = frames.count
        let shown = await waitUntil(.seconds(15)) { self.frames.count > before && Self.showsPage(view) && Self.fits(view) }
        check("\(step): the new panel paints the page", hid && discarded && shown && controller.tab === tab,
              "hidden \(hid), discarded \(discarding ? "\(discarded)" : "-"), same tab \(controller.tab === tab), "
                + describe(controller, framesSince: before))
        save(view, as: step)
    }

    /// The window shows another task: this task's views leave the window and its panel lets the tab go, which the memory
    /// saver discards in time. Back in the window, the panel takes the tab again and loads it.
    /// With `coveredOnReturn`, the task's views are back in the window before the window is on screen (the person comes
    /// back to Yardlet through the task's notification): the page loads again unseen, and is painted once on screen.
    private func parkAndReturn(_ tab: BrowserTab, coveredOnReturn: Bool) async {
        let name = coveredOnReturn ? "parked and back while covered" : "parked and back"
        guard let controller = BrowserHostPaneController.current, let view = controller.view,
              let hosting = Self.taskHosting(of: view), let container = hosting.superview else {
            return check("\(name): the panel paints the page again", false, "no task hosting view around the panel")
        }
        let hidden = events["hidden", default: 0]
        let frame = hosting.frame
        hosting.removeFromSuperview()
        let hid = await waitUntil(.seconds(5)) { self.events["hidden", default: 0] > hidden && !tab.isShown }
        let discarded = await discard(tab)
        let before = frames.count
        hosting.frame = frame
        if coveredOnReturn { hosting.isHidden = true }
        container.addSubview(hosting)
        var loadedUnseen = true
        if coveredOnReturn {
            loadedUnseen = await waitUntil(.seconds(15)) { !tab.isDiscarded && !tab.isLoading && controller.title == "Idle 1" }
            try? await Task.sleep(for: .seconds(1))
            hosting.isHidden = false
        }
        let shown = await waitUntil(.seconds(15)) { self.frames.count > before && Self.showsPage(view) }
        check("\(name): the panel paints the page again", hid && discarded && loadedUnseen && shown,
              "hidden \(hid), discarded \(discarded), loaded unseen \(coveredOnReturn ? "\(loadedUnseen)" : "-"), "
                + describe(controller, framesSince: before))
        save(view, as: coveredOnReturn ? "parked-and-back-covered" : "parked-and-back")
    }

    /// Chromium's GPU process ends while the tab is hidden (as when the Mac sleeps) and starts again for the next frame.
    private func reopenAfterGPURestart(_ tab: BrowserTab) async {
        let hidden = events["hidden", default: 0]
        await closePanel()
        let hid = await waitUntil(.seconds(5)) { self.events["hidden", default: 0] > hidden && !tab.isShown }
        let ended = endGPUProcess()
        try? await Task.sleep(for: .seconds(2))
        guard let controller = await openPanel(waitingForFrame: false), let view = controller.view else { return }
        let before = frames.count
        let shown = await waitUntil(.seconds(15)) { self.frames.count > before && Self.showsPage(view) }
        check("GPU process restarted: the new panel paints the page", hid && ended != nil && shown,
              "hidden \(hid), GPU process \(ended.map(String.init) ?? "not found"), " + describe(controller, framesSince: before))
        save(view, as: "gpu-restarted")

        // Ended again while the panel shows the page: the page's next change reaches the panel.
        let again = endGPUProcess()
        try? await Task.sleep(for: .seconds(2))
        let changed = frames.count
        _ = try? await tab.devTools.send("Runtime.evaluate", [
            "expression": .string("document.querySelector('h1').textContent = 'Idle page after the GPU process'; 1")
        ], timeout: .seconds(10))
        let painted = await waitUntil(.seconds(15)) { self.frames.count > changed && Self.showsPage(view) }
        check("GPU process restarted while shown: the page's change reaches the panel", again != nil && painted,
              "GPU process \(again.map(String.init) ?? "not found"), " + describe(controller, framesSince: changed))
        save(view, as: "gpu-restarted-shown")
    }

    // MARK: Helpers

    /// Chromium is told memory is critical: its frame eviction drops the saved drawing of every hidden page, as on a Mac
    /// short of memory after a long idle.
    private func dropHiddenDrawing(_ tab: BrowserTab) async {
        let answer = try? await tab.devTools.send("Memory.simulatePressureNotification", ["level": .string("critical")],
                                                  timeout: .seconds(5))
        events["pressure", default: 0] += answer == nil ? 0 : 1
        try? await Task.sleep(for: .seconds(1))
    }

    /// The memory saver's discard, asked of the host directly: the page's renderer ends and the tab keeps its page.
    private func discard(_ tab: BrowserTab) async -> Bool {
        let discarded = events["discarded", default: 0]
        client.send(.discard(tab: tab.id, urgent: false))
        return await waitUntil(.seconds(20)) { self.events["discarded", default: 0] > discarded && tab.isDiscarded }
    }

    /// Ends the QA host's GPU process (SIGTERM, as the earlier "GPU process exited unexpectedly: exit_code=15"); its pid.
    private func endGPUProcess() -> Int32? {
        guard let host = client.hostProcessID else { return nil }
        let ps = Process()
        ps.executableURL = URL(filePath: "/bin/ps")
        ps.arguments = ["-A", "-o", "pid=,ppid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        guard (try? ps.run()) != nil else { return nil }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), Int(fields[1]) == host,
                  fields[2].contains("--type=gpu-process") else { continue }
            return kill(pid, SIGTERM) == 0 ? pid : nil
        }
        return nil
    }

    /// Grows or shrinks the QA window by turns, which stays off every screen.
    private func resize(_ window: NSWindow) {
        let size = window.contentLayoutRect.size
        let grow: CGFloat = size.width < 1500 ? 160 : -160
        window.setContentSize(NSSize(width: size.width + grow, height: size.height + grow / 2))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// The frame on screen is the view's size, at the window's scale.
    private static func fits(_ view: BrowserHostView) -> Bool {
        guard let surface = view.viewSurface else { return false }
        let scale = view.window?.backingScaleFactor ?? 2
        return abs(IOSurfaceGetWidth(surface) - Int((view.bounds.width * scale).rounded())) <= 2
            && abs(IOSurfaceGetHeight(surface) - Int((view.bounds.height * scale).rounded())) <= 2
    }

    /// The window's own hosting view of the task the panel is in (`TaskSurfaceHostings`).
    private static func taskHosting(of view: NSView) -> NSView? {
        var current = view.superview
        while let candidate = current {
            if candidate is NSHostingView<AnyView> { return candidate }
            current = candidate.superview
        }
        return nil
    }

    /// The color at the middle of the lower half of what the panel shows, below the page's heading; nil when it shows no
    /// frame, which leaves the panel's white.
    private static func color(_ view: BrowserHostView?) -> (red: Int, green: Int, blue: Int)? {
        guard let surface = view?.viewSurface else { return nil }
        IOSurfaceLock(surface, [.readOnly], nil)
        defer { IOSurfaceUnlock(surface, [.readOnly], nil) }
        let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
        guard width > 0, height > 0 else { return nil }
        let pixel = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
            + (height * 3 / 4) * IOSurfaceGetBytesPerRow(surface) + (width / 2) * 4
        return IOSurfaceGetPixelFormat(surface) == SurfaceFormat.rgba
            ? (Int(pixel[0]), Int(pixel[1]), Int(pixel[2])) : (Int(pixel[2]), Int(pixel[1]), Int(pixel[0]))
    }

    private enum SurfaceFormat {
        static let rgba: OSType = 0x5247_4241
    }

    /// The panel shows the `/idle` page's blue, not white.
    private static func showsPage(_ view: BrowserHostView?) -> Bool {
        guard let color = color(view) else { return false }
        return color.blue > 140 && color.red < 110 && color.green < 170
    }

    private func describe(_ controller: BrowserHostPaneController, framesSince before: Int? = nil) -> String {
        let tab = controller.tab
        let shown = Self.color(controller.view).map { "rgb(\($0.red),\($0.green),\($0.blue))" } ?? "no frame (white)"
        let size = controller.view?.viewSurface.map { "\(IOSurfaceGetWidth($0))×\(IOSurfaceGetHeight($0))" } ?? "-"
        let viewSize = controller.view.map { "\(Int($0.bounds.width))×\(Int($0.bounds.height))" } ?? "-"
        return "frame \(size) for view \(viewSize) pt, frames \(before.map { "\(frames.count - $0)" } ?? "\(frames.count)"), shows \(shown), "
            + "title \(controller.title), tab \(tab?.id ?? -1) shown \(tab?.isShown ?? false) discarded \(tab?.isDiscarded ?? false) "
            + "panels \(tab?.panelCount ?? 0)/\(tab?.visiblePanelCount ?? 0), events \(events.sorted { $0.key < $1.key })"
    }

    private func openPanel(waitingForFrame: Bool = true) async -> BrowserHostPaneController? {
        let previous = BrowserHostPaneController.current
        NotificationCenter.default.post(name: BrowserHostQAFixture.openBrowserPanel, object: nil)
        guard await waitUntil(.seconds(10), { BrowserHostPaneController.current !== previous
                && BrowserHostPaneController.current?.view != nil && BrowserHostPaneController.current?.hasTab == true }),
              let controller = BrowserHostPaneController.current else {
            check("the task's browser panel opens", false, "no panel")
            return nil
        }
        let frames = frames
        controller.frameObserver = { _, _ in frames.add() }
        if waitingForFrame { _ = await waitUntil(.seconds(10)) { controller.view?.viewSurface != nil } }
        return controller
    }

    private func closePanel() async {
        NotificationCenter.default.post(name: BrowserHostQAFixture.closeBrowserPanel, object: nil)
        _ = await waitUntil(.seconds(5)) { BrowserHostPaneController.current?.hasTab != true }
        try? await Task.sleep(for: .milliseconds(500))
    }

    /// The panel's frame as PNG, for the record.
    private func save(_ view: BrowserHostView?, as step: String) {
        guard let surface = view?.viewSurface else {
            record["\(step)-png"] = .string("no frame: the panel showed its white background")
            return
        }
        let image = CIImage(ioSurface: surface)
        guard let picture = CIContext().createCGImage(image, from: image.extent) else { return }
        try? NSBitmapImageRep(cgImage: picture).representation(using: .png, properties: [:])?
            .write(to: output.appending(path: "\(step).png"))
    }

    private func waitUntil(_ timeout: Duration, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return true
    }

    private func check(_ name: String, _ ok: Bool, _ detail: String) {
        checks.append(.object(["check": .string(name), "ok": .bool(ok), "detail": .string(String(detail.prefix(800)))]))
        write()
    }

    private func write() {
        record["checks"] = .array(checks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? encoder.encode(JSONValue.object(record)).write(to: output.appending(path: "result.json"), options: .atomic)
    }

    private func finish() async {
        write()
        try? "done".write(to: output.appending(path: "markers/finished"), atomically: true, encoding: .utf8)
        client.terminateHost()
        try? await Task.sleep(for: .seconds(1))
        endBrowserQA(checks: checks)
    }
}

/// Frames placed on the panel's screen, counted on the thread that placed them.
private final class FrameCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
}
#endif
