import Foundation
import XCTest
@testable import NativeHarnessClient

/// The one composer's options per harness (plan M11, A6.3): which controls each harness's
/// composer offers, in whose words, and the path each choice takes. The frame is shared; the
/// choices, names and effects stay the provider's.
@MainActor
final class ComposerSessionOptionsProjectionTests: XCTestCase {
    private typealias Fixtures = ComposerUnificationFixtures

    /// One line per harness: what its task composer offers.
    private struct Row: Equatable, CustomStringConvertible {
        var placeholder: String
        var bashMode: Bool
        var submission: ComposerSubmissionPath
        var retention: ComposerDraftRetention
        var followUp: ComposerFollowUpOptions.Policy?
        var commands: String?
        var refreshes: Bool
        var mode: String?
        var permission: String?
        var skills: Int
        var contextUsed: UInt64?
        var model: String?

        var description: String {
            "\(placeholder) bash=\(bashMode) \(submission) \(retention) followUp=\(String(describing: followUp)) "
                + "commands=\(commands ?? "-") refreshes=\(refreshes) mode=\(mode ?? "-") "
                + "permission=\(permission ?? "-") skills=\(skills) context=\(contextUsed.map(String.init) ?? "-") "
                + "model=\(model ?? "-")"
        }
    }

    private func row(_ options: ComposerSessionOptions) -> Row {
        let commands = options.commands.map { commands -> String in
            let source = switch commands.source {
            case .codexCatalog: "codexCatalog"
            case let .provider(list): "provider(\(list.count))"
            }
            return "\(source)/\(commands.selection)/\(commands.preparation)"
                + (commands.preparesWhenListOpens ? "/prepareOnOpen" : "")
                + (commands.readsGitRepository ? "/git" : "")
                + (commands.readsCatalogWhenTypedDetached ? "/typedDetached" : "")
        }
        let mode = options.mode.map { mode -> String in
            switch mode {
            case .planIndicator: "planIndicator"
            case let .selector(selector, canChoose, _): "\(selector.name)=\(selector.currentValue) canChoose=\(canChoose)"
            }
        }
        let permission = options.permission.map { slot in
            "\(slot.title) \(slot.apply) choices=\(slot.selector?.choices.count ?? 0) canChoose=\(slot.canChoose)"
                + (slot.isElevated ? " elevated" : "") + (slot.hasPendingRequest ? " pending" : "")
        }
        let model = options.model.map { slot -> String in
            let apply = switch slot.apply {
            case .codexModel: "codexModel"
            case .codexRunLocation: "codexRunLocation"
            case .providerOption: "providerOption"
            }
            return "\(slot.menu.title) \(apply) canChoose=\(slot.menu.canChoose)"
        }
        return Row(placeholder: options.placeholder, bashMode: options.bashMode, submission: options.submission,
                   retention: options.draftRetention, followUp: options.followUp?.policy,
                   commands: commands, refreshes: options.refreshesStatusOnAttach, mode: mode, permission: permission,
                   skills: options.skills?.skills.count ?? 0, contextUsed: options.contextUsage?.contextUsedTokens,
                   model: model)
    }

    private var codexState: CodexCapabilityState {
        var state = CodexCapabilityState()
        state.modelCatalog = Fixtures.codexCatalog
        state.modes = [Fixtures.planPreset, Fixtures.defaultPreset]
        state.selectedModeID = Fixtures.planPreset.id
        state.selectedRunLocation = .approveForMe
        state.skills = Fixtures.skills + [CodexSkillSummary(name: "off", displayName: "Off", description: "",
                                                            enabled: false, scope: "user", path: "/skills/off")]
        return state
    }

    // MARK: - The table

