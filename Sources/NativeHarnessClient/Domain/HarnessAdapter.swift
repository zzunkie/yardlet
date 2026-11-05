import Foundation

protocol HarnessAdapter: Actor {
    nonisolated var kind: HarnessKind { get }

    func probeRuntime() async throws -> HarnessRuntimeDescriptor
    func createSession(_ request: CreateHarnessSessionRequest) async throws -> HarnessSessionHandle
    func resumeSession(providerSessionID: String, localSessionID: UUID, workspaceURL: URL) async throws -> HarnessSessionHandle
    func send(_ prompt: String, to session: HarnessSessionHandle) async throws
    /// Harness-neutral submission carrying composer attachments and mentions. Text-only input
    /// must reach the provider in exactly the shape `send(_:to:)` already uses.
    func send(_ input: HarnessUserInput, to session: HarnessSessionHandle) async throws
    func interrupt(_ session: HarnessSessionHandle) async throws
    func respond(
        to permissionRequestID: String,
        decision: PermissionDecision,
        in session: HarnessSessionHandle
    ) async throws
    func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope>
    func close(_ session: HarnessSessionHandle) async
}

extension HarnessAdapter {
    /// The default keeps every existing adapter source-compatible: with no attachment the turn
    /// is the same text send it always was, and with one it fails loudly instead of transmitting
    /// a prompt the user did not write.
    func send(_ input: HarnessUserInput, to session: HarnessSessionHandle) async throws {
        guard input.images.isEmpty else {
            throw HarnessAdapterError.capabilityUnavailable(
                L10n.format("%@ cannot send image attachments", kind.displayName)
            )
        }
        try await send(input.promptText, to: session)
    }
}

/// Optional multi-root surface. A task always runs in one primary folder; a project's remaining
/// roots reach the provider through its own mechanism (Codex `runtimeWorkspaceRoots`, Claude
/// `--add-dir`). Adapters without one simply do not conform, and the task keeps its cwd alone.
protocol HarnessWorkspaceRootsConfiguring: Actor {
    func setAdditionalWorkspaceRoots(_ roots: [URL], for localSessionID: UUID) async
}

/// Optional instruction-source surface. Only a provider that tells Yardlet which instruction
/// files it loaded can be shown as applied; everything else is reported as merely present.
protocol HarnessInstructionSourceReporting: Actor {
    func instructionSources(for localSessionID: UUID) async -> [String]?
}

/// Optional image-negotiation surface for a family whose agent answers for itself whether it
/// takes image input. Only the adapter that ran the handshake knows the answer, so it reports
/// it here rather than letting the composer guess from the harness name. `nil` means the agent
/// has not answered yet; adapters whose transport always carries images do not conform.
protocol HarnessImageInputReporting: Actor {
    func acceptsImageInput(for localSessionID: UUID) async -> Bool?
}

/// Optional model-list surface: the models, with their effort levels, the runtime advertised when
/// the session connected. Yardlet keeps the list so a composer can name and offer models before a
/// task connects. `nil` means the runtime has not answered yet.
protocol HarnessModelCatalogReporting: Actor {
    func advertisedModels(for localSessionID: UUID) async -> [HarnessModelOption]?
}

/// Optional launch-time option surface. Some provider options are CLI flags rather than
/// in-session settings, so a change to one reaches the provider only when its next process
/// starts. Yardlet hands the task's saved options to the adapter before the session attaches;
/// adapters whose options are all in-session simply do not conform.
protocol HarnessLaunchOptionConfiguring: Actor {
    func setLaunchOptions(_ options: [String: String], for localSessionID: UUID) async
}

/// Optional surface for a session that leaves no history of its own with the provider: nothing
/// saved where the provider's app, its CLI or Yardlet's import would list it. `run_agent` asks
/// for it before the session is created, as its conversation is kept with the calling task, and a
/// side chat, which is temporary.
protocol HarnessHistoryFreeSessionConfiguring: Actor {
    /// Asks that the session about to be created for `localSessionID` keep no history. False
    /// when this provider has no way to, and the session is kept as any other.
    func keepNoHistory(for localSessionID: UUID) async -> Bool
}

/// Optional richer permission surface for adapters whose provider offers more
/// than one allow or deny action. The base decision API stays source-compatible.
protocol HarnessPermissionActionResponding: Actor {
    func respond(
        to permissionRequestID: String,
        selectedActionID: String,
        in session: HarnessSessionHandle
    ) async throws
}

/// Optional answer surface for adapters whose provider asks a question or submits a plan
/// instead of merely requesting permission. The answer is what the provider's own request
/// offered, so an adapter that never sends one simply does not conform and the base decision
/// API keeps working unchanged.
protocol HarnessStructuredPermissionResponding: Actor {
    func respond(
        to permissionRequestID: String,
        answer: PermissionStructuredAnswer,
        in session: HarnessSessionHandle
    ) async throws
}

/// Optional session-lifecycle surface for a provider that keeps its own list of sessions, so
/// Yardlet's archive, unarchive, delete, and rename also reach the provider's copy (Codex
/// threads: `thread/archive`, `thread/unarchive`, `thread/delete`, `thread/name/set`).
/// Adapters without one do not conform, and those actions stay inside Yardlet's index.
/// None of these calls resumes a session or starts a turn.
protocol HarnessSessionLifecycleProviding: Actor {
    func archiveProviderSession(_ session: HarnessSessionHandle) async throws
    /// Restores a session this provider archived for Yardlet, by its provider ID. It takes no
    /// handle because an archived session is not attached.
    func unarchiveProviderSession(providerSessionID: String) async throws
    func deleteProviderSession(_ session: HarnessSessionHandle) async throws
    func renameProviderSession(_ session: HarnessSessionHandle, to title: String) async throws
}

/// Adapters whose runtime names a task from its recent conversation with a side call of its own,
/// attached or not (`RecentConversationTitle`).
protocol HarnessTaskTitleSuggesting: Actor {
    func suggestTaskTitle(fromRecentConversation excerpt: String) async throws -> String
}

enum HarnessAdapterError: Error, Equatable, Sendable {
    case runtimeNotFound(URL?)
    case unsupportedRuntime(version: String)
    case capabilityUnavailable(String)
    case invalidProviderEvent(String)
    case processExited(code: Int32, message: String)
    case attachmentUnreadable(URL)
}

extension HarnessAdapterError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .runtimeNotFound(url):
            return L10n.format(
                "Runtime executable was not found: %@",
                url?.path(percentEncoded: false) ?? L10n.string("Unknown path")
            )
        case let .unsupportedRuntime(version):
            return L10n.format("Unsupported runtime version: %@", version)
        case let .capabilityUnavailable(message), let .invalidProviderEvent(message):
            return message
        case let .processExited(code, message):
            let detail = message.isEmpty ? L10n.string("No process error detail") : message
            return L10n.format("Harness process exited (%d): %@", code, detail)
        case let .attachmentUnreadable(url):
            return L10n.format(
                "Attachment could not be read: %@",
                url.path(percentEncoded: false)
            )
        }
    }
}
