import SwiftUI
import UIKit
import YardletRemote

// MARK: - Palette

/// Quiet monochrome mobile palette (docs/DESIGN_SYSTEM.md, "Mobile").
/// Lists stand on the canvas as rows with hairlines between them; each step up the ladder (a field, a card, a pressed
/// control) reads apart from the one under it in both appearances. Chromatic color is restricted to status indicators
/// and error states.
enum YardletPalette {
    static let background = adaptive(light: 0xFFFFFF, dark: 0x111214)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x111214)
    static let surfaceContainerLow = adaptive(light: 0xF6F6F7, dark: 0x1B1D21)
    static let surfaceContainer = adaptive(light: 0xF0F0F2, dark: 0x202227)
    static let surfaceContainerHigh = adaptive(light: 0xE8E8EB, dark: 0x25282E)
    static let surfaceContainerHighest = adaptive(light: 0xDFDFE3, dark: 0x2E3138)

    static let primary = adaptive(light: 0x1C1C1E, dark: 0xECECEE)
    static let onPrimary = adaptive(light: 0xFFFFFF, dark: 0x111214)
    static let onSurface = adaptive(light: 0x1C1C1E, dark: 0xECECEE)
    /// Secondary words: at least 4.5:1 on every surface up to `surfaceContainerHighest` in both appearances.
    static let onSurfaceVariant = Color(uiColor: onSurfaceVariantUIColor)

    /// The chosen part of a segmented switch: above its track in both appearances (the canvas is darker than the
    /// track in Dark).
    static let selectedSegment = adaptive(light: 0xFFFFFF, dark: 0x3A3D44)

    static let outline = adaptive(light: 0xC8C8CD, dark: 0x4A4D55)
    /// Hairlines: the dividers between a list's rows, a field's edge.
    static let outlineVariant = adaptive(light: 0xE3E3E6, dark: 0x2C2F35)

    /// Links in messages: 4.5:1 or more on the canvas and the message surfaces.
    static let link = adaptive(light: 0x0062C4, dark: 0x5AA9FF)

    static let error = adaptive(light: 0xD70015, dark: 0xFF6961)
    static let errorContainer = adaptive(light: 0xFDECEC, dark: 0x3A1A1A)

    /// Dark-safe neutral swipe action fills preserving >=4.5:1 contrast for white labels/icons in Light and Dark modes.
    static let swipePrimary = adaptive(light: 0x3A3A3C, dark: 0x3A3A3E)
    static let swipeSecondary = adaptive(light: 0x636366, dark: 0x48484A)

    /// Status indicator colors only: approvals, questions, usage limits, unread, failures, running and connection.
    /// Marks, not words: each keeps 3:1 on the light canvas, with the Mac's light values (`#C75C00`, `#248A3D`) where
    /// the system's are too pale. Words in a status color use `warningText`, `successText` or `error`.
    enum Status {
        static let approval = adaptive(light: 0x248A3D, dark: 0x30D158)
        static let question = adaptive(light: 0xC75C00, dark: 0xFF9F0A)
        static let limit = adaptive(light: 0xC75C00, dark: 0xFF9F0A)
        static let unread = adaptive(light: 0x007AFF, dark: 0x0A84FF)
        static let failed = adaptive(light: 0xFF3B30, dark: 0xFF453A)
        static let running = adaptive(light: 0x8E8E93, dark: 0x98989D)
        static let connected = adaptive(light: 0x248A3D, dark: 0x30D158)
    }

    /// Words in a status color, 4.5:1 or more on every surface: a warning, a success, and (as `error`) a failure.
    static let warningText = adaptive(light: 0xA65300, dark: 0xFF9F0A)
    static let successText = adaptive(light: 0x177033, dark: 0x30D158)
    static let dangerText = error

    static func uiColor(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
    }

    static var onSurfaceUIColor: UIColor { uiColor(light: 0x1C1C1E, dark: 0xECECEE) }
    static var onSurfaceVariantUIColor: UIColor { uiColor(light: 0x626266, dark: 0xA3A5AC) }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: uiColor(light: light, dark: dark))
    }
}

extension Text {
    /// An empty field's placeholder in the palette's secondary words: the system's placeholder grey stays under 4.5:1
    /// on the app's filled fields.
    static func placeholder(_ key: LocalizedStringKey) -> Text {
        Text(key).foregroundStyle(YardletPalette.onSurfaceVariant)
    }
}