    func testEachHarnessOffersItsOwnChoicesInTheSharedSlots() {
        let codex = ComposerSessionOptionsProjection.make(
            harness: .codex, session: Fixtures.session(.codex), codexCapabilities: codexState,
            providerCapabilities: nil, providerUsage: Fixtures.providerUsage, codexTokenUsage: Fixtures.codexTokenUsage,
            isAttached: false)
        let claude = ComposerSessionOptionsProjection.make(
            harness: .claudeCode, session: Fixtures.session(.claudeCode), providerCapabilities: Fixtures.claudeLiveCapabilities,
            providerUsage: Fixtures.providerUsage, isAttached: true)
        let claudeDetached = ComposerSessionOptionsProjection.make(
            harness: .claudeCode, session: Fixtures.session(.claudeCode, options: ["permissionMode": "acceptEdits"]),
            providerCapabilities: Fixtures.claudeDetachedCapabilities, providerUsage: nil, isAttached: false)
        let openCode = ComposerSessionOptionsProjection.make(
            harness: .openCode, session: Fixtures.session(.openCode), providerCapabilities: Fixtures.acpCapabilities,
            providerUsage: Fixtures.providerUsage, isAttached: true)
        let openCodeDetached = ComposerSessionOptionsProjection.make(
            harness: .openCode, session: Fixtures.session(.openCode), providerCapabilities: nil, providerUsage: nil,
            isAttached: false)
        let cursor = ComposerSessionOptionsProjection.make(
            harness: .cursorAgent, session: Fixtures.session(.cursorAgent), providerCapabilities: nil, providerUsage: nil,
            isAttached: false)

        let ask = { (name: String) in L10n.format("Ask %@…", name) }
        let expected: [(String, ComposerSessionOptions, Row)] = [
            ("Codex", codex, Row(
                placeholder: ask("Codex"), bashMode: false, submission: .codexDraft, retention: .codexBuiltinCommands,
                followUp: .codex, commands: "codexCatalog/runCodexCommand/codexCommands/prepareOnOpen/git",
                refreshes: true, mode: "planIndicator",
                permission: "\(CodexRunLocation.approveForMe.shortName) codexRunLocation choices=3 canChoose=true",
                skills: 1, contextUsed: 64_000,
                model: "GPT-6.1-Sol · \(L10n.string("High")) codexModel canChoose=true")),
            ("Claude Code", claude, Row(
                placeholder: ask("Claude Code"), bashMode: true, submission: .providerInput, retention: .claudeChatReset,
                followUp: .claudeCode, commands: "provider(0)/insert/providerSettings/typedDetached",
                refreshes: true, mode: nil,
                permission: "\(L10n.string("Accept edits")) providerOption choices=6 canChoose=true",
                skills: 0, contextUsed: 120_000, model: "Opus · High providerOption canChoose=true")),
            ("Claude Code before it connects", claudeDetached, Row(
                placeholder: ask("Claude Code"), bashMode: true, submission: .providerInput, retention: .claudeChatReset,
                followUp: .claudeCode, commands: "provider(0)/insert/providerSettings/typedDetached",
                refreshes: true, mode: nil,
                permission: "\(L10n.string("Accept edits")) providerOption choices=6 canChoose=false",
                skills: 0, contextUsed: nil, model: "Fable · \(L10n.string("Extra high")) providerOption canChoose=true")),
            ("OpenCode (ACP)", openCode, Row(
                placeholder: ask("OpenCode"), bashMode: false, submission: .providerInput, retention: .none,
                followUp: .afterTurn, commands: nil, refreshes: true, mode: "Mode=build canChoose=true",
                permission: "\(L10n.string("On request")) providerOption choices=0 canChoose=true",
                skills: 0, contextUsed: 120_000, model: "Sonnet · Medium providerOption canChoose=true")),
            ("OpenCode before it connects", openCodeDetached, Row(
                placeholder: ask("OpenCode"), bashMode: false, submission: .providerInput, retention: .none,
                followUp: .afterTurn, commands: nil, refreshes: true, mode: nil,
                permission: "\(L10n.string("On request")) providerOption choices=0 canChoose=false",
                skills: 0, contextUsed: nil, model: nil)),
            ("Cursor Agent, which asks nothing", cursor, Row(
                placeholder: ask("Cursor Agent"), bashMode: false, submission: .providerInput, retention: .none,
                followUp: .afterTurn, commands: nil, refreshes: true, mode: nil, permission: nil,
                skills: 0, contextUsed: nil, model: nil))
        ]
        for (name, options, row) in expected {
            XCTAssertEqual(self.row(options), row, name)
        }
    }

    func testWithoutATaskAProviderOffersNoSessionControlsButKeepsItsComposer() {
        let claude = ComposerSessionOptionsProjection.make(harness: .claudeCode, session: nil, providerCapabilities: nil,
                                                           providerUsage: Fixtures.providerUsage, isAttached: false)
        XCTAssertNil(claude.permission)
        XCTAssertNil(claude.mode)
        XCTAssertNil(claude.model)
        XCTAssertFalse(claude.refreshesStatusOnAttach)
        XCTAssertTrue(claude.bashMode)
        XCTAssertNotNil(claude.followUp)
        XCTAssertNotNil(claude.commands)
        XCTAssertEqual(claude.contextUsage, Fixtures.providerUsage, "The ring shows whatever usage the task reported")

        // Codex's own controls do not depend on the task record.
        let codex = ComposerSessionOptionsProjection.make(harness: .codex, session: nil, codexCapabilities: codexState,
                                                          providerCapabilities: nil, providerUsage: nil, isAttached: false)
        XCTAssertNotNil(codex.permission)
        XCTAssertNotNil(codex.model)
        XCTAssertTrue(codex.refreshesStatusOnAttach)
    }

    // MARK: - Permissions

