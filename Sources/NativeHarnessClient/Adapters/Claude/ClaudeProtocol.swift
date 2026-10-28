import Foundation

struct ClaudeRawFrame: Equatable, Sendable {
    let value: JSONValue
    let data: Data
}

struct ClaudeLaunchConfiguration: Equatable, Sendable {
    let providerSessionID: String
    let workspaceURL: URL
    let resumesExistingSession: Bool
    /// A project's roots other than the cwd. Empty leaves the launch arguments unchanged.
    var additionalRoots: [URL] = []
    /// Claude in Chrome, the CLI's own `--chrome` integration. False leaves the launch arguments
    /// unchanged; the CLI owns whether the extension is present and may refuse the flag.
    var chromeIntegration = false
    /// The Yardlet MCP server's `--mcp-config` file. Nil leaves the launch arguments unchanged;
    /// the servers the user configured for Claude Code load as they always do.
    var agentToolConfigPath: String? = nil
    var forkSource: HarnessSessionForkSource? = nil
    /// The permission mode the task last chose, in the selector's own value. Nil launches in
    /// Manual, as every task did before the mode was kept.
    var permissionMode: String? = nil
    /// The model the task chose, passed as `--model`. Nil runs the account's own model.
    var model: String? = nil
    /// The CLI saves nothing of this session (`--no-session-persistence`, print mode only): no
    /// conversation file for `--resume`, the Claude app or an import to find. For `run_agent`.
    var keepsNoHistory = false
    /// Yardlet instructions, passed as `--append-system-prompt`. Nil leaves the launch arguments unchanged.
    var appendSystemPrompt: String? = nil
    /// A settings document for this process alone, passed as `--settings` (the harness's own servers
    /// Yardlet's connectors stand in for). Nil leaves the launch arguments unchanged; nothing is
    /// written to the account's settings.
    var settings: String? = nil
}

/// The permission modes the selector offers, in its own values. Only these are kept with a task
/// or passed at launch. Bypass permissions skips every permission check; the selector asks before
/// choosing it, as Codex asks before Full access (the user's decision, 2026-10-12).
enum ClaudePermissionMode {
    static let manual = "manual"
    static let plan = "plan"
    static let bypassPermissions = "bypassPermissions"
    static let selectable: [String] = [manual, plan, "acceptEdits", "auto", "dontAsk", bypassPermissions]

    /// The `--permission-mode` value for a saved selector value. Manual keeps the `default`
    /// spelling launches always used, which every supported CLI accepts; anything outside the
    /// selector's modes launches as Manual.
    static func launchArgument(for mode: String?) -> String {
        guard let mode, selectable.contains(mode), mode != manual else { return "default" }
        return mode
    }

    static func displayName(_ mode: String) -> String? {
        switch mode {
        case manual: L10n.string("Manual")
        case "plan": L10n.string("Plan")
        case "acceptEdits": L10n.string("Accept edits")
        case "auto": L10n.string("Auto")
        case "dontAsk": L10n.string("Don't ask")
        case bypassPermissions: L10n.string("Bypass permissions")
        default: nil
        }
    }

    /// Whether the mode runs tools without asking at all, drawn like Codex's Full access.
    static func isElevated(_ mode: String?) -> Bool {
        mode == bypassPermissions
    }

    static let acceptEdits = "acceptEdits"
    static let auto = "auto"

    /// How much the mode lets the CLI do without the person, least first: plan reads only; the default
    /// asks and dontAsk refuses what is not allowed; acceptEdits takes file edits; auto lets its
    /// classifier take the rest; bypassPermissions takes everything. No mode is the default.
    static func freedom(_ mode: String?) -> Int {
        switch mode {
        case plan: 0
        case acceptEdits: 2
        case auto: 3
        case bypassPermissions: 4
        default: 1
        }
    }
}

/// The Claude Code tools whose permission request is a question or a plan the user answers
/// rather than a tool call to allow. Both are the CLI's own built-in tool names.
enum ClaudeAnswerableTool {
    static let askUserQuestion = "AskUserQuestion"
    static let exitPlanMode = "ExitPlanMode"
    static let names: Set<String> = [askUserQuestion, exitPlanMode]
}

/// A thinking block that holds what the model wrote between tool calls, not its reasoning. Claude
/// Opus 5.5, Sonnet 5.5 and Fable 5.1 send a note longer than a sentence or two that precedes a tool
/// call as a progress-update thinking block, whatever the thinking display; under the display Claude
/// Code asks for (`updates`, or `summarized`) its text is a summary of the note, and it can be empty.
/// The block's signature names its kind: `narration`, read as Claude Code 2.1.299 (`Gve`, which
/// fills `narration_block_indexes`) and the Claude app 3.1623.3 (its `narration_summary` items) read
/// it, the string in field 8 of field 1 of field 2 of the decoded signature. Anything else, a
/// signature that does not decode included, is reasoning.
enum ClaudeProgressUpdate {
    static func isProgressUpdate(_ block: JSONValue) -> Bool {
        guard block["type"]?.stringValue == "thinking", let signature = block["signature"]?.stringValue,
              let data = Data(base64Encoded: signature.padding(
                  toLength: (signature.count + 3) / 4 * 4, withPad: "=", startingAt: 0)) else { return false }
        let bytes = [UInt8](data)
        guard let outer = field(2, in: bytes[...]), let inner = field(1, in: outer),
              let kind = field(8, in: inner) else { return false }
        return String(decoding: kind, as: UTF8.self) == "narration"
    }

