import SwiftUI

/// A task from a dot's Activity, read in place of the dot's conversation, as the provider's own app
/// previews it: the execution record only, in the one conversation renderer, with nothing that would
/// resume, answer or change the task. The record arrives a page at a time; what is not read yet, or
/// could not be, says so instead of passing for the whole record.
struct PersonalAgentActivityView: View {
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    let agent: PersonalAgent
    @Bindable var reading: PersonalAgentActivityReading
    var showsDetails = false
    let close: () -> Void
    let reload: () -> Void
    let loadEarlierTurns: () -> Void
    let loadItems: (String) -> Void
    let retryItems: () -> Void
    var toggleDetails: () -> Void = {}
    @Environment(\.yardletInterfaceScale) private var scale
    @Environment(\.openURL) private var openURL
    @State private var renderState = ConversationRenderState()

    private var history: PersonalAgentActivityHistory { reading.history }

    var body: some View {
        VStack(spacing: 0) {
            header
            notices
            content
        }
        .background(ParityTheme.canvas)
        // The task ran on the provider's computer: its web links open, a path names no file on this Mac.
        .environment(\.transcriptOpensLocalFiles, false)
        .environment(\.openURL, OpenURLAction { url in
            guard PersonalAgentActivityHistory.opensLink(url) else { return .discarded }
            openURL(url)
            return .handled
        })
        .onMacShortcutExit(perform: close)
    }

    private var header: some View {
        HStack(spacing: 8) {
            ParityHeaderButton(systemName: "chevron.left", help: L10n.format("Back to %@", agent.name), action: close)
                .accessibilityLabel(L10n.format("Back to %@", agent.name))
            Image(systemName: PersonalAgentDetailsPanel.symbol(reading.activity))
                .foregroundStyle(.secondary).accessibilityHidden(true)
            Text(reading.activity.title).font(.parity(.control, weight: .semibold, scale: scale))
                .lineLimit(1).truncationMode(.tail)
            let status = PersonalAgentDetailsPanel.statusText(reading.activity)
            if !status.isEmpty { Text(status).font(.yardlet(.caption, scale: interfaceScale)).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: 8)
            ParityHeaderButton(systemName: "arrow.clockwise", help: L10n.string("Refresh"), action: reload)
                .disabled(history.phase == .loading)
                .accessibilityLabel(L10n.string("Refresh task"))
            ParityHeaderButton(systemName: "sidebar.right",
                               help: L10n.string(showsDetails ? "Hide dot details" : "Show dot details"),
                               isOn: showsDetails, action: toggleDetails)
                .accessibilityLabel(L10n.string(showsDetails ? "Hide dot details" : "Show dot details"))
        }
        .padding(.leading, 8).padding(.trailing, 8).frame(height: PersonalAgentConversationView.headerHeight)
        .environment(\.parityHeaderControls, true)
        .accessibilityElement(children: .contain)
    }

    /// What of a loaded record is missing: items of some turns, or the turns before them.
    @ViewBuilder
    private var notices: some View {
        if history.phase == .loaded {
            if history.isPartial {
                notice(L10n.string("Some steps of this task could not be loaded."), failure: history.itemFailures.values.first,
                       retry: retryItems)
            }
            if let failure = history.earlierTurnsFailure {
                notice(L10n.string("Earlier turns could not be loaded."), failure: failure, retry: loadEarlierTurns)
            }
        }
    }

    private func notice(_ text: String, failure: PersonalAgentFailure?, retry: @escaping () -> Void) -> some View {
        PersonalAgentNotice(text: text) {
            Button(L10n.string("Try again"), action: retry)
        }
        .help(failure?.message ?? "")
        .conversationColumn().padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch history.phase {
        case .loading:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(L10n.string("Loading task…")).foregroundStyle(.secondary)
            }
            .font(.system(size: 13 * scale))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missing:
            state(L10n.string("This task is no longer available."), systemName: "questionmark.circle", retry: nil)
        case let .failed(failure):
            state(failure.message, systemName: "exclamationmark.triangle", retry: reload)
        case .loaded where history.isEmpty:
            state(L10n.string("This task has no turns yet."), systemName: "text.bubble", retry: nil)
        case .loaded:
            ConversationTimeline(
                source: .codex(history.state, workspaceURL: URL(filePath: "/"), historySelection: nil),
                placement: .panel,
                actions: ConversationActions(loadMoreCodexTurns: loadEarlierTurns, loadMoreCodexItems: loadItems),
                diagnosticID: "dots-activity", renderState: renderState
            )
        }
    }

    private func state(_ text: String, systemName: String, retry: (() -> Void)?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemName).font(.system(size: 22 * interfaceScale)).foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            HStack(spacing: 12) {
                if let retry { Button(L10n.string("Try again"), action: retry) }
                Button(L10n.format("Back to %@", agent.name), action: close)
            }
        }
        .font(.system(size: 13 * scale))
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