    func testCodexPermissionsAreTheCodexAppsMenuAndFullAccessAsksFirst() throws {
        let slot = ComposerSessionOptionsProjection.codexPermission(.askForApproval, config: CodexPermissionConfig())
        let selector = try XCTUnwrap(slot.selector)
        XCTAssertEqual(selector.choices.map(\.value), ["askForApproval", "approveForMe", "dangerFullAccess"])
        XCTAssertEqual(selector.choices.map(\.name), [L10n.string("Ask for approval"), L10n.string("Approve for me"),
                                                      L10n.string("Full access")])
        XCTAssertEqual(selector.choices.map(\.description), [
            L10n.string("Always ask to edit external files and use the internet"),
            L10n.string("Only ask for actions detected as potentially unsafe"),
            L10n.string("Unrestricted access to the internet and any file on your computer")])
        XCTAssertEqual(slot.title, L10n.string("Ask for approval"))
        XCTAssertFalse(slot.isElevated)
        XCTAssertFalse(slot.hasPendingRequest, "Codex's requests are counted by its conversation model (M3)")
        XCTAssertNil(slot.help)
        XCTAssertEqual(slot.accessibilityHint, L10n.string("Change permissions"))
        XCTAssertEqual(Array(slot.confirmations.keys), ["dangerFullAccess"])
        XCTAssertEqual(slot.confirmations["dangerFullAccess"], .init(
            title: L10n.string("Turn on full access?"),
            message: L10n.string("Codex will be able to run commands, use the internet, and create and edit files anywhere on this computer without your permission. This comes with risks like loss or exposure of sensitive data and prompt injection."),
            confirm: L10n.string("Confirm")))
        XCTAssertEqual(slot.apply.choice(id: selector.id, value: "approveForMe"), .codexRunLocation(.approveForMe))
        XCTAssertNil(slot.apply.choice(id: selector.id, value: "bypass"))
        XCTAssertTrue(ComposerSessionOptionsProjection.codexPermission(.dangerFullAccess, config: .init()).isElevated)

        // config.toml turns Approve for me off and sets permissions none of the modes is: the app's Custom.
        let custom = ComposerSessionOptionsProjection.codexPermission(
            .custom, config: CodexPermissionConfig(offersApproveForMe: false, offersCustom: true))
        XCTAssertEqual(custom.selector?.choices.map(\.value), ["askForApproval", "dangerFullAccess", "custom"])
        XCTAssertEqual(custom.selector?.choices.last?.name, L10n.string("Custom (config.toml)"))
        XCTAssertEqual(custom.title, L10n.string("Custom"))
        // A task already on a choice the menu no longer offers keeps it listed; Read-only comes first.
        let readOnly = ComposerSessionOptionsProjection.codexPermission(
            .readOnly, config: CodexPermissionConfig(offersApproveForMe: false))
        XCTAssertEqual(readOnly.selector?.choices.map(\.value), ["readOnly", "askForApproval", "dangerFullAccess"])
        // In Korean, the app's words, with Yardlet's own for Full access and Custom.
        XCTAssertEqual(["Ask for approval", "Approve for me", "Full access", "Custom (config.toml)"]
            .map { L10n.string($0, languageCode: "ko") }, ["승인 요청", "나 대신 승인", "전체 접근", "사용자 지정 (config.toml)"])
        XCTAssertEqual(L10n.string("Only ask for actions detected as potentially unsafe", languageCode: "ko"),
                       "잠재적으로 위험한 것으로 감지된 작업에만 승인을 요청합니다")
    }

    func testAProviderPermissionsControlKeepsItsSelectorAndWording() throws {
        // Attached: Claude's own modes, applied as its selector's values.
        let attached = try XCTUnwrap(ComposerSessionOptionsProjection.make(
            harness: .claudeCode, session: Fixtures.session(.claudeCode), providerCapabilities: Fixtures.claudeLiveCapabilities,
            providerUsage: nil, isAttached: true).permission)
        XCTAssertEqual(attached.selector?.choices.map(\.value), ClaudePermissionMode.selectable)
        XCTAssertEqual(attached.selector?.description, "Controls how Claude Code asks before using tools.")
        XCTAssertEqual(attached.apply.choice(id: "permissionMode", value: "plan"),
                       .providerOption(id: "permissionMode", value: "plan"))
        XCTAssertEqual(Array(attached.confirmations.keys), [ClaudePermissionMode.bypassPermissions])
        XCTAssertNil(attached.explanation)
        XCTAssertFalse(attached.preparesBeforeOpening)
        XCTAssertEqual(attached.help, L10n.string("Show permission details"))

        // Detached with a live selector still around: opening reads the settings first, and the
        // choices wait for the task to resume.
        let detached = try XCTUnwrap(ComposerSessionOptionsProjection.make(
            harness: .claudeCode, session: Fixtures.session(.claudeCode), providerCapabilities: Fixtures.claudeLiveCapabilities,
            providerUsage: nil, isAttached: false).permission)
        XCTAssertTrue(detached.preparesBeforeOpening)
        XCTAssertFalse(detached.canChoose)

        // Before it connects, a Claude task that saved no mode names the one it launches in, as
        // the new-task screen and the connected selector do.
        let unsaved = try XCTUnwrap(ComposerSessionOptionsProjection.make(
            harness: .claudeCode, session: Fixtures.session(.claudeCode),
            providerCapabilities: Fixtures.claudeDetachedCapabilities, providerUsage: nil, isAttached: false).permission)
        XCTAssertEqual(unsaved.title, L10n.string("Manual"))

        // A pending request, with no selector: the control says so and points at the card.
        let waiting = Fixtures.session(.openCode, status: .waitingForApproval)
        let pending = try XCTUnwrap(ComposerSessionOptionsProjection.make(
            harness: .openCode, session: waiting, providerCapabilities: nil, providerUsage: nil, isAttached: true).permission)
        XCTAssertEqual(pending.title, L10n.string("Approval required"))
        XCTAssertTrue(pending.hasPendingRequest)
        XCTAssertEqual(pending.explanation, .init(
            text: L10n.string("Review the pending request card to approve or deny this action."), icon: "hand.raised.fill"))

        // A pending request card in the conversation counts the same way.
        let entry = TranscriptEntry(content: .permission(
            PermissionRequest(id: "r1", title: "Run", detail: nil, command: "ls"), state: .pending))
        let counted = try XCTUnwrap(ComposerSessionOptionsProjection.make(
            harness: .openCode, session: Fixtures.session(.openCode), providerCapabilities: nil, providerUsage: nil,
            entries: [entry], isAttached: true).permission)
        XCTAssertTrue(counted.hasPendingRequest)

        // An elevated provider policy is drawn in orange.
        var bypass = Fixtures.acpCapabilities
        bypass.selectors.append(ProviderCapabilitySelector(id: "approvalPolicy", name: "Approvals", description: nil,
            category: nil, currentValue: "full", choices: [.init(value: "ask", name: "Ask", description: nil),
                                                           .init(value: "full", name: "Full access", description: nil)]))
        XCTAssertEqual(ComposerSessionOptionsProjection.make(harness: .openCode, session: Fixtures.session(.openCode),
            providerCapabilities: bypass, providerUsage: nil, isAttached: true).permission?.isElevated, true)
    }

