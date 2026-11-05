import Foundation

/// The `PATH` the person's login shell sets up. An app opened from the Dock or Finder gets launchd's
/// `/usr/bin:/bin:/usr/sbin:/sbin`, without the folders `~/.zprofile` and `~/.zshrc` add, Homebrew's
/// among them, so the agents Yardlet starts and the commands they run would not find the person's
/// tools. As the Claude app and editors that start CLIs do, the Mac app asks the login shell once, in
/// the background at launch (`startReading`). Agents wait for that read before they start (`ready()`),
/// and the programs Yardlet starts get its `PATH` (`RuntimeProcessEnvironment.app`).
///
/// Only `PATH` is taken. The other variables a profile exports include API keys and the folders that
/// hold an agent's sign-in and history (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`), which stay as the app has
/// them.
enum LoginShellPath {
    /// How long the shell may take. The Claude app gives the same read 4 seconds; a shell that takes
    /// longer leaves the app's own `PATH` in place.
    static let timeout: Duration = .seconds(5)

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var reading: Task<Void, Never>?
        var path: String?
    }

    private static let state = State()

    /// Starts the read, once. Yardlet started from a terminal already has that terminal's `PATH`, and
    /// an interactive shell started from it would take the terminal over, so then nothing is read.
    static func startReading(shell: String, environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard FileHandle(forUpdatingAtPath: "/dev/tty") == nil else { return }
        state.lock.withLock {
            guard state.reading == nil else { return }
            state.reading = Task.detached(priority: .userInitiated) {
                let path = await read(shell: URL(filePath: shell), environment: environment)
                state.lock.withLock { state.path = path }
            }
        }
    }

    /// Waits for the read `startReading` began, which ends within `timeout`; returns at once when
    /// none began.
    static func ready() async {
        await state.lock.withLock { state.reading }?.value
    }

    /// The `PATH` read, or nil while it is being read, when it failed, or when none began.
    static var value: String? {
        state.lock.withLock { state.path }
    }

    /// Starts `shell` as an interactive login shell, so it reads the files a terminal window's shell
    /// reads, and returns the `PATH` it ends up with; nil when the shell fails or takes longer than
    /// `timeout`, which ends it and what it started.
    static func read(shell: URL, environment: [String: String], timeout: Duration = timeout) async -> String? {
        let file = FileManager.default.temporaryDirectory.appending(path: "Yardlet-login-path-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = shell
        // `printenv` prints the same in every shell. The value goes to a file rather than a pipe,
        // which a program the profile leaves running in the background would hold open.
        process.arguments = ["-l", "-i", "-c", #"/usr/bin/printenv PATH > "$YARDLET_LOGIN_PATH_FILE""#]
        // oh-my-zsh neither offers its update nor checks its folders' permissions.
        process.environment = environment.merging([
            "YARDLET_LOGIN_PATH_FILE": file.path(percentEncoded: false),
            "DISABLE_AUTO_UPDATE": "true",
            "ZSH_DISABLE_COMPFIX": "true"
        ]) { $1 }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in exited.continuation.finish() }
        do { try NativeProcessTree.run(process) } catch { return nil }
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in exited.stream {}; return true }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
        guard finished else {
            NativeProcessTree.terminate(process: process)
            return nil
        }
        let path = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return path?.isEmpty == false ? path : nil
    }
}
