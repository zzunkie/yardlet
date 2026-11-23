import QuickLook
import SwiftUI
import YardletRemote

/// One task's conversation, latest first at the bottom, earlier turns on request, live while it runs, with the
/// composer below it (docs/REMOTE_PROTOCOL.md §4.2, §6), in full detail from a Mac that sends it (§15.24). What the
/// task made, and the files and tasks its answers link, open from here (§15.22).
struct TaskView: View {
    let session: HostSession
    let taskID: String
    @State private var conversation: ConversationState?
    /// A turn's message in the composer to edit (§15.23).
    @State private var editing: MessageEdit?
    /// The line whose output, body or subagent card is open.
    @State private var detailItem: RemoteItem?
    /// The task a subagent's card chose to open, opened once the card has closed.
    @State private var subtaskToOpen: String?
    @State private var openedSubtask: String?
    /// A picture shown whole, over the conversation as it goes on changing.
    @State private var openedPreview: OpenedPreview?
    /// Memory-only loader for inline Markdown local task images and explicitly loaded web images.
    @State private var imageLoader: MarkdownImageLoader?
    @State private var isShowingSettings = false
    @State private var isConfirmingArchive = false
    /// The end of the conversation is in view; otherwise a button takes the person back to it.
    @State private var isAtLatest = true
    @State private var isShowingOutputs = false
    /// An output chosen in the Outputs sheet, read once the sheet has closed.
    @State private var outputToOpen: String?
    /// The file coming from the Mac or shown, and the copy QuickLook shows.
    @State private var reading: MacFileReading?
    @State private var preview: URL?
    /// Opens another task over this one: a linked task, a fork, or a new chat a command started.
    @Environment(\.openTask) private var openTask
    /// The title last read from the list, kept while the list is read again after a reconnection.
    @State private var knownTitle = ""
    /// The task's browser tab screen, while it shows (§15.25).
    @State private var browserTarget: BrowserTarget?
    @Environment(\.dismiss) private var dismiss
    @Environment(PhoneModel.self) private var model

    private var task: RemoteTask? { session.task(taskID) }
    private var title: String { task.map { $0.title.isEmpty ? String(localized: "Untitled task") : $0.title } ?? knownTitle }