    // MARK: - Model and mode

    func testModelChoicesTakeEachProvidersOwnPath() throws {
        let codex = try XCTUnwrap(ComposerSessionOptionsProjection.make(
            harness: .codex, session: nil, codexCapabilities: codexState, providerCapabilities: nil, providerUsage: nil,
            isAttached: true).model)
        XCTAssertEqual(codex.apply.choice(id: "reasoningEffort", value: "low"),
                       .codexModel(CodexModelSelection(model: "gpt-6.1-sol", reasoningEffort: "low", serviceTier: "default")))
        XCTAssertEqual(codex.apply.choice(id: "fastMode", value: "on"),
                       .codexModel(CodexModelSelection(model: "gpt-6.1-sol", reasoningEffort: "high", serviceTier: "priority")))
        XCTAssertNil(codex.apply.choice(id: "model", value: "not-listed"), "Codex applies only models its catalog lists")
        XCTAssertEqual(codex.menu.speed?.name, "Fast")

        let claude = try XCTUnwrap(ComposerSessionOptionsProjection.make(
            harness: .claudeCode, session: Fixtures.session(.claudeCode), providerCapabilities: Fixtures.claudeLiveCapabilities,
            providerUsage: nil, isAttached: true).model)
        XCTAssertEqual(claude.apply.choice(id: "effort", value: "low"), .providerOption(id: "effort", value: "low"))

        let openCode = try XCTUnwrap(ComposerSessionOptionsProjection.make(
            harness: .openCode, session: Fixtures.session(.openCode), providerCapabilities: Fixtures.acpCapabilities,
            providerUsage: nil, isAttached: false))
        XCTAssertEqual(openCode.model?.menu.canChoose, false, "A detached agent's model list loads when the menu opens")
        guard case let .selector(mode, canChoose, apply)? = openCode.mode else { return XCTFail("The agent's mode selector") }
        XCTAssertEqual(mode.choices.map(\.name), ["Build", "Plan"])
        XCTAssertFalse(canChoose)
        XCTAssertEqual(apply.choice(id: "mode", value: "plan"), .providerOption(id: "mode", value: "plan"))

        // Codex shows Plan only while Plan mode is on.
        var defaultMode = codexState
        defaultMode.selectedModeID = Fixtures.defaultPreset.id
        XCTAssertNil(ComposerSessionOptionsProjection.make(harness: .codex, session: nil, codexCapabilities: defaultMode,
            providerCapabilities: nil, providerUsage: nil, isAttached: true).mode)
    }

    func testTheCodexContextRingCountsAsItsStatusPanelDoes() throws {
        let usage = try XCTUnwrap(ComposerSessionOptionsProjection.codexContextUsage(Fixtures.codexTokenUsage))
        XCTAssertEqual(usage.contextWindowTokens, 256_000)
        XCTAssertEqual(usage.contextUsedTokens, 64_000)
        XCTAssertEqual(ConversationSessionStatusProjection.contextFraction(usage), 0.25)
        XCTAssertNil(usage.inputTokens, "The ring's fill is the context; the token counts are its breakdowns")
        let words = CodexStatusProjection.Words()
        let status = CodexStatusProjection(threadID: nil, descendantThreadIDs: [], tokenUsage: Fixtures.codexTokenUsage,
                                           rateLimits: nil, isReadingRateLimits: true, selectedModel: nil).rows
        XCTAssertTrue(status.contains { row in
            if case let .value(_, text, _) = row { return text == words.format("%lld%% left", Int64(75)) }
            return false
        }, "/status reports the same 75% left")
        // D5: without a window the ring has no fill but still opens onto the turn's tokens, which the
        // Codex usage footer under the conversation used to list.
        let windowless = try XCTUnwrap(ComposerSessionOptionsProjection.codexContextUsage(
            CodexThreadTokenUsage(total: Fixtures.codexTokenUsage.total, last: Fixtures.codexTokenUsage.last,
                                  modelContextWindow: nil)))
        XCTAssertNil(ConversationSessionStatusProjection.contextFraction(windowless))
        XCTAssertNil(ComposerSessionOptionsProjection.codexContextUsage(nil))
    }

