import AppKit
import Observation
@preconcurrency import SwiftTerm
import SwiftUI

/// The folders a terminal panel's task uses: a shell opened outside them (on the new-task screen
/// before its folder changed, or for a task that started in a new worktree) says so, as the Codex
/// app's terminal does, and offers to start again in the task's folder.
struct TerminalFolderContext {
    /// The task's folders, the one a restart opens in first.
    let folders: [URL]
    /// Ends the shell and opens the next one in `folders[0]`.
    let restart: () -> Void

    func contains(_ folder: URL) -> Bool {
        folders.contains { Project.isSamePath($0, folder) }
    }
}

struct TerminalPane: View {
    private var workspaceURL: URL { session.workspaceURL }
    /// A command a conversation card handed to this terminal (`TaskWorkspaceState.handOffToTerminal`).
    var handoff: TerminalCommandRequest?
    /// Called once the handoff has been typed, or could not be: either way it is done with.
    var onHandoffDone: (TerminalCommandRequest.ID) -> Void = { _ in }
    let onClose: () -> Void
    var folder: TerminalFolderContext? = nil
    @State private var session: NativeTerminalSession
    /// The task's workspace keeps the shell (`TaskWorkspaceState.terminal`), which goes on while no
    /// panel shows it; otherwise the panel's own shell ends with the panel.
    private let isShared: Bool
    @State private var confirmsRestart = false
    @State private var confirmsFolderRestart = false
    @State private var hasStarted: Bool
    @FocusState private var isStartFocused: Bool
    @Environment(\.taskKeyboardFocus) private var keyboardFocus
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    init(
        workspaceURL: URL,
        handoff: TerminalCommandRequest? = nil,
        launch: ShellLaunchEnvironment = .userLoginShell(),
        startsAutomatically: Bool = true,
        taskID: UUID? = nil,
        onHandoffDone: @escaping (TerminalCommandRequest.ID) -> Void = { _ in },
        onClose: @escaping () -> Void
    ) {
        self.handoff = handoff
        self.onHandoffDone = onHandoffDone
        self.onClose = onClose
        isShared = false
        _session = State(initialValue: NativeTerminalSession(workspaceURL: workspaceURL, launch: launch, taskID: taskID))
        _hasStarted = State(initialValue: startsAutomatically)
    }

