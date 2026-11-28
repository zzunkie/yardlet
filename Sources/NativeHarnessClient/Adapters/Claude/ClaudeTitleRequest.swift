import Foundation

/// Names a Claude Code task from its recent conversation (`RecentConversationTitle`): one
/// `claude -p` run with the account's latest Haiku, on the task's account, in an empty private
/// folder. It keeps no conversation (`--no-session-persistence`); `--safe-mode` leaves out the
/// person's CLAUDE.md, skills, plugins, hooks and MCP servers while the login works as usual; no tool
/// is offered, a one-line system prompt takes the place of Claude Code's own, and thinking is off
/// (`MAX_THINKING_TOKENS=0`), which a few words do not need. `--bare` would leave out the same, but it
/// signs in only with an API key.
enum ClaudeTitleRequest {
    /// Claude Code's documented variable for the thinking budget; 0 turns thinking off.
    static let thinkingBudget = "MAX_THINKING_TOKENS"

    /// The conversation goes in on standard input, so it is in no process's arguments.
    static func arguments(model: String) -> [String] {
        ["-p", "--model", model, "--system-prompt", RecentConversationTitle.systemPrompt,
         "--tools", "", "--strict-mcp-config", "--safe-mode", "--disable-slash-commands",
         "--no-session-persistence", "--output-format", "json"]
    }

    static func run(executableURL: URL, environment: [String: String], model: String, prompt: String,
                    timeout: Duration = RecentConversationTitle.timeout, exitGrace: Duration = .seconds(20)) async throws -> String {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let folder = try RecentConversationTitle.makeFolder()
            defer { try? FileManager.default.removeItem(at: folder) }

            let process = Process()
            let input = Pipe.childInput()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = executableURL
            process.arguments = arguments(model: model)
            process.currentDirectoryURL = folder
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            process.environment = ClaudeProcessTransport.environment(
                base: RuntimeProcessEnvironment.values(executableURL: executableURL),
                overrides: environment.merging([thinkingBudget: "0"]) { _, new in new })
            let exit = try ProcessExit(running: process, asAgent: true)

            let timeoutTask = Task {
                // Cancellation also starts the grace period. EOF lets Claude finish saving its login.
                try? await Task.sleep(for: timeout)
                guard process.isRunning else { return false }
                try? input.fileHandleForWriting.close()
                if !(await exit.wait(timeout: exitGrace)), process.isRunning {
                    NativeProcessTree.terminate(process: process)
                }
                return true
            }
            return try await withTaskCancellationHandler {
                try? input.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
                try? input.fileHandleForWriting.close()
                let stderr = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }
                let stdout = output.fileHandleForReading.readDataToEndOfFile()
                let ended = await exit.wait(timeout: timeout)
                timeoutTask.cancel()
                let timedOut = await timeoutTask.value
                try Task.checkCancellation()
                guard ended, !timedOut else {
                    throw HarnessAdapterError.capabilityUnavailable(
                        L10n.format("%@ did not answer in time.", HarnessKind.claudeCode.displayName))
                }
                return try title(fromOutput: stdout, exitCode: process.terminationStatus,
                                 errorOutput: await stderr.value)
            } onCancel: {
                timeoutTask.cancel()
            }
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    /// The name in the CLI's `--output-format json` result, or the error it reported.
    static func title(fromOutput output: Data, exitCode: Int32, errorOutput: Data = Data()) throws -> String {
        let result = try? JSONDecoder().decode(JSONValue.self, from: output)
        let text = result?["result"]?.stringValue
        guard exitCode == 0, result?["is_error"]?.boolValue != true else {
            let message = text ?? String(decoding: errorOutput, as: UTF8.self)
                .split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            throw HarnessAdapterError.processExited(code: exitCode, message: message)
        }
        let line = text?.split(whereSeparator: \.isNewline).first.map(String.init)
        guard let title = SessionTitleProjection.normalizedProviderTitle(line) else {
            throw HarnessAdapterError.capabilityUnavailable(
                L10n.format("%@ did not suggest a name.", HarnessKind.claudeCode.displayName))
        }
        return title
    }
}