// MARK: - Metrics

enum YardletMetrics {
    static let spacingXS: CGFloat = 4
    static let spacingSM: CGFloat = 8
    static let spacingMD: CGFloat = 12
    static let spacingLG: CGFloat = 16
    static let spacingXL: CGFloat = 20

    static let radiusChip: CGFloat = 10
    static let radiusRow: CGFloat = 14
    static let radiusCard: CGFloat = 16
    static let radiusSheetCard: CGFloat = 14
    static let radiusComposer: CGFloat = 20
}

// MARK: - Korean Word-Break Typography Helper

enum YardletTypography {
    /// Paragraph style tuned for Korean prose (`hangulWordPriority`) in UIKit text views and attributed text.
    static func paragraphStyle(lineSpacing: CGFloat = 4) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.lineBreakMode = .byWordWrapping
        style.lineBreakStrategy = .hangulWordPriority
        return style
    }

    static func attributedProse(_ text: String,
                                font: UIFont = .preferredFont(forTextStyle: .body),
                                color: UIColor = YardletPalette.onSurfaceUIColor,
                                lineSpacing: CGFloat = 4) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle(lineSpacing: lineSpacing)
        ])
    }
}

// MARK: - Status Indicators & Harness Mark

/// Small circular state dot using Yardlet's restricted status palette.
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 8
    var accessibilityLabel: Text?

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .modifier(OptionalAccessibilityLabel(label: accessibilityLabel))
    }
}

private struct OptionalAccessibilityLabel: ViewModifier {
    let label: Text?

    func body(content: Content) -> some View {
        if let label {
            content.accessibilityLabel(label)
        } else {
            content.accessibilityHidden(true)
        }
    }
}

/// Connection dot for a paired Mac.
struct ConnectionStatusDot: View {
    let connection: HostSession.Connection
    var size: CGFloat = 8

    var body: some View {
        StatusDot(color: color, size: size, accessibilityLabel: label)
    }

    private var color: Color {
        switch connection {
        case .connected: YardletPalette.Status.connected
        case .connecting: YardletPalette.Status.question
        case .removed: YardletPalette.Status.failed
        case .unreachable, .stopped: YardletPalette.Status.running
        }
    }

    private var label: Text {
        switch connection {
        case .connected: Text("Connected")
        case .connecting: Text("Connecting")
        case .removed: Text("Removed")
        case .unreachable, .stopped: Text("Offline")
        }
    }
}

/// Quiet monochrome glyph identifying a task's harness (`claude`, `codex`, `antigravity`, etc.): the mark alone, with
/// no tile behind it.
struct HarnessMark: View {
    let harness: String
    let harnessName: String
    var size: CGFloat = 18

    var body: some View {
        glyph
            .font(.system(size: size * 0.62, weight: .semibold, design: .rounded))
            .foregroundStyle(YardletPalette.onSurfaceVariant)
            .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        let key = harness.lowercased()
        if key.contains("claude") {
            Image(systemName: "sparkle")
        } else if key.contains("codex") || key.contains("openai") {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
        } else if key.contains("antigravity") || key.contains("gemini") {
            Image(systemName: "sparkles")
        } else {
            Text(verbatim: String((harnessName.first ?? harness.first ?? "?").uppercased()))
        }
    }
}

// MARK: - Monochrome Surface Card

/// Quiet monochrome surface card following the Android surface ladder.
struct MonochromeCard<Content: View>: View {
    var fill: Color = YardletPalette.surfaceContainerLow
    var border: Color = YardletPalette.outlineVariant
    var cornerRadius: CGFloat = YardletMetrics.radiusCard
    var padding: CGFloat = YardletMetrics.spacingLG
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(border, lineWidth: 0.75)
            )
    }
}

// MARK: - Top Mac Header Bar