    /// A panel showing the shell its task's workspace keeps. A shell already running shows as it is.
    init(
        session: NativeTerminalSession,
        handoff: TerminalCommandRequest? = nil,
        startsAutomatically: Bool = true,
        folder: TerminalFolderContext? = nil,
        onHandoffDone: @escaping (TerminalCommandRequest.ID) -> Void = { _ in },
        onClose: @escaping () -> Void
    ) {
        self.handoff = handoff
        self.onHandoffDone = onHandoffDone
        self.onClose = onClose
        self.folder = folder
        isShared = true
        _session = State(initialValue: session)
        _hasStarted = State(initialValue: startsAutomatically || session.hasShell)
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkSurfaceHeader(
                title: workspaceURL.lastPathComponent,
                systemName: "terminal",
                workspaceURL: workspaceURL,
                status: session.isRunning ? nil : session.statusText,
                statusTint: session.exitCode.map({ $0 != 0 }) == true || session.terminationSignal != nil
                    ? .red : .secondary,
                onClose: onClose
            ) {
                EmptyView()

            }
            .contextMenu {
                if hasStarted {
                    Button(L10n.string("Restart")) {
                        if session.isRunning { confirmsRestart = true } else { session.restart() }
                    }
                }
            }

            if let folder, let target = folder.folders.first, hasStarted, !folder.contains(workspaceURL),
               session.dismissedFolderNotice.map({ !Project.isSamePath($0, target) }) ?? true {
                folderNotice(target)
            }

            if hasStarted {
                SwiftTermHost(session: session, isDark: colorScheme == .dark, fontSize: 12 * interfaceScale)
                .id(session.generation)
                .padding(.horizontal, 10).padding(.bottom, 8)
                .background(Color(nsColor: TerminalAppearance.background(isDark: colorScheme == .dark)))
            } else {
                VStack(spacing: 10) {
                    Button(L10n.string("Start terminal")) {
                        hasStarted = true
                        keyboardFocus?.move(to: .terminal)
                    }
                        .buttonStyle(.bordered)
                        .focused($isStartFocused)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ParityTheme.canvas)
            }
        }
        .confirmationDialog(L10n.string("Restart terminal?"), isPresented: $confirmsRestart) {
            Button(L10n.string("Restart terminal"), role: .destructive) { session.restart() }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("This stops the terminal's running processes and clears its output."))
        }
        .confirmationDialog(L10n.string("Restart terminal?"), isPresented: $confirmsFolderRestart) {
            Button(L10n.string("Restart terminal"), role: .destructive) { folder?.restart() }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("This stops the terminal's running processes and clears its output."))
        }
        .onAppear {
            if isShared { session.panelAppeared() }
        }
        .onDisappear {
            if isShared { session.panelDisappeared() } else { session.stop() }
        }
        .task(id: handoff?.id) {
            guard let handoff else { return }
            await type(handoff)
        }
        .task(id: keyboardFocus?.request) {
            guard let request = keyboardFocus?.request, request.target == .terminal else { return }
            await Task.yield()
            guard !Task.isCancelled, keyboardFocus?.request == request else { return }
            if hasStarted {
                if session.focus() { keyboardFocus?.consume(request) }
            } else {
                keyboardFocus?.consume(request)
                isStartFocused = true
            }
        }
    }

    /// Puts a handed-off command at the shell's prompt without running it: the person reads it and
    /// presses Return. A terminal that has not started starts, as the click asked for it; one whose
    /// shell has exited starts a new shell, as Restart does without asking when nothing runs.
    private func type(_ handoff: TerminalCommandRequest) async {
        if !hasStarted {
            hasStarted = true
        } else if !session.isRunning {
            session.restart()
        }
        _ = await session.typeForReviewWhenReady(handoff.command)
        guard !Task.isCancelled else { return }
        onHandoffDone(handoff.id)
    }

    /// The Codex app's "This terminal is outside this chat's workspaces" with Open new terminal: the
    /// shell stays where it is until the person starts the next one in the task's folder.
    private func folderNotice(_ target: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(L10n.format("This terminal opened in %@, outside the task's folder.", workspaceURL.lastPathComponent))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(L10n.format("Restart in %@", target.lastPathComponent)) {
                if session.isRunning { confirmsFolderRestart = true } else { folder?.restart() }
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .help(target.path(percentEncoded: false))
            ParityIconButton(systemName: "xmark", help: L10n.string("Dismiss")) {
                session.dismissedFolderNotice = target
            }
        }
        .font(.system(size: 11.5 * interfaceScale))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(ParityTheme.subtleFill)
    }
}

@MainActor
enum TerminalAppearance {
    static func background(isDark: Bool) -> NSColor {
        isDark ? NativeTerminalSession.backgroundColor : NSColor(calibratedWhite: 0.985, alpha: 1)
    }

    static func foreground(isDark: Bool) -> NSColor {
        isDark ? NativeTerminalSession.foregroundColor : NSColor(calibratedWhite: 0.16, alpha: 1)
    }

    static func palette(isDark: Bool) -> [SwiftTerm.Color] {
        let hex: [UInt32] = isDark
            ? [0x202124, 0xf07178, 0x9ccc65, 0xffcb6b, 0x82aaff, 0xc792ea, 0x89ddff, 0xdadce0,
               0x73777f, 0xff8b92, 0xb5d98a, 0xffdf91, 0xa5c2ff, 0xdbaff5, 0xb0eaff, 0xffffff]
            : [0x202124, 0xb3261e, 0x216e39, 0x805600, 0x174ea6, 0x7839a5, 0x006778, 0x5f6368,
               0x6c7075, 0xc0342b, 0x2b7741, 0x916200, 0x285db0, 0x8645ad, 0x147180, 0x3c4043]
        return hex.map { value in
            SwiftTerm.Color(red: UInt16((value >> 16) & 255) * 257,
                            green: UInt16((value >> 8) & 255) * 257,
                            blue: UInt16(value & 255) * 257)
        }
    }
}

