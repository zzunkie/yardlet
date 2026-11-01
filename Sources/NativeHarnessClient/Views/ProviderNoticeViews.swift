import SwiftUI

/// The card a turn shows when a plan limit stopped it: which limit, when it resets, the windows the
/// report measured as limit window rows, and, on the latest card of an idle task, using a reset the
/// task's account holds, continuing under another account, and continuing once the limit resets:
/// on its own if armed before the reset, or on Resume after it.
struct UsageLimitCard: View {
    let entryID: UUID
    let limit: HarnessRateLimit
    /// Only the transcript's last entry offers to continue; a later turn has moved past it.
    let isLatest: Bool
    /// The task's notices and limit actions; without them the card only reports the limit.
    var notices: TaskProviderNotices? = nil
    @State private var showsAccounts = false
    /// When the card last looked at the clock: as it appeared, and again at the reset.
    @State private var now = Date()

    var body: some View {
        // Read while drawing, so a saved or removed account shows or hides the button.
        let accounts = offersActions ? notices?.accounts() : nil
        let usageReset = offersActions ? notices?.usageReset() : nil
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "gauge.with.dots.needle.100percent")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 5) {
                    Text(ProviderNoticeText.limitHeadline(limit))
                        .font(.callout.weight(.semibold))
                    if let detail {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !windows.isEmpty {
                        // The windows the report measured, in the rows and words of the account list:
                        // as wide as they need, or wrapping their values in a narrow pane.
                        let list = AccountLimitWindowList(windows: windows, reset: .time, fontSize: 12)
                        ViewThatFits(in: .horizontal) {
                            list.fixedSize()
                            list
                        }
                        .padding(.top, 3)
                    }
                }
            }
            if let notices, offersActions {
                ControlRowLayout(spacing: 14, rowSpacing: 8) {
                    if let usageReset {
                        UsageResetButton(choice: usageReset.choice, placement: .limitCard)
                            .environment(\.usageResetContext, usageReset.context)
                    }
                    if let accounts, !accounts.others.isEmpty {
                        Button { showsAccounts.toggle() } label: {
                            HStack(spacing: 4) {
                                Text(L10n.string("Continue with another account"))
                                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                            }
                        }
                        .buttonStyle(.borderless)
                        .fixedSize()
                        .parityPointer()
                        .popover(isPresented: $showsAccounts) {
                            AccountList(mode: .continueAfterLimit(accounts.session), store: accounts.store,
                                runtimeSelections: accounts.runtimeSelections,
                                onChoose: { choice in
                                    showsAccounts = false
                                    if let connection = choice.connection { notices.continueWithAccount(connection) }
                                }, maxListHeight: 330)
                                .padding(16).frame(width: 610)
                        }
                    }
                    // Before the reset the task can wait for it; once it has passed, as when the
                    // person comes back after it, the task continues where it stopped on a press.
                    if let resetsAt = limit.resetsAt, resetsAt > now {
                        Toggle(L10n.string("Auto-continue when limits reset"), isOn: Binding(
                            get: { isArmed },
                            set: { notices.setAutoContinue($0, entryID, resetsAt) }
                        ))
                        .toggleStyle(.paritySwitch)
                        .controlSize(.mini)
                        .fixedSize()
                    } else if limit.resetsAt != nil, let resume = notices.continueAfterReset {
                        Button(L10n.string("Resume")) { resume(entryID) }
                            .buttonStyle(.borderless)
                            .fixedSize()
                            .parityPointer()
                    }
                }
                .font(.callout.weight(.medium))
                if let error = notices.switchError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.04), in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).stroke(.orange.opacity(0.2)) }
        .task(id: offersActions) {
            guard offersActions, let notices else { return }
            await notices.refreshAccounts()
        }
        .task(id: offersActions ? limit.resetsAt : nil) {
            // The continuous clock keeps counting while the Mac sleeps, so a reset that passed
            // during sleep shows at wake.
            guard let resetsAt = limit.resetsAt, resetsAt > now else { return }
            try? await Task.sleep(for: .seconds(max(0, resetsAt.timeIntervalSinceNow)))
            if !Task.isCancelled { now = Date() }
        }
    }

    private var windows: [AccountLimitWindow] { AccountLimitWindow.windows(reportedBy: limit) }

    private var offersActions: Bool { isLatest && notices?.canContinue == true }
    private var isArmed: Bool { isLatest && notices?.autoContinueEntryID == entryID }

    /// The reset, or once armed when the task continues; the CLI's own words when it named no
    /// reset.
    private var detail: String? {
        if isArmed, let resetsAt = limit.resetsAt {
            return L10n.format("Auto-resuming at %@", ProviderNoticeText.resetTime(resetsAt))
        }
        return ProviderNoticeText.limitReset(limit) ?? limit.message
    }
}

/// Where the provider summarized earlier conversation, as a divider in the timeline.
struct CompactionMarker: View {
    let compaction: HarnessContextCompaction

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                rule
                HStack(spacing: 6) {
                    if compaction.phase == .started {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: compaction.phase == .failed
                            ? "exclamationmark.triangle" : "rectangle.compress.vertical")
                    }
                    Text(ProviderNoticeText.compaction(compaction))
                        .monospacedDigit()
                }
                .fixedSize()
                rule
            }
            if compaction.phase == .failed, let message = compaction.message, !message.isEmpty {
                Text(message)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
        .foregroundStyle(compaction.phase == .failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        .accessibilityElement(children: .combine)
    }

    private var rule: some View {
        Rectangle().fill(ParityTheme.separator).frame(height: 1)
    }
}

/// The lines just above the composer: that Yardlet continued the task after a restart, and a plan
/// limit the provider warned is close. A request the provider is retrying shows on the running
/// turn's status line instead (D6).
struct ProviderNoticeLines: View {
    let notices: TaskProviderNotices

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if notices.reconnecting {
                Label(L10n.string("Reconnecting"), systemImage: "network.slash")
                    .foregroundStyle(.secondary)
            }
            if notices.resumedAfterRestart {
                Label(L10n.string("Yardlet restarted while this task was working, so it picked up where it left off."),
                    systemImage: "arrow.clockwise")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let warning = notices.limitWarning, (warning.resetsAt ?? .distantFuture) > Date() {
                Label(ProviderNoticeText.limitWarning(warning), systemImage: "gauge.with.dots.needle.67percent")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .lineLimit(1)
        .frame(maxWidth: ParityTheme.contentWidth, alignment: .leading)
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity)
    }

    static func showsAnything(_ notices: TaskProviderNotices?) -> Bool {
        notices?.resumedAfterRestart == true || notices?.reconnecting == true
            || notices?.limitWarning.map { ($0.resetsAt ?? .distantFuture) > Date() } == true
    }
}
