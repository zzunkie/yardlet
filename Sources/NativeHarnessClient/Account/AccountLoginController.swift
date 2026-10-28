import AppKit
import Darwin
import Foundation
import Observation
@preconcurrency import SwiftTerm

@MainActor
@Observable
final class AccountLoginController: NSObject, @MainActor LocalProcessTerminalViewDelegate, NativeSurfaceResource {
    private(set) var output = ""
    private(set) var isRunning = false
    private(set) var detectedURL: URL?
    private(set) var detectedCode: String?
    private(set) var exitCode: Int32?
    private(set) var operation: AccountConnectionOperation = .connect
    private(set) var interaction: AccountConnectionInteraction = .guided
    private(set) var wasCancelled = false
    private var connectionVerified = false

    @ObservationIgnored private(set) var processIdentifier: pid_t?
    @ObservationIgnored private weak var terminalView: LocalProcessTerminalView?
    @ObservationIgnored private var pendingCommand: AccountInteractiveCommand?
    @ObservationIgnored private var terminalPollTask: Task<Void, Never>?
    @ObservationIgnored private var terminalOutputPrefix = ""
    @ObservationIgnored private var pendingInitialInput: String?
    @ObservationIgnored private var pendingInitialInputTrigger: String?
    private let outputLimit = 256 * 1024

    var phase: AccountConnectionPhase {
        if connectionVerified { return .completed }
        if wasCancelled { return .cancelled }
        if isRunning {
            if detectedURL != nil { return .browserHandoff }
            if interaction == .terminalRequired || Self.outputRequiresInput(output) {
                return .inputRequired
            }
            return .preparing
        }
        guard let exitCode else { return .preparing }
        return exitCode == 0 ? .completed : .failed
    }

    override init() {
        super.init()
        NativeSurfaceResourceRegistry.shared.register(self)
    }

    /// Prepares a command for the interactive SwiftTerm surface. The process starts
    /// when the view attaches on the next SwiftUI render pass.
    func start(_ command: AccountInteractiveCommand) {
        stop()
        output = command.startupMessage ?? ""
        detectedURL = nil
        detectedCode = nil
        exitCode = nil
        operation = command.operation
        interaction = command.interaction
        wasCancelled = false
        terminalOutputPrefix = output
        pendingCommand = command
        pendingInitialInput = command.initialInput
        pendingInitialInputTrigger = command.initialInputTrigger
        isRunning = true
    }