    var body: some View {
        Group {
            if let conversation {
                content(conversation)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        // An opaque bar: words scrolled under it would otherwise read through the title and its buttons.
        .toolbarBackground(Color(.systemBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .modifier(TaskSubtitle(title: title, subtitle: subtitle))
        .toolbar {
            if session.taskFiles, !(session.outputs[taskID] ?? []).isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingOutputs = true
                    } label: {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel("Outputs")
                }
            }
            // §15.25: the task's browser, when it has tabs to show.
            if showsBrowser {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        openBrowser(nil)
                    } label: {
                        Image(systemName: "globe")
                    }
                    .accessibilityLabel("Browser")
                }
            }
            ToolbarItem(placement: .topBarTrailing) { menu }
        }
        .onAppear {
            conversation = session.open(taskID)
            if imageLoader == nil { imageLoader = MarkdownImageLoader(session: session, taskID: taskID) }
            session.browser.follow(taskID)
        }
        .onDisappear { session.browser.unfollow(taskID) }
        // What the task made: read when it opens, on each connection and when a turn starts or ends.
        .task(id: OutputsReading(offered: session.taskFiles && session.isConnected, running: task?.running == true)) {
            await session.loadOutputs(taskID)
        }
        // A notification of a tab handed to the person opens it over the conversation.
        .onChange(of: model.browserToOpen, initial: true) { _, opened in
            guard opened == taskID else { return }
            model.browserToOpen = nil
            if !session.hasSnapshot || session.browser.isOffered { openBrowser(nil) }
        }
        .fullScreenCover(item: $browserTarget) { target in
            BrowserView(session: session, taskID: taskID, tabID: target.tabID)
        }
        .onChange(of: task?.title, initial: true) { _, title in
            if let title, !title.isEmpty { knownTitle = title }
        }
        #if DEBUG
        .task {
            let sheet = UserDefaults.standard.string(forKey: "sheet")
            guard sheet == "taskSettings" || sheet == "outputs" else { return }
            try? await Task.sleep(for: .seconds(1.5))
            if sheet == "taskSettings" { isShowingSettings = true }
            if sheet == "outputs" { isShowingOutputs = true }
        }
        #endif
        .onChange(of: session.isConnected) { _, connected in
            // Reopened after a reconnection: marks it read again if a result came meanwhile.
            if connected { conversation = session.open(taskID) }
        }
        .sheet(item: $detailItem, onDismiss: {
            openedSubtask = subtaskToOpen
            subtaskToOpen = nil
        }) { item in
            if item.subagent != nil {
                SubagentSheet(session: session, taskID: taskID, item: item) { childTask in
                    subtaskToOpen = childTask
                    detailItem = nil
                }
            } else {
                LineDetailView(session: session, taskID: taskID, item: item)
            }
        }
        .sheet(item: $openedPreview) { PreviewViewer(source: $0.source) }
        .navigationDestination(item: $openedSubtask) { childTask in
            TaskView(session: session, taskID: childTask)
        }
        .sheet(isPresented: $isShowingSettings) {
            TaskSettingsView(session: session, taskID: taskID)
        }
        .sheet(isPresented: $isShowingOutputs, onDismiss: {
            if let path = outputToOpen { openFile(path) }
            outputToOpen = nil
        }) {
            OutputsSheet(session: session, taskID: taskID) { output in
                outputToOpen = output.path
                isShowingOutputs = false
            }
        }
        .quickLookPreview($preview)
        .onChange(of: preview) { _, shown in
            // The viewer closed: nothing of the file stays on the phone.
            if shown == nil { closeFile() }
        }
        .onDisappear {
            if preview == nil { closeFile() }
        }
        .confirmationDialog("Archive this task?", isPresented: $isConfirmingArchive, titleVisibility: .visible) {
            Button("Archive") {
                Task {
                    if await session.perform(.archiveTask(taskID: taskID)) { dismiss() }
                }
            }
        } message: {
            Text("It leaves the list on \(session.name) too. You can find it there under archived tasks.")
        }
    }

    /// The Mac shows the task's tabs to the phone and the task has some, or one waits on the person.
    private var showsBrowser: Bool {
        session.browser.isOffered
            && (!session.browser.tabs(for: taskID).isEmpty || task?.pendingKind == "browserHandoff")
    }

    private func openBrowser(_ tabID: String?) {
        browserTarget = BrowserTarget(tabID: tabID)
    }

    private var subtitle: String {
        guard let task else { return "" }
        return [task.harnessName, session.project(task.projectId)?.name].compactMap { $0 }.joined(separator: " · ")
    }

