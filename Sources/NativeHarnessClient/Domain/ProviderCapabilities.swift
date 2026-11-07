import Foundation

struct ProviderCapabilityChoice: Equatable, Identifiable, Sendable {
    let value: String
    let name: String
    let description: String?

    var id: String { value }
}

struct ProviderCapabilitySelector: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let description: String?
    let category: String?
    var currentValue: String
    let choices: [ProviderCapabilityChoice]
}

struct ProviderCapabilityAction: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let description: String
    let systemImage: String
}

struct ProviderCapabilityState: Equatable, Sendable {
    var selectors: [ProviderCapabilitySelector] = []
    var actions: [ProviderCapabilityAction] = []
    var notes: [String] = []
    var isLoading = false
    var errors: [String] = []
    var actionMessage: String?
    /// Whether this session's agent settled that it takes image input, for a family that
    /// negotiates it rather than carrying it by transport. `nil` means the
    /// agent has not answered yet, and the composer keeps offering the control until it does.
    var acceptsImageInput: Bool?
    /// Session-advertised slash commands and user-invocable skills. No filesystem inventory.
    var composerCommands: [ProviderComposerCommand] = []
    /// The model and effort selectors come from the list the runtime last advertised, for a task
    /// that has not connected: a choice is kept with the task and applied when it starts, so the
    /// composer offers them without waking the task. Never set on a runtime's own state.
    var offersModelsBeforeAttach = false
    /// The MCP servers the running session loaded, as the harness last reported them. Nil where
    /// the harness has not reported any (or reports none at all).
    var mcpServers: [HarnessMCPServerStatus]?
    /// The task can keep a context limit of its own. A side chat cannot: it has no history to
    /// resume, so its runtime is not started again.
    var offersContextLimit = false
    /// The task chose a context limit its running process does not have yet.
    var contextLimitAppliesLater = false

    static let empty = ProviderCapabilityState()
}

protocol ProviderCapabilityProviding: Actor {
    func providerCapabilities(for session: HarnessSessionHandle) async throws
        -> ProviderCapabilityState
    func setProviderOption(
        id: String,
        value: String,
        in session: HarnessSessionHandle
    ) async throws -> ProviderCapabilityState
    func performProviderAction(
        id: String,
        in session: HarnessSessionHandle
    ) async throws -> ProviderCapabilityState
}

enum ProviderCapabilityActionID {
    static let compact = "compact"
}

enum ProviderCapabilityAccessibility {
    static func selectedChoiceName(for selector: ProviderCapabilitySelector) -> String {
        selector.choices.first { $0.value == selector.currentValue }?.name
            ?? selector.currentValue
    }

    static func actionHint(for action: ProviderCapabilityAction) -> String {
        action.description
    }
}
