import Foundation

// The CLI a task runs on (docs/NATIVE_SESSION_STORAGE.md, "Runtime paths"): its harness's current
// runtime, the one the person chose in Settings › Harnesses or else the newest install found, as the
// Codex and Claude apps open every conversation with the CLI they have now. A task records the path of
// the CLI it last started with. That path is a record, not something to run: a desktop app that
// bundles the CLI removes the recorded version when it updates, and another install may be the
// harness's runtime now. Whatever starts a task's CLI, asks it a question or looks up the adapter kept
// for it gets the CLI here; nothing else passes `SessionRecord.runtimeExecutableURL` on as an
// executable (`TaskRuntimeLintTests`).
extension AppModel {
    /// The CLI a task runs on now: its harness's current runtime. A harness with none (no install
    /// found and none chosen) leaves the recorded path, which the caller runs or finds missing.
    /// Nothing is written.
    func runtime(of session: SessionRecord) -> URL {
        runtimeSelections.selectedURL(for: session.harness) ?? session.runtimeExecutableURL
    }

    /// The task with its row pointed at the CLI it starts with now, before its runtime starts or its
    /// CLI is asked something. An attached task keeps the record of the CLI its runtime runs until that
    /// runtime ends. The provider session, its home and its account stay as they were.
    func sessionWithCurrentRuntime(_ session: SessionRecord) async -> SessionRecord {
        let current = runtime(of: session).standardizedFileURL
        guard current != session.runtimeExecutableURL, handlesBySessionID[session.id] == nil,
              let updated = try? await store.updateRuntimeExecutable(id: session.id, to: current)
        else { return session }
        return updated
    }

    /// What the registry keeps a task's adapter under: its harness, the CLI it runs on now, its
    /// storage and its account. Tasks of one harness and account share one key whatever CLI each
    /// recorded, so Codex tasks of an account share one App Server.
    func runtimeKey(of session: SessionRecord) -> HarnessRegistry.Key {
        HarnessRegistry.Key(harness: session.harness, executableURL: runtime(of: session),
                            environmentScope: session.environmentScope, connection: session.connection)
    }

    /// The same for the task as recorded, to remember by what was learned of a runtime (`canBranch`).
    /// It names a runtime without looking for its file, so a view may ask on every draw; nothing is
    /// started or looked up in the registry with it.
    func recordedRuntimeKey(of session: SessionRecord) -> HarnessRegistry.Key {
        HarnessRegistry.Key(harness: session.harness, executableURL: session.runtimeExecutableURL,
                            environmentScope: session.environmentScope, connection: session.connection)
    }

    /// The adapter the registry keeps for the task's runtime, storage and account: the one the task
    /// attaches with, and the one its saved conversation is read with while it is detached. Asking
    /// starts no runtime.
    func registryAdapter(for session: SessionRecord) async -> any HarnessAdapter {
        await registry.adapter(for: runtimeKey(of: session))
    }

    /// The CLI a process started for the task runs: its runtime, or the earlier version Yardlet holds
    /// in its place while an update failed its check (`CLIRuntimeOverrides`).
    func startedExecutable(of session: SessionRecord) async -> URL {
        await registry.startedExecutable(for: session.harness, requested: runtime(of: session))
    }
}
