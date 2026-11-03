import SwiftUI
import YardletRemote

/// One task's conversation, latest first at the bottom, earlier turns on request, live while it runs, with the
/// composer below it (docs/REMOTE_PROTOCOL.md §4.2, §6).
struct TaskView: View {
    let session: HostSession
    let taskID: String
    @State private var conversation: ConversationState?
    @State private var detailItem: RemoteItem?
    @State private var isShowingSettings = false
    @State private var isConfirmingArchive = false
    @Environment(\.dismiss) private var dismiss

    private var task: RemoteTask? { session.task(taskID) }

    var body: some View {
        Group {
            if let conversation {
                content(conversation)
            } else {
                ProgressView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(task?.title ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            ToolbarItem(placement: .topBarTrailing) { menu }
        }
        .onAppear { conversation = session.open(taskID) }
        #if DEBUG
        .task {
            guard UserDefaults.standard.string(forKey: "sheet") == "taskSettings" else { return }
            try? await Task.sleep(for: .seconds(1.5))
            isShowingSettings = true
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
                             context: ItemContext(session: session, taskID: taskID, task: task),
                             toggleWork: { toggleWork(turn.turnID, in: conversation) },
                             openDetail: { detailItem = $0 })
                        .equatable()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            if !conversation.isLoaded { ProgressView() }
        }
        .safeAreaInset(edge: .top, spacing: 0) { ConnectionBanner(session: session) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                CommandErrorBanner(session: session)
                ComposerView(session: session, taskID: taskID, conversation: conversation,
                             openSettings: { isShowingSettings = true })
            }
        }
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

/// What every item view needs to act: the Mac and the task.
struct ItemContext {
    let session: HostSession
    let taskID: String
    let task: RemoteTask?
}

/// One turn: what was sent, the turn's header, its work (folded once finished, as on the Mac), its answers and the
/// requests still waiting.
struct TurnView: View, @MainActor Equatable {
    let turn: ConversationState.Turn
    let isWorkOpen: Bool
    let context: ItemContext
    let toggleWork: () -> Void
    let openDetail: (RemoteItem) -> Void

    static func == (lhs: TurnView, rhs: TurnView) -> Bool {
        lhs.turn == rhs.turn && lhs.isWorkOpen == rhs.isWorkOpen && lhs.context.task == rhs.context.task
    }

    var body: some View {
        let folds = turn.header?.foldsWork == true && !isWorkOpen
        VStack(alignment: .leading, spacing: 12) {
            ForEach(turn.items, id: \.id) { item in
                if !(folds && item.inWork == true) {
                    ItemView(item: item, context: context, isWorkOpen: isWorkOpen, toggleWork: toggleWork,
                             openDetail: openDetail)
                }
            }
        }
    }
}

struct ItemView: View {
    let item: RemoteItem
    let context: ItemContext
    let isWorkOpen: Bool
    let toggleWork: () -> Void
    let openDetail: (RemoteItem) -> Void

    var body: some View {
        switch item.kind {
        case .turn:
            TurnHeaderView(item: item, isWorkOpen: isWorkOpen, toggleWork: toggleWork)
        case .user:
            UserMessageView(item: item)
        case .assistant:
            AssistantView(item: item)
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
            ErrorView(item: item, context: context)
        case .notice:
            NoticeLine(text: item.text ?? item.title ?? "")
        }
    }
}

/// The turn's header: "Thinking…" while it runs, "Worked for 1m 30s" once done, which opens its folded work.
struct TurnHeaderView: View {
    let item: RemoteItem
    let isWorkOpen: Bool
    let toggleWork: () -> Void

    var body: some View {
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

/// What the person sent, on the right.
struct UserMessageView: View {
    let item: RemoteItem

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 4) {
                if item.shell == true {
                    Text(item.text ?? "")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                } else {
                    Text(MarkdownView.inline(item.text ?? ""))
                        .textSelection(.enabled)
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
}

/// The agent's answer in full, or a working note in smaller, muted type.
struct AssistantView: View {
    let item: RemoteItem

    var body: some View {
        if item.role == "commentary" {
            MarkdownView(text: item.text ?? "", font: .subheadline)
                .foregroundStyle(.secondary)
        } else if item.role == "proposedPlan" {
            VStack(alignment: .leading, spacing: 8) {
                Label("Proposed plan", systemImage: "list.bullet.clipboard").font(.subheadline.weight(.semibold))
                MarkdownView(text: item.text ?? "")
            }
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            MarkdownView(text: item.text ?? "")
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
