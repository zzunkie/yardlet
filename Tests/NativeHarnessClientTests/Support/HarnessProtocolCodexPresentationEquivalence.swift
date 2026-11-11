import Foundation
@testable import NativeHarnessClient

/// Read-only shadow gate used before routing Codex presentation through YHP.
///
/// The native reducer remains authoritative. A migration candidate reads the
/// typed `yardlet.codex` snapshot alongside it and must produce no differences.
enum HarnessProtocolCodexPresentationEquivalence {
    static func differences(
        native: CodexTaskState,
        projected: HarnessProtocolCodexPresentationSnapshot,
        localSessionID: UUID
    ) -> [String] {
        var differences: [String] = []
        compare(projected.localSessionID, localSessionID, "localSessionID", &differences)
        compare(projected.activeTurnID, native.activeTurnID, "activeTurnID", &differences)
        compare(
            projected.lastAppliedSequence,
            native.lastAppliedSequence,
            "lastAppliedSequence",
            &differences
        )
        compareThread(native.thread, projected.thread, path: "thread", into: &differences)
        compareApprovals(native.approvalsByID, projected.approvals, into: &differences)
        compareServerRequests(
            native.serverRequestsByID,
            projected.serverRequests,
            into: &differences
        )
        return differences
    }

    private static func compareApprovals(
        _ native: [String: CodexApprovalState],
        _ projected: [HarnessProtocolCodexApproval],
        into differences: inout [String]
    ) {
        let nativeValues = native.values.sorted { $0.id < $1.id }
        compare(projected.count, nativeValues.count, "approvals.count", &differences)
        for (index, pair) in zip(nativeValues, projected).enumerated() {
            let path = "approvals[\(index)]"
            compare(pair.1.id, pair.0.id, "\(path).id", &differences)
            compare(pair.1.method, pair.0.method, "\(path).method", &differences)
            compare(pair.1.threadID, pair.0.threadID, "\(path).threadID", &differences)
            compare(pair.1.turnID, pair.0.turnID, "\(path).turnID", &differences)
            compare(pair.1.itemID, pair.0.itemID, "\(path).itemID", &differences)
            let nativeResolution: (String, JSONValue?) = switch pair.0.resolution {
            case .pending: ("pending", nil)
            case let .resolved(result): ("resolved", result)
            }
            compare(pair.1.resolution, nativeResolution.0, "\(path).resolution", &differences)
            compare(pair.1.result, nativeResolution.1, "\(path).result", &differences)
            compare(pair.1.raw, pair.0.raw, "\(path).raw", &differences)
        }
    }

    private static func compareThread(
        _ native: CodexThreadState?,
        _ projected: HarnessProtocolCodexThread?,
        path: String,
        into differences: inout [String]
    ) {
        guard let native, let projected else {
            if (native == nil) != (projected == nil) { differences.append(path) }
            return
        }
        compare(projected.id, native.id, "\(path).id", &differences)
        compare(projected.sessionID, native.sessionID, "\(path).sessionID", &differences)
        compare(projected.name, native.name, "\(path).name", &differences)
        compare(projected.preview, native.preview, "\(path).preview", &differences)
        compare(
            projected.workspacePath,
            native.workspacePath,
            "\(path).workspacePath",
            &differences
        )
        compare(projected.cliVersion, native.cliVersion, "\(path).cliVersion", &differences)
        compare(
            projected.modelProvider,
            native.modelProvider,
            "\(path).modelProvider",
            &differences
        )
        compare(
            projected.parentThreadID,
            native.parentThreadID,
            "\(path).parentThreadID",
            &differences
        )
        compare(
            projected.forkedFromID,
            native.forkedFromID,
            "\(path).forkedFromID",
            &differences
        )
        let nativeStatus = threadStatus(native.status)
        compare(projected.status, nativeStatus.status, "\(path).status", &differences)
        compare(
            projected.activeFlags,
            nativeStatus.activeFlags,
            "\(path).activeFlags",
            &differences
        )
        compare(
            projected.canAcceptDirectInput,
            native.canAcceptDirectInput,
            "\(path).canAcceptDirectInput",
            &differences
        )
        compare(projected.createdAt, native.createdAt, "\(path).createdAt", &differences)
        compare(projected.updatedAt, native.updatedAt, "\(path).updatedAt", &differences)
        compare(
            projected.turnsNextCursor,
            native.turnsNextCursor,
            "\(path).turnsNextCursor",
            &differences
        )
        compare(
            projected.turnsBackwardsCursor,
            native.turnsBackwardsCursor,
            "\(path).turnsBackwardsCursor",
            &differences
        )
        compare(
            projected.itemsBackwardsCursor,
            native.itemsBackwardsCursor,
            "\(path).itemsBackwardsCursor",
            &differences
        )
        compare(projected.raw, native.raw, "\(path).raw", &differences)
        compare(
            projected.turns.count,
            native.turns.count,
            "\(path).turns.count",
            &differences
        )
        for (index, pair) in zip(native.turns, projected.turns).enumerated() {
            compareTurn(
                pair.0,
                pair.1,
                path: "\(path).turns[\(index)]",
                into: &differences
            )
        }
    }

