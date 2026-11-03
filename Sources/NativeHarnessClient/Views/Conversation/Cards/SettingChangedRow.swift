import SwiftUI

private struct OpenSettingsSectionKey: EnvironmentKey {
    static let defaultValue: (@MainActor (SettingsSection) -> Void)? = nil
}

extension EnvironmentValues {
    /// Opens Settings on a section. Nil where the conversation has no Settings to open (a row then
    /// shows no Open).
    var openSettingsSection: (@MainActor (SettingsSection) -> Void)? {
        get { self[OpenSettingsSectionKey.self] }
        set { self[OpenSettingsSectionKey.self] = newValue }
    }
}

/// A setting an agent changed (`update_setting`), as one outlined row where the call happened, as a created
/// schedule's row: a gear, the setting's name over what it went from and to, and Open, which shows its
/// section in Settings. The words are the ones the change was made in.
struct SettingChangedRow: View {
    let change: ConversationSettingChange

    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.openSettingsSection) private var openSettings

    var body: some View {
        let section = YardletSettingCatalog.setting(change.settingID)?.section
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "gearshape")
                .font(.system(size: 13 * interfaceScale))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(change.title)
                    .font(.system(size: 13 * interfaceScale, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(L10n.format("%@ → %@", change.from, change.to))
                    .font(.system(size: 12 * interfaceScale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let openSettings, let section {
                Button(L10n.string("Open")) { openSettings(section) }
                    .buttonStyle(.link)
                    .font(.system(size: 12 * interfaceScale))
                    .parityPointer()
                    .help(L10n.format("Open %@ in Settings", change.title))
                    .accessibilityLabel(L10n.format("Open %@ in Settings", change.title))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: ScheduledTaskCreatedRow.maximumWidth, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: ParityTheme.panelCornerRadius).stroke(ParityTheme.strongSeparator)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.format("Changed setting: %@", change.title))
    }
}
