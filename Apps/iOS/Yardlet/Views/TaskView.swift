import QuickLook
import SwiftUI
import YardletRemote

/// One task's conversation, latest first at the bottom, earlier turns on request, live while it runs, with the
/// composer below it (docs/REMOTE_PROTOCOL.md §4.2, §6). What the task made, and the files and tasks its answers link,
/// open from here (§15.22).
struct TaskView: View {
    let session: HostSession
    let taskID: String
    @State private var conversation: ConversationState?
    /// A turn's message in the composer to edit (§15.23).
    @State private var editing: MessageEdit?
    @State private var detailItem: RemoteItem?
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
    @Environment(\.dismiss) private var dismiss

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
            ToolbarItem(placement: .topBarTrailing) { menu }
        }
        .onAppear { conversation = session.open(taskID) }
        // What the task made: read when it opens, on each connection and when a turn starts or ends.
        .task(id: OutputsReading(offered: session.taskFiles && session.isConnected, running: task?.running == true)) {
            await session.loadOutputs(taskID)
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
        .sheet(item: $detailItem) { item in
            LineDetailView(session: session, taskID: taskID, item: item)
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

    private var subtitle: String {
        guard let task else { return "" }
        return [task.harnessName, session.project(task.projectId)?.name].compactMap { $0 }.joined(separator: " · ")
    }

    private func content(_ conversation: ConversationState) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
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
            .overlay {
                if !conversation.isLoaded { ProgressView() }
            }
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
    }

    var body: some View {
        let folds = turn.header?.foldsWork == true && !isWorkOpen
        // Retry goes on the turn's last error, where the Mac's card offers it (§15.31).
        let retryItem = turn.header?.options?.contains(RemoteNextStep.retry.rawValue) == true
            ? turn.items.last { $0.kind == .error }?.id : nil
        let offer = context.offersTurnActions ? TurnOffer(turn.items) : nil
        VStack(alignment: .leading, spacing: 12) {
            ForEach(RemoteTurnFold.rows(turn.items, folds: folds, opened: openedStretches), id: \.id) { row in
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
            NoticeLine(text: item.text ?? item.title ?? "")
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

/// What the person sent, on the right. A long press offers Copy and Select Text, and on the message that opened a turn
/// the turn's Edit Message and Fork from Here (§15.23), as the Claude and ChatGPT apps offer a message's actions.
struct UserMessageView: View {
    let item: RemoteItem
    var offer: TurnOffer?
    var context: ItemContext?
    @State private var isSelecting = false
    @State private var isForking = false

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            bubble
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contextMenu { actions }
        }
        .sheet(isPresented: $isSelecting) {
            SelectTextView(text: item.text ?? "")
        }
    }

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
        VStack(alignment: .trailing, spacing: 4) {
            if item.shell == true {
                Text(item.text ?? "")
                    .font(.system(.callout, design: .monospaced))
            } else {
                Text(MarkdownView.inline(item.text ?? ""))
            }
            if let count = item.imageCount, count > 0 {
                Label("\(count) images", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
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

/// One tool, command or step in a line, in the Mac's words (§6.4). A line with more opens its output and changes.
struct ActivityLine: View {
    let item: RemoteItem
    let openDetail: (RemoteItem) -> Void

    var body: some View {
        Button {
            if item.hasDetail == true { openDetail(item) }
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
                if item.hasDetail == true {
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.hasDetail != true)
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

struct NoticeLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").font(.footnote)
            Text(text).font(.footnote)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
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

