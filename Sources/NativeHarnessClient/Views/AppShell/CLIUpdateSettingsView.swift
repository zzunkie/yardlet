import SwiftUI
import YardletRemote

/// Settings › CLI Updates: the automatic-update switch and each installed harness's install
/// method, versions, and a check button. Where the person chose a harness's runtime and a newer
/// install is elsewhere on this Mac, its row says so with a button that uses it.
struct CLIUpdateSettingsView: View {
    struct RemoteContext {
        var state: RemoteHostSettings.CLIUpdates
        var isAutoUpdateEnabled: Bool
        var onSetAutoUpdate: (Bool) -> Void
        var onCheck: (HarnessKind) -> Void
        var onUseNewest: (HarnessKind) -> Void
    }

    private struct DisplayRow: Identifiable {
        var id: HarnessKind { harness }
        let harness: HarnessKind
        let method: String
        let versions: String
        let status: String?
        let isWarning: Bool
        let working: Bool
        let newerVersion: String?
        let newerText: String?
    }

    var center: CLIUpdateCenter?
    var runtimes: RuntimeSelectionStore?
    var remote: RemoteContext?

    init(center: CLIUpdateCenter, runtimes: RuntimeSelectionStore? = nil) {
        self.center = center
        self.runtimes = runtimes
        self.remote = nil
    }

    init(remote: RemoteContext) {
        self.center = nil
        self.runtimes = nil
        self.remote = remote
    }

    private var lastCheckAll: Date? {
        if let center { return center.lastCheckAll }
        return remote?.state.lastCheckedAt.map(RemoteHostSettingsProjection.date)
    }

    private var autoUpdateBinding: Binding<Bool> {
        Binding(
            get: { center?.isAutoUpdateEnabled ?? remote?.isAutoUpdateEnabled ?? false },
            set: { isOn in
                if let center {
                    center.setAutoUpdate(isOn)
                } else {
                    remote?.onSetAutoUpdate(isOn)
                }
            }
        )
    }

    private var displayRows: [DisplayRow] {
        if let center {
            return center.rows.map { row in
                let text = CLIUpdateRowPresentation(row: row, held: center.heldVersion(for: row.harness))
                let working = row.phase != .idle && row.phase != .waitingForTasks
                let newer = runtimes?.newerInstalls[row.harness]
                return DisplayRow(
                    harness: row.harness,
                    method: text.method,
                    versions: text.versions,
                    status: text.status,
                    isWarning: text.isWarning,
                    working: working,
                    newerVersion: newer?.version,
                    newerText: newer.map { CLIUpdateRowPresentation.newerInstallText($0, harness: row.harness) }
                )
            }
        }
        guard let remote else { return [] }
        return remote.state.rows.map { row in
            let harness = HarnessKind(rawValue: row.harness)
            return DisplayRow(
                harness: harness,
                method: row.method,
                versions: row.versions,
                status: row.status,
                isWarning: row.isWarning,
                working: row.working,
                newerVersion: row.newerVersion,
                newerText: row.newerText
            )
        }
    }

    var body: some View {
        let rows = displayRows
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: YardletSetting.cliAutomaticUpdates.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(ParityTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(YardletSetting.cliAutomaticUpdates.title).font(.callout.weight(.medium))
                    Text(YardletSetting.cliAutomaticUpdates.detail ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let last = lastCheckAll {
                        Text(L10n.format("Checked %@ · checks every 6 hours", Calendar.current.isDateInToday(last)
                            ? last.formatted(date: .omitted, time: .shortened)
                            : last.formatted(date: .abbreviated, time: .shortened)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Toggle(YardletSetting.cliAutomaticUpdates.title, isOn: autoUpdateBinding)
                    .labelsHidden()
                    .toggleStyle(.paritySwitch)
                    .controlSize(.small)
            }
            .padding(14)
            .parityCard()

            if rows.isEmpty {
                Text(L10n.string("No harness CLI is installed."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .parityCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        harnessRow(row)
                        if row.id != rows.last?.id {
                            Divider().padding(.leading, 28 + 12) // under the words, past the logo and the gap
                        }
                    }
                }
                .padding(.horizontal, 12)
                .parityCard()
            }
        }
        // Only installs whose file changed since they were last read run `--version`.
        .task { await runtimes?.findNewest() }
    }

    private func harnessRow(_ row: DisplayRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let descriptor = HarnessCatalog.descriptor(for: row.harness) {
                HarnessLogoView(descriptor: descriptor, size: 28)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(row.harness.displayName).font(.callout.weight(.semibold))
                Text(row.method).font(.caption).foregroundStyle(.secondary)
                Text(row.versions)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let status = row.status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(row.isWarning ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let newerVersion = row.newerVersion, let newerText = row.newerText {
                    HStack(spacing: 8) {
                        Text(newerText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(L10n.string("Use This Version")) {
                            if let center, let runtimes {
                                runtimes.useNewest(for: row.harness)
                                Task { await center.check(row.harness) }
                            } else {
                                remote?.onUseNewest(row.harness)
                            }
                        }
                        .controlSize(.small)
                        .disabled(row.working)
                        .parityPointer()
                        .accessibilityLabel(L10n.format("Use %1$@ %2$@", row.harness.displayName, newerVersion))
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            if row.working {
                ProgressView().controlSize(.small)
            }
            Button(L10n.string("Check for Updates")) {
                if let center {
                    Task { await center.check(row.harness) }
                } else {
                    remote?.onCheck(row.harness)
                }
            }
            .controlSize(.small)
            .disabled(row.working)
            .parityPointer()
            .accessibilityLabel(L10n.format("Check %@ for updates", row.harness.displayName))
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }
}