@MainActor
@Observable
final class NativeTerminalSession: NSObject, @MainActor LocalProcessTerminalViewDelegate, NativeSurfaceResource {
    static let backgroundColor = NSColor(
        calibratedRed: 20 / 255,
        green: 22 / 255,
        blue: 26 / 255,
        alpha: 1
    )
    static let foregroundColor = NSColor(
        calibratedRed: 218 / 255,
        green: 221 / 255,
        blue: 226 / 255,
        alpha: 1
    )

    let workspaceURL: URL
    private(set) var isRunning = false
    private(set) var title: String?
    private(set) var currentDirectory: String?
    private(set) var exitCode: Int32?
    private(set) var terminationSignal: Int32?
    private(set) var generation = 0
    /// The folder the person last dismissed the notice for (`TerminalFolderContext`).
    var dismissedFolderNotice: URL?
    /// The shell ended for good (`end()`); its task's workspace opens a new one next.
    private(set) var hasEnded = false

    /// The shell's view, kept with the shell rather than by the panel, so a panel drawn again for the
    /// same shell (the task the new-task screen started, the same task in another place) shows the same
    /// screen and scrollback. Each panel mounts it in a host of its own (`TerminalViewHost`).
    @ObservationIgnored private var terminalView: LocalProcessTerminalView?
    /// When the shell last printed, while its view reports it (`NativeTerminalView`).
    @ObservationIgnored private var lastOutputAt: ContinuousClock.Instant?
    /// Panels showing a shell the task's workspace keeps.
    @ObservationIgnored private var shownPanels = 0

    /// The shell it starts, the one launch bash mode's shell shares: the person's login shell, or
    /// a test's zsh with its own `ZDOTDIR` so it neither reads their rc files nor writes their
    /// shell history.
    let launch: ShellLaunchEnvironment
    /// The task whose panel this is: its shell, with what it starts, counts toward the task in
    /// Task Resource Usage. Nil on the new-task screen until the task starts (`move(toTask:)`).
    @ObservationIgnored private(set) var taskID: UUID?
    @ObservationIgnored private var registeredShellPID: Int32?

    init(workspaceURL: URL, launch: ShellLaunchEnvironment = .userLoginShell(), taskID: UUID? = nil) {
        self.workspaceURL = workspaceURL.standardizedFileURL
        self.launch = launch
        self.taskID = taskID
        super.init()
        NativeSurfaceResourceRegistry.shared.register(self)
    }

    /// A view has started the shell and not been stopped.
    var hasShell: Bool { terminalView != nil }

    /// The shell's view, which starts the shell the first time it is asked for after a stop.
    func view(make: () -> LocalProcessTerminalView) -> LocalProcessTerminalView {
        if let terminalView { return terminalView }
        let view = make()
        attach(view)
        return view
    }

    /// The shell now counts toward `id`: the task the new-task screen started, which took it over.
    func move(toTask id: UUID) {
        guard taskID != id else { return }
        unregisterShell()
        taskID = id
        if let terminalView, isRunning { registerShell(of: terminalView) }
    }

    /// A panel shows a shell its task's workspace keeps.
    func panelAppeared() {
        shownPanels += 1
    }

