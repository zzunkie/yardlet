import SwiftUI
import YardletRemote

/// Loads only when the latest limit card appears. The confirmation is the local card's content;
/// its use callback asks the host, with the account-bound token the confirmation read.
struct RemoteUsageResetButton: View {
    let load: @MainActor () async -> RemoteUsageReset?
    let use: @MainActor (String) async -> RemoteUsageReset?
    @State private var reset: RemoteUsageReset?
    @State private var showsConfirmation = false
    @State private var pending = false
    @State private var failed = false

    var body: some View {
        Group {
            if let reset, reset.availableCount > 0 || reset.state != nil {
                UsageResetButtonContent(count: reset.availableCount, showsConfirmation: $showsConfirmation) {
                    UsageResetConfirmationContent(title: reset.title, resets: reset.resets, quotas: reset.quotas,
                        state: pending ? .using : failed ? .failed(L10n.string("The host did not answer. Try again.")) : reset.localState,
                        close: { showsConfirmation = false }, use: {
                            pending = true; failed = false
                            Task {
                                if let answer = await use(reset.token) { self.reset = answer } else { failed = true }
                                pending = false
                            }
                        })
                }
            }
        }
        .task { reset = await load() }
        .onChange(of: showsConfirmation) { _, shown in
            if !shown && !pending { Task { reset = await load(); failed = false } }
        }
        .onChange(of: pending) { _, running in
            if !running && !showsConfirmation { Task { reset = await load(); failed = false } }
        }
    }
}

extension RemoteUsageReset {
    var resets: AccountUsageResets {
        AccountUsageResets(availableCount: availableCount,
            resets: resetTitle != nil || expiresAt != nil ? [.init(title: resetTitle, expiresAt: expiresAt.map { Date(timeIntervalSince1970: Double($0) / 1000) })] : [])
    }
    var quotas: [AccountUsageMetric] {
        metrics.map { AccountUsageMetric(id: $0.id, label: $0.label, usedFraction: $0.usedFraction,
            detail: $0.detail, resetsAt: $0.resetsAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }, evidence: .exactQuota, windowMinutes: $0.windowMinutes, model: $0.model) }
    }
    var localState: UsageResetState? {
        switch state {
        case "using": .using
        case "reset": .answered(.reset, left: left)
        case "nothingToReset": .answered(.nothingToReset, left: left)
        case "noResets": .answered(.noResets, left: left)
        case "failed": .failed(L10n.string("The host did not answer. Try again."))
        default: nil
        }
    }
}