    /// D5: the ring's details list what the Codex usage footer did — the last turn and the thread's
    /// running total, every count with the cache hit share — and a provider's usage under "Usage".
    func testTheContextRingListsTheUsageFootersCounts() throws {
        let codex = ComposerSessionOptionsProjection.make(
            harness: .codex, session: Fixtures.session(.codex), codexCapabilities: codexState,
            providerCapabilities: nil, providerUsage: nil, codexTokenUsage: Fixtures.codexTokenUsage, isAttached: true)
        XCTAssertEqual(codex.usageBreakdowns.map(\.title), [L10n.string("Last turn"), L10n.string("Cumulative")])
        let last = try XCTUnwrap(codex.usageBreakdowns.first)
        XCTAssertEqual(last.total, UInt64(Fixtures.codexTokenUsage.last.totalTokens))
        XCTAssertEqual(last.counts.map(\.label), ["Input", "Cached input", "Cache write", "Output", "Reasoning"].map {
            L10n.string($0)
        })
        XCTAssertEqual(last.counts.first?.tokens, UInt64(Fixtures.codexTokenUsage.last.inputTokens))
        XCTAssertEqual(last.cacheHitFraction, Fixtures.codexTokenUsage.last.cacheHitFraction)
        XCTAssertEqual(codex.usageBreakdowns.last?.total, UInt64(Fixtures.codexTokenUsage.total.totalTokens))

        let claude = ComposerSessionOptionsProjection.make(
            harness: .claudeCode, session: Fixtures.session(.claudeCode), providerCapabilities: nil,
            providerUsage: Fixtures.providerUsage, isAttached: true)
        XCTAssertEqual(claude.usageBreakdowns.map(\.title), [L10n.string("Usage")])
        XCTAssertEqual(claude.usageBreakdowns.first?.total,
                       ConversationSessionStatusProjection.totalUsageTokens(Fixtures.providerUsage))
        let openCode = ComposerSessionOptionsProjection.make(
            harness: .openCode, session: Fixtures.session(.openCode), providerCapabilities: nil, providerUsage: nil,
            isAttached: false)
        XCTAssertTrue(openCode.usageBreakdowns.isEmpty)
    }

    // MARK: - Queue, sends and commands

