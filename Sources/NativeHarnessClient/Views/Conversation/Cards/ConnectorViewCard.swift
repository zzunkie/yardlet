import AppKit
import SwiftUI

private struct ConnectorViewsKey: EnvironmentKey {
    static let defaultValue: ConnectorViewHost? = nil
}

extension EnvironmentValues {
    /// The task's way to its connectors' views; nil where views are not drawn (fixtures, another Mac's task), which
    /// leaves their rows as text.
    var connectorViews: ConnectorViewHost? {
        get { self[ConnectorViewsKey.self] }
        set { self[ConnectorViewsKey.self] = newValue }
    }
}

/// A connector call's MCP App view under its line (docs/CONNECTORS.md, "MCP Apps"): drawn when the row comes on
/// screen, the size the view reports up to its limit, in a hairline frame unless the server asked for none. Until
/// the view is live a quiet placeholder keeps its place; when it cannot be drawn the row's text shows instead, with
/// a way to try again.
struct ConnectorViewCard<Fallback: View>: View {
    /// The row's identity across redraws: the task and the item.
    let key: String
    let view: ConversationConnectorView
    let host: ConnectorViewHost
    @ViewBuilder let fallback: () -> Fallback

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        let controller = MCPAppViewPool.shared.controller(key)
        let display = controller.display
        if display.state == .failed {
            VStack(alignment: .leading, spacing: 8) {
                fallback()
                Button(L10n.string("Show view again")) { controller.retry() }
                    .buttonStyle(.link)
                    .font(.system(size: 12 * interfaceScale))
            }
        } else {
            let border = display.prefersBorder != false
            MCPAppContainer(key: key, controller: controller, start: { [view, host] in
                controller.start(view, host: host, isDark: colorScheme == .dark, openLink: { url in openURL(url) })
            })
            .frame(maxWidth: .infinity)
            .frame(height: display.height)
            .overlay {
                if display.state != .live {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(L10n.string("Loading"))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: border ? 8 : 0, style: .continuous))
            .overlay {
                if border {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                }
            }
            .onChange(of: colorScheme) { _, scheme in controller.setDark(scheme == .dark) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.string("Connector view"))
        }
    }
}

/// The AppKit place the pooled web view goes into. Coming on screen draws the view; leaving it lets the pool park
/// the view once more are live than it keeps.
private struct MCPAppContainer: NSViewRepresentable {
    let key: String
    let controller: MCPAppViewController
    let start: @MainActor () -> Void

    func makeNSView(context: Context) -> MCPAppContainerView {
        let view = MCPAppContainerView()
        update(view)
        return view
    }

    func updateNSView(_ view: MCPAppContainerView, context: Context) {
        update(view)
    }

    private func update(_ view: MCPAppContainerView) {
        controller.container = view
        let key = key, start = start
        view.onScreenChanged = { isOnScreen in
            MCPAppViewPool.shared.setOnScreen(key, isOnScreen)
            if isOnScreen { start() }
        }
        view.checkOnScreen()
    }

    static func dismantleNSView(_ view: MCPAppContainerView, coordinator: ()) {
        view.onScreenChanged?(false)
        view.onScreenChanged = nil
    }
}
