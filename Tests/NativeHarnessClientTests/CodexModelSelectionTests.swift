import XCTest
@testable import NativeHarnessClient

final class CodexModelSelectionTests: XCTestCase {
    func testModelChangeRetainsOnlySupportedEffortAndRoundTripsAtomically() throws {
        let option = CodexModelOption(id: "fast-id", model: "fast", displayName: "Fast",
            defaultReasoningEffort: "low", supportedReasoningEfforts: ["low", "high"], isDefault: false)
        var catalog = CodexModelCatalog(models: [option], selection: .init(model: "large", reasoningEffort: "ultra"))
        XCTAssertEqual(catalog.selecting(option).reasoningEffort, "low")
        catalog.selection = .init(model: "large", reasoningEffort: "high")
        let selection = catalog.selecting(option)
        XCTAssertEqual(selection.reasoningEffort, "high")
        XCTAssertEqual(CodexModelSelection.restored(from: [CodexModelSelection.storageKey: try XCTUnwrap(selection.storedValue)]), selection)
        XCTAssertNil(CodexModelSelection.restored(from: [CodexModelSelection.storageKey: "broken"]))
    }

    func testProductCatalogPaginationSelectionForkAndResumeStayTaskScoped() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [thread("main", model: "large", effort: "high")],
            "model/list": [
                .object(["data": .array([model("large", efforts: ["high", "ultra"]), model("hidden", hidden: true)]), "nextCursor": .string("page-two")]),
                .object(["data": .array([model("fast", efforts: ["low", "high"])])])
            ],
            "thread/fork": [thread("child", model: "large", effort: "high")],
            "thread/resume": [thread("restored", model: "fast", effort: "low")],
            "turn/start": [.object(["turn": .object(["id": .string("main-turn")])]), .object(["turn": .object(["id": .string("child-turn")])])]
        ])
        let routed = YHPCodexCompatibilityAdapter(
            adapter: CodexAdapter(executableURL: URL(filePath: "/tmp/fake-codex"), transport: transport),
            manifest: HarnessProtocolCompatibilityManifest.codex()
        )
        let main = try await routed.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/models"), initialPrompt: nil))
        let initial = try await routed.modelCatalog(for: main)
        XCTAssertEqual(initial.models.map(\.model), ["large", "fast"])
        XCTAssertEqual(initial.selection, .init(model: "large", reasoningEffort: "high"))
        _ = try await routed.selectModel(.init(model: "fast", reasoningEffort: "low"), for: main)
        let child = try await routed.fork(main, newLocalSessionID: UUID())
        let inherited = try await routed.modelCatalog(for: child)
        XCTAssertEqual(inherited.selection, .init(model: "fast", reasoningEffort: "low"))
        _ = try await routed.selectModel(.init(model: "large", reasoningEffort: "ultra"), for: child)
        let requestsBeforeMiss = await transport.requests
        XCTAssertEqual(requestsBeforeMiss.filter { $0.method == "model/list" }.count, 2)
        do {
            _ = try await routed.selectModel(.init(model: "fast", reasoningEffort: "ultra"), for: main)
            XCTFail("Unsupported effort must fail before a turn is sent")
        } catch {}
        do {
            _ = try await routed.selectModel(.init(model: "hidden", reasoningEffort: nil), for: main)
            XCTFail("Hidden model must not become a selectable choice")
        } catch {}
        try await routed.send("main", to: main)
        try await routed.send("child", to: child)
        let requests = await transport.requests
        let turns = requests.filter { $0.method == "turn/start" }
        XCTAssertEqual(turns.map { $0.params["model"]?.stringValue }, ["fast", "large"])
        XCTAssertEqual(turns.map { $0.params["effort"]?.stringValue }, ["low", "ultra"])
        XCTAssertTrue(turns.allSatisfy { $0.params["collaborationMode"] == nil })
        let pages = requests.filter { $0.method == "model/list" }
        XCTAssertEqual(pages.count, 4, "Each rejected selection retries one read")
        XCTAssertEqual(pages[1].params["cursor"]?.stringValue, "page-two")
        XCTAssertEqual(pages.first?.params["includeHidden"], .bool(false))
        let restored = try await routed.resumeSession(providerSessionID: "restored", localSessionID: UUID(), workspaceURL: main.workspaceURL)
        let resumed = try await routed.modelCatalog(for: restored)
        XCTAssertEqual(resumed.selection, .init(model: "fast", reasoningEffort: "low"))
        await routed.close(main)
        await routed.close(child)
        await routed.close(restored)
    }

    func testModelListExpiresWhileTheServerStaysOpen() async throws {
        let clock = TestClock()
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [thread("thread", model: "first", effort: "low")],
            "model/list": ["first", "second"].map { .object(["data": .array([model($0)])]) }
        ])
        let adapter = CodexAdapter(executableURL: URL(filePath: "/tmp/codex"), transport: transport, now: { clock.now })
        let session = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp"), initialPrompt: nil))
        let first = try await adapter.modelCatalog(for: session)
        clock.now.addTimeInterval(299)
        let cached = try await adapter.modelCatalog(for: session)
        XCTAssertEqual(first, cached)
        clock.now.addTimeInterval(1)
        let refreshed = try await adapter.modelCatalog(for: session)
        XCTAssertEqual(refreshed.models.map(\.model), ["second"])
        await adapter.close(session)
    }

    func testOverlappingReadsShareOneRequestAndAnExpiredSelectionMissReadsOnlyOnce() async throws {
        let clock = TestClock()
        let page = JSONValue.object(["data": .array([model("available")])])
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [thread("thread", model: "available", effort: "low")],
            "model/list": [page, page]
        ])
        let adapter = CodexAdapter(executableURL: URL(filePath: "/tmp/codex"), transport: transport, now: { clock.now })
        let session = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp"), initialPrompt: nil))
        await transport.suspendNextRequest("model/list")
        async let forced = adapter.modelsIfRunning()
        try await waitUntil { await transport.isRequestSuspended }
        let release = Task {
            await Task.yield()
            await transport.releaseSuspendedRequest()
        }
        let initial = try await adapter.modelCatalog(for: session)
        let refreshed = try await forced
        await release.value
        XCTAssertEqual(refreshed, initial.models)
        clock.now.addTimeInterval(300)
        do {
            _ = try await adapter.selectModel(.init(model: "missing", reasoningEffort: nil), for: session)
            XCTFail("The fresh list still excludes this model")
        } catch HarnessAdapterError.invalidProviderEvent(let message) {
            XCTAssertEqual(message, "Unsupported Codex model or reasoning effort")
        }
        let methods = await transport.requestMethods
        XCTAssertEqual(methods.filter { $0 == "model/list" }.count, 2)
        await adapter.close(session)
    }

    func testSelectionRefreshesOnAMissAndAReplacementServerListsItsOwnModels() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": Array(repeating: .object(["platformOs": .string("macos")]), count: 2),
            "thread/start": [thread("first", model: "old", effort: "low"), thread("second", model: "next", effort: "low")],
            "model/list": ["old", "new", "next"].map { .object(["data": .array([model($0)])]) }
        ])
        let adapter = CodexAdapter(executableURL: URL(filePath: "/tmp/codex"), transport: transport)
        func open() async throws -> HarnessSessionHandle {
            try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp"), initialPrompt: nil))
        }
        let first = try await open()
        let original = try await adapter.modelCatalog(for: first)
        XCTAssertEqual(original.models.map(\.model), ["old"])
        let updated = try await adapter.selectModel(.init(model: "new", reasoningEffort: "low"), for: first)
        XCTAssertEqual(updated.selection?.model, "new")
        await adapter.close(first)
        let second = try await open()
        let restarted = try await adapter.modelCatalog(for: second)
        XCTAssertEqual(restarted.models.map(\.model), ["next"])
        await adapter.close(second)
    }

    private func model(_ id: String, efforts: [String] = ["low"], hidden: Bool = false) -> JSONValue {
        .object(["id": .string(id), "model": .string(id), "displayName": .string(id.capitalized),
                 "hidden": .bool(hidden), "defaultReasoningEffort": .string(efforts[0]),
                 "supportedReasoningEfforts": .array(efforts.map { .object(["reasoningEffort": .string($0)]) })])
    }

    private func thread(_ id: String, model: String, effort: String) -> JSONValue {
        .object(["thread": .object(["id": .string(id), "turns": .array([])]), "model": .string(model), "reasoningEffort": .string(effort)])
    }
}
