import Foundation
import YardletAgentTools

/// What a task's composer knows about connectors, before Yardlet's own list is added: the MCP
/// servers the harness reported for the running session, and whether the session gets Yardlet's
/// connectors at all (through the Yardlet MCP server, 13.8).
struct ComposerConnectorsSlot: Equatable, Sendable {
    /// Nil where the harness has not reported its servers, or reports none.
    var sessionServers: [HarnessMCPServerStatus]?
    var carriesYardletConnectors: Bool
    /// The harness lists Yardlet's tools again when told (Claude Code), so a change reaches a
    /// running task from its next turn; others read the list when the task starts or resumes.
    var toolListFollowsNextTurn = false
}

/// The composer's connector list, as the Claude app's Code composer lists them under "+" →
/// "Connectors" (2.37337.1 `oF`) with the statuses of its session rail (`lD`) and its "MCP servers
/// in this session" dialog: the first row manages connectors (Yardlet's settings), then each
/// connector and server with its state, those that need the user first. The submenu says how many
/// need reconnecting.
///
/// Yardlet's connectors carry a switch for this task and, when they need a sign-in, "Reconnect";
/// the servers the harness loaded itself are read-only (Yardlet does not write the harness's
/// configuration, and Claude Code's own toggle writes `.claude.json`). Yardlet's connectors reach a
/// session through the one `yardlet` MCP server, which is not listed itself; when the harness
/// reports that server down, the connectors it carries are down with it.
struct ComposerConnectorList: Equatable, Sendable {
    struct Row: Equatable, Sendable, Identifiable {
        enum Source: Equatable, Sendable {
            /// One of Yardlet's connectors (Settings → Connectors).
            case yardlet
            /// A server the harness itself loaded (its own configuration or account).
            case session
        }

        enum State: Equatable, Sendable {
            case connected
            case pending
            case needsAuthentication
            case failed
            case disabled
            /// A Yardlet connector added but not connected.
            case notConnected
            /// A Yardlet connector the user turned off for this task.
            case offInTask
            /// A Yardlet connector whose server the harness loads itself, so the harness's copy is used.
            case harnessHasIt
            /// A harness's own server left out of this task because Yardlet's connector at the same
            /// address serves it. The harness may report it as failed ("blocked"); it is not an error.
            case yardletStandsIn
        }

        let id: String
        let name: String
        let state: State
        let toolCount: Int?
        let source: Source
        /// The Yardlet connector behind the row, for its switch and "Reconnect".
        var connectorID: UUID? = nil
        var presetID: String? = nil
        /// Where its picture comes from: the connector's server and directory entry, or for a
        /// harness's own server the directory entry its name stands for.
        var icons: ConnectorIconSources = .none

        var needsAttention: Bool { state == .failed || state == .needsAuthentication }

        /// A Yardlet row that the user can switch for this task: on, or turned off here.
        var isSwitchable: Bool {
            source == .yardlet && connectorID != nil && state != .harnessHasIt
        }

        var isOn: Bool { state != .offInTask }

        /// A Yardlet row whose sign-in needs the user: signed out, refused, or never connected.
        var canReconnect: Bool {
            source == .yardlet && (state == .needsAuthentication || state == .notConnected)
        }

        /// "Reconnect" for a sign-in the server refused, "Connect" for one never made.
        var reconnectTitle: String {
            state == .needsAuthentication ? L10n.string("Reconnect") : L10n.string("Connect")
        }

        /// The Claude app's status words (`IvjoDSPGEQ`, `tUEUSDJfDv`, `dRgDU8kd+k`, `vXCeIi67rj`,
        /// `YtxGgOZEIf`, `w7oF88SsI/`); a Yardlet connector not connected keeps Settings' word.
        var statusText: String {
            switch state {
            case .connected:
                switch toolCount {
                case 1?: L10n.string("Connected · 1 tool")
                case let count? where count > 1: L10n.format("Connected · %lld tools", Int64(count))
                default: L10n.string("Connected")
                }
            case .pending: L10n.string("Connecting…")
            case .needsAuthentication: L10n.string("Needs authentication")
            case .failed: L10n.string("Failed")
            case .disabled: L10n.string("Turned off for this project")
            case .notConnected: L10n.string("Not connected")
            case .offInTask: L10n.string("Off for this task")
            case .harnessHasIt: L10n.string("Uses the harness's own server")
            case .yardletStandsIn: L10n.string("Uses Yardlet's connector")
            }
        }
    }

    let rows: [Row]
    /// A change to Yardlet's connectors reaches this task from its next turn (`ComposerConnectorsSlot`).
    var toolListFollowsNextTurn = false

    var needsReconnectionCount: Int { rows.filter(\.needsAttention).count }

    /// The "Connectors" item's hint: "1 needs reconnection".
    var hint: String? {
        switch needsReconnectionCount {
        case 0: nil
        case 1: L10n.string("1 needs reconnection")
        case let count: L10n.format("%lld need reconnection", Int64(count))
        }
    }

    /// Nil where the composer has nothing to say about connectors: the session gets none of
    /// Yardlet's and its harness reports no servers. `taskState` says whether each Yardlet
    /// connector reaches this task (on, off here, or left to the harness's own server);
    /// `standInServerNames` are the harness's servers Yardlet's connectors stand in for.
    static func make(
        _ slot: ComposerConnectorsSlot?,
        connectors: [ConnectorRecord],
        taskState: (ConnectorRecord) -> ConnectorTaskState = { _ in .on },
        standInServerNames: Set<String> = []
    ) -> ComposerConnectorList? {
        guard let slot, slot.carriesYardletConnectors || slot.sessionServers != nil else {
            return nil
        }
        let yardletServer = slot.sessionServers?.first { $0.name == AgentToolEnvironment.serverName }
        var rows: [Row] = []
        if slot.carriesYardletConnectors {
            rows += connectors.map { record in
                var state: Row.State = switch record.status {
                case .connected: .connected
                case .signInRequired: .needsAuthentication
                case .notConnected: .notConnected
                }
                if state == .connected, let carrier = yardletServer?.state, carrier != .connected {
                    state = switch carrier {
                    case .pending: .pending
                    case .disabled: .disabled
                    case .connected, .failed, .needsAuthentication: .failed
                    }
                }
                switch taskState(record) {
                case .on: break
                case .off: state = .offInTask
                case .harnessHasIt: state = .harnessHasIt
                }
                return Row(id: "yardlet-\(record.id.uuidString)", name: record.displayName, state: state,
                           toolCount: state == .connected ? record.offeredTools.count : nil, source: .yardlet,
                           connectorID: record.id, presetID: record.presetID, icons: record.iconSources)
            }
        }
        rows += (slot.sessionServers ?? []).filter { $0.name != AgentToolEnvironment.serverName }.map { server in
            let state: Row.State = if standInServerNames.contains(server.name) { .yardletStandsIn } else {
                switch server.state {
                case .connected: .connected
                case .pending: .pending
                case .needsAuthentication: .needsAuthentication
                case .failed: .failed
                case .disabled: .disabled
                }
            }
            let preset = ConnectorPreset.preset(forServerNamed: server.name)
            return Row(id: "session-\(server.name)", name: server.name, state: state, toolCount: server.toolCount,
                       source: .session, presetID: preset?.id, icons: .preset(preset?.id))
        }
        // Those that need the user first, as the Claude app's rail sorts them; otherwise as listed.
        let ordered = rows.filter(\.needsAttention) + rows.filter { !$0.needsAttention }
        return ComposerConnectorList(
            rows: ordered,
            toolListFollowsNextTurn: slot.toolListFollowsNextTurn
        )
    }
}
