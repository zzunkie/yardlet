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
                Image(systemName: YardletSetting.yardletInstructions.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(ParityTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(YardletSetting.yardletInstructions.title).font(.callout.weight(.medium))
                    Text(YardletSetting.yardletInstructions.detail ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(YardletSetting.yardletInstructions.note ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle(YardletSetting.yardletInstructions.title, isOn: $store.isEnabled)
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
            Image(systemName: YardletSetting.dailyEvaluation.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(ParityTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(YardletSetting.dailyEvaluation.title).font(.callout.weight(.medium))
                Text(YardletSetting.dailyEvaluation.detail ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(YardletSetting.dailyEvaluation.note ?? "")
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
            Toggle(YardletSetting.dailyEvaluation.title, isOn: $store.isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(14)
        .parityCard()
    }
}
