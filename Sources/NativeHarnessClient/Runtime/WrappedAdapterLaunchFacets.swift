import Foundation

/// The launch settings a YHP wrapper hands straight to the adapter it wraps (B16). The wrapped
/// adapter still owns the process it launches and the session request it sends, so a launch flag,
/// a project's extra roots, the Yardlet MCP server and Yardlet instructions have to reach it before the session starts,
/// earlier than any session-scoped YHP request. Only the wrapped adapter also learns which
/// instruction files the provider actually loaded. Whether the person is looking at a task goes to it
/// too: it decides the next-message suggestions it asks for. A facet the wrapped adapter lacks is skipped.
struct WrappedAdapterLaunchFacets: Sendable {
    private let launchOptions: (any HarnessLaunchOptionConfiguring)?
    private let workspaceRoots: (any HarnessWorkspaceRootsConfiguring)?
    private let instructionSources: (any HarnessInstructionSourceReporting)?
    private let agentTools: (any HarnessAgentToolConfiguring)?
    private let yardletInstructions: (any HarnessYardletInstructionsConfiguring)?
    private let history: (any HarnessHistoryFreeSessionConfiguring)?
    private let sight: (any HarnessTaskSightReceiving)?

    init(wrapping adapter: any HarnessAdapter) {
        launchOptions = adapter as? any HarnessLaunchOptionConfiguring
        workspaceRoots = adapter as? any HarnessWorkspaceRootsConfiguring
        instructionSources = adapter as? any HarnessInstructionSourceReporting
        agentTools = adapter as? any HarnessAgentToolConfiguring
        yardletInstructions = adapter as? any HarnessYardletInstructionsConfiguring
        history = adapter as? any HarnessHistoryFreeSessionConfiguring
        sight = adapter as? any HarnessTaskSightReceiving
    }

    func setUnseen(since date: Date?, for localSessionID: UUID) async {
        await sight?.setUnseen(since: date, for: localSessionID)
    }

    func keepNoHistory(for localSessionID: UUID) async -> Bool {
        await history?.keepNoHistory(for: localSessionID) ?? false
    }

    func setLaunchOptions(_ options: [String: String], for localSessionID: UUID) async {
        await launchOptions?.setLaunchOptions(options, for: localSessionID)
    }

    func setAdditionalWorkspaceRoots(_ roots: [URL], for localSessionID: UUID) async {
        await workspaceRoots?.setAdditionalWorkspaceRoots(roots, for: localSessionID)
    }

    func instructionSources(for localSessionID: UUID) async -> [String]? {
        await instructionSources?.instructionSources(for: localSessionID) ?? nil
    }

    func setAgentToolServer(_ server: AgentToolServerLaunch?, for localSessionID: UUID) async {
        await agentTools?.setAgentToolServer(server, for: localSessionID)
    }

    func setYardletInstructions(_ instructions: YardletInstructionsDelivery?, for localSessionID: UUID) async {
        await yardletInstructions?.setYardletInstructions(instructions, for: localSessionID)
    }
}

/// A YHP wrapper whose launch settings go through `WrappedAdapterLaunchFacets`. Conforming gives
/// the wrapper the launch protocols with this one forwarding.
protocol WrappedAdapterLaunchForwarding:
    HarnessLaunchOptionConfiguring,
    HarnessWorkspaceRootsConfiguring,
    HarnessInstructionSourceReporting,
    HarnessAgentToolConfiguring,
    HarnessYardletInstructionsConfiguring,
    HarnessHistoryFreeSessionConfiguring,
    HarnessTaskSightReceiving
{
    nonisolated var launchFacets: WrappedAdapterLaunchFacets { get }
}

extension WrappedAdapterLaunchForwarding {
    func setLaunchOptions(_ options: [String: String], for localSessionID: UUID) async {
        await launchFacets.setLaunchOptions(options, for: localSessionID)
    }

    func setAdditionalWorkspaceRoots(_ roots: [URL], for localSessionID: UUID) async {
        await launchFacets.setAdditionalWorkspaceRoots(roots, for: localSessionID)
    }

    func instructionSources(for localSessionID: UUID) async -> [String]? {
        await launchFacets.instructionSources(for: localSessionID)
    }

    func setAgentToolServer(_ server: AgentToolServerLaunch?, for localSessionID: UUID) async {
        await launchFacets.setAgentToolServer(server, for: localSessionID)
    }

    func setYardletInstructions(_ instructions: YardletInstructionsDelivery?, for localSessionID: UUID) async {
        await launchFacets.setYardletInstructions(instructions, for: localSessionID)
    }

    func keepNoHistory(for localSessionID: UUID) async -> Bool {
        await launchFacets.keepNoHistory(for: localSessionID)
    }

    func setUnseen(since date: Date?, for localSessionID: UUID) async {
        await launchFacets.setUnseen(since: date, for: localSessionID)
    }
}
