import Foundation

// The CLI a task runs on (docs/NATIVE_SESSION_STORAGE.md, "Runtime paths"). A task records the path
// of the CLI it was created with, and that file can go while Yardlet runs: a desktop app that
// bundles the CLI removes the recorded version when it updates. So the recorded path is a record,
// not something to run. Whatever starts a task's CLI, asks it a question or looks up the adapter
// kept for it gets the CLI here, where a missing one is followed by one rule; nothing else passes
// `SessionRecord.runtimeExecutableURL` on as an executable (`TaskRuntimeLintTests`).
extension AppModel {
    /// The CLI a task runs on now: the one it recorded while that exists, else where the desktop app
    /// that bundles it moved it, else the harness's current runtime. With nowhere to follow it is the
    /// recorded path, which the caller then finds missing. Nothing is written.
    func runtime(of session: SessionRecord) -> URL {
        runtimeReplacement(for: session) ?? session.runtimeExecutableURL
    }

    /// Where a task whose recorded runtime is gone continues: where the desktop app that bundles the
    /// runtime moved it, or else the harness's current runtime. Nil while the recorded one exists.
    func runtimeReplacement(for session: SessionRecord) -> URL? {
        guard !ExecutableLookup.current.isProgram(session.runtimeExecutableURL) else { return nil }
        return RuntimeRelocation.successor(of: session.runtimeExecutableURL, for: session.harness)
            ?? runtimeSelections.selectedURL(for: session.harness)
    }

    /// A task keeps the runtime it was created with. When a desktop app that bundles that runtime
    /// moved it or removed its old version, the task continues with where the runtime now lives,
    /// or else with the harness's current runtime, and its row says so from then on. The provider
    /// session and its home stay as they were, and a recorded runtime that still exists is never
    /// replaced.
    func sessionWithAvailableRuntime(_ session: SessionRecord) async -> SessionRecord {
        guard let replacement = runtimeReplacement(for: session),
              let updated = try? await store.updateRuntimeExecutable(id: session.id, to: replacement)
        else { return session }
        return updated
    }

    /// What the registry keeps a task's adapter under: its harness, the CLI it runs on now, its
    /// storage and its account.
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
