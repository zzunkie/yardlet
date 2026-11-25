import Foundation
import YardletAgentTools
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

/// Settings toggle for Yardlet's native MCP Code Mode (default off; leaves nothing behind when off).
enum CodeModePreference {
    static let key = "YardletAgentCodeMode"

    static var isSupported: Bool {
#if canImport(JavaScriptCore)
        true
#else
        false
#endif
    }

    /// Settings › General › Tasks › MCP Code Mode. `auto`, the default, decides per task (`isOn`).
    enum Mode: String, CaseIterable {
        case auto, on, off

        var title: String {
            switch self {
            case .auto: L10n.string("Auto")
            case .on: L10n.string("On")
            case .off: L10n.string("Off")
            }
        }
    }

    /// In `auto`, Claude Code tasks use Code Mode from this many connector tools: with fewer, its own
    /// tool search loads the few it needs in fewer turns.
    static let claudeCodeConnectorToolThreshold = 30

    /// The chosen mode. Before it had three values the setting was a switch, saved only once the person
    /// turned it: a saved `true` reads as `on` and a saved `false` as `off`, and no value at all as `auto`.
    static func mode(in defaults: UserDefaults = .yardlet) -> Mode {
        switch defaults.object(forKey: key) {
        case let value as String: Mode(rawValue: value) ?? .auto
        case let value as Bool: value ? .on : .off
        default: .auto
        }
    }

    /// Saves a switch from before the setting had three values as the mode it reads as, so Settings,
    /// which reads the value as text, shows it.
    static func convertSavedSwitch(in defaults: UserDefaults = .yardlet) {
        guard defaults.object(forKey: key) is Bool else { return }
        defaults.set(mode(in: defaults).rawValue, forKey: key)
    }

    /// Whether a task of this harness, offered this many connector tools, gets Code Mode. In `auto`,
    /// Codex never does (it runs its own code mode); Claude Code does from
    /// `claudeCodeConnectorToolThreshold` connector tools; Antigravity and the other harnesses do from one.
    static func isOn(_ mode: Mode, harness: HarnessKind?, connectorToolCount: Int) -> Bool {
        guard isSupported else { return false }
        switch mode {
        case .on: return true
        case .off: return false
        case .auto:
            switch harness {
            case nil, .codex?: return false
            case .claudeCode?: return connectorToolCount >= claudeCodeConnectorToolThreshold
            default: return connectorToolCount > 0
            }
        }
    }
}

/// Runs model-authored JavaScript inside an isolated `JavaScriptCore` sandbox with a synchronous
/// `callTool(name, args)` bridge into `AgentToolBroker`. No filesystem, network, or shell APIs are
/// exposed; every underlying tool call keeps Yardlet's token, approval, and scrubbing boundaries.
///
/// Trade-off: in-process `JavaScriptCore` has no public Swift cancellation API for pure infinite JS
/// loops (`while (true) {}`). Tool calls, timeouts, and outer task cancellation are enforced at
/// every bridge boundary and via an async deadline timer so the caller is never blocked past the
/// script timeout.
enum CodeModeRunner {
    static let maxCalls = 20
    static let defaultTimeoutSeconds: Double = 30
    static let maxTimeoutSeconds: Double = 60
    static let maxCodeBytes = 32 * 1024
    static let maxOutputBytes = 16 * 1024
    static let maxLogLines = 50
    static let maxLogBytes = 4 * 1024

    typealias ToolDispatcher = @Sendable (_ tool: String, _ arguments: ToolJSON) async -> AgentToolResult

    static func run(
        code: String,
        timeoutSeconds: Double?,
        dispatch: @escaping ToolDispatcher
    ) async -> AgentToolResult {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure("code is empty.", .invalidArguments, retry: .withChanges)
        }
        guard trimmed.utf8.count <= maxCodeBytes else {
            return .failure("code is \(trimmed.utf8.count) bytes; the limit is \(maxCodeBytes) bytes.",
                            .invalidArguments, retry: .withChanges)
        }
        let timeout = min(max(timeoutSeconds ?? defaultTimeoutSeconds, 1), maxTimeoutSeconds)

#if canImport(JavaScriptCore)
        return await runInJavaScriptCore(code: trimmed, timeoutSeconds: timeout, dispatch: dispatch)
#else
        return .failure("MCP Code Mode is not available on this platform.", .unreachable, retry: .no)
#endif
    }

    /// Truncates `text` to at most `maxBytes` UTF-8 bytes without splitting Unicode scalars.
    static func truncateUTF8(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        guard text.utf8.count > maxBytes else { return text }
        var bytes = 0
        var end = text.startIndex
        for scalar in text.unicodeScalars {
            let scalarBytes = scalar.utf8.count
            if bytes + scalarBytes > maxBytes { break }
            bytes += scalarBytes
            end = text.unicodeScalars.index(after: end)
        }
        return String(text[..<end])
    }

