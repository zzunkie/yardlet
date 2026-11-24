import Foundation
import XCTest
@testable import NativeHarnessClient

final class CodexCompletionParityTests: XCTestCase {
    func testCompletedReviewRefreshesItsWorkerAndCanonicalHeadThroughBothRoutes() async throws {
        for routed in [false, true] {
            let finished = JSONValue.object(["id": .string("review"), "status": .string("completed"), "items": .array([
                .object(["id": .string("output"), "type": .string("exitedReviewMode"), "review": .string("QA finding")])])])
            let worker = JSONValue.object(["id": .string("worker"), "status": .string("interrupted"), "items": .array([])])
            let original = JSONValue.object(["thread": .object(["id": .string("original"), "status": .object(["type": .string("idle")]),
                "turnsNextCursor": .string("saved-older-cursor"), "turns": .array([
                    .object(["id": .string("older"), "status": .string("completed"), "items": .array([])])])]),
                "model": .string("gpt-test"), "reasoningEffort": .string("high")])
            let transport = FakeCodexTransport(responses: ["initialize": [.object(["platformOs": .string("macos")])],
                "thread/start": [original], "review/start": [.object(["turn": .object(["id": .string("review")])])],
                "thread/turns/list": [.object(["data": .array([.object(["id": .string("older"), "status": .string("completed"), "items": .array([])])]),
                    "nextCursor": .string("saved-older-cursor")]), .object(["data": .array([finished, worker]), "nextCursor": .null])]])
            let direct = CodexAdapter(executableURL: URL(filePath: "/tmp/codex"), transport: transport)
            let adapter: any HarnessAdapter = routed ? YHPCodexCompatibilityAdapter(adapter: direct,
                manifest: HarnessProtocolCompatibilityManifest.codex()) : direct
            let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp"), initialPrompt: nil))
            let events = await adapter.events(for: handle)
            let observer = Task { for await _ in events {} }
            defer { observer.cancel() }
            let presentation = try XCTUnwrap(adapter as? any CodexPresentationProviding)
            let states = try await presentation.presentationStates(for: handle)
            let presentationObserver = Task { for await _ in states {} }
            defer { presentationObserver.cancel() }
            _ = try await presentation.loadTurns(for: handle, cursor: nil, limit: 3)
            let provider = try XCTUnwrap(adapter as? any CodexCapabilityProviding)
            try await provider.startReview(.baseBranch("qa-base"), in: handle)
            await transport.emit(method: "item/completed", params: .object(["threadId": .string("original"), "turnId": .string("review"),
                "item": .object(["id": .string("entry"), "type": .string("enteredReviewMode"), "review": .string("QA review")])]))
            await transport.emit(method: "turn/started", params: .object(["threadId": .string("original"),
                "turn": .object(["id": .string("worker"), "status": .string("inProgress"), "items": .array([])])]))
            await transport.emit(method: "item/completed", params: .object(["threadId": .string("original"), "turnId": .string("review"),
                "item": .object(["id": .string("output"), "type": .string("exitedReviewMode"), "review": .string("QA finding")])]))
            await transport.emit(method: "turn/completed", params: .object(["threadId": .string("original"), "turn": finished]))
            var state = CodexTaskState.empty
            try await waitUntil {
                state = try await presentation.presentationState(for: handle)
                return state.thread?.turns.first(where: { $0.id == "worker" })?.status == .interrupted
            }
            XCTAssertEqual(state.thread?.turns.map(\.id), ["older", "worker", "review"])
            XCTAssertEqual(state.thread?.turns.last?.status, .completed)
            XCTAssertEqual(state.thread?.turns.first(where: { $0.id == "worker" })?.status, .interrupted)
            XCTAssertEqual(state.thread?.turnsNextCursor, "saved-older-cursor")
            XCTAssertNil(state.activeTurnID)
            let requests = await transport.requests
            XCTAssertEqual(requests.last { $0.method == "thread/turns/list" }?.params["limit"], .integer(12))
            await adapter.close(handle)
        }
    }