    func attach(_ view: AccountLoginTerminalView) {
        guard terminalView !== view, let command = pendingCommand else { return }
        terminalView = view
        view.processDelegate = self
        view.onOutput = { [weak self, weak view] in
            // While the process runs, the terminal poll reads its output. The last lines can
            // arrive after the exit is reported, once the poll has stopped.
            guard let self, let view, view === self.terminalView, !self.isRunning else { return }
            self.refreshTerminalOutput()
        }

        if let startupMessage = command.startupMessage, !startupMessage.isEmpty {
            view.feed(text: startupMessage.replacingOccurrences(of: "\n", with: "\r\n"))
            terminalOutputPrefix = ""
        }

        let environment = RuntimeProcessEnvironment.values(
            executableURL: command.executableURL,
            overrides: command.environment.merging([
                "TERM": "xterm-256color",
                "COLORTERM": "truecolor",
                "PAGER": "cat"
            ]) { _, new in new }
        ).map { "\($0.key)=\($0.value)" }.sorted()
        view.startProcess(
            executable: command.executableURL.path(percentEncoded: false),
            args: command.arguments,
            environment: environment,
            currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        )
        processIdentifier = view.process.shellPid
        isRunning = view.process.running
        startTerminalPolling()

        if command.initialInputTrigger == nil, let initialInput = command.initialInput {
            pendingInitialInput = nil
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(900))
                self?.send(initialInput)
            }
        }
    }

    func detach(_ view: LocalProcessTerminalView) {
        guard terminalView === view else { return }
        stop()
    }

    func pressEnter() { send("\r") }
    func moveUp() { send("\u{1B}[A") }
    func moveDown() { send("\u{1B}[B") }

    @discardableResult
    func submitInput(_ value: String) -> Bool {
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRunning, !input.isEmpty else { return false }
        send(input + "\r")
        return true
    }

    func cancel() {
        wasCancelled = true
        stopProcess(clearOutcome: false)
    }

    /// A read-only provider probe can finish a login whose TUI stays open after
    /// saving authentication. Stop only the login-owned process, without inventing
    /// a successful process exit or relying on terminal success text.
    func completeVerifiedConnection() {
        guard isRunning, !wasCancelled, operation == .connect else { return }
        connectionVerified = true
        stopProcess(clearOutcome: false)
        detectedURL = nil
        detectedCode = nil
    }

    func openDetectedURL() {
        guard let detectedURL else { return }
        NSWorkspace.shared.open(detectedURL)
    }

    func copyDetectedCode() {
        guard let detectedCode else { return }
        TranscriptClipboard.copy(detectedCode)
    }

    func stop() {
        stopProcess(clearOutcome: true)
    }

    private func stopProcess(clearOutcome: Bool) {
        terminalPollTask?.cancel()
        terminalPollTask = nil
        if let terminalView {
            let terminalPID = terminalView.process.shellPid
            if terminalPID > 0 {
                NativeProcessTree.terminate(rootPID: terminalPID)
            }
            if terminalView.process.running {
                terminalView.terminate()
            }
        }
        terminalView = nil
        pendingCommand = nil
        pendingInitialInput = nil
        pendingInitialInputTrigger = nil
        processIdentifier = nil
        isRunning = false
        if clearOutcome {
            connectionVerified = false
            detectedURL = nil
            detectedCode = nil
            exitCode = nil
            wasCancelled = false
        }
    }

    func terminateForApplicationShutdown() {
        stop()
    }

    private func send(_ value: String) {
        guard let terminalView, isRunning else { return }
        let bytes = Array(value.utf8)
        terminalView.send(source: terminalView, data: bytes[...])
    }

    private func startTerminalPolling() {
        terminalPollTask?.cancel()
        terminalPollTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.terminalView != nil {
                self.refreshTerminalOutput()
                if !self.isRunning { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func refreshTerminalOutput() {
        guard let terminalView else { return }
        let terminalText = terminalView.getTerminal().unwrappedText
        output = terminalOutputPrefix + terminalText
        if let trigger = pendingInitialInputTrigger,
           terminalText.contains(trigger),
           let input = pendingInitialInput {
            pendingInitialInput = nil
            pendingInitialInputTrigger = nil
            send(input)
        }
        if detectedURL == nil { detectedURL = Self.firstHTTPSURL(in: output) }
        if detectedCode == nil { detectedCode = Self.firstDeviceCode(in: output) }
        if output.utf8.count > outputLimit {
            output = String(decoding: output.utf8.suffix(outputLimit), as: UTF8.self)
        }
    }

    private func didTerminate(exitCode: Int32?) {
        refreshTerminalOutput()
        terminalPollTask?.cancel()
        terminalPollTask = nil
        pendingCommand = nil
        pendingInitialInput = nil
        pendingInitialInputTrigger = nil
        processIdentifier = nil
        isRunning = false
        self.exitCode = exitCode ?? -1
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard source === terminalView else { return }
        didTerminate(exitCode: exitCode)
    }

    nonisolated static func firstDeviceCode(in value: String) -> String? {
        let normalized = stripANSI(value)
        let pattern = #"(?i)(?:device\s+code|verification\s+code|code|코드)[^A-Z0-9]{0,24}([A-Z0-9]{4,}(?:-[A-Z0-9]{4,})?)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        for match in expression.matches(
            in: normalized,
            range: NSRange(normalized.startIndex..., in: normalized)
        ) {
            guard let range = Range(match.range(at: 1), in: normalized) else { continue }
            let candidate = String(normalized[range]).uppercased()
            if candidate != "HTTP", candidate != "HTTPS" { return candidate }
        }
        return nil
    }

    nonisolated static func outputRequiresInput(_ value: String) -> Bool {
        let normalized = stripANSI(value).lowercased()
        if normalized.contains("●"), normalized.contains("○") { return true }
        return [
            "select login method",
            "select authentication method",
            "login method",
            "choose a provider",
            "select a provider",
            "select provider",
            "enter api key"
        ].contains { normalized.contains($0) }
    }

    nonisolated static func stripANSI(_ value: String) -> String {
        value.replacingOccurrences(
            of: "\\x1B(?:\\[[0-?]*[ -/]*[@-~]|\\][^\\x07]*(?:\\x07|\\x1B\\\\))",
            with: "",
            options: .regularExpression
        ).replacingOccurrences(of: "\r", with: "")
    }

    static func firstHTTPSURL(in value: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return detector.matches(in: value, range: range)
            .compactMap(\.url)
            .first { $0.scheme == "https" }
    }
}
