import Foundation

/// For the checks that start a harness on Windows (Windows/scripts/check-harness.ps1, check-codex.ps1): with
/// YARDLET_QA_HARNESS_CHECK naming a harness (`kimi-code`, `codex`), the app takes the runtime it found for that
/// harness, as a new task would, and runs the engine's verification probe on it in the environment a task gives it
/// (Codex's home among it), which asks the CLI its version, starts it for the protocol's handshake and stops it once
/// it has answered. What it found and the verdict go to the event log (YARDLET_QA_EVENT_LOG). Without the variable
/// nothing runs.
@MainActor
enum QAHarnessCheck {
    static func runIfAsked(model: AppModel) {
        guard let name = ProcessInfo.processInfo.environment["YARDLET_QA_HARNESS_CHECK"], !name.isEmpty else { return }
        let log = QAEventLog.shared
        let harness = HarnessKind(rawValue: name)
        guard let executable = model.runtimeSelections.selectedURL(for: harness) else {
            log.write("harness not found: \(name)")
            return
        }
        log.write("harness found: \(name) \(ExecutableLookup.current.nativePath(executable))")
        let codexEnvironment = model.codexEnvironmentManager
        Task {
            if harness == .codex, let values = try? await codexEnvironment?.processEnvironment().values {
                log.write("harness home: \(values["CODEX_HOME"] ?? "none")")
            }
            switch await CLIVerificationProbe(codexEnvironment: codexEnvironment).verify(harness, executable: executable) {
            case .passed: log.write("harness check: passed")
            case .failed(let reason): log.write("harness check failed: \(reason)")
            }
        }
    }
}