    func testReviewSendsChosenBaseBranchThroughBothRoutes() async throws {
        for routed in [false, true] {
            let transport = FakeCodexTransport(responses: ["initialize": [.object(["platformOs": .string("macos")])],
                "thread/start": [thread()], "review/start": [.object(["turn": .object(["id": .string("review")])])]])
            let direct = CodexAdapter(executableURL: URL(filePath: "/tmp/codex"), transport: transport)
            let adapter: any HarnessAdapter = routed
                ? YHPCodexCompatibilityAdapter(adapter: direct, manifest: HarnessProtocolCompatibilityManifest.codex()) : direct
            let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp"), initialPrompt: nil))
            let provider = try XCTUnwrap(adapter as? any CodexCapabilityProviding)
            try await provider.startReview(.baseBranch("origin/main"), in: handle)
            let requests = await transport.requests
            XCTAssertEqual(requests.first { $0.method == "review/start" }?.params["target"],
                .object(["type": .string("baseBranch"), "branch": .string("origin/main")]))
            XCTAssertFalse(requests.contains { $0.method == "turn/start" })
            await adapter.close(handle)
        }
    }

    func testCompactUsesNativeActionThroughBothRoutesAndRejectsActiveWork() async throws {
        for routed in [false, true] {
            for busy in [false, true] {
                let transport = FakeCodexTransport(responses: [
                    "initialize": [.object(["platformOs": .string("macos")])],
                    "thread/start": [thread()], "thread/read": [thread(status: busy ? "active" : "idle")],
                    "thread/compact/start": [.object([:])]
                ])
                let direct = CodexAdapter(executableURL: URL(filePath: "/tmp/codex"), transport: transport)
                let adapter: any HarnessAdapter = routed
                    ? YHPCodexCompatibilityAdapter(adapter: direct, manifest: HarnessProtocolCompatibilityManifest.codex()) : direct
                let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp"), initialPrompt: nil))
                let provider = try XCTUnwrap(adapter as? any CodexCapabilityProviding)
                do { try await provider.compactConversation(in: handle); XCTAssertFalse(busy) }
                catch { XCTAssertTrue(busy) }
                let requests = await transport.requests
                XCTAssertEqual(requests.filter { $0.method == "thread/compact/start" }.count, busy ? 0 : 1)
                XCTAssertEqual(requests.first { $0.method == "thread/compact/start" }?.params,
                    busy ? nil : .object(["threadId": .string("original")]))
                XCTAssertFalse(requests.contains { ["turn/start", "turn/steer", "thread/revert"].contains($0.method) })
                await adapter.close(handle)
            }
        }
    }