    /// A panel stopped showing it. A running shell goes on without one, as the Codex app's and VS
    /// Code's terminals do when their panel hides or another thread shows: it ends when the person
    /// exits or restarts it, with its task (`TaskWorkspaceState.endTerminal`), or when Yardlet quits.
    /// One that exited, or never started, ends once no panel shows it, so the next panel opens a new
    /// shell. That is checked after the window's update, so a panel drawn again in the same update
    /// (the task the new-task screen started, the same task in another place) keeps it.
    func panelDisappeared() {
        shownPanels = max(0, shownPanels - 1)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.shownPanels == 0, !self.hasEnded, !self.isRunning else { return }
            self.end()
        }
    }

    /// Ends the shell for good: the workspace that keeps it opens a new one next time.
    func end() {
        hasEnded = true
        stop()
    }

    private func registerShell(of view: LocalProcessTerminalView) {
        unregisterShell()
        let shellPID = view.process.shellPid
        guard let taskID, shellPID > 0 else { return }
        TaskProcessRegistry.shared.register(shellPID, owner: .task(taskID))
        registeredShellPID = shellPID
    }

    private func unregisterShell() {
        guard let taskID, let shellPID = registeredShellPID else { return }
        TaskProcessRegistry.shared.unregister(shellPID, owner: .task(taskID))
        registeredShellPID = nil
    }

    func attach(_ view: LocalProcessTerminalView) {
        guard terminalView !== view else { return }
        terminalView = view
        view.processDelegate = self
        exitCode = nil
        terminationSignal = nil
        currentDirectory = workspaceURL.path(percentEncoded: false)
        lastOutputAt = nil
        (view as? NativeTerminalView)?.onOutput = { [weak self] in self?.lastOutputAt = .now }

        let start = launch.start(in: workspaceURL)
        view.startProcess(
            executable: start.executable,
            args: start.arguments,
            environment: start.environment,
            execName: start.processName,
            currentDirectory: start.currentDirectory
        )
        isRunning = true
        registerShell(of: view)
    }

    func restart() {
        stop()
        generation += 1
    }

    func stop() {
        if let terminalView {
            terminateProcess(in: terminalView)
        }
        terminalView = nil
        isRunning = false
    }

    func terminateForApplicationShutdown() {
        stop()
    }

    private func terminateProcess(in view: LocalProcessTerminalView) {
        unregisterShell()
        let shellPID = view.process.shellPid
        guard view.process.running, shellPID > 0 else { return }

        NativeProcessTree.terminate(rootPID: shellPID)
        view.terminate()
    }

    func send(_ text: String) {
        guard let terminalView, isRunning else { return }
        let bytes = Array(text.utf8)
        terminalView.send(source: terminalView, data: bytes[...])
    }

    /// Sends `text` once the shell is at its prompt: running, and quiet for `quietPeriod` since it
    /// last printed. A shell that has just started prints its startup files' output and its prompt
    /// first; text typed before the prompt would be echoed twice. Past `limit` it is sent if a shell
    /// runs, whatever it printed. False when no shell ran in time or the wait was cancelled.
    @discardableResult
    /// A command typed for the person to review and run: the text a shell takes as input without
    /// executing it. Without a trailing Return a one-line command waits at the prompt. A command over
    /// several lines goes as a bracketed paste when the shell asked for that mode (zsh's line editor
    /// does), so its inner line breaks wait too; a shell that did not ask gets the lines as typed.
    static func reviewText(_ command: String, bracketedPaste: Bool = true) -> String {
        let trimmed = command.trimmingCharacters(in: .newlines)
        guard trimmed.contains(where: \.isNewline), bracketedPaste else { return trimmed }
        return "\u{1B}[200~" + trimmed + "\u{1B}[201~"
    }

    /// Types a command for review, as `reviewText`, using the shell's own paste mode.
    private func sendForReview(_ command: String) {
        send(Self.reviewText(command, bracketedPaste: terminalView?.getTerminal().bracketedPasteMode ?? false))
    }

    /// Waits for the shell's prompt as `typeWhenReady` does, then types `command` for review, in the
    /// paste mode the shell asked for by then.
    func typeForReviewWhenReady(_ command: String) async -> Bool {
        guard await waitUntilReady() else { return false }
        sendForReview(command)
        return true
    }

    func typeWhenReady(
        _ text: String, quietPeriod: Duration = .milliseconds(300), limit: Duration = .seconds(10)
    ) async -> Bool {
        guard await waitUntilReady(quietPeriod: quietPeriod, limit: limit) else { return false }
        send(text)
        return true
    }

    /// The shell is running and its output has been quiet for `quietPeriod`: it is at its prompt.
    private func waitUntilReady(
        quietPeriod: Duration = .milliseconds(300), limit: Duration = .seconds(10)
    ) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if isRunning, let lastOutputAt, ContinuousClock.now - lastOutputAt >= quietPeriod { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !Task.isCancelled && isRunning
    }

    func focus() -> Bool {
        guard let terminalView, let window = terminalView.window else { return false }
        return window.makeFirstResponder(terminalView)
    }

    var bufferText: String {
        terminalView?.getTerminal().unwrappedText ?? ""
    }

    var statusText: String {
        if isRunning { return L10n.string("Running") }
        if let terminationSignal { return L10n.format("Stopped by signal %d", terminationSignal) }
        if let exitCode { return L10n.format("Exited (%d)", exitCode) }
        return L10n.string("Stopped")
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        self.title = title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        currentDirectory = directory
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        // SwiftTerm's macOS forkpty backend supplies waitpid status, not WEXITSTATUS.
        if let status = exitCode {
            let signal = status & 0x7f
            self.exitCode = signal == 0 ? (status >> 8) & 0xff : nil
            terminationSignal = signal != 0 && signal != 0x7f ? signal : nil
        } else {
            self.exitCode = nil
            terminationSignal = nil
        }
        isRunning = false
        unregisterShell()
    }
}