#if canImport(JavaScriptCore)
    private final class ExecutionState: @unchecked Sendable {
        let lock = NSLock()
        var toolCalls = 0
        var logs: [String] = []
        var logBytes = 0
        var timedOut = false
        var cancelled = false
        var activeCallTask: Task<Void, Never>?
        var activeCallSemaphore: DispatchSemaphore?
        let deadline: Date

        init(timeoutSeconds: Double) {
            self.deadline = Date().addingTimeInterval(timeoutSeconds)
        }

        func appendLog(_ line: String) {
            lock.lock()
            defer { lock.unlock() }
            guard logs.count < CodeModeRunner.maxLogLines, logBytes < CodeModeRunner.maxLogBytes else { return }
            let remaining = CodeModeRunner.maxLogBytes - logBytes
            let clipped = CodeModeRunner.truncateUTF8(line, maxBytes: remaining)
            guard !clipped.isEmpty else { return }
            logs.append(clipped)
            logBytes += clipped.utf8.count
        }

        func cancelInFlightCall(asTimeout: Bool) {
            lock.lock()
            if asTimeout {
                timedOut = true
            } else {
                cancelled = true
            }
            let task = activeCallTask
            let sem = activeCallSemaphore
            lock.unlock()
            task?.cancel()
            sem?.signal()
        }

        func timeoutFailure(timeoutSeconds: Double) -> AgentToolResult {
            lock.lock()
            let calls = toolCalls
            lock.unlock()
            if calls > 0 {
                return .failure(
                    "Script timed out after \(Int(timeoutSeconds))s after running \(calls) tool call\(calls == 1 ? "" : "s"). Check whether earlier calls already took effect before retrying.",
                    .outcomeUnknown,
                    retry: .afterChecking
                )
            }
            return .failure("Script timed out after \(Int(timeoutSeconds))s.", .timedOut, retry: .withChanges)
        }
    }

    private final class ContinuationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<AgentToolResult, Never>?
        private var timer: DispatchSourceTimer?

        init(continuation: CheckedContinuation<AgentToolResult, Never>) {
            self.continuation = continuation
        }

        func setTimer(_ timer: DispatchSourceTimer) {
            lock.lock()
            if continuation == nil {
                lock.unlock()
                timer.cancel()
                return
            }
            self.timer = timer
            lock.unlock()
        }

        func finish(with result: AgentToolResult) {
            lock.lock()
            let cont = continuation
            continuation = nil
            let activeTimer = timer
            timer = nil
            lock.unlock()
            activeTimer?.cancel()
            cont?.resume(returning: result)
        }
    }

    private static func runInJavaScriptCore(
        code: String,
        timeoutSeconds: Double,
        dispatch: @escaping ToolDispatcher
    ) async -> AgentToolResult {
        let state = ExecutionState(timeoutSeconds: timeoutSeconds)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let gate = ContinuationGate(continuation: continuation)

                if Task.isCancelled {
                    state.cancelInFlightCall(asTimeout: false)
                    gate.finish(with: .failure("Script was cancelled.", .refused, retry: .no))
                    return
                }

                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
                timer.schedule(deadline: .now() + timeoutSeconds + 0.25)
                timer.setEventHandler {
                    state.cancelInFlightCall(asTimeout: true)
                    gate.finish(with: state.timeoutFailure(timeoutSeconds: timeoutSeconds))
                }
                gate.setTimer(timer)
                timer.resume()

                // Run JSContext on a dedicated non-cooperative thread so synchronous `callTool` bridges
                // never starve Swift's cooperative pool or the main actor.
                let worker = Thread {
                    let result = executeWorker(code: code, timeoutSeconds: timeoutSeconds, state: state, dispatch: dispatch)
                    gate.finish(with: result)
                }
                worker.name = "com.zzunkie.yardlet.code-mode"
                worker.start()
            }
        } onCancel: {
            state.cancelInFlightCall(asTimeout: false)
        }
    }

    private static func executeWorker(
        code: String,
        timeoutSeconds: Double,
        state: ExecutionState,
        dispatch: @escaping ToolDispatcher
    ) -> AgentToolResult {
        guard let context = JSContext() else {
            return .failure("Could not initialize JavaScriptCore sandbox.", .unreachable, retry: .no)
        }

        var capturedException: String?
        context.exceptionHandler = { _, value in
            capturedException = value?.toString() ?? "JavaScript execution error"
        }

        // Accept optional JSValue so JS `null`/`undefined` never crashes ObjC-to-Swift bridging.
        let logBlock: @convention(block) (JSValue?) -> Void = { value in
            guard let value, !value.isNull, !value.isUndefined, let line = value.toString() else { return }
            state.appendLog(line)
        }

        // Synchronous bridge returning a JSON-encoded envelope `{ok, value?, error?}` parsed inside JS.
        let callToolBlock: @convention(block) (JSValue?, JSValue?) -> String = { rawNameValue, rawArgsValue in
            let rawName = (rawNameValue?.isNull == false && rawNameValue?.isUndefined == false)
                ? (rawNameValue?.toString() ?? "") : ""
            let rawArgsJSON = (rawArgsValue?.isNull == false && rawArgsValue?.isUndefined == false)
                ? (rawArgsValue?.toString() ?? "{}") : "{}"
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)

            state.lock.lock()
            let alreadyTimedOut = state.timedOut || Date() >= state.deadline
            let alreadyCancelled = state.cancelled
            if alreadyTimedOut { state.timedOut = true }
            state.lock.unlock()

            if alreadyCancelled {
                return encodeEnvelope(["error": "Script was cancelled."])
            }
            if alreadyTimedOut {
                return encodeEnvelope(["error": "Script timed out."])
            }
            guard !name.isEmpty else {
                return encodeEnvelope(["error": "callTool requires a non-empty tool name."])
            }
            guard name != CodeModeToolCatalog.runScript else {
                return encodeEnvelope(["error": "Recursive calls to \(CodeModeToolCatalog.runScript) are not allowed."])
            }

            let parsedArgs: ToolJSON
            if rawArgsJSON.isEmpty || rawArgsJSON == "null" || rawArgsJSON == "undefined" {
                parsedArgs = .object([:])
            } else if let data = rawArgsJSON.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode(ToolJSON.self, from: data),
                      case .object = decoded {
                parsedArgs = decoded
            } else {
                return encodeEnvelope(["error": "callTool arguments must be a JSON object."])
            }

            state.lock.lock()
            if state.toolCalls >= CodeModeRunner.maxCalls {
                state.lock.unlock()
                return encodeEnvelope(["error": "Script exceeded the maximum of \(CodeModeRunner.maxCalls) tool calls."])
            }
            state.toolCalls += 1
            state.lock.unlock()

            let remaining = state.deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                state.lock.lock()
                state.timedOut = true
                state.lock.unlock()
                return encodeEnvelope(["error": "Script timed out."])
            }

            final class CallBox: @unchecked Sendable {
                var value: AgentToolResult?
            }
            let callBox = CallBox()
            let callSemaphore = DispatchSemaphore(value: 0)
            let callTask = Task.detached(priority: .userInitiated) {
                callBox.value = await dispatch(name, parsedArgs)
                callSemaphore.signal()
            }

            state.lock.lock()
            state.activeCallTask = callTask
            state.activeCallSemaphore = callSemaphore
            let cancelledNow = state.cancelled
            state.lock.unlock()

            if cancelledNow {
                callTask.cancel()
                return encodeEnvelope(["error": "Script was cancelled."])
            }

            let waitResult = callSemaphore.wait(timeout: .now() + remaining)

            state.lock.lock()
            state.activeCallTask = nil
            state.activeCallSemaphore = nil
            let wasCancelled = state.cancelled
            let wasTimedOut = state.timedOut || waitResult == .timedOut
            if waitResult == .timedOut { state.timedOut = true }
            state.lock.unlock()

            if wasCancelled {
                callTask.cancel()
                return encodeEnvelope(["error": "Script was cancelled."])
            }
            if wasTimedOut {
                callTask.cancel()
                return encodeEnvelope(["error": "Tool call \(name) timed out."])
            }
            guard let toolResult = callBox.value else {
                return encodeEnvelope(["error": "Tool call \(name) returned no result."])
            }

            return encodeToolResult(name: name, toolResult: toolResult)
        }

        // Bind bridge functions inside a closure and remove globals before running user code.
        context.setObject(logBlock, forKeyedSubscript: "__yardletLog" as NSString)
        context.setObject(callToolBlock, forKeyedSubscript: "__yardletCallTool" as NSString)

        let prelude = """
        (function(nativeLog, nativeCallTool) {
            delete globalThis.__yardletLog;
            delete globalThis.__yardletCallTool;
            globalThis.console = {
                log: function() {
                    var parts = [];
                    for (var i = 0; i < arguments.length; i++) {
                        var v = arguments[i];
                        if (typeof v === 'string') { parts.push(v); }
                        else {
                            try {
                                var s = JSON.stringify(v);
                                parts.push(s === undefined ? String(v) : s);
                            } catch (e) {
                                parts.push(String(v));
                            }
                        }
                    }
                    nativeLog(parts.join(' '));
                }
            };
            globalThis.callTool = function(name, args) {
                var serialized = '{}';
                if (args !== undefined && args !== null) {
                    if (typeof args !== 'object' || Array.isArray(args)) {
                        throw new Error('callTool arguments must be a JSON object.');
                    }
                    var s = JSON.stringify(args);
                    serialized = (s === undefined) ? '{}' : s;
                }
                var raw = nativeCallTool(name == null ? '' : String(name), serialized);
                var env = JSON.parse(raw);
                if (env.error) { throw new Error(env.error); }
                if (env.isError) { return { isError: true, text: env.text }; }
                return env.value;
            };
        })(globalThis.__yardletLog, globalThis.__yardletCallTool);
        """
        context.evaluateScript(prelude)

        context.setObject(code as NSString, forKeyedSubscript: "__yardletUserCode" as NSString)
        let runner = """
        (function() {
            var source = globalThis.__yardletUserCode;
            delete globalThis.__yardletUserCode;
            var fn = new Function(source);
            var result = fn();
            var encoded = JSON.stringify(result === undefined ? null : result);
            return encoded === undefined ? 'null' : encoded;
        })()
        """
        let jsOutput = context.evaluateScript(runner)

        state.lock.lock()
        let didTimeOut = state.timedOut
        let didCancel = state.cancelled
        let calls = state.toolCalls
        let logs = state.logs
        state.lock.unlock()

        if didCancel {
            return .failure("Script was cancelled.", .refused, retry: .no)
        }
        if didTimeOut {
            return state.timeoutFailure(timeoutSeconds: timeoutSeconds)
        }
        if let exception = capturedException {
            return .failure("Script error: \(exception)", .invalidArguments, retry: .withChanges)
        }
        let rawResult = jsOutput?.isUndefined == false ? (jsOutput?.toString() ?? "null") : "null"
        let formatted = formatOutput(resultJSON: rawResult, logs: logs, toolCalls: calls)
        return .text(formatted)
    }

    private static func encodeToolResult(name: String, toolResult: AgentToolResult) -> String {
        var textParts: [String] = []
        var imageCount = 0
        for content in toolResult.content {
            switch content {
            case let .text(text):
                textParts.append(text)
            case let .json(value):
                if let data = try? JSONEncoder().encode(value),
                   let jsonText = String(data: data, encoding: .utf8) {
                    textParts.append(jsonText)
                }
            case .image:
                imageCount += 1
            }
        }
        let combinedText = textParts.joined(separator: "\n")

        if toolResult.isError {
            return encodeEnvelope([
                "isError": true,
                "text": combinedText.isEmpty ? "Tool \(name) returned an error." : combinedText
            ])
        }

        if combinedText.isEmpty, let structured = toolResult.structuredContent,
           let data = try? JSONEncoder().encode(structured),
           let jsonObject = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return encodeEnvelope(["ok": true, "value": jsonObject])
        }

        if let data = combinedText.data(using: .utf8),
           let jsonObject = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return encodeEnvelope(["ok": true, "value": jsonObject])
        }

        var fallback: [String: Any] = ["text": combinedText, "isError": false]
        if imageCount > 0 {
            fallback["omittedImages"] = imageCount
        }
        return encodeEnvelope(["ok": true, "value": fallback])
    }

    private static func encodeEnvelope(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"error":"Could not serialize tool result."}"#
        }
        return text
    }

    private static func formatOutput(resultJSON: String, logs: [String], toolCalls: Int) -> String {
        var payload: [String: Any] = ["toolCalls": toolCalls]
        if let data = resultJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            payload["result"] = parsed
        } else {
            payload["result"] = resultJSON
        }
        if !logs.isEmpty {
            payload["logs"] = logs
        }
        let encoded: String
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            encoded = text
        } else {
            encoded = resultJSON
        }
        guard encoded.utf8.count > maxOutputBytes else { return encoded }
        let suffix = "\n... [output truncated at \(maxOutputBytes) bytes]"
        let budget = max(0, maxOutputBytes - suffix.utf8.count)
        return truncateUTF8(encoded, maxBytes: budget) + suffix
    }
#endif
}