    func testFastCatalogPersistsAndAppliesOnlySupportedNativeTierThroughBothRoutes() async throws {
        for routed in [false, true] {
            let transport = FakeCodexTransport(responses: [
                "initialize": [.object(["platformOs": .string("macos")])], "thread/start": [thread()],
                "model/list": [.object(["data": .array([.object([
                    "id": .string("model"), "model": .string("gpt-test"), "displayName": .string("Test"),
                    "defaultReasoningEffort": .string("high"), "supportedReasoningEfforts": .array([.object(["reasoningEffort": .string("high")])]),
                    "isDefault": .bool(true), "serviceTiers": .array([.object(["id": .string("priority"), "name": .string("Fast"), "description": .string("2x speed, increased usage")])]),
                    "additionalSpeedTiers": .array([.string("fast")])
                ])]), "nextCursor": .null])],
                "turn/start": [.object(["turn": .object(["id": .string("fast-turn")])]), .object(["turn": .object(["id": .string("default-turn")])])]
            ])
            let direct = CodexAdapter(executableURL: URL(filePath: "/tmp/codex"), transport: transport)
            let adapter: any HarnessAdapter = routed
                ? YHPCodexCompatibilityAdapter(adapter: direct, manifest: HarnessProtocolCompatibilityManifest.codex()) : direct
            let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp"), initialPrompt: nil))
            let provider = try XCTUnwrap(adapter as? any CodexCapabilityProviding)
            let catalog = try await provider.selectModel(.init(model: "gpt-test", reasoningEffort: "high", serviceTier: "priority"), for: handle)
            XCTAssertEqual(catalog.fastTier?.name, "Fast")
            XCTAssertEqual(catalog.fastTier?.id, "priority")
            XCTAssertTrue(catalog.isFast)
            let selection = try XCTUnwrap(catalog.selection)
            XCTAssertEqual(CodexModelSelection.restored(from: [CodexModelSelection.storageKey: selection.storedValue!]), selection)
            XCTAssertEqual(CodexModelMenuProjection.selection(id: "reasoningEffort", value: "high", catalog: catalog)?.serviceTier, "priority")
            try await adapter.send("Fast input", to: handle)
            let standard = try await provider.selectModel(.init(model: "gpt-test", reasoningEffort: "high", serviceTier: "default"), for: handle)
            XCTAssertFalse(standard.isFast)
            try await adapter.send("Standard input", to: handle)
            do { _ = try await provider.selectModel(.init(model: "gpt-test", reasoningEffort: "high", serviceTier: "invented"), for: handle); XCTFail() } catch {}
            let starts = await transport.requests.filter { $0.method == "turn/start" }
            XCTAssertEqual(starts.map { $0.params["serviceTier"] }, [.string("priority"), .string("default")])
            await adapter.close(handle)
        }
        let legacy = CodexModelCatalog(models: [.init(id: "legacy", model: "legacy", displayName: "Legacy",
            defaultReasoningEffort: "high", supportedReasoningEfforts: ["high"], isDefault: true,
            serviceTiers: [.init(id: "fast", name: "Fast", description: "")])],
            selection: .init(model: "legacy", reasoningEffort: "high", serviceTier: "fast"))
        XCTAssertTrue(legacy.isFast)
        XCTAssertEqual(legacy.fastTier?.id, "fast")
        XCTAssertFalse(CodexModelCatalog().isFast)

        let multiTierModel = CodexModelOption(
            id: "gpt-6.2-sol", model: "gpt-6.2-sol", displayName: "GPT-6.2-Sol",
            defaultReasoningEffort: "high", supportedReasoningEfforts: ["low", "high"], isDefault: true,
            serviceTiers: [
                .init(id: "priority", name: "Fast", description: "2x speed, increased usage"),
                .init(id: "ultrafast", name: "Ultrafast", description: "The fastest available responses for latency-sensitive work.")
            ])
        let singleTierModel = CodexModelOption(
            id: "gpt-6.2-astra", model: "gpt-6.2-astra", displayName: "GPT-6.2-Astra",
            defaultReasoningEffort: "high", supportedReasoningEfforts: ["high"], isDefault: false,
            serviceTiers: [.init(id: "priority", name: "Fast", description: "2x speed, increased usage")])
        let multiCatalog = CodexModelCatalog(
            models: [multiTierModel, singleTierModel],
            selection: .init(model: "gpt-6.2-sol", reasoningEffort: "high", serviceTier: "ultrafast"))
        XCTAssertEqual(multiCatalog.availableServiceTiers.map(\.id), ["priority", "ultrafast"])
        XCTAssertEqual(multiCatalog.activeServiceTier?.id, "ultrafast")
        let speedSelector = try XCTUnwrap(CodexModelMenuProjection.speed(multiCatalog))
        XCTAssertEqual(speedSelector.id, "serviceTier")
        XCTAssertFalse(speedSelector.isBinarySpeedSwitch)
        XCTAssertEqual(speedSelector.currentValue, "ultrafast")
        XCTAssertEqual(speedSelector.choices.map(\.value), ["default", "priority", "ultrafast"])
        XCTAssertEqual(CodexModelMenuProjection.selection(id: "serviceTier", value: "priority", catalog: multiCatalog)?.serviceTier, "priority")
        XCTAssertEqual(CodexModelMenuProjection.selection(id: "serviceTier", value: "default", catalog: multiCatalog)?.serviceTier, "default")
        let highLabel = CodexReasoningLabel.name("high")
        XCTAssertEqual(ComposerModelMenu.codex(multiCatalog).title, "GPT-6.2-Sol · \(highLabel) · Ultrafast")
        XCTAssertEqual(multiCatalog.selecting(singleTierModel).serviceTier, "default",
                       "Switching to a model without ultrafast resets serviceTier to default")
        let defaultMultiCatalog = CodexModelCatalog(
            models: [multiTierModel],
            selection: .init(model: "gpt-6.2-sol", reasoningEffort: "high", serviceTier: "default"))
        XCTAssertEqual(ComposerModelMenu.codex(defaultMultiCatalog).title, "GPT-6.2-Sol · \(highLabel)")
        XCTAssertEqual(CodexModelMenuProjection.speed(defaultMultiCatalog)?.currentValue, "default")
    }

    private func thread(status: String = "idle") -> JSONValue {
        .object(["thread": .object(["id": .string("original"), "status": .object(["type": .string(status)]), "turns": .array([])]),
                 "model": .string("gpt-test"), "reasoningEffort": .string("high")])
    }
}
