import Foundation

// What a task keeps for its platform's screens: the sign-in terminal, the terminal panel's shell,
// the bash-mode shell, a browser tab's preview page and the conversation's cached turn views. The
// engine holds them by these names and each platform's screens define them; here none of them runs.

/// A harness's sign-in command in a terminal: not run here.
@MainActor
final class AccountLoginController {
    private(set) var isRunning = false
    var phase: AccountConnectionPhase { .cancelled }

    func start(_ command: AccountInteractiveCommand) {}
    func stop() {}
    func completeVerifiedConnection() {}
}

/// The terminal panel's shell: none starts here.
@MainActor
final class NativeTerminalSession {
    private(set) var hasEnded = false

    init(workspaceURL: URL, launch: ShellLaunchEnvironment = .userLoginShell(), taskID: UUID? = nil) {}

    func move(toTask id: UUID) {}

    func end() { hasEnded = true }
}

/// Bash mode's shell: none starts here, so its commands end at once.
@MainActor
final class TaskShellProcess: TaskShell {
    let workingDirectory: URL
    let isAlive = false
    let wasReset = false
    let hasOwnProcesses = false
    let isRunningCommand = false

    init(workingDirectory: URL, launch: ShellLaunchEnvironment) {
        self.workingDirectory = workingDirectory
    }

    func command(_ command: String, note: String?) -> any ShellCommandRunning {
        UnavailableShellCommand()
    }

    func close() {}
}

/// A browser tab's page where the build has no browser engine: none loads here.
@MainActor
final class BrowserPreviewModel {
    private(set) var address = ""
    private(set) var title = ""
    private(set) var isLoading = false
    var onChange: (() -> Void)?

    init(preferences: BrowserPreviewPreferences = .init()) {
        address = preferences.address
    }

    func navigate() {}

    func terminateForApplicationShutdown() {}
}

/// The conversation's cached turn views: there are none to keep.
@MainActor
final class ConversationRenderState {
    init() {}
}

/// A bash-mode command where no shell runs: it finishes at once without running.
final class UnavailableShellCommand: ShellCommandRunning {
    var onOutput: ((String) -> Void)?
    var onFinish: ((ShellCommandResult) -> Void)?

    func start() { onFinish?(ShellCommandResult(output: "", exitCode: nil, launchError: "No shell runs on this platform.")) }
    func stop() {}
    func terminate() {}
}
