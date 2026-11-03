import SwiftUI

/// The words of one harness's row in Settings › CLI Updates.
struct CLIUpdateRowPresentation: Equatable {
    var method: String
    var versions: String
    var status: String?
    var isWarning: Bool

    init(row: CLIUpdateCenter.Row, held: CLIRuntimeOverrides.Entry?) {
        method = Self.methodText(row.method)
        let installed = row.installed ?? L10n.string("unknown")
        switch (row.method, row.latest) {
        case (.appBundled, _), (.manual, _), (_, nil), (_, .unknown?):
            versions = L10n.format("Installed %@", installed)
        case let (_, .available(latest)?):
            versions = L10n.format("Installed %1$@ · Latest %2$@", installed, latest)
        case (_, .upToDate?):
            versions = L10n.format("Installed %1$@ · Latest %2$@", installed, installed)
        case (_, .failed?):
            versions = L10n.format("Installed %@ · Could not check for a newer version", installed)
        }

        isWarning = false
        switch row.phase {
        case .checking: status = L10n.string("Checking…"); return
        case .verifying: status = L10n.string("Checking that Yardlet can use it…"); return
        case .updating: status = L10n.string("Updating…"); return
        case .waitingForTasks: status = L10n.string("Updates when its tasks finish"); return
        case .idle: break
        }
        if let held {
            isWarning = true
            status = L10n.format("%1$@ did not pass Yardlet's check, so Yardlet runs %2$@", held.failedVersion, held.version)
            return
        }
        switch row.outcome {
        case let .updated(from, to)?:
            status = L10n.format("Updated from %1$@ to %2$@", from, to)
            return
        case let .failedWithoutPrevious(version)?:
            isWarning = true
            status = L10n.format("%@ did not pass Yardlet's check", version)
            return
        case .couldNotVerifyCurrent?:
            isWarning = true
            status = L10n.string("Yardlet could not check the current version, so it did not update it")
            return
        case let .updateFailed(reason)?:
            isWarning = true
            status = L10n.format("Update failed: %@", reason)
            return
        case nil:
            break
        }
        switch row.method {
        case let .appBundled(app):
            status = L10n.format("Updated with the %@ app", app)
            return
        case .manual:
            status = L10n.string("Update it yourself")
            return
        default:
            break
        }
        switch row.decision {
        case .skip(.cannotVerify)?, .skip(.cannotKeepPrevious)?:
            status = L10n.string("Yardlet cannot check or undo an update of this CLI, so it does not update it")
        case .skip(.failedBefore)?:
            if case let .available(version)? = row.latest {
                isWarning = true
                status = L10n.format("%@ did not pass Yardlet's check", version)
            } else { status = nil }
        case .skip(.upToDate)?:
            status = L10n.string("Up to date")
        default:
            if case .available? = row.latest { status = L10n.string("Update available") }
            else if case .upToDate? = row.latest { status = L10n.string("Up to date") }
            else { status = nil }
        }
    }

    /// A newer install than the runtime the person chose, and where it comes from.
    static func newerInstallText(_ install: RuntimeSelectionStore.Install, harness: HarnessKind) -> String {
        L10n.format("Newer version installed: %1$@ · %2$@", install.version,
                    methodText(CLIInstallDetector.detect(harness: harness, executable: install.url)))
    }

    static func methodText(_ method: CLIInstallMethod) -> String {
        switch method {
        case let .homebrewFormula(name, _): L10n.format("Homebrew formula %@", name)
        case let .homebrewCask(token, _, _): L10n.format("Homebrew cask %@", token)
        case let .npmGlobal(package, _, _): L10n.format("npm global package %@", package)
        case let .selfUpdater(updater): L10n.format("Updates itself (%@)", updater.commandText)
        case let .appBundled(app): L10n.format("Comes with the %@ app", app)
        case .manual: L10n.string("Installed by hand")
        }
    }
}

/// Settings › CLI Updates: the automatic-update switch and each installed harness's install
/// method, versions, and a check button. Where the person chose a harness's runtime and a newer
/// install is elsewhere on this Mac, its row says so with a button that uses it.
struct CLIUpdateSettingsView: View {
    @Bindable var center: CLIUpdateCenter
    var runtimes: RuntimeSelectionStore?

    var body: some View {
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
                    if let last = center.lastCheckAll {
                        Text(L10n.format("Checked %@ · checks every 6 hours", Calendar.current.isDateInToday(last)
                            ? last.formatted(date: .omitted, time: .shortened)
                            : last.formatted(date: .abbreviated, time: .shortened)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Toggle(YardletSetting.cliAutomaticUpdates.title, isOn: Binding(
                    get: { center.isAutoUpdateEnabled },
                    set: { center.setAutoUpdate($0) }))
                    .labelsHidden()
                    .toggleStyle(.paritySwitch)
                    .controlSize(.small)
            }
            .padding(14)
            .parityCard()

            if center.rows.isEmpty {
                Text(L10n.string("No harness CLI is installed."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .parityCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(center.rows) { row in
                        harnessRow(row)
                        if row.id != center.rows.last?.id {
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

    private func harnessRow(_ row: CLIUpdateCenter.Row) -> some View {
        let text = CLIUpdateRowPresentation(row: row, held: center.heldVersion(for: row.harness))
        let working = row.phase != .idle && row.phase != .waitingForTasks
        return HStack(alignment: .top, spacing: 12) {
            if let descriptor = HarnessCatalog.descriptor(for: row.harness) {
                HarnessLogoView(descriptor: descriptor, size: 28)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(row.harness.displayName).font(.callout.weight(.semibold))
                Text(text.method).font(.caption).foregroundStyle(.secondary)
                Text(text.versions)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let status = text.status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(text.isWarning ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let runtimes, let newer = runtimes.newerInstalls[row.harness] {
                    HStack(spacing: 8) {
                        Text(CLIUpdateRowPresentation.newerInstallText(newer, harness: row.harness))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(L10n.string("Use This Version")) {
                            runtimes.useNewest(for: row.harness)
                            Task { await center.check(row.harness) }
                        }
                        .controlSize(.small)
                        .disabled(working)
                        .parityPointer()
                        .accessibilityLabel(L10n.format("Use %1$@ %2$@", row.harness.displayName, newer.version))
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            if working {
                ProgressView().controlSize(.small)
            }
            Button(L10n.string("Check for Updates")) {
                Task { await center.check(row.harness) }
            }
            .controlSize(.small)
            .disabled(working)
            .parityPointer()
            .accessibilityLabel(L10n.format("Check %@ for updates", row.harness.displayName))
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }
}
