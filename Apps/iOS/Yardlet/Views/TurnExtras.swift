import SwiftUI
import YardletRemote

extension RemoteItem: @retroactive Identifiable {}

/// The error a turn ended on, or the plan limit that stopped it with what its card offers (§6.7, §15.17).
struct ErrorView: View {
    let item: RemoteItem
    let context: ItemContext
    @State private var isChoosingAccount = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(item.title ?? (isLimit ? String(localized: "Usage limit reached") : String(localized: "Something went wrong")),
                  systemImage: isLimit ? "gauge.with.dots.needle.100percent" : "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isLimit ? Color.orange : Color.red)
            if let message = item.message, !message.isEmpty {
                Text(message).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let resetsAt = item.resetsAt {
                Text("Resets \(context.session.date(resetsAt).formatted(.relative(presentation: .named)))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if (item.options ?? []).contains("continueWithAccount") {
                Button("Continue with Another Account…") { isChoosingAccount = true }
                    .buttonStyle(.bordered)
            }
            if (item.options ?? []).contains("autoContinue") {
                Toggle("Continue when the limit resets", isOn: Binding(
                    get: { item.autoContinue == true },
                    set: { on in context.session.send(.setAutoContinue(taskID: context.taskID, enabled: on)) }))
                    .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $isChoosingAccount) {
            AccountChooser(context: context)
        }
    }

    private var isLimit: Bool { item.errorKind == "usageLimit" }
}

/// The limit card's account list (§15.17): the task's account and those that share its history.
private struct AccountChooser: View {
    let context: ItemContext
    @Environment(\.dismiss) private var dismiss
    @State private var accounts: [RemoteAccount]?

    var body: some View {
        NavigationStack {
            List {
                if let accounts {
                    ForEach(accounts, id: \.id) { account in
                        Button {
                            Task {
                                if await context.session.perform(.continueWithAccount(taskID: context.taskID,
                                                                                      accountID: account.id)) {
                                    dismiss()
                                }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(account.name).foregroundStyle(.primary)
                                    if account.current == true {
                                        Text("Current").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                if let detail = account.detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
                                ForEach(account.usage, id: \.label) { usage in
                                    Text("\(usage.label): \(usage.usedPercent ?? 0)% used")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(account.available != true)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Continue With")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task {
                let response = await context.session.response(to: .limitAccounts(taskID: context.taskID))
                accounts = response.accounts ?? []
            }
        }
        .presentationDetents([.medium, .large])
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

/// A line's output and changes (§15.8), read when it opens.
struct LineDetailView: View {
    let session: HostSession
    let taskID: String
    let item: RemoteItem
    @Environment(\.dismiss) private var dismiss

    private var detail: RemoteItemDetail? { session.conversations[taskID]?.details[item.id] }

    var body: some View {
        NavigationStack {
            ScrollView {
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
            .navigationTitle(item.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { session.loadDetail(taskID, itemID: item.id) }
        }
        .presentationDetents([.medium, .large])
    }

    private func code(_ text: String, truncated: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if truncated {
                Text("Showing the end of the output.").font(.footnote).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
