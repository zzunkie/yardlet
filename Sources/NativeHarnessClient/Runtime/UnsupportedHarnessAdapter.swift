import Foundation

actor UnsupportedHarnessAdapter: HarnessAdapter {
    nonisolated let kind: HarnessKind
    private let executableURL: URL
    /// Why this runtime cannot run tasks, when Yardlet knows (a version too old, say).
    private let reason: String?

    init(kind: HarnessKind, executableURL: URL, reason: String? = nil) {
        self.kind = kind
        self.executableURL = executableURL.standardizedFileURL
        self.reason = reason
    }

    func probeRuntime() async throws -> HarnessRuntimeDescriptor {
        guard !HarnessCatalog.retired.contains(kind), reason == nil else { throw unavailable() }
        throw HarnessAdapterError.capabilityUnavailable(
            L10n.format(
                "%@ adapter is not implemented yet for %@",
                kind.displayName,
                executableURL.path(percentEncoded: false)
            )
        )
    }

    func createSession(_ request: CreateHarnessSessionRequest) async throws
        -> HarnessSessionHandle {
        throw unavailable()
    }

    func resumeSession(
        providerSessionID: String,
        localSessionID: UUID,
        workspaceURL: URL
    ) async throws -> HarnessSessionHandle {
        throw unavailable()
    }

    func send(_ prompt: String, to session: HarnessSessionHandle) async throws {
        throw unavailable()
    }

    func interrupt(_ session: HarnessSessionHandle) async throws {
        throw unavailable()
    }

    func respond(
        to permissionRequestID: String,
        decision: PermissionDecision,
        in session: HarnessSessionHandle
    ) async throws {
        throw unavailable()
    }

    func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> {
        AsyncStream { $0.finish() }
    }

    func close(_ session: HarnessSessionHandle) async {}

    private func unavailable() -> HarnessAdapterError {
        reason.map { .capabilityUnavailable($0) } ?? Self.unavailable(kind)
    }

    /// A harness Yardlet took out of its list (a saved task of it still opens) is no longer
    /// supported; any other has no adapter yet.
    static func unavailable(_ kind: HarnessKind) -> HarnessAdapterError {
        .capabilityUnavailable(HarnessCatalog.retired.contains(kind)
            ? L10n.format("Yardlet no longer supports %@.", kind.displayName)
            : L10n.format("%@ adapter is not implemented yet", kind.displayName))
    }
}