    private static func compareTurn(
        _ native: CodexTurnState,
        _ projected: HarnessProtocolCodexTurn,
        path: String,
        into differences: inout [String]
    ) {
        compare(projected.id, native.id, "\(path).id", &differences)
        compare(projected.status, turnStatus(native.status), "\(path).status", &differences)
        compare(projected.startedAt, native.startedAt, "\(path).startedAt", &differences)
        compare(projected.completedAt, native.completedAt, "\(path).completedAt", &differences)
        compare(
            projected.durationMilliseconds,
            native.durationMilliseconds,
            "\(path).durationMilliseconds",
            &differences
        )
        compare(
            projected.itemsView,
            itemsView(native.itemsView),
            "\(path).itemsView",
            &differences
        )
        compare(
            projected.itemsNextCursor,
            native.itemsNextCursor,
            "\(path).itemsNextCursor",
            &differences
        )
        compare(projected.error, native.error, "\(path).error", &differences)
        compare(projected.retryingError, native.retryingError, "\(path).retryingError", &differences)
        compare(projected.raw, native.raw, "\(path).raw", &differences)
        comparePlan(native.plan, projected.plan, path: "\(path).plan", into: &differences)
        compareUsage(
            native.tokenUsage,
            projected.tokenUsage,
            path: "\(path).tokenUsage",
            into: &differences
        )
        compare(
            projected.items.count,
            native.items.count,
            "\(path).items.count",
            &differences
        )
        for (index, pair) in zip(native.items, projected.items).enumerated() {
            let itemPath = "\(path).items[\(index)]"
            compare(pair.1.id, pair.0.id, "\(itemPath).id", &differences)
            compare(
                pair.1.lifecycle,
                pair.0.lifecycle.rawValue,
                "\(itemPath).lifecycle",
                &differences
            )
            compare(pair.1.type, pair.0.content.typeName, "\(itemPath).type", &differences)
            compare(pair.1.startedAt, pair.0.startedAt, "\(itemPath).startedAt", &differences)
            compare(
                pair.1.completedAt,
                pair.0.completedAt,
                "\(itemPath).completedAt",
                &differences
            )
            compare(pair.1.raw, pair.0.raw, "\(itemPath).raw", &differences)
        }
    }

    private static func comparePlan(
        _ native: CodexPlanState?,
        _ projected: HarnessProtocolCodexPlan?,
        path: String,
        into differences: inout [String]
    ) {
        guard let native, let projected else {
            if (native == nil) != (projected == nil) { differences.append(path) }
            return
        }
        compare(projected.explanation, native.explanation, "\(path).explanation", &differences)
        compare(projected.steps.count, native.steps.count, "\(path).steps.count", &differences)
        for (index, pair) in zip(native.steps, projected.steps).enumerated() {
            let stepPath = "\(path).steps[\(index)]"
            compare(pair.1.id, pair.0.id, "\(stepPath).id", &differences)
            compare(pair.1.text, pair.0.text, "\(stepPath).text", &differences)
            compare(
                pair.1.status,
                planStatus(pair.0.status),
                "\(stepPath).status",
                &differences
            )
        }
    }

    private static func compareUsage(
        _ native: CodexThreadTokenUsage?,
        _ projected: HarnessProtocolCodexThreadTokenUsage?,
        path: String,
        into differences: inout [String]
    ) {
        guard let native, let projected else {
            if (native == nil) != (projected == nil) { differences.append(path) }
            return
        }
        compare(
            projected.modelContextWindow,
            native.modelContextWindow,
            "\(path).modelContextWindow",
            &differences
        )
        compareUsageBreakdown(native.total, projected.total, path: "\(path).total", into: &differences)
        compareUsageBreakdown(native.last, projected.last, path: "\(path).last", into: &differences)
    }