    /// The first length-delimited field `number` of a protocol buffer message.
    private static func field(_ number: UInt64, in bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8>? {
        var index = bytes.startIndex
        func varint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.endIndex, shift < 64 {
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while index < bytes.endIndex {
            guard let key = varint() else { return nil }
            switch key & 7 {
            case 0:
                guard varint() != nil else { return nil }
            case 1, 5:
                let size = key & 7 == 1 ? 8 : 4
                guard bytes.endIndex - index >= size else { return nil }
                index += size
            case 2:
                guard let length = varint(), length <= UInt64(bytes.endIndex - index) else { return nil }
                let value = bytes[index..<(index + Int(length))]
                index += Int(length)
                if key >> 3 == number { return value }
            default:
                return nil
            }
        }
        return nil
    }
}

/// Claude Code's own "don't ask again" offer on a `can_use_tool` request. The CLI lists the
/// permission updates that choice applies as `permission_suggestions` and applies them when the
/// allow answer returns them as `updatedPermissions`. Yardlet returns the list exactly as the CLI
/// sent it and never composes a rule of its own; it only reads where the updates would be kept so
/// the card can say so.
struct ClaudePermissionSuggestionOffer: Equatable, Sendable {
    /// The card's choice for applying the suggestions, beside allow once and deny.
    let action: PermissionRequestAction
    /// The CLI's `permission_suggestions`, untouched.
    let updates: [JSONValue]
}

enum ClaudePermissionSuggestions {
    /// The ids the card's choices carry. Allow and deny keep the ids the YHP route already uses
    /// for a plain answer, so both routes resolve them the same way.
    enum ActionID {
        static let allow = "allow"
        static let deny = "deny"
        static let allowForSession = "allow_session"
        static let allowAlways = "allow_always"
    }

    /// The CLI keeps these in memory for the running process only.
    private static let sessionDestinations: Set<String> = ["session", "cliArg"]
    /// The CLI writes these to a settings file, narrowest first.
    private static let settingsDestinations = ["localSettings", "projectSettings", "userSettings"]
    /// The modes the permission-mode selector already names. `bypassPermissions` is absent on
    /// purpose: the selector asks before switching to it, which a suggestion's choice would skip.
    private static let modeNames: [String: String] = [
        "default": "Manual",
        "plan": "Plan",
        "acceptEdits": "Accept edits",
        "auto": "Auto",
        "dontAsk": "Don't ask"
    ]

    /// The request's choices when it carried suggestions Yardlet can name honestly: allow once,
    /// the suggestions' own choice, and deny. Anything else returns no offer, and the card keeps
    /// its plain allow and deny.
    static func actions(for offer: ClaudePermissionSuggestionOffer) -> [PermissionRequestAction] {
        [
            PermissionRequestAction(
                id: ActionID.allow,
                label: L10n.string("Allow"),
                decision: .allow,
                kind: "allow_once"
            ),
            offer.action,
            PermissionRequestAction(
                id: ActionID.deny,
                label: L10n.string("Deny"),
                decision: .deny,
                kind: "reject_once"
            )
        ]
    }

    /// Reads the offer from the `can_use_tool` request. There is none when the request carried no
    /// suggestion, when the CLI asked hosts to omit the persistent choice
    /// (`suppress_always_allow_rule`), when a safety check requires manual approval
    /// (`classifier_approvable: false`, where the native dialog narrows the list itself), or when
    /// an update is one whose effect a single scope label would misstate.
    static func offer(from request: JSONValue) -> ClaudePermissionSuggestionOffer? {
        guard request["suppress_always_allow_rule"]?.boolValue != true,
              request["classifier_approvable"]?.boolValue != false,
              let updates = request["permission_suggestions"]?.arrayValue,
              !updates.isEmpty else { return nil }

        var destinations: Set<String> = []
        var sessionMode: String?
        for update in updates {
            guard let destination = update["destination"]?.stringValue,
                  sessionDestinations.contains(destination)
                    || settingsDestinations.contains(destination) else { return nil }
            switch update["type"]?.stringValue {
            case "addRules":
                // Only an allow rule is what "allow" says; a deny or ask rule is not this choice.
                guard update["behavior"]?.stringValue == "allow" else { return nil }
            case "addDirectories":
                break
            case "setMode":
                // A mode change is named for the session it lasts for. Written to a settings file
                // it would change every later session's default, which this choice does not say.
                guard sessionDestinations.contains(destination),
                      let mode = update["mode"]?.stringValue,
                      modeNames[mode] != nil,
                      sessionMode == nil || sessionMode == mode else { return nil }
                sessionMode = mode
            default:
                // Replacing or removing rules and directories is not an allow.
                return nil
            }
            destinations.insert(destination)
        }

        let settings = settingsDestinations.filter(destinations.contains)
        let action: PermissionRequestAction
        if settings.isEmpty {
            action = PermissionRequestAction(
                id: ActionID.allowForSession,
                label: sessionMode.flatMap { modeNames[$0] }.map {
                    L10n.format("Allow and switch to %@ mode for this session", L10n.string($0))
                } ?? L10n.string("Allow for session"),
                decision: .allow,
                kind: ActionID.allowForSession
            )
        } else {
            // A rule kept in a file and a mode switch kept for the session are two scopes one
            // label cannot name; the native dialog never offers them as one row either.
            guard sessionMode == nil else { return nil }
            let places = settings.map(placeName).joined(separator: ", ")
            action = PermissionRequestAction(
                id: ActionID.allowAlways,
                label: settings.contains("userSettings")
                    ? L10n.format("Always allow in every project (saved to %@)", places)
                    : L10n.format("Always allow in this project (saved to %@)", places),
                decision: .allow,
                kind: ActionID.allowAlways
            )
        }
        return ClaudePermissionSuggestionOffer(action: action, updates: updates)
    }

    /// Where each settings destination is kept, in the words the card shows. The project files are
    /// relative to the task's project; user settings follow the account's Claude Code home.
    private static func placeName(_ destination: String) -> String {
        switch destination {
        case "projectSettings": L10n.string("shared .claude/settings.json")
        case "userSettings": L10n.string("Claude Code user settings")
        default: ".claude/settings.local.json"
        }
    }
}

enum ClaudeProtocol {
    static func flagSettings(id: String, settings: JSONValue) -> JSONValue {
        controlRequest(id: id, request: .object(["subtype": .string("apply_flag_settings"), "settings": settings]))
    }

    static func settings(id: String) -> JSONValue {
        controlRequest(id: id, request: .object(["subtype": .string("get_settings")]))
    }

    /// The CLI's `/context` numbers. `summary` answers from the last response's usage and local
    /// estimates, without the token-count requests the full breakdown makes.
    static func contextUsage(id: String) -> JSONValue {
        controlRequest(id: id, request: .object([
            "subtype": .string("get_context_usage"), "detail": .string("summary")
        ]))
    }

    /// The `get_context_usage` answer as context-window usage: `totalTokens` of `rawMaxTokens`
    /// (`maxTokens` from a CLI that sends no raw size), the numbers the CLI's `/context` and the
    /// Claude app show, with the `/context` categories and the auto-compact threshold. The summary
    /// answer carries the same fields, estimated locally.
    static func contextUsage(from response: JSONValue) -> HarnessProtocolUsage? {
        guard let used = ClaudeEventProjector.unsigned(response["totalTokens"]),
              let window = ClaudeEventProjector.unsigned(response["rawMaxTokens"])
                ?? ClaudeEventProjector.unsigned(response["maxTokens"]),
              window > 0 else { return nil }
        let categories: [HarnessContextBreakdown.Category] = (response["categories"]?.arrayValue ?? []).compactMap { row in
            guard let name = row["name"]?.stringValue,
                  let tokens = ClaudeEventProjector.unsigned(row["tokens"]) else { return nil }
            let kind = row["kind"]?.stringValue.flatMap(HarnessContextBreakdown.Category.Kind.init(rawValue:))
                ?? (row["isDeferred"]?.boolValue == true ? .deferred : HarnessContextBreakdown.kind(forName: name))
            return HarnessContextBreakdown.Category(name: name, tokens: tokens, kind: kind)
        }
        return HarnessProtocolUsage(
            inputTokens: nil,
            cachedInputTokens: nil,
            outputTokens: nil,
            reasoningTokens: nil,
            totalCostUSD: nil,
            contextWindowTokens: window,
            contextUsedTokens: used,
            extensionValues: [:],
            contextBreakdown: HarnessContextBreakdown(
                categories: categories,
                windowTokens: window,
                autoCompactThresholdTokens: ClaudeEventProjector.unsigned(response["autoCompactThreshold"]),
                isAutoCompactEnabled: response["isAutoCompactEnabled"]?.boolValue ?? false,
                autoCompactSource: response["autocompactSource"]?.stringValue
            ),
            contextWindowModel: response["model"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    static func rewindFiles(id: String, userMessageID: String, dryRun: Bool) -> JSONValue {
        .object(["type": .string("control_request"), "request_id": .string(id), "request": .object([
            "subtype": .string("rewind_files"), "user_message_id": .string(userMessageID), "dry_run": .bool(dryRun)
        ])])
    }
    /// `promptSuggestions` asks this CLI process for a predicted next message after each turn, as the
    /// Claude app asks when its "Prompt suggestions" is on. Without it the request is the one every
    /// session always sent. The CLI still keeps the person's own `promptSuggestionEnabled: false`
    /// and `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION`; nothing is written to their settings.
    static func initialize(id: String, promptSuggestions: Bool = false) -> JSONValue {
        var request: [String: JSONValue] = [
            "subtype": .string("initialize"),
            "hooks": .null
        ]
        if promptSuggestions { request["promptSuggestions"] = .bool(true) }
        return controlRequest(id: id, request: .object(request))
    }

    /// `{"type":"prompt_suggestion","suggestion":…,"uuid":…,"session_id":…}`: the CLI's predicted
    /// next user message (2.1.295, 2.1.299), sent a moment after a turn's `result` when the session
    /// was started with `promptSuggestions`. It comes from a forked request on the session's model
    /// that reuses the conversation's prompt cache and writes nothing to the transcript.
    static func promptSuggestion(in value: JSONValue) -> String? {
        guard value["type"]?.stringValue == "prompt_suggestion",
              value["parent_tool_use_id"]?.stringValue?.isEmpty != false else { return nil }
        return NextMessageSuggestionText.normalized(value["suggestion"]?.stringValue)
    }

    /// A follow-up sent while a turn runs carries a `uuid` and a `priority` (`next` or `now`).
    /// The CLI queues it under that uuid, reports it with `command_lifecycle` frames and withdraws
    /// it with `cancel_async_message`. Without them the frame is the shape every turn always used.
    static func userMessage(
        _ prompt: String,
        sessionID: String,
        uuid: String? = nil,
        priority: HarnessFollowUpPriority? = nil
    ) -> JSONValue {
        followUp(.object([
            "type": .string("user"),
            "message": .object([
                "role": .string("user"),
                "content": .string(prompt)
            ]),
            "parent_tool_use_id": .null,
            "session_id": .string(sessionID)
        ]), uuid: uuid, priority: priority)
    }

    /// The Claude app's message after a quit or a lost connection cut a turn off
    /// (`RestartContinuation.claudeText(after:)`): the same `user` frame, stamped as one the host
    /// sent on its own (`origin: {kind: "auto-continuation"}`) rather than typed.
    static func restartContinuation(sessionID: String, after cut: TurnCut = .quit) -> JSONValue {
        .object([
            "type": .string("user"),
            "message": .object([
                "role": .string("user"),
                "content": .string(RestartContinuation.claudeText(after: cut))
            ]),
            "parent_tool_use_id": .null,
            "session_id": .string(sessionID),
            "origin": .object(["kind": .string(RestartContinuation.claudeOrigin)])
        ])
    }

    /// A turn that carries attachments uses the content-block form of the same `user` frame.
    /// With no image the frame stays byte-identical to the plain string content shape, so an
    /// ordinary text turn is unaffected by attachment support existing.
    static func userMessage(
        text: String,
        images: [HarnessUserInput.EncodedImage],
        sessionID: String,
        uuid: String? = nil,
        priority: HarnessFollowUpPriority? = nil
    ) -> JSONValue {
        guard !images.isEmpty else {
            return userMessage(text, sessionID: sessionID, uuid: uuid, priority: priority)
        }
        var blocks: [JSONValue] = []
        if !text.isEmpty {
            blocks.append(.object(["type": .string("text"), "text": .string(text)]))
        }
        for image in images {
            blocks.append(.object([
                "type": .string("image"),
                "source": .object([
                    "type": .string("base64"),
                    "media_type": .string(image.mimeType),
                    "data": .string(image.base64Data)
                ])
            ]))
        }
        return followUp(.object([
            "type": .string("user"),
            "message": .object([
                "role": .string("user"),
                "content": .array(blocks)
            ]),
            "parent_tool_use_id": .null,
            "session_id": .string(sessionID)
        ]), uuid: uuid, priority: priority)
    }

    /// A follow-up is something the user typed, so it is stamped `origin: {kind: "human"}`, as the
    /// CLI asks of a host wrapping keyboard input. Without it the CLI counts the message as
    /// unattributed, and its Send now stops the running turn instead of moving a running command
    /// to the background.
    private static func followUp(
        _ message: JSONValue,
        uuid: String?,
        priority: HarnessFollowUpPriority?
    ) -> JSONValue {
        guard var object = message.objectValue, uuid != nil || priority != nil else { return message }
        if let uuid { object["uuid"] = .string(uuid) }
        if let priority { object["priority"] = .string(priority.rawValue) }
        object["origin"] = .object(["kind": .string("human")])
        return .object(object)
    }

    /// Withdraws a queued `user` message by its uuid. The CLI answers `{"cancelled": false}` when it
    /// already took the message into a turn.
    static func cancelAsyncMessage(id: String, messageUUID: String) -> JSONValue {
        controlRequest(id: id, request: .object([
            "subtype": .string("cancel_async_message"), "message_uuid": .string(messageUUID)
        ]))
    }

    /// The `system/init` capability that says the CLI reads `send_now` on an `interrupt`.
    static let sendNowCapability = "interrupt_send_now_v1"

    /// Send now on a message the CLI holds: an `interrupt` that is not a Stop. The CLI moves what
    /// the running turn waits on to the background so the turn reads the message, or stops the
    /// turn when it cannot, and answers which in `send_now`. Nothing queued is cancelled.
    static func sendNow(id: String, messageUUID: String) -> JSONValue {
        controlRequest(id: id, request: .object([
            "subtype": .string("interrupt"), "send_now": .bool(true), "message_uuid": .string(messageUUID)
        ]))
    }

    /// The members of a main-thread `system/init` frame's `capabilities`.
    static func initCapabilities(in value: JSONValue) -> Set<String>? {
        guard value["type"]?.stringValue == "system", value["subtype"]?.stringValue == "init",
              value["parent_tool_use_id"]?.stringValue?.isEmpty != false,
              let members = value["capabilities"]?.arrayValue else { return nil }
        return Set(members.compactMap(\.stringValue))
    }

    /// `{"type":"command_lifecycle","command_uuid":…,"state":…}`: what became of a message the
    /// CLI queued under the uuid it was sent with. `queued` when it enters the queue, `started`
    /// when a turn takes it in (the running one at its next step, or a new one), then one of
    /// `completed`, `cancelled`, `discarded` or `refused`.
    static func commandLifecycle(in value: JSONValue) -> (messageID: String, state: String)? {
        guard value["type"]?.stringValue == "command_lifecycle",
              let messageID = value["command_uuid"]?.stringValue, !messageID.isEmpty,
              let state = value["state"]?.stringValue else { return nil }
        return (messageID, state)
    }

    /// The main conversation's model starting to answer: the first frame of every turn's response
    /// (`message_start` with partial messages on, otherwise the `assistant` message). A subagent's
    /// frames carry its `parent_tool_use_id` and are not the conversation's turn.
    static func startsMainResponse(_ value: JSONValue) -> Bool {
        guard value["parent_tool_use_id"]?.stringValue?.isEmpty != false else { return false }
        switch value["type"]?.stringValue {
        case "stream_event": return value["event"]?["type"]?.stringValue == "message_start"
        case "assistant": return true
        default: return false
        }
    }

    static func stopTask(id: String, taskID: String) -> JSONValue {
        controlRequest(id: id, request: .object([
            "subtype": .string("stop_task"), "task_id": .string(taskID)
        ]))
    }

    static func interrupt(id: String) -> JSONValue {
        controlRequest(
            id: id,
            request: .object(["subtype": .string("interrupt")])
        )
    }

    /// The `terminal_reason` values of a turn the CLI aborted: stopped while the model was
    /// answering, or while its tool calls ran. The CLI's own screen draws neither as an error.
    static let abortedTerminalReasons: Set<String> = ["aborted_streaming", "aborted_tools"]

    /// Whether a main `result` ends a turn the CLI aborted rather than one that failed. 2.1.295
    /// ends an aborted turn whose last message is not the model's answer (the interruption marker,
    /// or a tool call) as `subtype: "error_during_execution"`, `is_error: true`, no `result` text,
    /// `errors` holding its own `[ede_diagnostic] …` line, and `terminal_reason` `aborted_streaming`
    /// or `aborted_tools`. A turn that failed carries another reason, or none when it threw. A CLI
    /// from before `terminal_reason` sends none for an aborted turn either, so `allowingUnstatedReason`
    /// takes the subtype alone.
    static func endsAbortedTurn(_ value: JSONValue, allowingUnstatedReason: Bool) -> Bool {
        guard value["type"]?.stringValue == "result",
              value["parent_tool_use_id"]?.stringValue?.isEmpty != false,
              value["is_error"]?.boolValue == true,
              value["subtype"]?.stringValue == "error_during_execution" else { return false }
        guard let reason = value["terminal_reason"]?.stringValue else { return allowingUnstatedReason }
        return abortedTerminalReasons.contains(reason)
    }

    /// What cut a turn the CLI ended on its own connection error, read from its main `result`: an API
    /// error (`terminal_reason` "api_error", or none from an older CLI) that got no HTTP status (no
    /// `api_error_status`: the request never had an answer), whose words are one of the CLI's connection
    /// errors once its retries ran out. 2.1.299 words them in `xfe` ("Can't reach the API server —
    /// check your internet or DNS (ENOTFOUND)", "Connection dropped (ECONNRESET)", "Unable to connect to
    /// API. Check your internet connection", "Request timed out. …", "Connection lost while your computer
    /// was asleep", …); the Claude app 3.1623.3 continues the same set by the same words (`TZe`). An SSL
    /// certificate error is no lost connection. `.sleep` for the Mac's sleep, `.connection` otherwise;
    /// nil for anything else: a stop, a plan limit, a sign-in or server error, a failed tool.
    static func turnCut(ofResult value: JSONValue) -> TurnCut? {
        guard value["type"]?.stringValue == "result",
              value["parent_tool_use_id"]?.stringValue?.isEmpty != false,
              value["is_error"]?.boolValue == true,
              value["terminal_reason"].map({ $0.stringValue == "api_error" }) ?? true,
              value["api_error_status"] == nil || value["api_error_status"] == .null,
              let text = value["result"]?.stringValue else { return nil }
        if text.contains("while your computer was asleep") { return .sleep }
        if text.contains("Unable to connect to API:") || text.localizedCaseInsensitiveContains("certificate") { return nil }
        return connectionWordings.contains { text.contains($0) } ? .connection : nil
    }

    /// Whether a main `result` ends a turn on an error that the same request can get past later, read as
    /// the Claude app 4.29 reads it before offering Try again (`Wt`): an API error with no HTTP status
    /// (the request never had an answer), a rate limit (429) or a server error (5xx, 529 overloaded
    /// among them). A sign-in, permission or bad request (any other 4xx) and the turn limit
    /// (`error_max_turns`) are not; nor is a failure that was no API error. The status is the result's
    /// `api_error_status`, or else the one its words name ("API Error: 401", as the app reads them). A
    /// CLI from before `terminal_reason` names an API error without a status only by the connection
    /// words `turnCut` reads.
    static func endsTurnOnTransientError(_ value: JSONValue) -> Bool {
        guard value["type"]?.stringValue == "result",
              value["parent_tool_use_id"]?.stringValue?.isEmpty != false,
              value["is_error"]?.boolValue == true,
              value["subtype"]?.stringValue != "error_max_turns" else { return false }
        let words = value["result"]?.stringValue ?? ""
        if let status = value["api_error_status"]?.doubleValue
            ?? words.firstMatch(of: /API Error:? \(?(\d{3})\b/).flatMap({ Double($0.1) }) {
            return status == 429 || status >= 500
        }
        guard let reason = value["terminal_reason"]?.stringValue else { return turnCut(ofResult: value) != nil }
        return reason == "api_error"
    }

    /// The CLI's words for a request that could not reach the API or lost it (2.1.299 `xfe` and its
    /// fallback "Connection to the API was lost (CODE)"), and the error codes the Claude app's own
    /// list names.
    static let connectionWordings = [
        "Can't reach the API server", "No internet route", "Connection dropped", "Connection refused",
        "Unable to connect to API", "Connection to the API was lost", "Connection lost",
        "Connection closed before the response finished", "Request timed out", "socket connection was closed",
        "ECONNRESET", "ECONNREFUSED", "ETIMEDOUT", "ENOTFOUND", "EAI_AGAIN", "ENETUNREACH", "EHOSTUNREACH",
    ]

    static func setModel(id: String, model: String) -> JSONValue {
        controlRequest(
            id: id,
            request: .object(["subtype": .string("set_model"), "model": .string(model)])
        )
    }

    static func setPermissionMode(id: String, mode: String) -> JSONValue {
        controlRequest(
            id: id,
            request: .object([
                "subtype": .string("set_permission_mode"),
                "mode": .string(mode)
            ])
        )
    }

    /// Claude Code announces its permission mode as a `system` `status` message whenever the
    /// mode changes, whatever changed it: `set_permission_mode`, a session `setMode` returned with
    /// an approval, or the CLI itself. The message names Manual `default`, as the CLI's settings
    /// do; the selector keeps Manual as `manual`, which the CLI takes as the same mode, so the
    /// announced mode is returned in the selector's own value.
    static func announcedPermissionMode(in value: JSONValue) -> String? {
        guard value["type"]?.stringValue == "system",
              value["subtype"]?.stringValue == "status",
              let mode = value["permissionMode"]?.stringValue,
              !mode.isEmpty else { return nil }
        return selectorPermissionMode(mode)
    }

    /// The mode Claude Code reports in its `initialize` answer. 2.1.281 sends it as
    /// `current_permission_mode`, spelled as the announcement spells it; `permissionMode` is still
    /// read for an answer that used that key.
    static func initialPermissionMode(in response: JSONValue) -> String? {
        guard let mode = response["current_permission_mode"]?.stringValue
                ?? response["permissionMode"]?.stringValue,
              !mode.isEmpty else { return nil }
        return selectorPermissionMode(mode)
    }

    /// The model Claude Code reports in its `initialize` answer. Its schema names the field
    /// `current_model`, which 2.1.281 fills only for a Remote Control client, so a stream-json
    /// answer usually carries no model at all; `model` is still read for an answer that used it.
    static func initialModel(in response: JSONValue) -> String? {
        guard let model = response["current_model"]?.stringValue
                ?? response["model"]?.stringValue,
              !model.isEmpty else { return nil }
        return model
    }

    private static func selectorPermissionMode(_ mode: String) -> String {
        mode == "default" ? "manual" : mode
    }

    static func permissionResponse(
        requestID: String,
        decision: PermissionDecision,
        originalInput: JSONValue,
        answers: [PermissionQuestionAnswer] = [],
        denialMessage: String? = nil,
        updatedPermissions: [JSONValue]? = nil
    ) -> JSONValue {
        let response: JSONValue
        switch decision {
        case .allow:
            var allow: [String: JSONValue] = [
                "behavior": .string("allow"),
                "updatedInput": answers.isEmpty
                    ? originalInput
                    : answeredInput(originalInput, answers: answers)
            ]
            // The CLI's own suggestions, returned as it sent them, are what makes the choice
            // outlast this one call. A plain allow carries no such key at all.
            if let updatedPermissions {
                allow["updatedPermissions"] = .array(updatedPermissions)
            }
            response = .object(allow)
        case .deny:
            // The message is what the model is told. A reason the user wrote replaces the
            // standing wording; a blank one leaves that wording exactly as it was.
            let reason = denialMessage?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            response = .object([
                "behavior": .string("deny"),
                "message": .string(reason.isEmpty ? "User denied this action" : reason),
                "interrupt": .bool(false)
            ])
        }

        return .object([
            "type": .string("control_response"),
            "response": .object([
                "subtype": .string("success"),
                "request_id": .string(requestID),
                "response": response
            ])
        ])
    }

    /// Claude Code takes an `AskUserQuestion` answer as the tool's own input with an `answers`
    /// map added, keyed by the question text the request carried. A question the request marked
    /// `multiSelect` takes the picked labels as an array, which only that kind of question
    /// accepts; the CLI joins them itself and quotes any label that would otherwise be ambiguous.
    /// Every other question takes its single label as a string. An answer in the person's own
    /// words ("Other") goes where a label would: the string itself, or the array's last entry after
    /// the labels (the CLI takes one more entry than the question has options). Every other key is
    /// returned untouched, because the CLI rejects an answer that changes one.
    private static func answeredInput(
        _ originalInput: JSONValue,
        answers: [PermissionQuestionAnswer]
    ) -> JSONValue {
        var object = originalInput.objectValue ?? [:]
        // Whether a question takes several answers is the provider's own declaration, read back
        // from the request rather than restated by the card.
        let multiSelectQuestions = Set(
            (originalInput["questions"]?.arrayValue ?? []).compactMap { entry -> String? in
                guard entry["multiSelect"]?.boolValue == true else { return nil }
                return entry["question"]?.stringValue
            }
        )
        var map: [String: JSONValue] = [:]
        for answer in answers {
            let values = answer.values
            guard let first = values.first else { continue }
            map[answer.question] = multiSelectQuestions.contains(answer.question)
                ? .array(values.map(JSONValue.string))
                : .string(first)
        }
        object["answers"] = .object(map)
        return .object(object)
    }

    /// The answerable content a `can_use_tool` request carries, read from the tool's own input.
    /// Anything else stays a plain allow or deny.
    static func structure(toolName: String?, input: JSONValue) -> PermissionRequestStructure? {
        switch toolName {
        case ClaudeAnswerableTool.askUserQuestion:
            let questions = questions(from: input)
            return questions.isEmpty ? nil : .questions(questions)
        case ClaudeAnswerableTool.exitPlanMode:
            guard let plan = input["plan"]?.stringValue,
                  !plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .plan(plan)
        default:
            return nil
        }
    }

    /// The change a `can_use_tool` request would make, read from the built-in tool's own input:
    /// `Edit` and `MultiEdit` replace `old_string` with `new_string` (every occurrence with
    /// `replace_all`), `Write` sets a file's `content`, and `Bash` runs `command`, which its
    /// `description` explains. Other tools keep the request's own summary.
    static func preview(toolName: String?, input: JSONValue) -> PermissionRequestPreview? {
        switch toolName {
        case "Edit":
            guard let path = input["file_path"]?.stringValue, let edit = editPreview(input) else { return nil }
            return .edits(path: path, edits: [edit], omittedEditCount: 0)
        case "MultiEdit":
            guard let path = input["file_path"]?.stringValue else { return nil }
            let entries = input["edits"]?.arrayValue ?? []
            let edits = entries.prefix(PermissionRequestPreview.editLimit).compactMap(editPreview)
            guard !edits.isEmpty else { return nil }
            return .edits(
                path: path,
                edits: edits,
                omittedEditCount: max(0, entries.count - PermissionRequestPreview.editLimit)
            )
        case "Write":
            guard let path = input["file_path"]?.stringValue,
                  let content = input["content"]?.stringValue else { return nil }
            return .write(path: path, content: PermissionPreviewText(bounding: content))
        case "Bash":
            guard let command = input["command"]?.stringValue, !command.isEmpty else { return nil }
            let description = input["description"]?.stringValue
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            return .command(
                PermissionPreviewText(bounding: command),
                description: description?.isEmpty == false ? description : nil
            )
        default:
            return nil
        }
    }

    private static func editPreview(_ input: JSONValue) -> PermissionEditPreview? {
        guard let old = input["old_string"]?.stringValue,
              let new = input["new_string"]?.stringValue else { return nil }
        return PermissionEditPreview(
            oldText: PermissionPreviewText(bounding: old),
            newText: PermissionPreviewText(bounding: new),
            replacesAll: input["replace_all"]?.boolValue == true
        )
    }

    private static func questions(from input: JSONValue) -> [PermissionQuestion] {
        (input["questions"]?.arrayValue ?? []).compactMap { entry in
            guard let question = entry["question"]?.stringValue, !question.isEmpty else {
                return nil
            }
            let options = (entry["options"]?.arrayValue ?? []).compactMap { option in
                option["label"]?.stringValue.flatMap { label in
                    label.isEmpty ? nil : PermissionQuestionOption(
                        label: label,
                        description: option["description"]?.stringValue
                    )
                }
            }
            guard !options.isEmpty else { return nil }
            // Claude Code always takes the person's own answer besides the options ("Users will
            // always be able to select Other"), and an answer that leaves a question out.
            return PermissionQuestion(
                question: question,
                header: entry["header"]?.stringValue,
                options: options,
                allowsMultipleSelections: entry["multiSelect"]?.boolValue == true,
                allowsCustomAnswer: true
            )
        }
    }

    /// The questions an `AskUserQuestion` call asked and the answers its result recorded
    /// (`tool_use_result`, saved as `toolUseResult`): `answers` maps a question's text to what it
    /// was answered with, one string. A multiple-selection question's picks are joined with ", ",
    /// a pick that holds ", " or a quote written as a JSON string (the CLI's own join), which is
    /// read back the same way; a string the join cannot have written is one answer. A value that
    /// names an option is that option; anything else is the person's own words. The CLI's
    /// placeholders for a question with no pick are no answer. Nil when the result records no
    /// answers.
    static func answeredQuestions(input: JSONValue, result: JSONValue?) -> HarnessAnsweredQuestions? {
        guard let recorded = result?["answers"]?.objectValue else { return nil }
        let questions = questions(from: input)
        guard !questions.isEmpty else { return nil }
        let unanswered: Set<String> = ["", "(notes only)", "[No preference]"]
        let answers = questions.compactMap { question -> PermissionQuestionAnswer? in
            let values: [String]
            switch recorded[question.question] {
            case let .string(text)?:
                values = question.allowsMultipleSelections ? (splitJoinedAnswers(text) ?? [text]) : [text]
            case let .array(items)?:
                values = items.compactMap(\.stringValue)
            default:
                return nil
            }
            let labels = Set(question.options.map(\.label))
            let picked = question.options.map(\.label).filter(values.contains)
            let own = values.filter { !labels.contains($0) && !unanswered.contains($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard !picked.isEmpty || !own.isEmpty else { return nil }
            return PermissionQuestionAnswer(
                question: question.question, selectedLabels: picked,
                customAnswer: own.isEmpty ? nil : own.joined(separator: ", ")
            )
        }
        return HarnessAnsweredQuestions(questions: questions, answers: answers)
    }

    /// The CLI's join of a multiple-selection answer read back: entries split on ", ", an entry
    /// that starts with a quote read as a JSON string. Nil for a string the join cannot have written.
    static func splitJoinedAnswers(_ text: String) -> [String]? {
        var values: [String] = []
        var rest = Substring(text)
        while true {
            if rest.hasPrefix("\"") {
                var end: String.Index?
                var escaped = false
                var index = rest.index(after: rest.startIndex)
                while index < rest.endIndex {
                    let character = rest[index]
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        end = index
                        break
                    }
                    index = rest.index(after: index)
                }
                guard let end,
                      let data = String(rest[...end]).data(using: .utf8),
                      let value = try? JSONDecoder().decode(String.self, from: data) else { return nil }
                values.append(value)
                rest = rest[rest.index(after: end)...]
            } else {
                let separator = rest.range(of: ", ")
                let value = separator.map { rest[..<$0.lowerBound] } ?? rest
                if value.contains("\"") { return nil }
                values.append(String(value))
                rest = separator.map { rest[$0.lowerBound...] } ?? ""
            }
            if rest.isEmpty { break }
            guard rest.hasPrefix(", ") else { return nil }
            rest = rest.dropFirst(2)
            if rest.isEmpty { return nil }
        }
        return values
    }

    private static func controlRequest(id: String, request: JSONValue) -> JSONValue {
        .object([
            "type": .string("control_request"),
            "request_id": .string(id),
            "request": request
        ])
    }
}

struct ClaudeWireCodec: Sendable {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    func encodeLine(_ value: JSONValue) throws -> Data {
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    func decodeLine(_ data: Data) throws -> JSONValue {
        let trimmed = data.drop(while: { $0 == 0x0A || $0 == 0x0D })
        let value = try decoder.decode(JSONValue.self, from: Data(trimmed))
        guard value.objectValue != nil else {
            throw HarnessAdapterError.invalidProviderEvent("Claude frame must be an object")
        }
        return value
    }
}

struct ClaudeEventProjector: Sendable {
    /// `activities` carries the tool calls this session already started so a `tool_result`
    /// message can complete the card the `tool_use` block opened.
    func payloads(
        from value: JSONValue,
        activities: [String: HarnessActivity] = [:]
    ) -> [HarnessEventPayload] {
        // Nested assistant, user and partial frames belong to the Agent/Task call, never to the
        // main answer or its thinking block. Its result and task lifecycle carry the parent card.
        guard value["parent_tool_use_id"]?.stringValue?.isEmpty != false else { return [] }
        switch value["type"]?.stringValue {
        case "system":
            guard value["subtype"]?.stringValue == "local_command_output",
                  let content = value["content"]?.stringValue,
                  let id = value["uuid"]?.stringValue else { return [] }
            return [.activityCompleted(HarnessActivity(
                id: "claude-command:\(id)", kind: "command", title: L10n.string("Command output"), output: content
            ))]
        case "stream_event":
            guard value["event"]?["type"]?.stringValue == "content_block_delta" else { return [] }
            let delta = value["event"]?["delta"]
            if delta?["type"]?.stringValue == "thinking_delta",
               let thinking = delta?["thinking"]?.stringValue ?? delta?["text"]?.stringValue {
                return [.reasoningDelta(thinking)]
            }
            guard delta?["type"]?.stringValue == "text_delta",
                  let text = delta?["text"]?.stringValue else {
                return []
            }
            return [.assistantDelta(text)]

        case "assistant":
            let blocks = value["message"]?["content"]?.arrayValue ?? []
            let text = blocks.compactMap { block -> String? in
                guard block["type"]?.stringValue == "text" else { return nil }
                return block["text"]?.stringValue
            }.joined()
            func thinking(isProgressUpdate: Bool) -> String {
                blocks.compactMap { block -> String? in
                    guard block["type"]?.stringValue == "thinking",
                          ClaudeProgressUpdate.isProgressUpdate(block) == isProgressUpdate else { return nil }
                    return block["thinking"]?.stringValue ?? block["text"]?.stringValue
                }.joined()
            }
            var payloads: [HarnessEventPayload] = []
            let reasoning = thinking(isProgressUpdate: false)
            if !reasoning.isEmpty {
                payloads.append(.reasoningCompleted(reasoning))
            }
            // What the model wrote between tool calls, which the API sent as thinking (an empty one
            // is no more than the reasoning the API leaves out).
            let progress = thinking(isProgressUpdate: true)
            if !progress.isEmpty {
                payloads.append(.progressUpdateCompleted(progress))
            }
            if !text.isEmpty {
                payloads.append(.assistantMessageCompleted(text))
            }
            payloads.append(contentsOf: blocks.compactMap { block in
                guard block["type"]?.stringValue == "tool_use" else { return nil }
                return .activityStarted(toolUseActivity(block))
            })
            return payloads

        case "user":
            // Claude Code reports tool results as a `user` message. Without this the card the
            // `tool_use` block opened never completes and the turn ends marking it stopped.
            return (value["message"]?["content"]?.arrayValue ?? []).compactMap { block in
                guard block["type"]?.stringValue == "tool_result",
                      let toolUseID = block["tool_use_id"]?.stringValue else { return nil }
                return .activityCompleted(
                    toolResultActivity(block, toolUseID: toolUseID, started: activities[toolUseID])
                )
            }

        case "result":
            var payloads: [HarnessEventPayload] = []
            if let usage = usage(from: value) {
                payloads.append(.usageUpdated(usage))
            }
            if value["is_error"]?.boolValue == true {
                payloads.append(
                    .error(
                        message: value["result"]?.stringValue ?? "Claude reported an error",
                        recoverable: true,
                        transient: ClaudeProtocol.endsTurnOnTransientError(value) ? true : nil
                    )
                )
            }
            payloads.append(.turnCompleted)
            return payloads

        default:
            return []
        }
    }

    /// Claude reports the turn's token counts and its own cost on the `result` message. Only
    /// what the provider sent is published; the context window comes from `modelUsage` when the
    /// runtime included it and is otherwise left unknown.
    func usage(from value: JSONValue) -> HarnessProtocolUsage? {
        let usage = value["usage"]
        let inputTokens = unsigned(usage?["input_tokens"] ?? usage?["inputTokens"])
        let cachedInputTokens = unsigned(
            usage?["cache_read_input_tokens"] ?? usage?["cacheReadInputTokens"]
        )
        let outputTokens = unsigned(usage?["output_tokens"] ?? usage?["outputTokens"])
        let totalCostUSD = (value["total_cost_usd"] ?? value["totalCostUSD"])?.doubleValue
        let contextWindowTokens = value["modelUsage"]?.objectValue?.values
            .compactMap { unsigned($0["contextWindow"] ?? $0["context_window"]) }
            .max()
        guard inputTokens != nil || cachedInputTokens != nil || outputTokens != nil
                || totalCostUSD != nil else { return nil }
        return HarnessProtocolUsage(
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            reasoningTokens: nil,
            totalCostUSD: totalCostUSD,
            contextWindowTokens: contextWindowTokens,
            contextUsedTokens: nil,
            extensionValues: [:]
        )
    }

    private func unsigned(_ value: JSONValue?) -> UInt64? {
        Self.unsigned(value)
    }

    static func unsigned(_ value: JSONValue?) -> UInt64? {
        guard let number = value?.doubleValue,
              number.isFinite,
              number >= 0,
              number <= Double(UInt64.max) else { return nil }
        return UInt64(number)
    }

    /// `rate_limit_event.rate_limit_info` as 2.1.291 sends it: `status` (`allowed`,
    /// `allowed_warning` or `rejected`), the limiting window's `rateLimitType`, `utilization` as a
    /// fraction of it and `resetsAt` in epoch seconds, and `unifiedWindows`, every window the same
    /// response measured.
    static func rateLimit(from info: JSONValue?) -> HarnessRateLimit? {
        let status: HarnessRateLimit.Status
        switch info?["status"]?.stringValue {
        case "allowed": status = .allowed
        case "allowed_warning": status = .warning
        case "rejected": status = .rejected
        default: return nil
        }
        let window = rateLimitWindow(info?["rateLimitType"]?.stringValue)
        let measured = info?["unifiedWindows"]?.objectValue ?? [:]
        return HarnessRateLimit(
            status: status,
            window: window?.window,
            model: window?.model,
            resetsAt: epochDate(info?["resetsAt"]),
            usedFraction: fraction(info?["utilization"]),
            isUsingOverage: info?["isUsingOverage"]?.boolValue == true,
            windows: measured.keys.sorted().compactMap { key in
                guard let window = rateLimitWindow(key),
                      let used = fraction(measured[key]?["utilization"]) else { return nil }
                return HarnessRateLimit.WindowUsage(
                    window: window.window,
                    model: window.model,
                    usedFraction: used,
                    resetsAt: epochDate(measured[key]?["resetsAt"])
                )
            }
        )
    }

    /// The CLI's names for its plan limits: `five_hour` is the session limit, `seven_day` the
    /// weekly one, and each other weekly limit covers one model. The CLI itself calls
    /// `seven_day_overage_included` its Fable limit.
    private static func rateLimitWindow(
        _ type: String?
    ) -> (window: HarnessRateLimit.Window, model: String?)? {
        switch type {
        case "five_hour": return (.session, nil)
        case "seven_day": return (.weekly, nil)
        case "seven_day_opus": return (.model, "Opus")
        case "seven_day_sonnet": return (.model, "Sonnet")
        case "seven_day_overage_included": return (.model, "Fable")
        case "overage": return (.overage, nil)
        default: return nil
        }
    }

    private static func epochDate(_ value: JSONValue?) -> Date? {
        guard let seconds = value?.doubleValue, seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func fraction(_ value: JSONValue?) -> Double? {
        guard let number = value?.doubleValue, number.isFinite, number >= 0 else { return nil }
        return number
    }

    /// `system/api_retry`: the attempt about to be made, the retry budget, and why the request
    /// failed — the CLI's error category, or else the HTTP status, which is null for a request
    /// that never got a response.
    static func retry(from frame: JSONValue) -> HarnessProviderRetry? {
        guard let attempt = frame["attempt"]?.doubleValue, let budget = frame["max_retries"]?.doubleValue,
              attempt >= 1, budget >= 1, attempt <= 10_000, budget <= 10_000 else { return nil }
        let status = frame["error_status"]?.doubleValue
        let cause: HarnessProviderRetry.Cause = switch frame["error"]?.stringValue {
        case "overloaded": .overloaded
        case "rate_limit": .rateLimited
        case "server_error": .serverError
        default:
            switch status {
            case 529?: .overloaded
            case 429?: .rateLimited
            case let code? where code >= 500: .serverError
            case nil where frame["error_status"] == .null: .connection
            default: .other
            }
        }
        return HarnessProviderRetry(attempt: Int(attempt), maxRetries: Int(budget), cause: cause)
    }

    /// `system/compact_boundary`: the context sizes before and after the summary, when the CLI
    /// measured them.
    static func compactionBoundary(from frame: JSONValue) -> HarnessContextCompaction {
        HarnessContextCompaction(
            phase: .completed,
            tokensBefore: unsigned(frame["compact_metadata"]?["pre_tokens"]),
            tokensAfter: unsigned(frame["compact_metadata"]?["post_tokens"])
        )
    }

    private func toolUseActivity(_ block: JSONValue) -> HarnessActivity {
        let name = block["name"]?.stringValue ?? L10n.string("Claude activity")
        let input = block["input"]
        return HarnessActivity(
            id: block["id"]?.stringValue ?? UUID().uuidString,
            kind: name,
            title: name,
            detail: input?["command"]?.stringValue,
            input: toolInputText(input, tool: name),
            diff: Self.fileChange(toolName: name, input: input)
        )
    }

    /// The change an `Edit` or `Write` call makes, read from its own input: the text `Edit`
    /// replaces and its replacement, or the contents `Write` gives the file. The call's result
    /// later names where in the file the edit landed (`ClaudeSessionProjection`).
    static func fileChange(toolName: String, input: JSONValue?) -> HarnessActivityDiff? {
        guard let input, let path = input["file_path"]?.stringValue, !path.isEmpty else { return nil }
        switch toolName {
        case "Edit":
            guard let old = input["old_string"]?.stringValue, let new = input["new_string"]?.stringValue else {
                return nil
            }
            return HarnessActivityDiff(path: path, oldText: old, newText: new)
        case "Write":
            guard let content = input["content"]?.stringValue else { return nil }
            return HarnessActivityDiff(path: path, newText: content)
        default:
            return nil
        }
    }

    /// Claude Code's built-in tools whose arguments have a known shape: the field the card leads
    /// with, then the fields that follow it in reading order. Any other field comes after these.
    /// `ClaudeToolArguments` reads the text back to word the call's line.
    static let toolInputFields: [String: [String]] = [
        "Bash": ["command", "description", "timeout", "run_in_background"],
        "Read": ["file_path", "offset", "limit", "pages"],
        "Write": ["file_path", "content"],
        "Edit": ["file_path", "old_string", "new_string", "replace_all"],
        "MultiEdit": ["file_path", "edits"],
        "NotebookEdit": ["notebook_path", "cell_id", "edit_mode", "cell_type", "new_source"],
        "Glob": ["pattern", "path"],
        "Grep": ["pattern", "path", "glob", "type", "output_mode"],
        "WebFetch": ["url", "prompt"],
        "WebSearch": ["query", "allowed_domains", "blocked_domains"],
        "Agent": ["prompt", "subagent_type", "description", "model"],
        "Task": ["prompt", "subagent_type", "description", "model"]
    ]

    /// The call's arguments, each shown once: the leading field as it is, then every other field
    /// as `name: value`. A flag left off or an empty field adds nothing; a nested value keeps its
    /// JSON so nothing is hidden. A tool without a known shape keeps the whole object as JSON.
    private func toolInputText(_ input: JSONValue?, tool: String) -> String? {
        guard let input else { return nil }
        guard let fields = Self.toolInputFields[tool], let object = input.objectValue,
              let lead = object[fields[0]]?.stringValue, !lead.isEmpty else {
            return input.readableText
        }
        let names = fields.dropFirst().filter { object[$0] != nil }
            + object.keys.filter { !fields.contains($0) }.sorted()
        var blocks = [lead]
        var lines: [String] = []
        for name in names {
            guard let text = fieldText(object[name]) else { continue }
            if text.contains("\n") {
                if !lines.isEmpty { blocks.append(lines.joined(separator: "\n")) }
                lines = []
                blocks.append("\(name):\n\(text)")
            } else {
                lines.append("\(name): \(text)")
            }
        }
        if !lines.isEmpty { blocks.append(lines.joined(separator: "\n")) }
        return blocks.joined(separator: "\n\n")
    }

    private func fieldText(_ value: JSONValue?) -> String? {
        switch value {
        case nil, .null?, .bool(false)?:
            return nil
        case let .array(items)? where !items.isEmpty && items.allSatisfy({ $0.stringValue != nil }):
            return items.compactMap(\.stringValue).joined(separator: ", ")
        case let value?:
            return value.readableText
        }
    }

    private func toolResultActivity(
        _ block: JSONValue,
        toolUseID: String,
        started: HarnessActivity?
    ) -> HarnessActivity {
        HarnessActivity(
            id: toolUseID,
            kind: started?.kind ?? "tool_result",
            title: started?.title ?? L10n.string("Tool result"),
            detail: started?.detail,
            outcome: block["is_error"]?.boolValue == true ? .failed : nil,
            input: started?.input,
            output: block["content"]?.contentText,
            images: block["content"]?.contentImages
        )
    }
}

extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }
}
