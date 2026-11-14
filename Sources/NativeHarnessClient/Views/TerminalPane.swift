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

/// The task's terminal tabs, which the panel's header shows as the side panel shows its tabs, with a
/// + for another tab in the task's folder. The task's workspace keeps them (`TaskWorkspaceState.terminals`).
struct TerminalTabsContext {
    let workspace: TaskWorkspaceState
    /// Where a new tab opens: the task's folder, or the new-task screen's.
    let folder: URL
    let launch: ShellLaunchEnvironment
    let taskID: UUID?
}

/// One half of a split terminal: the tab's name over its screen, with its close, so each half says which
/// tab it shows; the strip above still lists every tab.
private struct TerminalSplitHalf<Content: View>: View {
    let session: NativeTerminalSession
    let title: String
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "terminal").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(title).lineLimit(1).truncationMode(.middle)
                if !session.isRunning {
                    Text(session.statusText).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                ParityIconButton(systemName: "xmark", help: L10n.string("Close tab"), action: onClose)
            }
            .font(.caption)
            .padding(.leading, 12).padding(.trailing, 4)
            .frame(height: 26)
            .background(Color(nsColor: TerminalAppearance.background(isDark: colorScheme == .dark)))
            content()
        }
    }
}

/// What a terminal tab's menu adds to the side panel's tab menu (`WorkSurfaceTabMenu`).
struct TerminalTabMenuActions: Sendable {
    var rename: @MainActor @Sendable (String) -> Void
    var restart: @MainActor @Sendable (String) -> Void
}

