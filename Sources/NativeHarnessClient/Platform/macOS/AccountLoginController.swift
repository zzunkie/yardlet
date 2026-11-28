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
    /// Changes with each command, so the console makes its terminal anew for the next one (a
    /// sign-in that follows a sign-out in the same console).
    private(set) var commandID = UUID()
    private(set) var connectionVerified = false

    @ObservationIgnored private(set) var processIdentifier: pid_t?
    @ObservationIgnored private weak var terminalView: LocalProcessTerminalView?
    @ObservationIgnored private var pendingCommand: AccountInteractiveCommand?
    @ObservationIgnored private var terminalPollTask: Task<Void, Never>?
    @ObservationIgnored private var initialInputTask: Task<Void, Never>?
    @ObservationIgnored private var terminalOutputPrefix = ""
    @ObservationIgnored private var pendingInitialInput: String?
    @ObservationIgnored private var pendingInitialInputTrigger: String?
    private var opensBrowser = false
    private var automaticPrompt: String?
    @ObservationIgnored private var verifySuccessfulExit: (() async -> Bool)?
    @ObservationIgnored private var verificationTask: Task<Void, Never>?
    /// A prepared sign-in may replace a successful sign-out before the console redraws.
    @ObservationIgnored var onSuccessfulCompletion: (() -> Void)?
    private var verificationFailed = false
    private let outputLimit = 256 * 1024

    var phase: AccountConnectionPhase {
        if connectionVerified { return .completed }
        if wasCancelled { return .cancelled }
        if verificationFailed { return .failed }
        if isRunning, exitCode != nil { return .preparing }
        if isRunning {
            if interaction == .terminalRequired { return .inputRequired }
            if detectedURL != nil { return .browserHandoff }
            if Self.outputRequiresInput(output, automaticPrompt: automaticPrompt) {
                return .inputRequired
            }
            return opensBrowser ? .browserHandoff : .preparing
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
    func start(_ command: AccountInteractiveCommand, verifySuccessfulExit: (() async -> Bool)? = nil) {
        stop()
        self.verifySuccessfulExit = verifySuccessfulExit
        output = command.startupMessage ?? ""
        detectedURL = nil
        detectedCode = nil
        exitCode = nil
        operation = command.operation
        opensBrowser = command.opensBrowser
        automaticPrompt = command.initialInputTrigger
        interaction = command.interaction
        wasCancelled = false
        terminalOutputPrefix = output
        commandID = UUID()
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
            guard let self, let view, view === self.terminalView, self.exitCode != nil else { return }
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
        // A synchronous exit can already have started the next command.
        guard terminalView === view else { return }
        guard view.process.running else {
            if exitCode == nil { didTerminate(exitCode: -1) }
            return
        }
        processIdentifier = view.process.shellPid
        startTerminalPolling()

        if command.initialInputTrigger == nil, let initialInput = command.initialInput {
            pendingInitialInput = nil
            initialInputTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
                guard !Task.isCancelled else { return }
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

    /// A read-only provider probe can finish a sign-in or sign-out whose TUI stays
    /// open after changing authentication. Stop only the console-owned process, without
    /// inventing a successful process exit or relying on terminal success text.
    func completeVerifiedConnection() {
        guard isRunning, !wasCancelled else { return }
        connectionVerified = true
        let completion = onSuccessfulCompletion
        stopProcess(clearOutcome: false)
        detectedURL = nil
        detectedCode = nil
        completion?()
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
        onSuccessfulCompletion = nil
        verificationTask?.cancel()
        verificationTask = nil
        verifySuccessfulExit = nil
        initialInputTask?.cancel()
        initialInputTask = nil
        terminalPollTask?.cancel()
        terminalPollTask = nil
        if let terminalView {
            let terminalPID = terminalView.process.shellPid
            if terminalView.process.running, terminalPID > 0 {
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
            verificationFailed = false
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
        if let trigger = pendingInitialInputTrigger,
           terminalText.contains(trigger),
           let input = pendingInitialInput {
            pendingInitialInput = nil
            pendingInitialInputTrigger = nil
            send(input)
        }
        let text = terminalOutputPrefix + terminalText
        let bounded = text.utf8.count > outputLimit ? String(decoding: text.utf8.suffix(outputLimit), as: UTF8.self) : text
        guard bounded != output else { return }
        output = bounded
        if detectedURL.map(Self.isSignInURL) != true, let url = Self.firstHTTPSURL(in: output),
           detectedURL == nil || Self.isSignInURL(url) {
            detectedURL = url
        }
        if detectedCode == nil { detectedCode = Self.firstDeviceCode(in: output) }
    }

    private func didTerminate(exitCode: Int32?) {
        refreshTerminalOutput()
        initialInputTask?.cancel()
        initialInputTask = nil
        terminalPollTask?.cancel()
        terminalPollTask = nil
        pendingCommand = nil
        pendingInitialInput = nil
        pendingInitialInputTrigger = nil
        processIdentifier = nil
        self.exitCode = exitCode ?? -1
        let completion = onSuccessfulCompletion
        onSuccessfulCompletion = nil
        guard exitCode == 0, let verifySuccessfulExit else {
            isRunning = false
            if exitCode == 0, !wasCancelled { completion?() }
            return
        }
        self.verifySuccessfulExit = nil
        verificationTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let verified = await verifySuccessfulExit()
            guard let self, !Task.isCancelled else { return }
            self.connectionVerified = verified
            self.verificationFailed = !verified
            self.isRunning = false
            self.verificationTask = nil
            if verified { completion?() }
        }
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard source === terminalView else { return }
        didTerminate(exitCode: exitCode)
    }

    static func firstHTTPSURL(in value: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let candidates = detector.matches(in: value, range: range)
            .compactMap(\.url)
            .filter { url in
                guard url.scheme == "https" else { return false }
                let parts = (url.host?.lowercased().components(separatedBy: ".") ?? [])
                    + url.path.lowercased().components(separatedBy: "/")
                return !parts.contains { $0.hasPrefix("terms") || $0.contains("privacy")
                    || ["docs", "documentation", "policies", "tos"].contains($0) }
            }
        return candidates.first(where: isSignInURL) ?? candidates.first
    }

    private static func isSignInURL(_ url: URL) -> Bool {
        let hostLabel = url.host?.lowercased().split(separator: ".").first
        if let hostLabel, ["accounts", "auth", "login"].contains(String(hostLabel)) { return true }
        let authPaths = ["oauth", "oauth2", "authorize", "login", "device", "signin", "sso", "auth"]
        return url.path.lowercased().split(separator: "/").contains { authPaths.contains(String($0)) }
    }
}
