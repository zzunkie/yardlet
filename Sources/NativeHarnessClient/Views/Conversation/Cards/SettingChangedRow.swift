import SwiftUI

private struct OpenSettingsKey: EnvironmentKey {
    static let defaultValue: (@MainActor (SettingsDestination) -> Void)? = nil
}

extension EnvironmentValues {
    /// Opens Settings at a destination: a section, and the row in it to scroll to and highlight. Nil where the
    /// window has no Settings to open (a link to it is then left out).
    var openSettings: (@MainActor (SettingsDestination) -> Void)? {
        get { self[OpenSettingsKey.self] }
        set { self[OpenSettingsKey.self] = newValue }
    }
}

/// A setting an agent changed (`update_setting`), as one outlined row where the call happened, as a created
/// schedule's row: a gear, the setting's name over what it went from and to, and Open, which shows its
/// row in Settings, highlighted. The words are the ones the change was made in.
struct SettingChangedRow: View {
    let change: ConversationSettingChange

    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let destination = YardletSettingCatalog.setting(change.settingID)?.destination
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
            if let openSettings, let destination {
                Button(L10n.string("Open")) { openSettings(destination) }
                    .parityLinkButton()
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