struct TerminalPane: View {
    private var workspaceURL: URL { session.workspaceURL }
    /// A command a conversation card handed to this terminal (`TaskWorkspaceState.handOffToTerminal`).
    var handoff: TerminalCommandRequest?
    /// Called once the handoff has been typed, or could not be: either way it is done with.
    var onHandoffDone: (TerminalCommandRequest.ID) -> Void = { _ in }
    let onClose: () -> Void
    var folder: TerminalFolderContext? = nil
    var tabs: TerminalTabsContext? = nil
    /// The terminal as the side panel's Terminal tab (`TerminalLocation.right`): the side panel's strip
    /// above, the terminal's own tabs in a row below it.
    var isInSidePanel = false
    /// Adds a selection in the terminal to the task's message, while the terminal is shared.
    var onAttachSelection: ((_ selection: String, _ tabTitle: String) -> Void)? = nil
    @State private var session: NativeTerminalSession
    /// The task's workspace keeps the shell (`TaskWorkspaceState.terminal`), which goes on while no
    /// panel shows it; otherwise the panel's own shell ends with the panel.
    private let isShared: Bool
    /// A tab to restart where a program still runs, until the person says.
    @State private var restarting: NativeTerminalSession?
    @State private var confirmsFolderRestart = false
    /// Tabs to close where a program still runs, until the person says.
    @State private var closing: [NativeTerminalSession]?
    @State private var renaming: NativeTerminalSession?
    @State private var renameText = ""
    @State private var hasStarted: Bool
    @FocusState private var isStartFocused: Bool
    @Environment(\.taskKeyboardFocus) private var keyboardFocus
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.yardletCodeFont) private var codeFont
    @AppStorage(TerminalSharingPreference.key) private var sharesTerminal = true

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

    /// A panel showing a tab its task's workspace keeps. A shell already running shows as it is.
    init(
        session: NativeTerminalSession,
        tabs: TerminalTabsContext? = nil,
        handoff: TerminalCommandRequest? = nil,
        startsAutomatically: Bool = true,
        folder: TerminalFolderContext? = nil,
        onAttachSelection: ((_ selection: String, _ tabTitle: String) -> Void)? = nil,
        onHandoffDone: @escaping (TerminalCommandRequest.ID) -> Void = { _ in },
        isInSidePanel: Bool = false,
        onClose: @escaping () -> Void
    ) {
        self.onAttachSelection = onAttachSelection
        self.isInSidePanel = isInSidePanel
        self.handoff = handoff
        self.onHandoffDone = onHandoffDone
        self.onClose = onClose
        self.folder = folder
        self.tabs = tabs
        isShared = true
        _session = State(initialValue: session)
        _hasStarted = State(initialValue: startsAutomatically || session.hasShell)
    }

    var body: some View {
        let titles = TerminalTabTitle.titles(for: tabs?.workspace.terminals ?? [session])
        VStack(spacing: 0) {
            if isInSidePanel {
                // The side panel's strip, the terminal its Terminal tab, whose close hides the terminal.
                WorkSurfaceHeader(title: L10n.string("Terminal"), systemName: "terminal", workspaceURL: workspaceURL,
                                  onClose: onClose) { EmptyView() }
                tabsHeader(titles: titles)
                    .environment(\.workSurfaceHeaderRow, nil)
            } else {
                tabsHeader(titles: titles)
            }

            if let folder, let target = folder.folders.first, hasStarted, !folder.contains(workspaceURL),
               session.dismissedFolderNotice.map({ !Project.isSamePath($0, target) }) ?? true {
                folderNotice(target)
            }

            if hasStarted {
                if let split = tabs?.workspace.splitTerminal {
                    // Side by side below the conversation, one above the other in the narrower side panel.
                    let layout = isInSidePanel ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
                    layout {
                        TerminalSplitHalf(session: session, title: title(of: session, in: titles),
                                          onClose: { close([session]) }) {
                            terminalBody(session, titles: titles)
                        }
                        Divider()
                        TerminalSplitHalf(session: split, title: title(of: split, in: titles),
                                          onClose: { close([split]) }) {
                            terminalBody(split, titles: titles)
                        }
                        .onAppear { split.panelAppeared() }
                        .onDisappear { split.panelDisappeared() }
                    }
                } else {
                    terminalBody(session, titles: titles)
                }
            } else {
                VStack(spacing: 10) {
                    Button(L10n.string("Start terminal")) {
                        hasStarted = true
                        tabs?.workspace.terminalStartRequested = true
                        keyboardFocus?.move(to: .terminal)
                    }
                        .buttonStyle(.bordered)
                        .focused($isStartFocused)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ParityTheme.canvas)
            }
        }
        .confirmationDialog(L10n.string("Restart terminal?"), isPresented: Binding(
            get: { restarting != nil }, set: { if !$0 { restarting = nil } }
        )) {
            Button(L10n.string("Restart terminal"), role: .destructive) {
                if let restarting { finishRestarting(restarting) }
                restarting = nil
            }
            Button(L10n.string("Cancel"), role: .cancel) { restarting = nil }
        } message: {
            Text(L10n.string(restarting?.foregroundIsUnknown == true
                ? "Restarting clears the terminal's output and stops any commands that are running."
                : "This stops the terminal's running processes and clears its output."))
        }
        .confirmationDialog(L10n.string("Restart terminal?"), isPresented: $confirmsFolderRestart) {
            Button(L10n.string("Restart terminal"), role: .destructive) { folder?.restart() }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string(session.foregroundIsUnknown
                ? "Restarting clears the terminal's output and stops any commands that are running."
                : "This stops the terminal's running processes and clears its output."))
        }
        .confirmationDialog(
            closing.map { TerminalCloseQuestion.title(closing: $0.count) } ?? "",
            isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } })
        ) {
            Button(L10n.string((closing?.count ?? 1) > 1 ? "Close terminals" : "Close terminal"), role: .destructive) {
                if let closing { finishClosing(closing) }
                closing = nil
            }
            Button(L10n.string("Cancel"), role: .cancel) { closing = nil }
        } message: {
            if let closing { Text(TerminalCloseQuestion.message(closing: closing, titles: titles)) }
        }
        .alert(L10n.string("Rename terminal"), isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }
        )) {
            TextField(renaming.map(TerminalTabTitle.defaultTitle) ?? "", text: $renameText)
            Button(L10n.string("Cancel"), role: .cancel) { renaming = nil }
            Button(L10n.string("Rename")) {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                renaming?.name = name.isEmpty ? nil : name
                renaming = nil
            }
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

    private func title(of shell: NativeTerminalSession, in titles: [ObjectIdentifier: String]) -> String {
        titles[ObjectIdentifier(shell)] ?? TerminalTabTitle.defaultTitle(of: shell)
    }

    /// A tab's screen: the shell's view, which starts the shell the first time a panel shows it.
    private func terminalBody(_ shell: NativeTerminalSession, titles: [ObjectIdentifier: String]) -> some View {
        SwiftTermHost(session: shell, isDark: colorScheme == .dark,
                      font: codeFont.nsFont(ofSize: codeFont.size(12, scale: interfaceScale)),
                      attachSelection: attachSelection(title: title(of: shell, in: titles)))
        .id(shell.generation)
        .padding(.horizontal, 10).padding(.bottom, 8)
        .background(Color(nsColor: TerminalAppearance.background(isDark: colorScheme == .dark)))
        .task {
            guard shell.focusesWhenShown else { return }
            shell.focusesWhenShown = false
            await Task.yield()
            _ = shell.focus()
        }
    }

    /// The terminal's own header: its tabs, each closing its shell, and the panel's controls below the
    /// conversation; in the side panel, whose header has them, only the tabs.
    private func tabsHeader(titles: [ObjectIdentifier: String]) -> some View {
        WorkSurfaceHeader(
            title: titles[ObjectIdentifier(session)] ?? workspaceURL.lastPathComponent,
            systemName: "terminal",
            workspaceURL: workspaceURL,
            status: session.actionError ?? (session.isRunning ? nil : session.statusText),
            statusTint: session.exitCode.map({ $0 != 0 }) == true || session.terminationSignal != nil
                ? .red : .secondary,
            showsPanelControls: !isInSidePanel,
            onClose: tabs == nil ? onClose : { close([session]) }
        ) {
            if let tabs, hasStarted {
                let isSplit = tabs.workspace.splitTerminal != nil
                ParityIconButton(
                    systemName: isSplit ? "rectangle" : isInSidePanel ? "rectangle.split.1x2" : "rectangle.split.2x1",
                    help: L10n.string(isSplit ? "Unsplit Terminal" : "Split Terminal")
                ) {
                    if isSplit {
                        tabs.workspace.unsplitTerminal()
                    } else {
                        tabs.workspace.splitTerminal(in: tabs.folder, launch: tabs.launch, taskID: tabs.taskID)
                    }
                }
            }
        }
        .environment(\.workSurfaceNavigation, tabs.map { navigation($0, titles: titles) })
        .contextMenu {
            if tabs == nil, hasStarted {
                Button(L10n.string("Restart")) { restart(session) }
            }
        }
    }

    /// The selection goes to the message, and the keyboard with it, while the terminal is shared.
    private func attachSelection(title: String) -> ((String) -> Void)? {
        guard sharesTerminal, let onAttachSelection else { return nil }
        return { selection in onAttachSelection(selection, title) }
    }

    /// The header's tab strip: the task's terminal tabs, each closing on its own, with a + for another.
    private func navigation(_ tabs: TerminalTabsContext, titles: [ObjectIdentifier: String]) -> WorkSurfaceNavigation {
        let shells = tabs.workspace.terminals
        let byID = Dictionary(shells.map { (TerminalTabTitle.tabID($0), $0) }, uniquingKeysWith: { first, _ in first })
        return WorkSurfaceNavigation(
            tabs: shells.map { shell in
                WorkSurfaceTab(id: TerminalTabTitle.tabID(shell), title: titles[ObjectIdentifier(shell)] ?? "",
                               systemName: "terminal")
            },
            activeID: TerminalTabTitle.tabID(session),
            choices: [],
            select: { id in
                guard let shell = byID[id] else { return }
                tabs.workspace.showTerminalTab(shell)
                keyboardFocus?.move(to: .terminal)
            },
            open: { _ in },
            closeTab: { id in if let shell = byID[id] { close([shell]) } },
            closeTabs: { ids in close(ids.compactMap { byID[$0] }) },
            closePanel: { onClose() },
            kind: .terminal,
            newTab: WorkSurfaceNewTab(help: L10n.string("New terminal")) {
                tabs.workspace.openTerminalTab(in: tabs.folder, launch: tabs.launch, taskID: tabs.taskID)
                keyboardFocus?.move(to: .terminal)
            },
            terminalMenu: TerminalTabMenuActions(
                rename: { id in
                    guard let shell = byID[id] else { return }
                    renameText = shell.name ?? ""
                    renaming = shell
                },
                restart: { id in if let shell = byID[id] { restart(shell) } }
            )
        )
    }

    /// Closing tabs ends their shells, asking first only where a program still holds the terminal, as
    /// the Claude app asks before closing a terminal whose command still runs; a shell at its prompt
    /// closes without a question.
    private func close(_ shells: [NativeTerminalSession]) {
        guard !shells.isEmpty else { return }
        if shells.contains(where: \.isRunningProgram) { closing = shells } else { finishClosing(shells) }
    }

    private func finishClosing(_ shells: [NativeTerminalSession]) {
        guard let tabs else { return onClose() }
        if !tabs.workspace.closeTerminalTabs(shells) {
            onClose()
        } else {
            keyboardFocus?.move(to: .terminal)
        }
    }

    /// Restart asks first only while a program holds the terminal; a shell at its prompt, or one that
    /// exited, starts over at once. A tab the panel did not show shows as it starts over.
    private func restart(_ shell: NativeTerminalSession) {
        if shell.isRunningProgram { restarting = shell } else { finishRestarting(shell) }
    }

    private func finishRestarting(_ shell: NativeTerminalSession) {
        if let tabs {
            tabs.workspace.terminalStartRequested = true
            tabs.workspace.showTerminalTab(shell)
        }
        shell.restart()
    }

    /// Runs a handed-off command at the shell's prompt. A terminal that has not started starts, as the
    /// click asked for it; one whose shell has exited starts a new shell, as Restart does without asking
    /// when nothing runs.
    private func type(_ handoff: TerminalCommandRequest) async {
        if !hasStarted {
            hasStarted = true
        } else if !session.isRunning {
            session.restart()
        }
        _ = await session.runWhenReady(handoff.command)
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
                if session.isRunningProgram { confirmsFolderRestart = true } else { folder?.restart() }
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

/// The Claude app's question before closing a terminal whose command still runs ("Close terminal?",
/// "A command is still running in {name}. Closing the terminal stops it.").
@MainActor
enum TerminalCloseQuestion {
    static func title(closing count: Int) -> String {
        count > 1 ? L10n.format("Close %d terminals?", count) : L10n.string("Close terminal?")
    }

    static func message(closing shells: [NativeTerminalSession], titles: [ObjectIdentifier: String]) -> String {
        if shells.contains(where: \.foregroundIsUnknown) {
            return L10n.string(shells.count == 1
                ? "Closing this terminal stops any commands that are running."
                : "Closing these terminals stops any commands that are running.")
        }
        let running = shells.filter(\.isRunningProgram)
        guard running.count == 1, let shell = running.first else {
            return L10n.format("Commands are still running in %d terminals. Closing them stops them.", running.count)
        }
        let name = titles[ObjectIdentifier(shell)] ?? TerminalTabTitle.defaultTitle(of: shell)
        return L10n.format(shells.count > 1 ? "A command is still running in %@. Closing the terminals stops it."
                                            : "A command is still running in %@. Closing the terminal stops it.", name)
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

/// What shows a shell: the host's panel, or a remote window by the terminal ID its host gave it.
enum TerminalViewer: Hashable {
    case panel
    case remote(String)
}

/// A shell's size in character cells.
struct TerminalGrid: Equatable {
    var columns: Int
    var rows: Int
}

@MainActor
@Observable
final class NativeTerminalSession: NSObject, @MainActor TerminalViewDelegate, NativeSurfaceResource {
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

    /// The header strip's id for its tab.
    let id = UUID()
    private let initialWorkspaceURL: URL
    var workspaceURL: URL { hosting.workspaceURL ?? initialWorkspaceURL }
    /// The name the person gave its tab; nil keeps the default (`TerminalTabTitle`).
    var name: String?
    /// Takes the keyboard the next time a panel shows it: the tab a split opened.
    @ObservationIgnored var focusesWhenShown = false
    /// Its place among the tabs its task opened, for its default title: the lowest a tab of the task
    /// does not have.
    var number = 1
    private(set) var isRunning = false
    private(set) var actionError: String?
    private(set) var title: String?
    private(set) var currentDirectory: String?
    private(set) var exitCode: Int32?
    private(set) var terminationSignal: Int32?
    private(set) var generation = 0
    /// The folder the person last dismissed the notice for (`TerminalFolderContext`).
    var dismissedFolderNotice: URL?
    /// The shell ended for good (`end()`); its task's workspace opens a new one next.
    private(set) var hasEnded = false
    /// Told once the shell ends for good: its task's workspace drops its tab.
    @ObservationIgnored var onEnd: (() -> Void)?

    /// The renderer, kept with the session rather than by the panel, so a panel drawn again for the
    /// same shell (the task the new-task screen started, the same task in another place) shows the same
    /// screen and scrollback. Each panel mounts it in a host of its own (`TerminalViewHost`).
    @ObservationIgnored private var terminalView: TerminalView?
    @ObservationIgnored let hosting: any TerminalHosting
    @ObservationIgnored private var started = false
    var process: LocalProcess? { (hosting as? LocalTerminalHosting)?.process }
    @ObservationIgnored var onOutput: ((ArraySlice<UInt8>) -> Void)?
    @ObservationIgnored var onExit: ((Int32?) -> Void)?
    @ObservationIgnored var onStop: (() -> Void)?
    @ObservationIgnored var onOpenLink: ((URL) -> Void)?
    @ObservationIgnored private(set) var allowsClipboard = true
    @ObservationIgnored private var isRemoteOrigin = false
    @ObservationIgnored var clipboard = TerminalClipboard.system
    @ObservationIgnored private var mirror: TerminalBufferMirror?
    @ObservationIgnored private var columns = 80
    @ObservationIgnored private var rows = 24
    /// One shell has one size, however many renderers show it, as tmux's `window-size latest` has it: the shell takes
    /// the size its renderer typed in or attached last asks for, and every renderer reads the output at that size,
    /// drawn from its top left (docs/REMOTE_PROTOCOL.md §15.29). The size each renderer asks for, and the renderers
    /// the least recently used first.
    @ObservationIgnored private var viewerSizes: [TerminalViewer: TerminalGrid] = [:]
    @ObservationIgnored private var recentViewers: [TerminalViewer] = []
    /// The shell's size as its host last said, for a remote shell whose host says it (§15.29).
    @ObservationIgnored private var hostSize: TerminalGrid?
    /// Told the shell's new size, for the remote window showing it.
    @ObservationIgnored var onResize: ((TerminalGrid) -> Void)?
    /// When the shell last printed, while its view reports it (`NativeTerminalView`).
    @ObservationIgnored private var lastOutputAt: ContinuousClock.Instant?
    /// Panels showing a shell the task's workspace keeps.
    @ObservationIgnored private var shownPanels = 0
    var hasVisiblePanel: Bool { shownPanels > 0 }

    /// The shell it starts, the one launch bash mode's shell shares: the person's login shell, or
    /// a test's zsh with its own `ZDOTDIR` so it neither reads their rc files nor writes their
    /// shell history.
    let launch: ShellLaunchEnvironment
    /// The task whose panel this is: its shell, with what it starts, counts toward the task in
    /// Task Resource Usage. Nil on the new-task screen until the task starts (`move(toTask:)`).
    @ObservationIgnored private(set) var taskID: UUID?
    @ObservationIgnored private var registeredShellPID: Int32?

    init(workspaceURL: URL, launch: ShellLaunchEnvironment = .userLoginShell(), taskID: UUID? = nil,
         hosting: (any TerminalHosting)? = nil) {
        self.initialWorkspaceURL = workspaceURL.standardizedFileURL
        self.launch = launch
        self.taskID = taskID
        self.hosting = hosting ?? LocalTerminalHosting(folder: workspaceURL, launch: launch)
        super.init()
        self.hosting.onOutput = { [weak self] in self?.dataReceived(slice: $0) }
        self.hosting.onExit = { [weak self] in self?.processTerminated(exitCode: $0) }
        self.hosting.onReady = { [weak self] in
            guard let self else { return }
            self.isRunning = true
            self.registerShell()
        }
        (self.hosting as? RemoteTerminalHosting)?.onResize = { [weak self] in self?.hostResized($0) }
        NativeSurfaceResourceRegistry.shared.register(self)
    }

    /// The session started its host and has not been stopped.
    var hasShell: Bool { started }

    /// The shell's view, which starts the shell the first time it is asked for after a stop.
    func view(make: () -> TerminalView) -> TerminalView {
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
        if isRunning { registerShell() }
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
            guard let self, self.shownPanels == 0 else { return }
            // Out of sight, the panel no longer holds the shell's size.
            self.removeViewer(.panel)
            guard !self.hasEnded, !self.isRunning else { return }
            self.end()
        }
    }

    /// Ends the shell for good: the workspace that keeps it drops its tab, and opens a new one when
    /// it was the last.
    func end() {
        guard !hasEnded else { return }
        hasEnded = true
        stop()
        let onEnd = onEnd
        self.onEnd = nil
        onEnd?()
    }

    private func registerShell() {
        unregisterShell()
        let shellPID = process?.shellPid ?? 0
        guard let taskID, shellPID > 0 else { return }
        TaskProcessRegistry.shared.register(shellPID, owner: .task(taskID))
        registeredShellPID = shellPID
    }

    private func unregisterShell() {
        guard let taskID, let shellPID = registeredShellPID else { return }
        TaskProcessRegistry.shared.unregister(shellPID, owner: .task(taskID))
        registeredShellPID = nil
    }

    func attach(_ view: TerminalView) {
        guard terminalView !== view else { return }
        terminalView = view
        view.terminalDelegate = self
        (view as? NativeTerminalView)?.session = self
        if let mirror {
            view.terminal = mirror.terminal
            mirror.display = view
            // The public font setter rebuilds selection, search, caret and glyph caches for this emulator.
            let font = view.font
            view.font = font
        }
        sizeChanged(source: view, newCols: view.getTerminal().cols, newRows: view.getTerminal().rows)
        start()
    }

    /// Starts the PTY independently of any panel or AppKit view.
    func start() {
        guard !started, !hasEnded else { return }
        started = true
        // Ordinary panels already have an emulator. Only a shell started headless needs a mirror.
        if terminalView == nil {
            mirror = TerminalBufferMirror()
            mirror?.sendBytes = { [weak self] bytes in
                guard let self, self.hosting is LocalTerminalHosting else { return }
                self.hosting.send(bytes)
            }
            mirror?.terminal.resize(cols: columns, rows: rows)
        }
        exitCode = nil
        terminationSignal = nil
        actionError = nil
        currentDirectory = workspaceURL.path(percentEncoded: false)
        lastOutputAt = nil
        isRunning = false
        hosting.start()
        isRunning = hosting.isReady
        registerShell()
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        lastOutputAt = .now
        if let terminalView {
            terminalView.feed(byteArray: slice)
            (terminalView.superview as? TerminalViewHost)?.outputArrived()
        } else {
            mirror?.terminal.feed(buffer: slice)
        }
        onOutput?(slice)
    }

    /// The panel's renderer fits `columns` × `rows`.
    func resize(columns: Int, rows: Int) {
        request(.panel, columns: columns, rows: rows)
    }

    /// `viewer` fits `columns` × `rows`: the shell takes it when `viewer` was used last. A remote shell asks its host,
    /// which says the size it took with the output.
    func request(_ viewer: TerminalViewer, columns: Int, rows: Int) {
        let size = TerminalGrid(columns: max(2, min(columns, 500)), rows: max(2, min(rows, 300)))
        guard hosting is LocalTerminalHosting else {
            self.columns = size.columns
            self.rows = size.rows
            hosting.resize(columns: size.columns, rows: size.rows)
            fitEmulator()
            return
        }
        viewerSizes[viewer] = size
        if !recentViewers.contains(viewer) { recentViewers.insert(viewer, at: 0) }
        applyViewerSize()
    }

    /// The person typed in, or attached, `viewer`'s renderer: the shell takes the size it asked for.
    func use(_ viewer: TerminalViewer) {
        guard recentViewers.last != viewer else { return }
        recentViewers.removeAll { $0 == viewer }
        recentViewers.append(viewer)
        applyViewerSize()
    }

    /// `viewer` no longer shows the shell: the one used before it sets the size.
    func removeViewer(_ viewer: TerminalViewer) {
        guard recentViewers.contains(viewer) else { return }
        viewerSizes[viewer] = nil
        recentViewers.removeAll { $0 == viewer }
        applyViewerSize()
    }

    /// The shell's size now.
    var size: TerminalGrid { TerminalGrid(columns: columns, rows: rows) }

    private func applyViewerSize() {
        guard hosting is LocalTerminalHosting,
              let viewer = recentViewers.last(where: { viewerSizes[$0] != nil }), let size = viewerSizes[viewer] else { return }
        if size != self.size {
            columns = size.columns
            rows = size.rows
            hosting.resize(columns: size.columns, rows: size.rows)
            onResize?(size)
        }
        fitEmulator()
    }

    /// The host's shell takes this size from the output that comes next on (§15.29).
    private func hostResized(_ size: TerminalGrid) {
        hostSize = size
        fitEmulator()
    }

    /// The size the emulator reads the output at: the shell's. A remote shell whose host does not say its size takes
    /// the size asked for.
    var emulatorSize: TerminalGrid {
        hosting is LocalTerminalHosting ? size : hostSize ?? size
    }

    /// Brings the emulator to `emulatorSize` now, before any more output: through its panel, which shows a shell of
    /// another size from its top left (`TerminalViewHost`), or directly while no panel lays it out.
    private func fitEmulator() {
        if let host = terminalView?.superview as? TerminalViewHost, host.placesTerminal {
            host.frameTerminal()
            return
        }
        let size = emulatorSize
        guard let emulator = terminalView?.getTerminal() ?? mirror?.terminal,
              emulator.cols != size.columns || emulator.rows != size.rows else { return }
        emulator.resize(cols: size.columns, rows: size.rows)
        terminalView?.needsDisplay = true
    }

    /// The person typed, pasted or clicked in the panel; an answer the host's emulator gives the shell is not them.
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if (source as? NativeTerminalView)?.isAnswering != true { use(.panel) }
        send(data)
    }
    func send(_ data: ArraySlice<UInt8>) {
        guard isRunning else { return }
        actionError = nil
        hosting.send(data)
    }
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    /// What draws its current screen on a renderer that attaches while it runs (`TerminalRepaint`).
    var screenRepaint: Data? {
        guard let emulator = terminalView?.getTerminal() ?? mirror?.terminal else { return nil }
        return TerminalRepaint.bytes(of: emulator, cursorHidden: mirror?.cursorHidden ?? false)
    }

    func disableClipboardAccess() { allowsClipboard = false }
    func markRemoteOrigin() { isRemoteOrigin = true; allowsClipboard = false }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        let remote = isRemoteOrigin || hosting is RemoteTerminalHosting
        let scheme = url.scheme?.lowercased() ?? ""
        let taskLink: Bool = if case .task = ConversationLinkKind(url) { true } else { false }
        if remote, !["http", "https", "file"].contains(scheme), !taskLink {
            actionError = L10n.string("This link is not supported in a remote terminal.")
            return
        }
        if let onOpenLink { onOpenLink(url); return }
        guard hosting is LocalTerminalHosting, !remote || ["http", "https"].contains(scheme) else {
            actionError = L10n.string("Open this address in the remote task's browser.")
            return
        }
        NSWorkspace.shared.open(url)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard allowsClipboard, hosting is LocalTerminalHosting else { return }
        clipboard.write(content)
    }

    func clipboardRead(source: TerminalView) -> Data? {
        // Output may come from an untrusted file or remote command. Explicit Paste remains a view action.
        nil
    }

    func restart() {
        stop()
        generation += 1
    }

    func stop() {
        unregisterShell()
        onStop?()
        hosting.stop()
        started = false
        terminalView = nil
        mirror = nil
        isRunning = false
    }

    func terminateForApplicationShutdown() { stop() }

    func send(_ text: String) { send(Array(text.utf8)[...]) }

    /// A command as the shell takes a paste: its trailing line breaks left out, and a command over several
    /// lines as a bracketed paste when the shell asked for that mode (zsh's line editor does), so its inner
    /// line breaks wait in the line editor and the Return after it runs every line, as a pasted block runs; a
    /// shell that did not ask gets the lines as typed, each running as it comes.
    static func pasteText(_ command: String, bracketedPaste: Bool = true) -> String {
        let trimmed = command.trimmingCharacters(in: .newlines)
        guard trimmed.contains(where: \.isNewline), bracketedPaste else { return trimmed }
        return "\u{1B}[200~" + trimmed + "\u{1B}[201~"
    }

    /// Waits for the shell's prompt as `typeWhenReady` does, then pastes `command` (`pasteText`, in the
    /// paste mode the shell asked for by then) and presses Return, as the Claude app's Run in terminal runs
    /// what it types.
    func runWhenReady(_ command: String) async -> Bool {
        guard await waitUntilReady() else {
            actionError = L10n.string("The command was not sent because the shell prompt could not be confirmed.")
            return false
        }
        actionError = nil
        send(Self.pasteText(command, bracketedPaste: terminalView?.getTerminal().bracketedPasteMode ?? mirror?.terminal.bracketedPasteMode ?? false) + "\r")
        return true
    }

    /// Sends `text` once the shell is at its prompt (`waitUntilReady`). False when no shell was at its
    /// prompt in time or the wait was cancelled.
    @discardableResult
    func typeWhenReady(
        _ text: String, quietPeriod: Duration = .milliseconds(300), limit: Duration = .seconds(10)
    ) async -> Bool {
        guard await waitUntilReady(quietPeriod: quietPeriod, limit: limit) else { return false }
        send(text)
        return true
    }

    /// The shell holds its terminal and has been quiet for `quietPeriod` since it last printed: it is
    /// at its prompt. A shell that has just started prints its startup files' output and its prompt
    /// first; text typed before the prompt would be echoed twice. Past `limit` the shell is taken to be
    /// at its prompt if it holds the terminal, whatever it printed; never while a program holds it (a
    /// sign-in waiting, a dev server), whose input the text would be.
    private func waitUntilReady(
        quietPeriod: Duration = .milliseconds(300), limit: Duration = .seconds(10)
    ) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if hosting is RemoteTerminalHosting, await hosting.refreshPromptState() == nil { return false }
            if isAtPrompt, let lastOutputAt, ContinuousClock.now - lastOutputAt >= quietPeriod { break }
            try? await Task.sleep(for: .milliseconds(hosting is RemoteTerminalHosting ? 250 : 50))
        }
        return !Task.isCancelled && isAtPrompt
    }

    /// The process group that holds the terminal while the shell runs: the shell's own at its prompt,
    /// a program's while one runs in the foreground (an interactive shell gives each job its group).
    private var foregroundProcessGroup: pid_t? { hosting.foregroundProcessGroup }

    /// A program other than the shell holds the terminal: a command still runs in it. Read when asked,
    /// never watched.
    var foregroundIsUnknown: Bool { isRunning && hosting is RemoteTerminalHosting }

    var isRunningProgram: Bool {
        guard isRunning else { return false }
        // A remote process group is host-owned. Unknown foreground state must still ask before destruction.
        guard let group = foregroundProcessGroup, let shell = hosting.processID else { return isRunning && hosting is RemoteTerminalHosting }
        return group != shell
    }

    /// The shell holds its terminal: no command runs in the foreground.
    var isAtPrompt: Bool {
        isRunning && hosting.isAtPrompt == true
    }

    func focus() -> Bool {
        guard let terminalView, let window = terminalView.window else { return false }
        return window.makeFirstResponder(terminalView)
    }

    var bufferText: String {
        mirror?.terminal.unwrappedText ?? terminalView?.getTerminal().unwrappedText ?? ""
    }

    var statusText: String {
        if let status = hosting.statusMessage { return status }
        if isRunning { return L10n.string("Running") }
        if let terminationSignal { return L10n.format("Stopped by signal %d", terminationSignal) }
        if let exitCode { return L10n.format("Exited (%d)", exitCode) }
        return L10n.string("Stopped")
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // A panel that lays its terminal out asks for the size it fits itself; SwiftTerm resized for another reason (a
        // new font), and the panel lays it out again.
        if let host = source.superview as? TerminalViewHost, host.placesTerminal {
            host.terminalResizedItself()
            return
        }
        resize(columns: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        self.title = title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        currentDirectory = directory
    }

    func processTerminated(exitCode: Int32?) {
        onExit?(exitCode)
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
    let font: NSFont
    var attachSelection: ((String) -> Void)?

    func makeNSView(context: Context) -> TerminalViewHost {
        let view = session.view {
            let view = NativeTerminalView(
                frame: .zero,
                font: font,
                options: TerminalOptions(cursorStyle: .steadyBlock, scrollback: 5_000)
            )
            view.wantsLayer = true
            view.getTerminal().setCursorStyle(CursorStyle.steadyBlock)
            view.metalBufferingMode = MetalBufferingMode.perFrameAggregated
            try? view.setUseMetal(false)
            return view
        }
        applyAppearance(to: view, coordinator: context.coordinator)
        (view as? NativeTerminalView)?.attachSelection = attachSelection
        return TerminalViewHost(terminal: view)
    }

    func updateNSView(_ nsView: TerminalViewHost, context: Context) {
        applyAppearance(to: nsView.terminal, coordinator: context.coordinator)
        (nsView.terminal as? NativeTerminalView)?.attachSelection = attachSelection
    }

    private func applyAppearance(to view: TerminalView, coordinator: Coordinator) {
        if coordinator.isDark != isDark {
            view.nativeForegroundColor = TerminalAppearance.foreground(isDark: isDark)
            view.nativeBackgroundColor = TerminalAppearance.background(isDark: isDark)
            view.layer?.backgroundColor = TerminalAppearance.background(isDark: isDark).cgColor
            view.installColors(TerminalAppearance.palette(isDark: isDark))
            view.caretColor = NSColor.systemBlue
            coordinator.isDark = isDark
        }
        if coordinator.font != font {
            view.font = font
            coordinator.font = font
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
        var font: NSFont?

        init(session: NativeTerminalSession) {
            self.session = session
        }
    }
}

/// A fresh host for each panel, as `BrowserWebViewHost` is for a page: the shell's view moves into
/// the next panel's host, and the teardown of the panel it left, which SwiftUI may run after, cannot
/// take it out of its new place. It lays the view out at its shell's size (`frameTerminal`).
final class TerminalViewHost: NSView {
    let terminal: TerminalView
    /// The shell is taller than the panel: the panel shows the rows around its cursor.
    private var followsCursor = false
    /// The panel lays its terminal out at its shell's size (`TerminalCellMetrics` could be read); otherwise the terminal
    /// fills it and SwiftTerm sizes the shell, as before.
    private(set) var placesTerminal = false
    private var isPlacing = false

    init(terminal: TerminalView) {
        self.terminal = terminal
        super.init(frame: terminal.frame)
        terminal.removeFromSuperview()
        terminal.autoresizingMask = []
        // A shell larger than the panel stays inside it.
        wantsLayer = true
        clipsToBounds = true
        addSubview(terminal)
        terminal.frame = bounds
    }

    required init?(coder: NSCoder) { nil }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        place()
    }

    override func layout() {
        super.layout()
        place()
    }

    /// The panel asks its shell for the size it fits, then lays the terminal out at the shell's size (`frameTerminal`).
    private func place() {
        guard !isPlacing else { return }
        guard bounds.width > 0, bounds.height > 0, let session = (terminal as? NativeTerminalView)?.session,
              let metrics = TerminalCellMetrics(terminal) else {
            placesTerminal = false
            followsCursor = false
            if terminal.frame != bounds { terminal.frame = bounds }
            return
        }
        placesTerminal = true
        let fit = metrics.grid(fitting: bounds.size)
        session.request(.panel, columns: fit.columns, rows: fit.rows)
        frameTerminal(metrics)
    }

    /// Lays the terminal out at its shell's size (`NativeTerminalSession.emulatorSize`), which SwiftTerm then gives its
    /// emulator: the whole panel when that is the size the panel fits, else that size from the panel's top left, where a
    /// renderer used later chose it (`NativeTerminalSession.use`), clipped where the panel is smaller and with the rows
    /// around the cursor in view, rather than reflowing the screen to the panel.
    func frameTerminal(_ known: TerminalCellMetrics? = nil) {
        guard !isPlacing, let session = (terminal as? NativeTerminalView)?.session,
              let metrics = known ?? TerminalCellMetrics(terminal) else { return }
        isPlacing = true
        defer { isPlacing = false }
        let target = session.emulatorSize
        guard target != metrics.grid(fitting: bounds.size) else {
            followsCursor = false
            if terminal.frame != bounds { terminal.frame = bounds }
            // SwiftTerm counts the panel's cells itself; should it count otherwise, its count is what the panel fits.
            let emulator = terminal.getTerminal()
            if emulator.cols != target.columns || emulator.rows != target.rows {
                session.request(.panel, columns: emulator.cols, rows: emulator.rows)
            }
            return
        }
        let size = metrics.frameSize(for: target)
        let visibleRows = max(1, Int(bounds.height / metrics.cell.height))
        followsCursor = target.rows > visibleRows
        // Laid out first at its size from the top, so the cursor is read at that size.
        let top = NSRect(x: 0, y: bounds.height - size.height, width: size.width, height: size.height)
        if terminal.frame.size != top.size { terminal.frame = top }
        let firstRow = followsCursor
            ? min(max(0, terminal.getTerminal().getCursorLocation().y - visibleRows + 1), target.rows - visibleRows) : 0
        let frame = top.offsetBy(dx: 0, dy: CGFloat(firstRow) * metrics.cell.height)
        if terminal.frame != frame { terminal.frame = frame }
    }

    /// SwiftTerm resized the terminal for a reason of its own (a new font): laid out again.
    func terminalResizedItself() {
        guard !isPlacing else { return }
        place()
    }

    /// The shell printed: a panel showing part of a taller shell keeps its cursor in view.
    func outputArrived() {
        if followsCursor { frameTerminal() }
    }

    func unmount() {
        guard terminal.superview === self else { return }
        if let window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: terminal) {
            window.makeFirstResponder(nil)
        }
        terminal.removeFromSuperview()
    }
}

