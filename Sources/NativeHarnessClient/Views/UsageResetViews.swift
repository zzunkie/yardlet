import AppKit
import SwiftUI

/// The account store and runtimes a reset of an account's plan limits is used with. An account list
/// and a limit card provide it; without it the resets are not offered.
struct UsageResetContext {
    let store: ProviderConnectionStore
    let runtimeSelections: RuntimeSelectionStore
}

private struct UsageResetContextKey: EnvironmentKey {
    static let defaultValue: UsageResetContext? = nil
}

extension EnvironmentValues {
    var usageResetContext: UsageResetContext? {
        get { self[UsageResetContextKey.self] }
        set { self[UsageResetContextKey.self] = newValue }
    }
}

/// An account's banked resets of its plan limits and the way the person uses one: beside the
/// account's limits in an account list, and on a limit card. Both open the same confirmation, which
/// names the limits a reset restores, the reset it takes and how many are left after, and uses it
/// only when the person confirms. Nothing an agent calls reaches it.
struct UsageResetButton: View {
    enum Placement {
        /// A quiet line under the account's limits.
        case accountLimits
        /// An action among the limit card's.
        case limitCard
    }

    let choice: AccountChoice
    var placement: Placement = .accountLimits
    @Environment(\.usageResetContext) private var context
    @State private var showsConfirmation = false

    var body: some View {
        // The account as the store reads it now: a limit card is drawn again only when its turn changes.
        if let context, let resets = context.store.choice(for: choice.harness, connection: choice.connection)
            .snapshot?.usageResets,
           resets.availableCount > 0 || context.store.usageResetStates[choice.id] != nil {
            Button { showsConfirmation = true } label: { label(resets) }
                .buttonStyle(.borderless)
                .fixedSize()
                .parityPointer()
                .help(L10n.string("Use a reset to restore this account's usage limits now"))
                .popover(isPresented: Binding(get: { showsConfirmation }, set: { shown in
                    showsConfirmation = shown
                    // Closing it is seeing its answer; an attempt still running keeps its own.
                    if !shown { context.store.dismissUsageReset(for: choice) }
                }), arrowEdge: .bottom) {
                    UsageResetConfirmation(choice: choice, context: context) {
                        showsConfirmation = false
                        context.store.dismissUsageReset(for: choice)
                    }
                }
        }
    }

    @ViewBuilder private func label(_ resets: AccountUsageResets) -> some View {
        switch placement {
        case .accountLimits:
            Label(UsageResetText.available(resets.availableCount), systemImage: "arrow.counterclockwise")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(ParityTheme.accent)
                .lineLimit(1)
        case .limitCard:
            Text(L10n.format("Use a reset (%lld left)", Int64(resets.availableCount)))
        }
    }
}

/// The confirmation a reset is used from, and its answer.
struct UsageResetConfirmation: View {
    let choice: AccountChoice
    let context: UsageResetContext
    let close: () -> Void

    /// The account as the store reads it now, so a check that ends while this is open shows.
    private var current: AccountChoice { context.store.choice(for: choice.harness, connection: choice.connection) }
    private var state: UsageResetState? { context.store.usageResetStates[choice.id] }

    var body: some View {
        let current = current
        let resets = current.snapshot?.usageResets
        // Once answered, the limits read again show what changed and the answer says what is left.
        let answered: Bool = if case .answered? = state { true } else { false }
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string(answered ? "Usage limit reset" : "Use a usage limit reset?")).font(.headline)
                Text(current.title + " · " + current.harness.displayName)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            let restores = resets?.restores ?? []
            let restored = restores.isEmpty ? current.quotas : current.quotas.filter { restores.contains($0.id) }
            if !restored.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.string(answered ? "Limits now:" : "Resets these limits now:")).font(.callout)
                    AccountLimitWindowList(metrics: restored, reset: .time, fontSize: 11.5, rowSpacing: 6)
                }
            }
            if let resets, !answered {
                VStack(alignment: .leading, spacing: 3) {
                    if let next = resets.next { Text(UsageResetText.reset(next)) }
                    Text(UsageResetText.left(afterUse: resets)).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            if let state, let answer = UsageResetText.answer(state) {
                Text(answer)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(isTrouble(state) ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if case .failed = state {
                    Text(L10n.string("Trying again sends the same request, so no more than one reset is used."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                if let purchaseURL = resets?.purchaseURL {
                    Button(L10n.string("Buy an instant reset…")) { NSWorkspace.shared.open(purchaseURL) }
                        .buttonStyle(.link)
                        .help(L10n.string("Not a banked reset: buying one resets your limits at once. You pay on ChatGPT."))
                }
                Spacer(minLength: 12)
                buttons(resets: resets)
            }
            .controlSize(.regular)
        }
        .padding(18)
        .frame(width: 380)
        .task {
            // Show the account as it is now: a reading over a minute old is checked again.
            await context.store.check(choice, runtimeSelections: context.runtimeSelections)
        }
    }

    @ViewBuilder private func buttons(resets: AccountUsageResets?) -> some View {
        switch state {
        case .using:
            ProgressView().controlSize(.small)
            Text(L10n.string("Resetting your limits…")).font(.callout).foregroundStyle(.secondary)
        case .answered?:
            Button(L10n.string("Done"), action: close).keyboardShortcut(.defaultAction)
        case .failed?:
            Button(L10n.string("Cancel"), action: close).keyboardShortcut(.cancelAction)
            Button(L10n.string("Try again"), action: use).keyboardShortcut(.defaultAction)
        case nil:
            Button(L10n.string("Cancel"), action: close).keyboardShortcut(.cancelAction)
            Button(L10n.string("Use Reset"), action: use)
                .keyboardShortcut(.defaultAction)
                .disabled((resets?.availableCount ?? 0) == 0 || context.store.isChecking(choice))
        }
    }

    private func use() {
        Task { await context.store.useUsageReset(choice, runtimeSelections: context.runtimeSelections) }
    }

    private func isTrouble(_ state: UsageResetState) -> Bool {
        switch state {
        case .answered(.reset, _), .using: false
        case .answered, .failed: true
        }
    }
}