    func testQueueChipsKeepEachProvidersWordingAndMoves() {
        let queue = [
            CodexQueuedSubmission(draft: CodexComposerDraft(inputs: [.text("sent")]), state: .sent),
            CodexQueuedSubmission(draft: CodexComposerDraft(inputs: [.text("pending")])),
            CodexQueuedSubmission(draft: CodexComposerDraft(inputs: [.text("failed")]), state: .failed, failureMessage: "No")
        ]
        let claude = (0..<3).map { ComposerQueueChip.make(policy: .claudeCode, queue: queue, at: $0, canSend: true) }
        // Each chip says where its message goes: delivered for Claude's next step, or when the turn
        // ends with "Send now", which leaves the turn running.
        XCTAssertEqual(claude.map(\.status), [L10n.string("Delivered · Claude reads it at its next step"),
                                              L10n.string("Send when this turn ends"), L10n.string("Failed")])
        XCTAssertEqual(claude.map { $0.send?.label }, [nil, L10n.string("Send now"), nil],
                       "A message Claude reads at its next step needs no send")
        XCTAssertEqual(claude[1].send?.help, L10n.string("Send now: Claude reads it at its next step without stopping"))
        XCTAssertEqual(claude[0].icon, "checkmark.circle", "a delivered message reads as delivered")
        XCTAssertEqual(claude.map(\.stopAndSend), [L10n.string("Stop and send"), L10n.string("Stop and send"), nil])
        XCTAssertEqual(claude.map(\.removeLabel), Array(repeating: L10n.string("Remove from queue"), count: 3))
        XCTAssertEqual(claude.map(\.canMoveUp), [false, false, true], "A sent message neither moves nor is passed")
        XCTAssertEqual(claude.map(\.canMoveDown), [false, true, false])
        XCTAssertEqual(claude[2].help, "No")

        let codex = (0..<3).map { ComposerQueueChip.make(policy: .codex, queue: queue, at: $0, canSend: true) }
        XCTAssertEqual(codex.map(\.status), [L10n.string("Send when this turn ends"), L10n.string("Send when this turn ends"),
                                             L10n.string("Failed")])
        XCTAssertEqual(codex.map { $0.send?.label }, [L10n.string("Send now"), L10n.string("Send now"), nil])
        XCTAssertEqual(codex[1].send?.help, L10n.string("Send now: add it to the running task without stopping it"))
        XCTAssertEqual(codex.map(\.stopAndSend), [nil, nil, nil], "Codex's Steer never stops the turn")

        let afterTurn = ComposerQueueChip.make(policy: .afterTurn, queue: queue, at: 1, canSend: true)
        XCTAssertEqual(afterTurn.status, L10n.string("Send when this turn ends"))
        XCTAssertNil(afterTurn.send, "It goes when the turn ends, on its own")
        XCTAssertNil(afterTurn.stopAndSend)
        XCTAssertEqual(codex.map(\.removeLabel), Array(repeating: L10n.string("Delete queued message"), count: 3))
        XCTAssertEqual(codex.map(\.canMoveUp), [false, true, true])
        XCTAssertEqual(codex[2].help, "No", "A failed Codex message says why too")
        XCTAssertNil(ComposerQueueChip.make(policy: .codex, queue: queue, at: 1, canSend: false).send)

        let codexOptions = ComposerSessionOptionsProjection.make(harness: .codex, session: nil, providerCapabilities: nil,
                                                                 providerUsage: nil, isAttached: true)
        let claudeOptions = ComposerSessionOptionsProjection.make(harness: .claudeCode, session: nil,
                                                                  providerCapabilities: nil, providerUsage: nil, isAttached: true)
        XCTAssertEqual(codexOptions.followUp?.delivery, .codexDraft)
        let add = L10n.string("Add to the running task"), next = L10n.string("Deliver at the next step")
        let after = L10n.string("Send when this turn ends")
        XCTAssertEqual(codexOptions.followUp?.runningPlaceholder(preferred: .steer), L10n.format("↩ %@ · ⌘↩ %@", add, after))
        XCTAssertEqual(codexOptions.followUp?.runningPlaceholder(preferred: .queue), L10n.format("↩ %@ · ⌘↩ %@", after, add))
        XCTAssertEqual(codexOptions.followUp?.returnHint(preferred: .steer),
                       L10n.format("Return: %@. Command-Return: %@.", add, after))
        XCTAssertEqual(claudeOptions.followUp?.delivery, .providerInput)
        XCTAssertEqual(claudeOptions.followUp?.runningPlaceholder(preferred: .steer), L10n.format("↩ %@ · ⌘↩ %@", next, after))
        XCTAssertEqual(claudeOptions.followUp?.runningPlaceholder(preferred: .queue), L10n.format("↩ %@ · ⌘↩ %@", after, next))

        // A harness that takes nothing while its turn runs keeps what is sent for the next turn.
        let antigravity = ComposerSessionOptionsProjection.make(harness: .antigravityCLI, session: nil,
                                                                providerCapabilities: nil, providerUsage: nil, isAttached: true)
        XCTAssertEqual(antigravity.followUp?.policy, .afterTurn)
        XCTAssertEqual(antigravity.followUp?.delivery, .providerInput)
        XCTAssertEqual(antigravity.followUp?.runningPlaceholder(preferred: .steer), L10n.format("↩ %@", after))
        XCTAssertNil(antigravity.followUp?.alternateAction(preferred: .steer, canSteer: true),
                     "⌘Return queues as Return does")
        XCTAssertEqual(claudeOptions.followUp?.alternateAction(preferred: .steer, canSteer: true), .queue)
    }

    func testADraftStaysOnlyForTheCommandsThatRunFromIt() {
        XCTAssertTrue(ComposerDraftRetention.codexBuiltinCommands.keepsDraft(afterSending: "/compact"))
        XCTAssertTrue(ComposerDraftRetention.codexBuiltinCommands.keepsDraft(afterSending: " /review main"))
        XCTAssertFalse(ComposerDraftRetention.codexBuiltinCommands.keepsDraft(afterSending: "/clear"))
        XCTAssertTrue(ComposerDraftRetention.claudeChatReset.keepsDraft(afterSending: "/clear"))
        XCTAssertFalse(ComposerDraftRetention.claudeChatReset.keepsDraft(afterSending: "/compact"))
        XCTAssertFalse(ComposerDraftRetention.none.keepsDraft(afterSending: "/clear"))
    }

    func testCommandListsComeFromEachProvidersOwnSource() {
        var state = ProviderCapabilityState()
        state.composerCommands = [ProviderComposerCommand(name: "review", description: "Review", argumentHint: "", builtin: false)]
        state.errors = ["Claude Code could not list its commands"]
        let claude = ComposerSessionOptionsProjection.make(harness: .claudeCode, session: nil, providerCapabilities: state,
                                                           providerUsage: nil, isAttached: true)
        XCTAssertEqual(claude.commands?.source, .provider(state.composerCommands))
        XCTAssertEqual(claude.commands?.error, "Claude Code could not list its commands")
        let codex = ComposerSessionOptionsProjection.make(harness: .codex, session: nil, providerCapabilities: state,
                                                          providerUsage: nil, isAttached: true)
        XCTAssertEqual(codex.commands?.source, .codexCatalog)
        XCTAssertNil(codex.commands?.error, "Codex's list is its own catalog, not the provider state's")
    }

    // MARK: - Wiring

