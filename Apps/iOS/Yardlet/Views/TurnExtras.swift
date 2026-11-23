import SwiftUI
import YardletRemote

extension RemoteItem: @retroactive Identifiable {}

/// The error a turn ended on, or the plan limit that stopped it with what its card offers (§6.7, §15.17), and the next
/// step the Mac's card gives (§15.31): Try Again on an error, Resume on a limit card once the limit reset.
struct ErrorView: View {
    let item: RemoteItem
    let context: ItemContext
    let retryTurnID: String?
    @State private var isChoosingAccount = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(item.title ?? (isLimit ? String(localized: "Usage limit reached") : String(localized: "Something went wrong")),
                  systemImage: isLimit ? "gauge.with.dots.needle.100percent" : "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isLimit ? YardletPalette.Status.limit : YardletPalette.error)
            if let message = item.message, !message.isEmpty {
                Text(message).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let windows = item.limit?.windows, !windows.isEmpty {
                LimitWindowLines(windows: windows, session: context.session)
            } else if let resetsAt = item.resetsAt {
                Text("Resets \(context.session.date(resetsAt).formatted(.relative(presentation: .named)))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let retryTurnID {
                Button("Try Again") {
                    context.session.nextStep(context.taskID, turnID: retryTurnID, action: .retry)
                }
                .buttonStyle(.bordered)
                .disabled(!context.session.isConnected)
            }
            if (item.options ?? []).contains("continueWithAccount") {
                Button("Continue with Another Account…") { isChoosingAccount = true }
                    .buttonStyle(.bordered)
            }
            TimelineView(.everyMinute) { timeline in
                if resumes(at: timeline.date) {
                    // The limit reset: the Mac's card offers Resume where it offered to continue on its own.
                    Button("Resume") {
                        context.session.nextStep(context.taskID, turnID: item.turnId, action: .resumeAfterReset)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!context.session.isConnected)
                } else if (item.options ?? []).contains("autoContinue") {
                    Toggle("Continue when the limit resets", isOn: Binding(
                        get: { item.autoContinue == true },
                        set: { on in context.session.send(.setAutoContinue(taskID: context.taskID, enabled: on)) }))
                        .font(.subheadline)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $isChoosingAccount) {
            AccountChooser(context: context)
        }
    }

    private var isLimit: Bool { item.errorKind == "usageLimit" }

    private func resumes(at now: Date) -> Bool {
        guard (item.options ?? []).contains(RemoteNextStep.resumeAfterReset.rawValue) else { return false }
        guard let resetsAt = item.resetsAt else { return true }
        return context.session.date(resetsAt) <= now
    }
}

/// The limit card's account list (§15.17): the task's account and those that share its history. Why the Mac did not
/// move the task shows here, not under the sheet.
private struct AccountChooser: View {
    let context: ItemContext
    @Environment(\.dismiss) private var dismiss
    @State private var accounts: [RemoteAccount]?
    @State private var refusal: String?
    @State private var isMoving = false

    var body: some View {
        NavigationStack {
            List {
                if let accounts {
                    ForEach(accounts, id: \.id) { account in
                        if account.available == true && account.current != true {
                            Button {
                                pick(account)
                            } label: {
                                row(account)
                            }
                            .disabled(isMoving)
                        } else {
                            // The task's own account reads in full; one it cannot move to is dimmed.
                            row(account).opacity(account.current == true ? 1 : 0.5)
                        }
                    }
                    if refusal == nil, !accounts.contains(where: { $0.current != true }) {
                        Text("No other account can continue this task.").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let refusal {
                        Section {
                            Text(refusal).font(.footnote).foregroundStyle(.red)
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .scrollContentBackground(.hidden)
            .background(YardletPalette.background)
            .navigationTitle("Continue With")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task {
                let response = await context.session.response(to: .limitAccounts(taskID: context.taskID))
                if !response.ok { refusal = HostSession.message(for: response.error, host: context.session.name) }
                accounts = response.accounts ?? []
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ account: RemoteAccount) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(account.name).foregroundStyle(.primary)
                Spacer(minLength: 8)
                if account.current == true {
                    Text("Current").font(.caption).foregroundStyle(.secondary)
                } else if account.available != true {
                    Text("Unavailable").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let detail = account.detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            ForEach(account.usage, id: \.label) { usage in
                UsageLine(usage: usage, session: context.session)
            }
        }
    }

    private func pick(_ account: RemoteAccount) {
        Task {
            isMoving = true
            refusal = nil
            let response = await context.session.response(
                to: .continueWithAccount(taskID: context.taskID, accountID: account.id))
            isMoving = false
            if response.ok {
                dismiss()
            } else {
                refusal = HostSession.message(for: response.error, host: context.session.name)
            }
        }
    }
}

/// One limit window of an account: a short meter, then "Session 12% · Resets 4:00 PM".
private struct UsageLine: View {
    let usage: RemoteAccount.Usage
    let session: HostSession

    var body: some View {
        let percent = usage.usedPercent.map { min(max($0, 0), 100) }
        HStack(spacing: 8) {
            if let percent {
                ProgressView(value: Double(percent), total: 100)
                    .tint(percent >= 90 ? .orange : .secondary)
                    .frame(width: 36)
            }
            Text(text(percent))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func text(_ percent: Int?) -> String {
        var parts: [String] = []
        if let percent {
            parts.append(String(localized: "\(usage.label) \(percent)%"))
        } else if !usage.label.isEmpty {
            parts.append(usage.label)
        }
        if let resetsAt = usage.resetsAt {
            let date = session.date(resetsAt)
            // The clock time today, else a short date with it ("Nov 20, 1:56 AM").
            let time = Calendar.current.isDateInToday(date)
                ? date.formatted(date: .omitted, time: .shortened)
                : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
            parts.append(String(localized: "Resets \(time)"))
        }
        return parts.joined(separator: " · ")
    }
}

/// A task the agent suggests, with what the Mac's chip offers now (§15.9): Start, Do It Here and Dismiss, and Options
/// from a Mac that reads the chip's choices for the phone; else what became of it. Why a Start failed shows under it.
struct SuggestionView: View {
    let item: RemoteItem
    let context: ItemContext
    @State private var isShowingOptions = false

    private var actions: [String] { item.options ?? [] }
    private var offersOptions: Bool {
        context.session.suggestionOptions && actions.contains(RemoteSuggestionAction.start.rawValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(item.title ?? "", systemImage: "lightbulb").font(.subheadline.weight(.medium))
            if let detail = item.detail, !detail.isEmpty {
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            if item.suggestionState == "failed", let failure = item.suggestionFailure, !failure.isEmpty {
                Text(failure).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
            }
            if !actions.isEmpty {
                HStack(spacing: 8) {
                    if actions.contains(RemoteSuggestionAction.start.rawValue) {
                        Button("Start") { act(.start) }.prominentButton()
                    }
                    if actions.contains(RemoteSuggestionAction.here.rawValue) {
                        Button("Do It Here") { act(.here) }.buttonStyle(.bordered)
                    }
                    if offersOptions {
                        Button("Options") { isShowingOptions = true }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .accessibilityHint(item.title ?? "")
                    }
                    Spacer()
                    if actions.contains(RemoteSuggestionAction.dismiss.rawValue) {
                        Button {
                            act(.dismiss)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Dismiss")
                    }
                }
                .controlSize(.small)
                .disabled(!context.session.isConnected)
            } else if let outcome {
                Text(outcome).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $isShowingOptions) {
            if let id = item.suggestionId {
                SuggestionOptionsView(session: context.session, taskID: context.taskID, suggestionID: id,
                                      title: item.title ?? "")
            }
        }
        // Started, sent or dismissed meanwhile, here or on the Mac: its Options have nothing left to start.
        .onChange(of: offersOptions) { _, offered in
            if !offered { isShowingOptions = false }
        }
        #if DEBUG
        .task {
            guard UserDefaults.standard.string(forKey: "sheet") == "suggestionOptions" else { return }
            try? await Task.sleep(for: .seconds(1.5))
            if offersOptions { isShowingOptions = true }
        }
        #endif
    }

    private var outcome: String? {
        switch item.suggestionState {
        case "started": String(localized: "Started")
        case "dismissed": String(localized: "Dismissed")
        case "sentHere": String(localized: "Done here")
        case "starting": String(localized: "Starting…")
        default: nil
        }
    }

    private func act(_ action: RemoteSuggestionAction) {
        guard let id = item.suggestionId else { return }
        context.session.send(.actOnSuggestion(taskID: context.taskID, suggestionID: id, action: action))
    }
}

/// A line's output and changes (§15.8), read when it opens; in full detail what the line holds, at once and followed
/// while it runs (§15.31). A file change still reads its diffs.
struct LineDetailView: View {
    let session: HostSession
    let taskID: String
    let item: RemoteItem
    @Environment(\.dismiss) private var dismiss

    private var detail: RemoteItemDetail? { session.conversations[taskID]?.details[item.id] }
    /// The line as it is now.
    private var live: RemoteItem { session.conversations[taskID]?.item(item.id) ?? item }

    var body: some View {
        let live = self.live
        NavigationStack {
            ScrollView {
                if live.showsBody {
                    LineBodyView(item: live).equatable().padding(16)
                } else {
                    fetched
                }
            }
            .followsNewest(item.status == "running" && item.showsBody)
            .navigationTitle(item.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                if !live.showsBody { session.loadDetail(taskID, itemID: item.id) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// The output and diffs `itemDetail` read.
    private var fetched: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let command = item.detail, item.activity == "command" {
                Text(command)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
            if let detail {
                if let output = detail.output, !output.isEmpty {
                    code(output, truncated: detail.outputTruncated)
                }
                ForEach(detail.diffs, id: \.path) { diff in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(diff.path).font(.footnote.weight(.semibold)).lineLimit(2)
                            Spacer()
                            if let additions = diff.additions, let deletions = diff.deletions {
                                Text("+\(additions)").foregroundStyle(.green).font(.footnote.monospacedDigit())
                                Text("−\(deletions)").foregroundStyle(.red).font(.footnote.monospacedDigit())
                            }
                        }
                        DiffView(patch: diff.patch)
                        if diff.truncated == true {
                            Text("The rest of this change is on your Mac.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if detail.output?.isEmpty != false && detail.diffs.isEmpty {
                    Text("Nothing more to show.").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
            }
        }
        .padding(16)
    }

    private func code(_ text: String, truncated: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if truncated {
                Text("Showing the end of the output.").font(.footnote).foregroundStyle(.secondary)
            }
            CodeBlock(text: text)
        }
    }
}

/// A unified diff, added lines green and removed lines red.
struct DiffView: View {
    let patch: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(patch.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(color(line))
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(line))
                }
            }
            .padding(.vertical, 8)
            .textSelection(.enabled)
        }
        .background(YardletPalette.surfaceContainerLow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.5)
        )
    }

    private func color(_ line: String) -> Color {
        if line.hasPrefix("@@") { return .secondary }
        return .primary
    }

    private func background(_ line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green.opacity(0.15) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red.opacity(0.15) }
        return .clear
    }
}
