import AppKit
import SwiftUI

/// Settings › Yardlet Instructions: one switch, one editor, and the harnesses that receive
/// nothing. The text is saved as it is typed and reaches the next launch or resume. Below, the
/// routing evaluation's switch, off unless the person turns it on.
struct YardletInstructionsSettingsView: View {
    @Bindable var store: YardletInstructionsStore
    var evaluation: RoutingEvaluationStore? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "text.quote")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(ParityTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("Use Yardlet instructions")).font(.callout.weight(.medium))
                    Text(L10n.string("Added when Yardlet starts or resumes a task; a task whose harness is already running keeps the instructions it started with until it resumes, for example after Yardlet reopens. Never written to a harness's own files."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.string("Global instruction files such as AGENTS.md and CLAUDE.md also apply outside Yardlet; Yardlet instructions apply only to tasks Yardlet launches."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle(L10n.string("Use Yardlet instructions"), isOn: $store.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.paritySwitch)
                    .controlSize(.small)
            }
            .padding(14)
            .parityCard()

            TextEditor(text: $store.text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 240)
                .parityCard()
                .opacity(store.isEnabled ? 1 : 0.6)
                .accessibilityLabel(L10n.string("Yardlet Instructions"))

            if let evaluation { RoutingEvaluationSettingsCard(store: evaluation) }

            let unsupported = YardletInstructionsRoute.unsupportedHarnesses.map(\.displayName)
            if !unsupported.isEmpty {
                Text(L10n.format("Not supported: %@", unsupported.joined(separator: ", ")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The routing evaluation's switch, what it costs, and the last report.
private struct RoutingEvaluationSettingsCard: View {
    @Bindable var store: RoutingEvaluationStore

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(ParityTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string("Choose harnesses and models by daily evaluation")).font(.callout.weight(.medium))
                Text(L10n.string("Once a day, the models you use review the day's tasks, their own included, and the routing they settle on is added to these instructions."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.string("It uses your plans, and excerpts of your tasks are shown to the other harnesses' models. Turning it off removes its records."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if store.isEnabled, let last = store.state.lastRunAt, let report = store.lastReportURL {
                    HStack(spacing: 6) {
                        Text(L10n.format("Last evaluation %@", last.formatted(date: .abbreviated, time: .shortened)))
                            .foregroundStyle(.secondary)
                        Button(L10n.string("Open Report")) { NSWorkspace.shared.open(report) }
                            .buttonStyle(.link)
                    }
                    .font(.caption)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            Toggle(L10n.string("Choose harnesses and models by daily evaluation"), isOn: $store.isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(14)
        .parityCard()
    }
}