    func testTheWindowsWiringAgreesWithTheComposerForEveryHarness() {
        for descriptor in HarnessCatalog.builtIns {
            let harness = descriptor.id
            let wiring = ComposerSessionOptionsProjection.wiring(for: harness)
            let options = ComposerSessionOptionsProjection.make(harness: harness, session: Fixtures.session(harness),
                providerCapabilities: nil, providerUsage: nil, isAttached: true)
            XCTAssertEqual(wiring.submission, options.submission, harness.rawValue)
            XCTAssertEqual(wiring.followUpQueue, options.followUp?.policy, harness.rawValue)
            XCTAssertEqual(wiring.runsShellCommands, options.bashMode, harness.rawValue)
            XCTAssertEqual(wiring.runsCodexCommands, options.commands?.selection == .runCodexCommand, harness.rawValue)
            XCTAssertEqual(wiring.settings == .codexModels, options.model?.apply != .providerOption && options.model != nil,
                           harness.rawValue)
        }
    }

    // MARK: - The new-task composer

    func testTheNewTaskComposerOffersWhatEachHarnessCanStartWith() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "composer-options-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let catalogs = HarnessModelCatalogStore(locations: HarnessModelSettingsLocations(
            claudeConfigDirectory: root.appending(path: "claude"), codexHome: root.appending(path: "codex"),
            codexYardletHome: root.appending(path: "y")), environment: [:])
        catalogs.recordClaude(ModelVisibilityFixtures.claudeModels, for: nil)
        catalogs.recordCodex(Fixtures.codexCatalog.models, for: nil)

        let claude = ComposerSessionOptionsProjection.newTask(harness: .claudeCode, choice: nil, catalogs: catalogs,
                                                             connection: nil, workspaceURL: nil)
        let permission = try XCTUnwrap(claude.permission, "Claude Code launches in a chosen permission mode")
        XCTAssertEqual(permission.title, L10n.string("Manual"))
        XCTAssertEqual(permission.selector?.choices.map(\.value), ClaudePermissionMode.selectable)
        XCTAssertEqual(permission.selector?.choices.map(\.name),
                       ClaudePermissionMode.selectable.compactMap(ClaudePermissionMode.displayName))
        XCTAssertTrue(permission.canChoose)
        XCTAssertEqual(permission.apply.choice(id: "permissionMode", value: "plan"),
                       .providerOption(id: "permissionMode", value: "plan"))
        XCTAssertNotNil(claude.model)
        XCTAssertNotNil(claude.commands, "The home list reads Claude's commands")
        XCTAssertEqual(claude.submission, .providerInput)
        XCTAssertNil(claude.followUp)

        let chosen = ComposerSessionOptionsProjection.newTask(harness: .claudeCode,
            choice: NewTaskModelChoice(model: nil, permissionMode: "plan"), catalogs: catalogs, connection: nil, workspaceURL: nil)
        XCTAssertEqual(chosen.permission?.title, L10n.string("Plan"))

        // Codex's permission, with the same control, choices and Full access question as a task's composer;
        // the thread starts with it.
        let codex = ComposerSessionOptionsProjection.newTask(harness: .codex, choice: nil, catalogs: catalogs,
                                                            connection: nil, workspaceURL: nil)
        let codexPermission = try XCTUnwrap(codex.permission)
        XCTAssertEqual(codexPermission, ComposerSessionOptionsProjection.codexPermission(.askForApproval, config: .init()))
        XCTAssertEqual(codexPermission.title, L10n.string("Ask for approval"))
        XCTAssertEqual(codexPermission.apply.choice(id: NewTaskModelProjection.codexPermissionID, value: "dangerFullAccess"),
                       .codexRunLocation(.dangerFullAccess))
        let fullAccess = ComposerSessionOptionsProjection.newTask(harness: .codex,
            choice: NewTaskModelChoice(model: nil, permissionMode: "dangerFullAccess"), catalogs: catalogs, connection: nil,
            workspaceURL: nil)
        XCTAssertEqual(fullAccess.permission?.title, L10n.string("Full access"))
        XCTAssertEqual(fullAccess.permission?.isElevated, true)
        XCTAssertNil(codex.commands)
        XCTAssertNotNil(codex.model)
        XCTAssertEqual(codex.submission, .codexDraft)

        // An agent whose models and modes exist only inside a session offers nothing before one.
        let openCode = ComposerSessionOptionsProjection.newTask(harness: .openCode, choice: nil, catalogs: catalogs,
                                                               connection: nil, workspaceURL: nil)
        XCTAssertNil(openCode.model)
        XCTAssertNil(openCode.permission)
        XCTAssertNil(openCode.mode)
        XCTAssertNil(openCode.contextUsage)
    }

    func testANewTasksPermissionModeIsKeptWithItsModelChoiceAndStartsTheTask() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "composer-options-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let catalogs = HarnessModelCatalogStore(locations: HarnessModelSettingsLocations(
            claudeConfigDirectory: root.appending(path: "claude"), codexHome: root.appending(path: "codex"),
            codexYardletHome: root.appending(path: "y")), environment: [:])
        catalogs.recordClaude(ModelVisibilityFixtures.claudeModels, for: nil)

        var choice = try XCTUnwrap(NewTaskModelProjection.choosing("permissionMode", value: "acceptEdits",
            harness: .claudeCode, choice: nil, catalogs: catalogs, connection: nil, workspaceURL: nil))
        XCTAssertEqual(choice, NewTaskModelChoice(model: nil, permissionMode: "acceptEdits"))
        choice = try XCTUnwrap(NewTaskModelProjection.choosing("model", value: "opus", harness: .claudeCode,
            choice: choice, catalogs: catalogs, connection: nil, workspaceURL: nil))
        XCTAssertEqual(choice.permissionMode, "acceptEdits", "Choosing a model keeps the permission mode")
        XCTAssertNil(NewTaskModelProjection.choosing("permissionMode", value: "bypass", harness: .claudeCode,
            choice: choice, catalogs: catalogs, connection: nil, workspaceURL: nil), "Only the selector's own modes")
        XCTAssertNil(NewTaskModelProjection.choosing("permissionMode", value: "plan", harness: .codex,
            choice: nil, catalogs: catalogs, connection: nil, workspaceURL: nil))
        XCTAssertEqual(choice.providerOptions(for: .claudeCode), ["model": "opus", "permissionMode": "acceptEdits"])

        // Codex's permission is kept the same way, under the key its task keeps it.
        catalogs.recordCodex(Fixtures.codexCatalog.models, for: nil)
        var codex = try XCTUnwrap(NewTaskModelProjection.choosing(.codexRunLocation(.dangerFullAccess), harness: .codex,
            choice: nil, catalogs: catalogs, connection: nil, workspaceURL: nil))
        XCTAssertEqual(codex, NewTaskModelChoice(model: nil, permissionMode: "dangerFullAccess"))
        XCTAssertEqual(codex.providerOptions(for: .codex), [CodexRunLocation.storageKey: "dangerFullAccess"])
        let model = try XCTUnwrap(Fixtures.codexCatalog.models.first)
        codex = try XCTUnwrap(NewTaskModelProjection.choosing("model", value: model.model, harness: .codex,
            choice: codex, catalogs: catalogs, connection: nil, workspaceURL: nil))
        XCTAssertEqual(codex.model, model.model)
        XCTAssertEqual(codex.permissionMode, "dangerFullAccess", "Choosing a model keeps the permission")
        XCTAssertNil(NewTaskModelProjection.choosing(.codexRunLocation(.askForApproval), harness: .codex, choice: codex,
            catalogs: catalogs, connection: nil, workspaceURL: nil)?.permissionMode, "Ask for approval keeps none")
        XCTAssertNil(NewTaskModelProjection.choosing(.codexRunLocation(.readOnly), harness: .claudeCode, choice: nil,
            catalogs: catalogs, connection: nil, workspaceURL: nil))

        // A draft saved before the field existed still decodes, with no mode.
        let old = try JSONDecoder().decode(NewTaskModelChoice.self, from: Data(#"{"model":"opus","effort":"high"}"#.utf8))
        XCTAssertEqual(old, NewTaskModelChoice(model: "opus", effort: "high"))
        let draft = NewTaskDraft()
        draft.modelChoices[.claudeCode] = choice
        draft.modelChoices[.codex] = codex
        let restored = NewTaskDraft()
        restored.apply(try JSONDecoder().decode(HomeDraftSnapshot.self, from: JSONEncoder().encode(draft.snapshot)))
        XCTAssertEqual(restored.modelChoices[.claudeCode]?.permissionMode, "acceptEdits")
        XCTAssertEqual(restored.modelChoices[.codex], codex, "Remembered per harness, as model and effort are")
    }

    func testANewClaudeTaskLaunchesInTheChosenPermissionMode() async throws {
        let fixture = try await ClaudeFixture.make(settings: #"{"model":"fable"}"#, createsSession: false, in: self)
        let draft = NewTaskDraft()
        draft.text = "Plan the migration"
        draft.workspaceURL = fixture.root
        draft.harness = .claudeCode
        fixture.model.modelCatalogs.recordClaude(ModelVisibilityFixtures.claudeModels, for: fixture.connection)
        draft.modelChoices[.claudeCode] = NewTaskModelProjection.choosing("permissionMode", value: "plan",
            harness: .claudeCode, choice: nil, catalogs: fixture.model.modelCatalogs, connection: fixture.connection,
            workspaceURL: fixture.root)

        let submission = try XCTUnwrap(draft.beginSubmission(runtimeURL: fixture.cli, connection: fixture.connection))
        XCTAssertEqual(submission.providerOptions, ["permissionMode": "plan"])
        let created = try await fixture.model.createTask(submission)
        let task = try XCTUnwrap(created)
        XCTAssertEqual(task.providerOptions["permissionMode"], "plan")
        let transport = try XCTUnwrap(fixture.transports.all.first)
        let launched = await transport.configuration
        let configuration = try XCTUnwrap(launched)
        let arguments = ClaudeProcessTransport.arguments(for: configuration)
        let flag = try XCTUnwrap(arguments.firstIndex(of: "--permission-mode"))
        XCTAssertEqual(arguments[flag + 1], "plan")
        // The fake CLI does not report its mode in `initialize` as Claude Code does, so the task's
        // restore may ask again; it never asks for another mode.
        let requests = await transport.requestedValues
        XCTAssertTrue(requests.filter { $0["request"]?["subtype"] == .string("set_permission_mode") }
            .allSatisfy { $0["request"]?["mode"] == .string("plan") })
        let sent = await transport.sentValues
        XCTAssertEqual(sent.last?["message"]?["content"]?.stringValue, "Plan the migration")
    }
}
