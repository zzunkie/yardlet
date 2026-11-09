import Foundation

struct AccountCommandResult: Sendable {
    let exitCode: Int32
    let output: String
}

enum AccountCommandError: LocalizedError, Equatable, Sendable {
    case timedOut

    var errorDescription: String? {
        switch self {
        case .timedOut:
            return L10n.string("The account status check did not finish in time.")
        }
    }
}

enum AccountCommandRunner {
    static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:],
        timeout: Duration = .seconds(12)
    ) async throws -> AccountCommandResult {
        // A CLI installed as a Node script finds `node` through the login shell's `PATH`.
        await LoginShellPath.ready()
        return try await Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            process.environment = RuntimeProcessEnvironment.values(
                executableURL: executableURL,
                overrides: [
                "NO_COLOR": "1",
                "PAGER": "cat"
                ].merging(environment) { _, new in new }
            )
            let exit = try ProcessExit(running: process)

            // Foundation owns this child, so the timeout stops its tree and lets `Process`
            // reap it. A wrapper can still exit zero once its stalled child is stopped, so a
            // timed-out command reports the timeout instead of its partial output.
            let timeoutTask = Task {
                do { try await Task.sleep(for: timeout) } catch { return false }
                guard process.isRunning else { return false }
                NativeProcessTree.terminate(process: process)
                return true
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let ended = await exit.wait(timeout: timeout)
            timeoutTask.cancel()
            if await timeoutTask.value || !ended {
                NativeProcessTree.terminate(process: process)
                throw AccountCommandError.timedOut
            }
            return AccountCommandResult(
                exitCode: process.terminationStatus,
                output: String(decoding: data, as: UTF8.self)
            )
        }.value
    }
}
