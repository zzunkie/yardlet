import AppKit
import SwiftUI
import YardletRemote

/// Settings › Yardlet Instructions: one switch, one editor, and the harnesses that receive
/// nothing. The text is saved as it is typed and reaches the next launch or resume. Below, the
/// routing evaluation's switch, off unless the person turns it on.
struct YardletInstructionsSettingsView: View {
    struct RemoteContext {
        var state: RemoteHostSettings.Instructions
        var isEnabled: Bool
        var isEvaluationEnabled: Bool
        var onSetEnabled: (Bool) -> Void
        var onChangeText: (String) -> Void
        var onSetEvaluationEnabled: (Bool) -> Void
    }

    var store: YardletInstructionsStore?
    var evaluation: RoutingEvaluationStore?
    var remote: RemoteContext?

    init(store: YardletInstructionsStore, evaluation: RoutingEvaluationStore? = nil) {
        self.store = store
        self.evaluation = evaluation
        self.remote = nil
    }

    init(remote: RemoteContext) {
        self.store = nil
        self.evaluation = nil
        self.remote = remote
    }

    private var isEnabled: Bool {
        store?.isEnabled ?? remote?.isEnabled ?? false
    }

    private var isEnabledBinding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { value in
                if let store {
                    store.isEnabled = value
                } else {
                    remote?.onSetEnabled(value)
                }
            }
        )
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { store?.text ?? remote?.state.text ?? "" },
            set: { value in
                if let store {
                    store.text = value
                } else {
                    remote?.onChangeText(value)
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(YardletSetting.yardletInstructions.title).font(SettingsMetrics.titleFont)
                    Text(YardletSetting.yardletInstructions.detail ?? "")
                        .font(SettingsMetrics.detailFont)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle(YardletSetting.yardletInstructions.title, isOn: isEnabledBinding)
                    .labelsHidden()
                    .toggleStyle(.paritySwitch)
                    .controlSize(.small)
            }
            .padding(.vertical, SettingsMetrics.rowVerticalPadding)
            .settingsAnchor(YardletSetting.yardletInstructions.id)
            .padding(.horizontal, SettingsMetrics.groupHorizontalPadding)
            .parityCard()

            TextEditor(text: textBinding)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 240)
                .parityCard()
                .opacity(isEnabled ? 1 : 0.6)
                .accessibilityLabel(L10n.string("Yardlet Instructions"))

            if let evaluation {
                RoutingEvaluationSettingsCard(
                    isEnabled: Binding(get: { evaluation.isEnabled }, set: { evaluation.isEnabled = $0 }),
                    lastRunAt: evaluation.lastReportURL != nil ? evaluation.state.lastRunAt : nil,
                    reportURL: evaluation.lastReportURL
                )
            } else if let remote, remote.state.hasEvaluation {
                RoutingEvaluationSettingsCard(
                    isEnabled: Binding(get: { remote.isEvaluationEnabled }, set: { remote.onSetEvaluationEnabled($0) }),
                    lastRunAt: remote.state.lastEvaluationAt.map(RemoteHostSettingsProjection.date),
                    reportURL: nil
                )
            }

            let unsupported = YardletInstructionsRoute.unsupportedHarnesses.map(\.displayName)
            if !unsupported.isEmpty {
                Text(L10n.format("Not supported: %@", unsupported.joined(separator: ", ")))
                    .font(SettingsMetrics.detailFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The routing evaluation's switch, what it costs, and the last report.
private struct RoutingEvaluationSettingsCard: View {
    @Binding var isEnabled: Bool
    var lastRunAt: Date?
    var reportURL: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(YardletSetting.dailyEvaluation.title).font(SettingsMetrics.titleFont)
                Text(YardletSetting.dailyEvaluation.detail ?? "")
                    .font(SettingsMetrics.detailFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(YardletSetting.dailyEvaluation.note ?? "")
                    .font(SettingsMetrics.detailFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isEnabled, let last = lastRunAt {
                    HStack(spacing: 6) {
                        Text(L10n.format("Last evaluation %@", last.formatted(date: .abbreviated, time: .shortened)))
                            .foregroundStyle(.secondary)
                        if let report = reportURL {
                            Button(L10n.string("Open Report")) { NSWorkspace.shared.open(report) }
                                .parityLinkButton()
                        }
                    }
                    .font(SettingsMetrics.detailFont)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            Toggle(YardletSetting.dailyEvaluation.title, isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.paritySwitch)
                .controlSize(.small)
        }
        .padding(.vertical, SettingsMetrics.rowVerticalPadding)
        .padding(.horizontal, SettingsMetrics.groupHorizontalPadding)
        .parityCard()
        .settingsAnchor(YardletSetting.dailyEvaluation.id)
    }
}