private struct SwiftTermHost: NSViewRepresentable {
    let session: NativeTerminalSession
    let isDark: Bool
    let fontSize: CGFloat

    func makeNSView(context: Context) -> TerminalViewHost {
        let view = session.view {
            let view = NativeTerminalView(
                frame: .zero,
                font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                options: TerminalOptions(cursorStyle: .steadyBlock, scrollback: 5_000)
            )
            view.wantsLayer = true
            view.getTerminal().setCursorStyle(CursorStyle.steadyBlock)
            view.metalBufferingMode = MetalBufferingMode.perFrameAggregated
            try? view.setUseMetal(false)
            return view
        }
        applyAppearance(to: view, coordinator: context.coordinator)
        return TerminalViewHost(terminal: view)
    }

    func updateNSView(_ nsView: TerminalViewHost, context: Context) {
        applyAppearance(to: nsView.terminal, coordinator: context.coordinator)
    }

    private func applyAppearance(to view: LocalProcessTerminalView, coordinator: Coordinator) {
        if coordinator.isDark != isDark {
            view.nativeForegroundColor = TerminalAppearance.foreground(isDark: isDark)
            view.nativeBackgroundColor = TerminalAppearance.background(isDark: isDark)
            view.layer?.backgroundColor = TerminalAppearance.background(isDark: isDark).cgColor
            view.installColors(TerminalAppearance.palette(isDark: isDark))
            view.caretColor = NSColor.systemBlue
            coordinator.isDark = isDark
        }
        if coordinator.fontSize != fontSize {
            view.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            coordinator.fontSize = fontSize
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    static func dismantleNSView(_ nsView: TerminalViewHost, coordinator: Coordinator) {
        nsView.unmount()
    }

    @MainActor
    final class Coordinator {
        let session: NativeTerminalSession
        var isDark: Bool?
        var fontSize: CGFloat?

        init(session: NativeTerminalSession) {
            self.session = session
        }
    }
}

/// A fresh host for each panel, as `BrowserWebViewHost` is for a page: the shell's view moves into
/// the next panel's host, and the teardown of the panel it left, which SwiftUI may run after, cannot
/// take it out of its new place.
final class TerminalViewHost: NSView {
    let terminal: LocalProcessTerminalView

    init(terminal: LocalProcessTerminalView) {
        self.terminal = terminal
        super.init(frame: terminal.frame)
        terminal.removeFromSuperview()
        terminal.autoresizingMask = [.width, .height]
        addSubview(terminal)
        terminal.frame = bounds
    }

    required init?(coder: NSCoder) { nil }

    func unmount() {
        guard terminal.superview === self else { return }
        if let window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: terminal) {
            window.makeFirstResponder(nil)
        }
        terminal.removeFromSuperview()
    }
}

private struct TerminalShellLaunchKey: EnvironmentKey {
    static let defaultValue = ShellLaunchEnvironment.userLoginShell()
}

extension EnvironmentValues {
    /// The shell a task's terminal starts: the person's login shell, or a test's zsh that reads its
    /// own `ZDOTDIR`, so what a test types never reaches the person's shell history.
    var terminalShellLaunch: ShellLaunchEnvironment {
        get { self[TerminalShellLaunchKey.self] }
        set { self[TerminalShellLaunchKey.self] = newValue }
    }
}

/// The terminal panel's view: SwiftTerm's, telling its session when the shell prints, so a command
/// handed to the terminal waits for the prompt (`NativeTerminalSession.typeWhenReady`).
final class NativeTerminalView: LocalProcessTerminalView {
    var onOutput: (() -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onOutput?()
    }
}