/// The cell size SwiftTerm lays a view's terminal out with, which it does not publish: its rows' height from the frame
/// it asks for, and its columns' width from its font as it measures one, checked against that frame. Nil when they do
/// not agree, and the panel then lets the terminal fill it as before.
struct TerminalCellMetrics {
    let cell: CGSize
    /// The width beside the columns kept for the scroller.
    let reserved: CGFloat

    @MainActor
    init?(_ view: TerminalView) {
        let terminal = view.getTerminal()
        let optimal = view.getOptimalFrameSize().size
        guard terminal.cols > 0, terminal.rows > 0, optimal.height > 0 else { return nil }
        let font = view.font
        let advance = font.advancement(forGlyph: font.glyph(withName: "W")).width
        let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: view.scrollerStyle)
        let scales = [view.window?.backingScaleFactor, NSScreen.main?.backingScaleFactor, 2, 1].compactMap { $0 }
        for scale in scales {
            let width = max(1, (advance * scale).rounded() / scale)
            let reserved = optimal.width - width * CGFloat(terminal.cols)
            if abs(reserved) < 0.25 || abs(reserved - scroller) < 0.25 {
                cell = CGSize(width: width, height: optimal.height / CGFloat(terminal.rows))
                self.reserved = max(0, reserved)
                return
            }
        }
        return nil
    }

    /// The grid a frame of `size` holds, as SwiftTerm counts it.
    func grid(fitting size: CGSize) -> TerminalGrid {
        TerminalGrid(columns: max(2, Int((size.width - reserved) / cell.width)), rows: max(2, Int(size.height / cell.height)))
    }

    /// A frame that holds `grid` exactly, with less than a cell to spare so SwiftTerm counts the same grid.
    func frameSize(for grid: TerminalGrid) -> CGSize {
        CGSize(width: cell.width * CGFloat(grid.columns) + reserved + cell.width / 2,
               height: cell.height * CGFloat(grid.rows) + cell.height / 2)
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
/// handed to the terminal waits for the prompt (`NativeTerminalSession.typeWhenReady`). While the
/// terminal is shared (`TerminalSharingPreference`) its right-click menu and ⌘⇧L, the Claude app's
/// "Attach selection as context" key, attach the selection to the person's message; otherwise it has
/// no menu, as SwiftTerm's own view has none.
final class NativeTerminalView: TerminalView {
    /// The host's emulator is answering the shell (a cursor position, its colors), not the person typing.
    private(set) var isAnswering = false

    /// Parser-generated replies come only from the host's emulator. Key input still uses the view delegate.
    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        guard session?.hosting is LocalTerminalHosting else { return }
        isAnswering = true
        defer { isAnswering = false }
        super.send(source: source, data: data)
    }

    weak var session: NativeTerminalSession?
    var process: LocalProcess! { session?.process }
    /// Attaches the selected text to the task's message; nil while the terminal is not shared.
    var attachSelection: ((String) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard attachSelection != nil else { return super.menu(for: event) }
        let menu = NSMenu()
        let attach = NSMenuItem(title: L10n.string("Attach Selection to Message"),
                                action: #selector(attachSelectionToMessage(_:)), keyEquivalent: "l")
        attach.keyEquivalentModifierMask = [.command, .shift]
        attach.target = self
        menu.addItem(attach)
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.string("Copy"), action: #selector(copy(_:)), keyEquivalent: "c").target = self
        menu.addItem(withTitle: L10n.string("Paste"), action: #selector(paste(_:)), keyEquivalent: "v").target = self
        return menu
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if attachSelection != nil, window?.firstResponder === self,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "l" {
            attachSelectionToMessage(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(attachSelectionToMessage(_:)) { return selectionActive }
        return super.validateUserInterfaceItem(item)
    }

    /// The selection goes to the message; with nothing selected the key does nothing, as copy does.
    @objc func attachSelectionToMessage(_ sender: Any?) {
        guard let text = getSelection(), !text.isEmpty else { return NSSound.beep() }
        attachSelection?(text)
    }
}

/// What a terminal selection adds to the person's message: a fenced block under the tab's name, after
/// what the message already says, for the person to read, edit or send with the rest.
@MainActor
enum TerminalSelectionText {
    /// Adds the block to `draft`, with the caret after it for when the message takes the keyboard.
    static func attach(_ selection: String, from title: String, to draft: some ComposerDraftEditing) {
        let text = appending(selection, from: title, to: draft.text)
        draft.text = text
        draft.rememberSelection(NSRange(location: text.utf16.count, length: 0), in: text)
    }

    static func appending(_ selection: String, from title: String, to text: String) -> String {
        let body = selection.trimmingCharacters(in: .newlines)
        var fence = "```"
        while body.contains(fence) { fence += "`" }
        let block = L10n.format("Terminal (%@):", title) + "\n" + fence + "\n" + body + "\n" + fence + "\n"
        let kept = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text
        guard !kept.isEmpty else { return block }
        return kept + (kept.hasSuffix("\n\n") ? "" : kept.hasSuffix("\n") ? "\n" : "\n\n") + block
    }
}