/// Top bar shared by the 3 root tabs: connected Mac selector on the left, monochrome actions on the right.
struct MacHeaderBar: View {
    let macName: String
    let connection: HostSession.Connection
    let showsSchedules: Bool
    let showsSearch: Bool
    let isSearchActive: Bool
    /// The demo Mac: its selector says so, and the sheet it opens ends the demo.
    var isDemo = false
    let onTapMac: () -> Void
    let onTapSchedules: () -> Void
    let onToggleSearch: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onTapMac) {
                HStack(spacing: 8) {
                    ConnectionStatusDot(connection: connection, size: 8)
                    Text(macName)
                        .font(.headline)
                        .foregroundStyle(YardletPalette.onSurface)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if isDemo {
                        Text("· Tour")
                            .font(.subheadline)
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(YardletPalette.surfaceContainerLow, in: Capsule())
                .overlay(Capsule().strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.75))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Switch Mac or open menu"))
            .accessibilityValue(Text(verbatim: isDemo ? "\(macName), \(String(localized: "Tour")), \(connectionLabel)"
                                               : "\(macName), \(connectionLabel)"))

            Spacer(minLength: 8)

            if showsSchedules {
                headerIconButton(systemImage: "clock", label: "Scheduled Tasks", isActive: false, action: onTapSchedules)
            }
            if showsSearch {
                headerIconButton(systemImage: isSearchActive ? "xmark" : "magnifyingglass",
                                 label: isSearchActive ? "Close Search" : "Search Tasks",
                                 isActive: isSearchActive,
                                 action: onToggleSearch)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(YardletPalette.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(YardletPalette.outlineVariant)
                .frame(height: 0.5)
        }
    }

    private var connectionLabel: String {
        switch connection {
        case .connected: String(localized: "Connected")
        case .connecting: String(localized: "Connecting")
        case .removed: String(localized: "Removed")
        case .unreachable, .stopped: String(localized: "Offline")
        }
    }

    private func headerIconButton(systemImage: String, label: LocalizedStringKey, isActive: Bool,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isActive ? YardletPalette.onPrimary : YardletPalette.onSurface)
                .frame(width: 36, height: 36)
                .background(isActive ? YardletPalette.primary : YardletPalette.surfaceContainerLow, in: Circle())
                .overlay(
                    Circle().strokeBorder(isActive ? Color.clear : YardletPalette.outlineVariant, lineWidth: 0.75)
                )
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Compact Segmented Switch

/// Compact monochrome segmented control matching Android's ViewSwitch (`Home` / `Projects`).
struct CompactSegmentedSwitch<Option: Hashable>: View {
    struct Item: Identifiable {
        let value: Option
        let title: LocalizedStringKey

        var id: Option { value }
    }

    let items: [Item]
    @Binding var selection: Option

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let isSelected = selection == item.value
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        selection = item.value
                    }
                } label: {
                    Text(item.title)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? YardletPalette.onSurface : YardletPalette.onSurfaceVariant)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(YardletPalette.selectedSegment)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.5)
                                    )
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(YardletPalette.surfaceContainer, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.5)
        )
    }
}

// MARK: - 3-Tab Bottom Bar

enum MobileTab: String, CaseIterable, Hashable {
    case tasks
    case mail
    case calendar

    var title: LocalizedStringKey {
        switch self {
        case .tasks: "Tasks"
        case .mail: "Mail"
        case .calendar: "Calendar"
        }
    }

    var systemImage: String {
        switch self {
        case .tasks: "square.stack"
        case .mail: "envelope"
        case .calendar: "calendar"
        }
    }

    var selectedSystemImage: String {
        switch self {
        case .tasks: "square.stack.fill"
        case .mail: "envelope.fill"
        case .calendar: "calendar"
        }
    }
}

/// Monochrome 3-tab bottom bar (`Tasks · Mail · Calendar`) anchored in the bottom safe area: the chosen tab by its
/// filled symbol and primary words, as the system's tab bar marks it.
struct BottomTabBar: View {
    @Binding var selection: MobileTab
    var tasksBadgeColor: Color?
    var tasksBadgeLabel: String?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(MobileTab.allCases, id: \.self) { tab in
                let isSelected = selection == tab
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 4) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: isSelected ? tab.selectedSystemImage : tab.systemImage)
                                .font(.system(size: 18, weight: isSelected ? .semibold : .regular))
                                .frame(height: 22)
                            if tab == .tasks, let badgeColor = tasksBadgeColor {
                                Circle()
                                    .fill(badgeColor)
                                    .frame(width: 7, height: 7)
                                    .offset(x: 6, y: -1)
                            }
                        }
                        Text(tab.title)
                            .font(.caption2.weight(isSelected ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isSelected ? YardletPalette.onSurface : YardletPalette.onSurfaceVariant)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityValue(tab == .tasks ? (tasksBadgeLabel ?? "") : "")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }
}
