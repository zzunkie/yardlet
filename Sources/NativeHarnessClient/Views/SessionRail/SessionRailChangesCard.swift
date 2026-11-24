import AppKit
import SwiftUI

/// The rail's Changes card: the folder's uncommitted work, which opens the review panel, and the
/// task's pull request with what GitHub says of it through the person's `gh` — whether it can
/// merge, each check (failing first, a failed one's log on request), reviews, re-running failed
/// jobs, merging and auto-merge, "Fix CI" and the task's auto-fix.
struct SessionRailChangesCard: View {
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    let changes: SessionRailContent.Changes
    let actions: SessionRailActions

    var body: some View {
        VStack(alignment: .leading, spacing: ParitySpace.s8) {
            if let summary = changes.summary, !summary.isEmpty {
                Button(action: actions.openChanges) {
                    HStack(spacing: ParitySpace.s8) {
                        Image(systemName: "plusminus").foregroundStyle(.secondary).frame(width: 16 * interfaceScale)
                        Text(summary.fileCount == 1 ? L10n.string("1 file")
                             : L10n.format("%lld files", Int64(summary.fileCount)))
                        Spacer(minLength: ParitySpace.s8)
                        Text("+\(summary.additions)").foregroundStyle(.green).monospacedDigit()
                        Text("−\(summary.deletions)").foregroundStyle(.red).monospacedDigit()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9 * interfaceScale, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(minHeight: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .parityPointer()
                .help(L10n.string("Review changes"))
                .accessibilityLabel(L10n.string("Review changes"))
                .accessibilityValue(L10n.format("%lld files", Int64(summary.fileCount)))
            }
            if let pullRequest = changes.pullRequest {
                SessionRailPullRequestView(pullRequest: pullRequest, state: changes.pullRequestState,
                                           autoFix: changes.autoFix, asksAboutAutoFix: changes.asksAboutAutoFix,
                                           actions: actions)
            }
        }
    }
}

struct SessionRailPullRequestView: View {
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    let pullRequest: TaskPullRequest
    let state: PullRequestDetailCenter.TaskState?
    let autoFix: PullRequestAutoFixRecord?
    let asksAboutAutoFix: Bool
    let actions: SessionRailActions

    @State private var showsPassingChecks = false

    private var detail: PullRequestDetail? { state?.detail }
    private var prActions: SessionRailPullRequestActions? { actions.pullRequest }

    var body: some View {
        VStack(alignment: .leading, spacing: ParitySpace.s8) {
            header
            if let detail {
                if let text = detail.mergeStateText { mergeStateLine(detail, text: text) }
                if let method = detail.autoMerge, detail.isOpen { autoMergeLine(method) }
                if !detail.checks.isEmpty { checks(detail) }
                reviews(detail)
                if detail.isOpen { actionRow(detail) }
                if detail.isOpen { autoFixSection(detail) }
            } else if let problem = state?.problem {
                Text(problem.message)
                    .font(.parity(.caption, scale: interfaceScale))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if state?.isLoading == true {
                ProgressView().controlSize(.small)
            }
            if let error = state?.actionError {
                Text(error)
                    .font(.parity(.caption, scale: interfaceScale))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog(
            mergeQuestion,
            isPresented: Binding(get: { state?.pendingMerge != nil }, set: { if !$0 { prActions?.cancelMerge() } }),
            titleVisibility: .visible
        ) {
            Button(mergeConfirmTitle) { prActions?.confirmMerge() }
            Button(L10n.string("Cancel"), role: .cancel) { prActions?.cancelMerge() }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: ParitySpace.s4) {
            HStack(spacing: ParitySpace.s8) {
                TaskPullRequestBadgeView(badge: TaskPullRequestBadge(detail?.summary ?? pullRequest),
                                         onOpen: actions.openURL)
                Spacer(minLength: ParitySpace.s4)
                if state?.isLoading == true, detail != nil {
                    ProgressView().controlSize(.mini)
                } else if prActions != nil {
                    Button { prActions?.refresh() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10 * interfaceScale, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .parityPointer()
                    .help(L10n.string("Refresh"))
                    .accessibilityLabel(L10n.string("Refresh"))
                }
            }
            if let detail, !detail.title.isEmpty {
                Text(detail.title)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let head = detail?.headBranch {
                Text([head, detail?.baseBranch].compactMap { $0 }.joined(separator: " → "))
                    .font(.parity(.caption, scale: interfaceScale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func mergeStateLine(_ detail: PullRequestDetail, text: String) -> some View {
        let (symbol, tint): (String, Color) = if detail.hasConflicts {
            ("exclamationmark.triangle", .red)
        } else {
            switch detail.mergeState {
            case .clean, .hasHooks: ("checkmark.circle", .green)
            case .unstable: ("exclamationmark.circle", .orange)
            default: ("clock", .orange)
            }
        }
        return Label {
            Text(text).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.parity(.caption, scale: interfaceScale))
    }

    private func autoMergeLine(_ method: PullRequestDetail.MergeMethod) -> some View {
        HStack(spacing: ParitySpace.s8) {
            Label(L10n.format("Auto-merge on · %@", method.title), systemImage: "arrow.triangle.merge")
                .font(.parity(.caption, scale: interfaceScale))
                .foregroundStyle(.secondary)
            Spacer(minLength: ParitySpace.s4)
            if let prActions {
                Button(L10n.string("Turn off")) { prActions.requestMerge(.disableAuto) }
                    .buttonStyle(.plain)
                    .font(.parity(.caption, scale: interfaceScale))
                    .foregroundStyle(.secondary)
                    .parityPointer()
                    .disabled(state?.runningAction != nil)
            }
        }
    }

    // MARK: Checks

    private func checks(_ detail: PullRequestDetail) -> some View {
        let shown = detail.checks.filter { showsPassingChecks || $0.bucket == .failing || $0.bucket == .pending }
        let hiddenCount = detail.checks.count - shown.count
        return VStack(alignment: .leading, spacing: ParitySpace.s4) {
            if let summary = detail.checksSummaryText {
                Text(L10n.format("Checks: %@", summary))
                    .font(.parity(.caption, scale: interfaceScale))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(shown) { check in
                SessionRailCheckRow(check: check, log: state?.logs[check.id], actions: prActions,
                                    openURL: actions.openURL)
            }
            if hiddenCount > 0 {
                Button(L10n.format("Show %lld passing checks", Int64(hiddenCount))) { showsPassingChecks = true }
                    .buttonStyle(.plain).font(.parity(.caption, scale: interfaceScale)).foregroundStyle(.secondary).parityPointer()
            } else if showsPassingChecks {
                Button(L10n.string("Hide passing checks")) { showsPassingChecks = false }
                    .buttonStyle(.plain).font(.parity(.caption, scale: interfaceScale)).foregroundStyle(.secondary).parityPointer()
            }
        }
    }

    // MARK: Reviews

    @ViewBuilder private func reviews(_ detail: PullRequestDetail) -> some View {
        let decided = detail.reviews.filter { $0.decision == .approved || $0.decision == .changesRequested }
        if !decided.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(decided.enumerated()), id: \.offset) { _, review in
                    Label {
                        Text(L10n.format(review.decision == .approved ? "Approved by %@" : "Changes requested by %@",
                                         review.author))
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: review.decision == .approved ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(review.decision == .approved ? .green : .red)
                    }
                    .font(.parity(.caption, scale: interfaceScale))
                }
            }
        } else if detail.isOpen, detail.review == nil, detail.state == .open {
            Label(L10n.string("Waiting for review"), systemImage: "person.crop.circle.badge.clock")
                .font(.parity(.caption, scale: interfaceScale))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    @ViewBuilder private func actionRow(_ detail: PullRequestDetail) -> some View {
        if let prActions {
            let failed = detail.failedChecks
            HStack(spacing: ParitySpace.s8) {
                if !failed.isEmpty, autoFix?.isOn != true {
                    Button(L10n.string("Fix CI")) {
                        prActions.draftFix(PullRequestAutoFixPolicy.draft(for: detail, logs: loadedLogs))
                    }
                    .help(L10n.string("Put a request to fix the failing checks in the composer"))
                }
                if failed.contains(where: { $0.runID != nil }) {
                    Button(L10n.string("Re-run failed")) { prActions.rerunFailed(failed) }
                        .disabled(state?.runningAction != nil)
                        .help(L10n.string("Re-run failed checks"))
                }
                Spacer(minLength: 0)
                mergeMenu(detail, actions: prActions)
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
    }

    private var loadedLogs: [String: String] {
        (state?.logs ?? [:]).compactMapValues { log in
            if case let .loaded(text) = log { return text }
            return nil
        }
    }

    private func mergeMenu(_ detail: PullRequestDetail, actions prActions: SessionRailPullRequestActions) -> some View {
        let methods = (state?.mergeMethods ?? .all).allowed
        return Menu(L10n.string("Merge")) {
            ForEach(methods, id: \.self) { method in
                Button(method.title) { prActions.requestMerge(.merge(method)) }
                    .disabled(detail.state == .draft || detail.hasConflicts)
            }
            Divider()
            if detail.autoMerge == nil {
                ForEach(methods, id: \.self) { method in
                    Button(L10n.format("Merge when ready · %@", method.title)) { prActions.requestMerge(.enableAuto(method)) }
                }
            } else {
                Button(L10n.string("Cancel auto-merge")) { prActions.requestMerge(.disableAuto) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(state?.runningAction != nil)
    }

    private var mergeQuestion: String {
        guard let kind = state?.pendingMerge else { return "" }
        let number = String(pullRequest.number)
        return switch kind {
        case let .merge(method): L10n.format("Merge #%@ (%@)?", number, method.title)
        case let .enableAuto(method): L10n.format("Merge #%@ when ready (%@)?", number, method.title)
        case .disableAuto: L10n.format("Turn off auto-merge for #%@?", number)
        }
    }

    private var mergeConfirmTitle: String {
        switch state?.pendingMerge {
        case .merge?: L10n.string("Merge")
        case .enableAuto?: L10n.string("Turn on auto-merge")
        case .disableAuto?, nil: L10n.string("Turn off auto-merge")
        }
    }

    // MARK: Auto-fix

    @ViewBuilder private func autoFixSection(_ detail: PullRequestDetail) -> some View {
        if let prActions {
            if asksAboutAutoFix {
                VStack(alignment: .leading, spacing: ParitySpace.s8) {
                    Text(L10n.string("When this pull request's checks fail, send the task a message to fix them?"))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: ParitySpace.s8) {
                        Button(L10n.string("Turn on auto-fix")) { prActions.setAutoFix(true) }
                            .parityProminentButton()
                        Button(L10n.string("Not now")) { prActions.setAutoFix(false) }
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.small)
                }
                .padding(ParitySpace.s8)
                .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: ParityRadius.row))
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(isOn: Binding(get: { autoFix?.isOn == true }, set: { prActions.setAutoFix($0) })) {
                        Text(L10n.string("Auto-fix CI"))
                    }
                    .toggleStyle(.paritySwitch)
                    .controlSize(.mini)
                    .help(L10n.string("Sends the task a message to fix the checks when they fail, once per failure, while Yardlet is open."))
                    if autoFix?.isOn == true, let sent = autoFix?.lastSentAt {
                        Text(L10n.format("Last sent %@", sent.formatted(.relative(presentation: .named))))
                            .font(.parity(.caption, scale: interfaceScale))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

/// One check: its state, name and workflow, how long it took; a failed one opens its failed steps'
/// log in place, and every one opens on GitHub.
struct SessionRailCheckRow: View {
    let check: PullRequestDetail.Check
    let log: PullRequestDetailCenter.TaskState.Log?
    let actions: SessionRailPullRequestActions?
    let openURL: (URL) -> Void
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        VStack(alignment: .leading, spacing: ParitySpace.s4) {
            // The state and the menu on the check's name, not between its name and its workflow.
            HStack(alignment: .firstTextBaseline, spacing: ParitySpace.s8) {
                Image(systemName: symbol)
                    .font(.system(size: 10 * interfaceScale, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 13)
                    .centeredOnCapHeight(ofTextSize: ParityType.caption.size * interfaceScale)
                VStack(alignment: .leading, spacing: 0) {
                    Text(check.name).lineLimit(1).truncationMode(.middle)
                    if let detail = detailText {
                        Text(detail).font(.parity(.caption, scale: interfaceScale)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: ParitySpace.s4)
                Menu {
                    if check.bucket == .failing, check.runID != nil, let actions {
                        if log == nil {
                            Button(L10n.string("Show failure details")) { actions.loadLog(check) }
                        } else {
                            Button(L10n.string("Hide failure details")) { actions.closeLog(check) }
                        }
                    }
                    if let link = check.link {
                        Button(L10n.string("Open logs on GitHub")) { openURL(link) }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 10 * interfaceScale, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .centeredOnCapHeight(ofTextSize: ParityType.caption.size * interfaceScale)
                .accessibilityLabel(L10n.format("%@ actions", check.name))
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 1) {
                guard check.bucket == .failing, check.runID != nil, let actions else { return }
                if log == nil { actions.loadLog(check) } else { actions.closeLog(check) }
            }
            if let log { logView(log) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(check.name)
        .accessibilityValue(check.state)
    }

    @ViewBuilder private func logView(_ log: PullRequestDetailCenter.TaskState.Log) -> some View {
        switch log {
        case .loading:
            ProgressView().controlSize(.mini).padding(.leading, 19)
        case let .failed(message):
            Text(message).font(.parity(.caption, scale: interfaceScale)).foregroundStyle(.secondary).padding(.leading, 19)
        case let .loaded(text):
            ScrollView {
                Text(text.isEmpty ? L10n.string("No failed steps were logged.") : text)
                    .font(.system(size: ParityType.caption.size * interfaceScale, design: .monospaced)).fontDesign(nil)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(ParitySpace.s8)
            }
            .frame(maxHeight: 160)
            .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: ParityRadius.control))
        }
    }

    private var detailText: String? {
        let duration = check.duration.map { BackgroundTasksProjection.elapsedText(since: Date(timeIntervalSince1970: 0),
                                                                              now: Date(timeIntervalSince1970: $0)) }
        let parts = [check.workflow, duration].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var symbol: String {
        switch check.bucket {
        case .failing: "xmark.circle.fill"
        case .pending: "clock"
        case .passing: "checkmark.circle.fill"
        case .skipped: "minus.circle"
        }
    }

    private var tint: Color {
        switch check.bucket {
        case .failing: .red
        case .pending: .orange
        case .passing: .green
        case .skipped: .secondary
        }
    }
}