    private func content(_ conversation: ConversationState) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Each line of a turn is a row of its own: a turn of hundreds of lines drawn as one row is too tall for
                // the stack to place, and the conversation shows blank while it runs or after it folds.
                LazyVStack(alignment: .leading, spacing: 12) {
                    if conversation.hasOlder {
                        Button {
                            session.loadOlder(taskID)
                        } label: {
                            if conversation.isLoadingOlder {
                                ProgressView()
                            } else {
                                Text("Show Earlier Messages").font(.footnote.weight(.semibold))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                    }
                    if conversation.isGone {
                        ContentUnavailableView("This task is gone", systemImage: "tray",
                                               description: Text("\(session.name) no longer lists it."))
                    } else if conversation.isLoaded && conversation.turns.isEmpty {
                        Text("No messages yet.").font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    ForEach(conversation.turns) { turn in
                        TurnView(turn: turn, isWorkOpen: conversation.openedWork.contains(turn.turnID),
                                 context: ItemContext(session: session, taskID: taskID, task: task,
                                                      offersTurnActions: offersTurnActions,
                                                      editMessage: { editing = MessageEdit(turnID: $0, text: $1) },
                                                      openTask: { openTask($0) }),
                                 toggleWork: { toggleWork(turn.turnID, in: conversation) },
                                 openDetail: { detailItem = $0 })
                            .equatable()
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.latestID)
                        .onAppear { isAtLatest = true }
                        .onDisappear { isAtLatest = false }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .defaultScrollAnchor(.bottom)
            .modifier(ShowsEndAfterShrinking(proxy: proxy, end: Self.latestID))
            .overlay(alignment: .bottomTrailing) {
                if !isAtLatest && conversation.isLoaded {
                    Button {
                        withAnimation { proxy.scrollTo(Self.latestID, anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.body.weight(.semibold))
                            .frame(width: 40, height: 40)
                            .background(.regularMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(Color(.separator), lineWidth: 0.5))
                    }
                    .foregroundStyle(.primary)
                    .accessibilityLabel("Jump to Latest")
                    .padding(16)
                    .transition(.opacity)
                }
            }
            .environment(\.openURL, OpenURLAction(handler: open))
            .scrollDismissesKeyboard(.interactively)
            .environment(\.openPreview, OpenPreviewAction { openedPreview = $0 })
            .environment(\.markdownImageLoader, imageLoader)
            .overlay {
                if !conversation.isLoaded { ProgressView() }
            }
            .environment(\.openBrowserTab, session.browser.isOffered ? OpenBrowserTab { openBrowser($0) } : nil)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    if let reading, reading.isShown, reading.file == nil {
                        FileProgressBar(reading: reading) { closeFile() }
                    }
                    CommandErrorBanner(session: session)
                    ConnectionBanner(session: session)
                    TaskNoticesView(session: session, taskID: taskID)
                    VStack(spacing: 0) {
                        NextStepDock(session: session, taskID: taskID, conversation: conversation)
                        ComposerView(session: session, taskID: taskID, conversation: conversation, editing: $editing,
                                     openSettings: { isShowingSettings = true }, openTask: { openTask($0) })
                    }
                }
            }
        }
    }

    private static let latestID = "latest"

    /// A link in the conversation: a task it names opens as the list opens it, a file it names comes from the Mac, and
    /// any other link opens as it would elsewhere.
    private func open(_ url: URL) -> OpenURLAction.Result {
        if let linked = ConversationLinks.task(url) {
            if linked != taskID {
                if session.task(linked) != nil {
                    openTask(linked)
                } else {
                    session.commandError = String(localized: "\(session.name) no longer lists this task.")
                }
            }
            return .handled
        }
        if session.taskFiles, let path = ConversationLinks.file(url) {
            openFile(path)
            return .handled
        }
        return .systemAction
    }

    /// Reads one of the task's files from the Mac and shows it with QuickLook, which offers to share or save it.
    private func openFile(_ path: String) {
        closeFile()
        let reading = MacFileReading(path: path, hostID: session.id)
        self.reading = reading
        reading.start(path, of: taskID, from: session) { outcome in
            guard self.reading === reading else { return }
            switch outcome {
            case let .read(file):
                preview = file
            case let .failed(message):
                closeFile()
                if let message { session.commandError = message }
            }
        }
    }

    private func closeFile() {
        reading?.close()
        reading = nil
    }

    /// A turn's edit and fork are offered while the Mac takes them from the phone and the task is still listed (§15.23).
    private var offersTurnActions: Bool {
        session.taskControls && session.isConnected && conversation?.isGone != true
    }

    private func toggleWork(_ turnID: String, in conversation: ConversationState) {
        if conversation.openedWork.contains(turnID) {
            conversation.openedWork.remove(turnID)
        } else {
            conversation.openedWork.insert(turnID)
        }
    }

    private var menu: some View {
        Menu {
            if let task {
                Button {
                    session.send(.setPinned(taskID: taskID, pinned: !task.pinned))
                } label: {
                    Label(task.pinned ? "Unpin" : "Pin", systemImage: task.pinned ? "pin.slash" : "pin")
                }
                if session.taskControls {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Label("Model and Permissions", systemImage: "slider.horizontal.3")
                    }
                }
                if task.running {
                    Button(role: .destructive) {
                        session.send(.stopTurn(taskID: taskID))
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                }
                Button {
                    isConfirmingArchive = true
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More")
    }
}

/// When a task's outputs are read again: on each connection to a Mac that offers them, and when a turn starts or ends.
private struct OutputsReading: Equatable {
    let offered: Bool
    let running: Bool
}

/// What every item view needs to act: the Mac and the task, and the screen's own actions.
struct ItemContext {
    let session: HostSession
    let taskID: String
    let task: RemoteTask?
    /// The turns' Edit Message and Fork from Here may be offered now (§15.23).
    var offersTurnActions = false
    /// Edit Message on a turn's message: its words go into the composer (§15.23).
    var editMessage: (_ turnID: String, _ text: String) -> Void = { _, _ in }
    /// Opens a task this one started: a fork (§15.23).
    var openTask: (String) -> Void = { _ in }

    /// Fork from Here on a turn: the fork opens, as the Mac's window opens it.
    @MainActor func fork(_ turnID: String) async {
        if let forked = await session.fork(taskID, turnID: turnID) { openTask(forked) }
    }
}

/// One turn: what was sent, the turn's header, its work (folded once finished, as on the Mac), its answers and the
/// requests still waiting. As on the Mac, a message sent into the turn that stays in view parts the folded work
/// (`RemoteTurnFold`).
struct TurnView: View, @MainActor Equatable {
    let turn: ConversationState.Turn
    let isWorkOpen: Bool
    let context: ItemContext
    let toggleWork: () -> Void
    let openDetail: (RemoteItem) -> Void

    /// The messages whose folded work the person opened.
    @State private var openedStretches: Set<String> = []

    static func == (lhs: TurnView, rhs: TurnView) -> Bool {
        lhs.turn == rhs.turn && lhs.isWorkOpen == rhs.isWorkOpen && lhs.context.task == rhs.context.task
            && lhs.context.offersTurnActions == rhs.context.offersTurnActions
            && lhs.context.session.taskFiles == rhs.context.session.taskFiles
    }

    var body: some View {
        let folds = turn.header?.foldsWork == true && !isWorkOpen
        // Retry goes on the turn's last error, where the Mac's card offers it (§15.31).
        let retryItem = turn.header?.options?.contains(RemoteNextStep.retry.rawValue) == true
            ? turn.items.last { $0.kind == .error }?.id : nil
        let offer = context.offersTurnActions ? TurnOffer(turn.items) : nil
        let rows = RemoteTurnFold.rows(turn.items, folds: folds, opened: openedStretches)
        // The rows themselves, not a stack of them, so the conversation's lazy stack places each line on its own.
        ForEach(rows, id: \.id) { row in
            Group {
                switch row {
                case let .item(item):
                    ItemView(item: item, context: context, isWorkOpen: isWorkOpen, toggleWork: toggleWork,
                             openDetail: openDetail, retryTurnID: item.id == retryItem ? turn.turnID : nil,
                             offer: offer)
                case let .fold(message):
                    StretchFoldView(isOpen: openedStretches.contains(message)) {
                        if openedStretches.contains(message) {
                            openedStretches.remove(message)
                        } else {
                            openedStretches.insert(message)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Turns stand further apart than the lines within one.
            .padding(.top, row.id == rows.first?.id ? 6 : 0)
        }
    }
}

/// A conversation left scrolled far past its end, as when a long turn folds as it finishes, shows its end again:
/// the scroll view keeps its offset when the content above it shrinks, and the screen would stay blank until a swipe.
private struct ShowsEndAfterShrinking: ViewModifier {
    let proxy: ScrollViewProxy
    let end: String

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                // Further past the end than a pull at the bottom goes.
                geometry.contentOffset.y + geometry.containerSize.height
                    > geometry.contentSize.height + geometry.contentInsets.bottom + geometry.containerSize.height / 2
            } action: { _, isPastEnd in
                if isPastEnd { proxy.scrollTo(end, anchor: .bottom) }
            }
        } else {
            content
        }
    }
}

/// The fold of the work after a message sent into a folded turn, as the turn's header reads its fold.
struct StretchFoldView: View {
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                Text("Work details")
                Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.caption2.weight(.semibold))
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}

struct ItemView: View {
    let item: RemoteItem
    let context: ItemContext
    let isWorkOpen: Bool
    let toggleWork: () -> Void
    let openDetail: (RemoteItem) -> Void
    /// The turn whose error this is, when its header offers Retry.
    var retryTurnID: String?
    /// What the item's turn offers (§15.23), on the message that opened it, or on its header without one.
    var offer: TurnOffer?

    var body: some View {
        switch item.kind {
        case .turn:
            TurnHeaderView(item: item, isWorkOpen: isWorkOpen, toggleWork: toggleWork,
                           context: offer.flatMap { $0.messageID == nil && $0.canFork ? context : nil })
        case .user:
            switch item.sender?.kind {
            case "task"?: MessageFromTask(item: item, session: context.session)
            case "backgroundTask"?: BackgroundNotice(item: item)
            case "claudeSchedule"?: MessageFromSchedule(item: item)
            default: UserMessageView(item: item, offer: offer.flatMap { $0.messageID == item.id ? $0 : nil }, context: context)
            }
        case .assistant:
            AssistantView(item: item, opensFiles: context.session.taskFiles)
        case .activity:
            if item.activity == "taskSuggestion", item.suggestionId != nil {
                SuggestionView(item: item, context: context)
            } else {
                ActivityLine(item: item, openDetail: openDetail)
            }
        case .approval:
            if item.status == "pending" {
                RequestCard(item: item, context: context)
            } else {
                AnsweredRequestLine(item: item)
            }
        case .plan:
            PlanStepsView(item: item)
        case .error:
            ErrorView(item: item, context: context, retryTurnID: retryTurnID)
        case .notice:
            NoticeView(item: item)
        }
    }
}

/// The turn's header: "Thinking…" while it runs, "Worked for 1m 30s" once done, which opens its folded work. A turn
/// no message of the person's opened offers its Fork from Here here, on a long press (§15.23).
struct TurnHeaderView: View {
    let item: RemoteItem
    let isWorkOpen: Bool
    let toggleWork: () -> Void
    /// Set when the header holds the turn's fork.
    var context: ItemContext?
    @State private var isForking = false

    var body: some View {
        if let context {
            header.contextMenu {
                Button {
                    isForking = true
                    Task {
                        await context.fork(item.turnId)
                        isForking = false
                    }
                } label: {
                    Label("Fork from Here", systemImage: "arrow.triangle.branch")
                }
                .disabled(isForking)
            }
        } else {
            header
        }
    }

    @ViewBuilder
    private var header: some View {
        if item.status == "running" {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(progress).font(.subheadline).foregroundStyle(.secondary)
            }
        } else if item.foldsWork == true || item.durationMs != nil {
            Button(action: toggleWork) {
                HStack(spacing: 4) {
                    Text(summary)
                    if item.foldsWork == true, (item.workCount ?? 0) > 0 {
                        Image(systemName: isWorkOpen ? "chevron.down" : "chevron.right").font(.caption2.weight(.semibold))
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(item.foldsWork != true)
        }
    }

    private var progress: String {
        if item.progress == "reconnecting" {
            return item.progressText ?? String(localized: "Reconnecting…")
        }
        return String(localized: "Thinking…")
    }

    private var summary: String {
        let status: String? = switch item.status {
        case "interrupted": String(localized: "Stopped")
        case "failed": String(localized: "Failed")
        default: nil
        }
        if let durationMs = item.durationMs {
            let duration = Formatting.duration(milliseconds: durationMs)
            let worked = String(localized: "Worked for \(duration)")
            return status.map { "\($0) · \(worked)" } ?? worked
        }
        return status ?? String(localized: "\(item.workCount ?? 0) steps")
    }
}

/// What the person sent, on the right. In full detail the pictures it sent show above it (§15.24); those without a
/// preview are counted in it. A long press offers Copy and Select Text, and on the message that opened a turn the
/// turn's Edit Message and Fork from Here (§15.23), as the Claude and ChatGPT apps offer a message's actions.
struct UserMessageView: View {
    let item: RemoteItem
    var offer: TurnOffer?
    var context: ItemContext?
    @State private var isSelecting = false
    @State private var isForking = false

    var body: some View {
        let previews = item.images ?? []
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 6) {
                if !previews.isEmpty { PreviewStrip(previews: previews) }
                if !(item.text ?? "").isEmpty || uncounted > 0 || item.scheduled == true || previews.isEmpty {
                    bubble
                        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .contextMenu { actions }
                }
            }
        }
        .sheet(isPresented: $isSelecting) {
            SelectTextView(text: item.text ?? "")
        }
    }

    /// Pictures it sent that came without a preview.
    private var uncounted: Int { max(0, (item.imageCount ?? 0) - (item.images ?? []).count) }

    @ViewBuilder
    private var actions: some View {
        if let text = item.text, !text.isEmpty {
            Button {
                UIPasteboard.general.string = text
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button {
                isSelecting = true
            } label: {
                Label("Select Text", systemImage: "selection.pin.in.out")
            }
        }
        if let offer, let context {
            if offer.canEdit, let text = item.text {
                Button {
                    context.editMessage(offer.turnID, text)
                } label: {
                    Label("Edit Message", systemImage: "pencil")
                }
            }
            if offer.canFork {
                Button {
                    isForking = true
                    Task {
                        await context.fork(offer.turnID)
                        isForking = false
                    }
                } label: {
                    Label("Fork from Here", systemImage: "arrow.triangle.branch")
                }
                .disabled(isForking)
            }
        }
    }

    private var bubble: some View {
        let text = item.text ?? ""
        return VStack(alignment: .trailing, spacing: 4) {
            if item.shell == true {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
            } else if !text.isEmpty || (item.images ?? []).isEmpty {
                ConversationText(text)
            }
            if uncounted > 0 {
                Label("\(uncounted) images", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
            }
            if item.scheduled == true {
                Label("Sent on schedule", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// The agent's answer in full, or a working note in smaller, muted type. With `opensFiles`, a code span that names a
/// file links it (§15.22).
struct AssistantView: View {
    let item: RemoteItem
    var opensFiles = false

    var body: some View {
        if item.role == "commentary" {
            MarkdownView(text: item.text ?? "", font: .subheadline, opensFiles: opensFiles)
                .foregroundStyle(.secondary)
        } else if item.role == "proposedPlan" {
            VStack(alignment: .leading, spacing: 8) {
                Label("Proposed plan", systemImage: "list.bullet.clipboard").font(.subheadline.weight(.semibold))
                MarkdownView(text: item.text ?? "", opensFiles: opensFiles)
            }
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            MarkdownView(text: item.text ?? "", opensFiles: opensFiles)
        }
    }
}

/// One tool, command or step in a line, in the Mac's words (§6.4). A line with more opens its output and changes, or
/// a subagent's card. In full detail a running command shows its newest output under it, and a tool the pictures it
/// made (§15.24, §15.31).
struct ActivityLine: View {
    let item: RemoteItem
    /// Opens what the line holds; nil where nothing opens (a conversation that is only read).
    let openDetail: ((RemoteItem) -> Void)?

    private var opens: Bool { openDetail != nil && item.opensDetail }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            line
            if item.status == "running", let output = item.body?.output {
                LiveOutputTail(output: output).padding(.leading, 24)
            }
            if let images = item.images, !images.isEmpty {
                PreviewStrip(previews: images).padding(.leading, 24)
            }
            if let widget = item.body?.widget {
                ConversationWidgetCard(id: item.id, widget: widget)
            }
        }
    }

    private var line: some View {
        Button {
            if opens { openDetail?(item) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                icon
                    .font(.footnote)
                    .frame(width: 16)
                    .foregroundStyle(item.status == "failed" ? Color.red : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    words
                        .font(.subheadline)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    if let detail = item.detail, !detail.isEmpty, item.activity == "reasoning" || item.status == "failed" {
                        Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
                    }
                }
                Spacer(minLength: 0)
                if let additions = item.additions, let deletions = item.deletions {
                    HStack(spacing: 4) {
                        Text("+\(additions)").foregroundStyle(.green)
                        Text("−\(deletions)").foregroundStyle(.red)
                    }
                    .font(.footnote.monospacedDigit())
                }
                // A subagent on another harness or model than its task says which (§15.24).
                if let runsOn = item.subagent?.harnessLabel ?? item.subagent?.model {
                    Text(verbatim: runsOn).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                if opens {
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!opens)
    }

    /// The Mac's words with the verb muted, as it draws them; the title when the parts are not there.
    private var words: Text {
        guard let words = item.words, !words.isEmpty else {
            return Text(item.title ?? "")
        }
        var text = Text(verbatim: "")
        for (index, entry) in words.enumerated() {
            if index > 0 { text = text + Text(verbatim: ", ") }
            if let leading = entry.leading { text = text + Text(verbatim: leading + " ") }
            text = text + Text(verbatim: entry.verb).foregroundColor(.secondary)
            if let trailing = entry.trailing { text = text + Text(verbatim: " " + trailing) }
        }
        return text
    }

    @ViewBuilder
    private var icon: some View {
        if item.status == "running" {
            ProgressView().controlSize(.mini)
        } else {
            Image(systemName: symbol)
        }
    }

    private var symbol: String {
        if item.status == "failed" { return "exclamationmark.circle" }
        switch item.activity {
        case "command": return "terminal"
        case "fileChange": return "doc.text"
        case "tool": return "wrench.and.screwdriver"
        case "subagent": return "person.2"
        case "reasoning": return "brain"
        case "taskSuggestion": return "lightbulb"
        default: return "circle.dashed"
        }
    }
}

/// A request already answered, as a line in the work where it happened.
struct AnsweredRequestLine: View {
    let item: RemoteItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).font(.footnote).frame(width: 16).foregroundStyle(.secondary)
            Text(line).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private var icon: String {
        switch item.status {
        case "allowed": "checkmark.circle"
        case "denied", "rejected": "xmark.circle"
        case "expired": "clock"
        default: "checkmark.circle"
        }
    }

    private var line: String {
        let title = item.command ?? item.title ?? ""
        return switch item.status {
        case "allowed": String(localized: "Allowed: \(title)")
        case "denied", "rejected": String(localized: "Denied: \(title)")
        case "expired": String(localized: "Expired: \(title)")
        default: String(localized: "Answered: \(title)")
        }
    }
}

/// A step plan or to-do list (§6.6).
struct PlanStepsView: View {
    let item: RemoteItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let explanation = item.explanation, !explanation.isEmpty {
                Text(explanation).font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(Array((item.steps ?? []).enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: step.status == "completed" ? "checkmark.circle.fill"
                          : step.status == "inProgress" ? "circle.inset.filled" : "circle")
                        .font(.footnote)
                        .foregroundStyle(step.status == "completed" ? Color.secondary : Color.primary)
                    Text(step.text)
                        .font(.subheadline)
                        .strikethrough(step.status == "completed", color: .secondary)
                        .foregroundStyle(step.status == "completed" ? .secondary : .primary)
                }
            }
        }
    }
}

/// The task's harness and project under its title: the navigation bar's own subtitle on iOS 26, two lines in the bar's
/// middle before it.
private struct TaskSubtitle: ViewModifier {
    let title: String
    let subtitle: String

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.navigationSubtitle(subtitle)
        } else {
            content.toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }
}

