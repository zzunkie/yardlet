import SwiftUI

/// Yardlet's connectors and the way to their settings, which the window gives every composer.
@MainActor
struct ComposerConnectorEnvironment: @MainActor Equatable {
    var records: [ConnectorRecord] = []
    /// Whether each connector reaches this task: on, off here, or left to the harness's own server.
    var taskState: (ConnectorRecord) -> ConnectorTaskState = { _ in .on }
    /// The harness's own servers that Yardlet's connectors stand in for in this task, by name.
    var standInServerNames: Set<String> = []
    /// Turns a connector on or off for this task. Nil where the composer belongs to no task.
    var setOn: ((UUID, Bool) -> Void)?
    /// Signs a connector in again.
    var reconnect: ((UUID) -> Void)?
    /// Opens Settings → Connectors. Nil where there is no settings window to open.
    var openSettings: (() -> Void)?
    /// Opens the connector directory over the window, without Settings ("Add connectors").
    var addConnector: (() -> Void)? = nil
    /// What the closures act on. The window makes this afresh each time the task's conversation
    /// changes; acting on the same connectors, task and scope it is the same, so the composer that
    /// reads it is not drawn again for it.
    var target: Target? = nil

    struct Target: Equatable {
        let center: ObjectIdentifier?
        let taskID: UUID
        let scope: ConnectorTaskScope
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.records == rhs.records && lhs.target == rhs.target && lhs.standInServerNames == rhs.standInServerNames
            && (lhs.setOn == nil) == (rhs.setOn == nil) && (lhs.reconnect == nil) == (rhs.reconnect == nil)
            && (lhs.openSettings == nil) == (rhs.openSettings == nil)
            && (lhs.addConnector == nil) == (rhs.addConnector == nil)
    }
}

private struct ComposerConnectorEnvironmentKey: EnvironmentKey {
    static let defaultValue: ComposerConnectorEnvironment? = nil
}

extension EnvironmentValues {
    var composerConnectors: ComposerConnectorEnvironment? {
        get { self[ComposerConnectorEnvironmentKey.self] }
        set { self[ComposerConnectorEnvironmentKey.self] = newValue }
    }
}

/// A connector's mark: its directory symbol, or the first letter of its name, on a rounded tile.
/// A connector's picture: the service's own icon, from its MCP server or its own site
/// (`ConnectorIconSources`), in a tile as the Claude app frames one (a 16 pt picture in a 24 pt box).
/// Until it loads, or when none does, the directory's symbol stands in, or the name's first letter.
/// Below 20 pt (a tool line) a loaded picture stands alone.
struct ConnectorIcon: View {
    let name: String
    var presetID: String?
    /// Where its picture comes from; the directory entry's by default.
    var sources: ConnectorIconSources? = nil
    var size: CGFloat = 20

    @Environment(\.connectorIconStore) private var store
    @Environment(\.colorScheme) private var colorScheme
    @State private var loaded: (urls: [URL], image: NSImage)?

    private var urls: [URL] {
        (sources ?? .preset(presetID)).urls(dark: colorScheme == .dark)
    }

    var body: some View {
        let urls = urls
        let image = loaded.flatMap { $0.urls == urls ? $0.image : nil } ?? store.cachedImage(for: urls)
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: pictureSize, height: pictureSize)
                    .clipShape(RoundedRectangle(cornerRadius: pictureSize * 0.22))
            } else if let symbol = presetID.flatMap(ConnectorPreset.preset(id:))?.symbol {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background {
            if isTiled || image == nil {
                RoundedRectangle(cornerRadius: size * 0.25)
                    .fill(ParityTheme.subtleFill)
                    .overlay(RoundedRectangle(cornerRadius: size * 0.25).strokeBorder(ParityTheme.separator, lineWidth: 0.5))
            }
        }
        .task(id: urls) {
            guard !urls.isEmpty, store.cachedImage(for: urls) == nil, let image = await store.image(for: urls) else { return }
            loaded = (urls, image)
        }
        .accessibilityHidden(true)
    }

    private var isTiled: Bool { size >= 20 }

    /// Two thirds of the tile, as the Claude app's 16 in 24; nearly all of an untiled icon.
    private var pictureSize: CGFloat { isTiled ? (size * 2 / 3).rounded() : size * 0.9 }
}

/// One connector or server with its state, in the session rail's Connectors card. The composer's
/// "+" menu lists them with `ComposerConnectorsMenu`.
struct ComposerConnectorRow: View {
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    let row: ComposerConnectorList.Row
    let onSwitch: ((UUID, Bool) -> Void)?
    let onReconnect: ((UUID) -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            ConnectorIcon(name: row.name, presetID: row.presetID, sources: row.icons)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.statusText)
                    .font(.yardlet(.caption, scale: interfaceScale))
                    .foregroundStyle(statusStyle)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if row.canReconnect, let id = row.connectorID, let onReconnect {
                Button(row.reconnectTitle) { onReconnect(id) }
                    .controlSize(.small)
                    .parityPointer()
            }
            // One control, as the composer's list has: "Reconnect" stands in for the switch.
            if row.isSwitchable, !(row.canReconnect && onReconnect != nil), let id = row.connectorID, let onSwitch {
                Toggle(L10n.format("Use %@ in this task", row.name), isOn: Binding(
                    get: { row.isOn },
                    set: { onSwitch(id, $0) }
                ))
                .labelsHidden()
                .toggleStyle(.paritySwitch)
                .controlSize(.mini)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.name)
        .accessibilityValue(row.statusText)
    }

    private var statusStyle: AnyShapeStyle {
        switch row.state {
        case .failed: AnyShapeStyle(.red)
        case .needsAuthentication: AnyShapeStyle(.orange)
        default: AnyShapeStyle(.secondary)
        }
    }
}