    private static func compareUsageBreakdown(
        _ native: CodexTokenUsageBreakdown,
        _ projected: HarnessProtocolCodexTokenUsage,
        path: String,
        into differences: inout [String]
    ) {
        compare(projected.inputTokens, native.inputTokens, "\(path).inputTokens", &differences)
        compare(
            projected.cachedInputTokens,
            native.cachedInputTokens,
            "\(path).cachedInputTokens",
            &differences
        )
        compare(
            projected.cacheWriteInputTokens,
            native.cacheWriteInputTokens,
            "\(path).cacheWriteInputTokens",
            &differences
        )
        compare(projected.outputTokens, native.outputTokens, "\(path).outputTokens", &differences)
        compare(
            projected.reasoningOutputTokens,
            native.reasoningOutputTokens,
            "\(path).reasoningOutputTokens",
            &differences
        )
        compare(projected.totalTokens, native.totalTokens, "\(path).totalTokens", &differences)
    }

    private static func compareServerRequests(
        _ native: [String: CodexServerRequestState],
        _ projected: [HarnessProtocolCodexServerRequest],
        into differences: inout [String]
    ) {
        let nativeValues = native.values.sorted { $0.id < $1.id }
        compare(projected.count, nativeValues.count, "serverRequests.count", &differences)
        for (index, pair) in zip(nativeValues, projected).enumerated() {
            let path = "serverRequests[\(index)]"
            compare(pair.1.id, pair.0.id, "\(path).id", &differences)
            compare(pair.1.method, pair.0.method, "\(path).method", &differences)
            compare(pair.1.kind, pair.0.kind.wireName, "\(path).kind", &differences)
            compare(pair.1.threadID, pair.0.threadID, "\(path).threadID", &differences)
            compare(pair.1.turnID, pair.0.turnID, "\(path).turnID", &differences)
            compare(pair.1.itemID, pair.0.itemID, "\(path).itemID", &differences)
            compare(pair.1.params, pair.0.params, "\(path).params", &differences)
            let nativeResolution: (String, JSONValue?, Int64?, String?) = switch pair.0.resolution {
            case .pending: ("pending", nil, nil, nil)
            case let .resolved(result): ("resolved", result, nil, nil)
            case let .rejected(code, message): ("rejected", nil, code, message)
            }
            compare(pair.1.resolution, nativeResolution.0, "\(path).resolution", &differences)
            compare(pair.1.result, nativeResolution.1, "\(path).result", &differences)
            compare(
                pair.1.rejectionCode,
                nativeResolution.2,
                "\(path).rejectionCode",
                &differences
            )
            compare(
                pair.1.rejectionMessage,
                nativeResolution.3,
                "\(path).rejectionMessage",
                &differences
            )
        }
    }

    private static func threadStatus(
        _ status: CodexThreadRuntimeStatus
    ) -> (status: String, activeFlags: [String]) {
        switch status {
        case .notLoaded: ("not_loaded", [])
        case .idle: ("idle", [])
        case let .active(flags): ("active", flags)
        case .systemError: ("system_error", [])
        case .unknown: ("unknown", [])
        }
    }

    private static func turnStatus(_ status: CodexTurnStatus) -> String {
        switch status {
        case .inProgress: "in_progress"
        case .completed: "completed"
        case .interrupted: "interrupted"
        case .failed: "failed"
        case let .unknown(value): value
        }
    }

    private static func itemsView(_ view: CodexItemsView) -> String {
        switch view {
        case .notLoaded: "not_loaded"
        case .summary: "summary"
        case .full: "full"
        case let .unknown(value): value
        }
    }

    private static func planStatus(_ status: CodexPlanStepStatus) -> String {
        switch status {
        case .pending: "pending"
        case .inProgress: "in_progress"
        case .completed: "completed"
        case let .unknown(value): value
        }
    }

    private static func compare<T: Equatable>(
        _ projected: T,
        _ native: T,
        _ path: String,
        _ differences: inout [String]
    ) {
        if projected != native { differences.append(path) }
    }
}
