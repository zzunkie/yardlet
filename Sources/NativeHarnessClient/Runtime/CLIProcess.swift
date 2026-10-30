import Foundation

/// Runs the commands of CLI checks, updates and verification probes as child processes, with the
/// runtime's usual environment, no input, and a time limit that stops the process tree.
enum CLIProcess {
    static func run(_ command: CLICommand, currentDirectory: URL? = nil) async -> CLICommandResult {
        await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            let error = Pipe()
            process.executableURL = command.executable
            process.arguments = command.arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = error
            if let currentDirectory { process.currentDirectoryURL = currentDirectory }
            process.environment = RuntimeProcessEnvironment.values(executableURL: command.executable,
                overrides: ["NO_COLOR": "1", "PAGER": "cat"].merging(command.environment) { _, new in new })
            // `waitUntilExit` can wait on the wrong run loop after an await (`NativeProcessTree`), so
            // the end is taken from the termination handler.
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            do { try process.run() } catch {
                return CLICommandResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
            }
            let timeout = command.timeout
            let timer = Task {
                do { try await Task.sleep(for: timeout) } catch { return false }
                guard process.isRunning else { return false }
                NativeProcessTree.terminate(process: process)
                return true
            }
            // Both pipes are drained at once, so a command that writes a lot to either never stalls.
            let errorData = Task.detached { error.fileHandleForReading.readDataToEndOfFile() }
            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            let stderr = await errorData.value
            waitForExit(exited, seconds: 10)
            timer.cancel()
            if await timer.value {
                return CLICommandResult(exitCode: -1, stdout: String(decoding: outputData, as: UTF8.self),
                    stderr: L10n.string("Timed out"))
            }
            return CLICommandResult(exitCode: process.isRunning ? -1 : process.terminationStatus,
                stdout: String(decoding: outputData, as: UTF8.self),
                stderr: String(decoding: stderr, as: UTF8.self))
        }.value
    }

    /// One request of a line-delimited JSON exchange and how its answer is recognized: the first
    /// output line `answer` returns a verdict for decides the step.
    struct ExchangeStep: Sendable {
        var line: Data
        var answer: @Sendable (JSONValue) -> CLIVerification?
    }

    /// Starts `executable`, sends each step's line in turn and waits for its answer, then stops
    /// it. Runs in an empty private folder, so no project's settings or history are touched.
    static func exchange(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        steps: [ExchangeStep],
        timeout: Duration
    ) async -> CLIVerification {
        await Task.detached(priority: .utility) {
            let folder = FileManager.default.temporaryDirectory
                .appending(path: "Yardlet-CLICheck-\(UUID().uuidString)", directoryHint: .isDirectory)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            } catch { return .failed(error.localizedDescription) }
            defer { try? FileManager.default.removeItem(at: folder) }

            let process = Process()
            let input = Pipe.childInput()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = folder
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.environment = environment
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            do { try process.run() } catch { return .failed(error.localizedDescription) }
            let timer = Task {
                do { try await Task.sleep(for: timeout) } catch { return false }
                guard process.isRunning else { return false }
                NativeProcessTree.terminate(process: process)
                return true
            }
            defer {
                timer.cancel()
                try? input.fileHandleForWriting.close()
                if process.isRunning { NativeProcessTree.terminate(process: process) }
                waitForExit(exited, seconds: 5)
            }

            var buffer = Data()
            for step in steps {
                do { try input.fileHandleForWriting.write(contentsOf: step.line) } catch {
                    return .failed(L10n.string("The CLI stopped before it answered"))
                }
                var verdict: CLIVerification?
                reading: while verdict == nil {
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = Data(buffer[..<newline])
                        buffer.removeSubrange(...newline)
                        guard let value = try? JSONDecoder().decode(JSONValue.self, from: line) else { continue }
                        if let answer = step.answer(value) { verdict = answer; break reading }
                    }
                    let chunk = output.fileHandleForReading.availableData
                    guard !chunk.isEmpty, buffer.count + chunk.count <= 8 * 1_048_576 else { break }
                    buffer.append(chunk)
                }
                guard let verdict else {
                    timer.cancel()
                    return await timer.value ? .failed(L10n.string("Timed out"))
                        : .failed(L10n.string("The CLI stopped before it answered"))
                }
                guard verdict == .passed else { return verdict }
            }
            return .passed
        }.value
    }
}

extension CLIProcess {
    /// Blocks this worker thread until the termination handler ran, for at most `seconds`.
    fileprivate static func waitForExit(_ exited: DispatchSemaphore, seconds: Double) {
        _ = exited.wait(timeout: .now() + seconds)
    }
}

struct LiveCLICommandRunner: CLICommandRunning {
    func run(_ command: CLICommand) async -> CLICommandResult {
        await CLIProcess.run(command)
    }
}
