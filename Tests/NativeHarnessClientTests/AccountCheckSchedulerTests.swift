import Foundation
import XCTest
@testable import NativeHarnessClient

/// The accounts store's one check scheduler: one check per account at a time, one freshness rule,
/// and the newest check's answer is the one shown.
@MainActor final class AccountCheckSchedulerTests: XCTestCase {
    func testRequestsForAnAccountWhoseCheckIsRunningWaitForThatCheck() async throws {
        let reads = ReadGate()
        let store = ProviderConnectionStore(
            defaultLoader: { descriptor, _ in await reads.read(descriptor.id.rawValue, harness: descriptor.id, state: .signedIn) },
            connectionLoader: { connection, _ in await reads.read(connection.id, harness: connection.harness, state: .signedIn) })
        let saved = ProviderConnection(id: "work", name: "Work", harness: .claudeCode, providerID: nil,
            homePath: "/tmp/claude-work", credentialSelector: nil)
        try store.save(saved)
        let runtime = try runtime()

        // The chip, the account sheet and Settings ask at once; the refresh button too.
        let chip = Task { await store.check(defaultsOf: [.claudeCode], savedOf: [.claudeCode], runtimeSelections: runtime) }
        let sheet = Task { await store.check(defaultsOf: [], savedOf: [.claudeCode], runtimeSelections: runtime) }
        let settings = Task { await store.check(defaultsOf: [.claudeCode], savedOf: [.claudeCode],
            policy: .refresh, runtimeSelections: runtime) }
        try await waitUntil { await reads.waiting.count == 2 }
        XCTAssertTrue(store.isCheckingDefault(.claudeCode))
        XCTAssertTrue(store.checkingKeys.contains(saved.id))
        await reads.open()
        _ = await (chip.value, sheet.value, settings.value)

        let counts = await reads.counts
        XCTAssertEqual(counts, ["claude-code": 1, "work": 1], "One process per account, however many asked")
        XCTAssertEqual(store.defaultSnapshots[.claudeCode]?.state, .signedIn)
        XCTAssertEqual(store.snapshots[saved.id]?.state, .signedIn)
        XCTAssertTrue(store.checkingKeys.isEmpty)
    }

    func testAReadingConfirmedWithinAMinuteIsKeptUnlessRefreshed() async throws {
        let reads = ReadGate(opened: true)
        let store = ProviderConnectionStore(
            defaultLoader: { descriptor, _ in await reads.read(descriptor.id.rawValue, harness: descriptor.id, state: .signedIn) })
        let runtime = try runtime()
        await store.check(defaultsOf: [.codex], savedOf: [], runtimeSelections: runtime)
        await store.check(defaultsOf: [.codex], savedOf: [], runtimeSelections: runtime)
        var counts = await reads.counts
        XCTAssertEqual(counts["codex"], 1, "A fresh reading is not checked again")
        let key = AccountChoice.nativeID(for: .codex)
        XCTAssertTrue(store.isFresh(key))
        XCTAssertFalse(store.isFresh(key, now: Date().addingTimeInterval(ProviderConnectionStore.freshnessInterval)),
            "After a minute it is checked again")

        await store.check(defaultsOf: [.codex], savedOf: [], policy: .refresh, runtimeSelections: runtime)
        counts = await reads.counts
        XCTAssertEqual(counts["codex"], 2, "The refresh button checks a fresh reading again")

        // Home's usage band reads again every 15 minutes, keeping any reading made meanwhile.
        let span = TokenUsagePace.span
        await store.check(defaultsOf: [.codex], savedOf: [], policy: .ifOlderThan(span), runtimeSelections: runtime)
        counts = await reads.counts
        XCTAssertEqual(counts["codex"], 2, "A reading under 15 minutes old is used rather than read again")
        XCTAssertTrue(store.isFresh(key, now: Date().addingTimeInterval(span - 60), within: span))
        XCTAssertFalse(store.isFresh(key, now: Date().addingTimeInterval(span), within: span))
    }

    func testRememberedAndUnfinishedReadingsAreNeverFresh() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "scheduler-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheURL = root.appending(path: ProviderConnectionStore.snapshotCacheFileName)
        let first = ProviderConnectionStore(snapshotCacheURL: cacheURL)
        first.publishDefaults([snapshot(.claudeCode, .signedIn)])
        XCTAssertTrue(first.isFresh(AccountChoice.nativeID(for: .claudeCode)))
        first.publishDefaults([snapshot(.claudeCode, .unknown)])
        XCTAssertEqual(first.readingStatus[AccountChoice.nativeID(for: .claudeCode)], .checkFailed)
        XCTAssertFalse(first.isFresh(AccountChoice.nativeID(for: .claudeCode)),
            "A check that could not finish is tried again")

        let relaunched = ProviderConnectionStore(snapshotCacheURL: cacheURL)
        XCTAssertEqual(relaunched.readingStatus[AccountChoice.nativeID(for: .claudeCode)], .remembered)
        XCTAssertFalse(relaunched.isFresh(AccountChoice.nativeID(for: .claudeCode)),
            "A reading from an earlier launch is checked again")
    }

    func testARestartedCheckDiscardsTheAnswerOfTheOneItReplaced() async throws {
        let reads = ReadGate()
        let store = ProviderConnectionStore(defaultLoader: { descriptor, _ in
            // The first read describes the login before a sign-in finished; later ones after it.
            await reads.read(descriptor.id.rawValue, harness: descriptor.id, state: nil)
        })
        let runtime = try runtime()
        let before = Task { await store.check(defaultsOf: [.claudeCode], savedOf: [], runtimeSelections: runtime) }
        try await waitUntil { await reads.waiting.count == 1 }
        let after = Task { await store.check(defaultsOf: [.claudeCode], savedOf: [], policy: .restart,
            runtimeSelections: runtime) }
        try await waitUntil { await reads.waiting.count == 2 }
        await reads.open()
        _ = await (before.value, after.value)
        XCTAssertEqual(store.defaultSnapshots[.claudeCode]?.state, .signedIn,
            "The check started after the sign-in is the one shown, whichever answered last")
        XCTAssertTrue(store.checkingKeys.isEmpty)
    }

    func testAnOutsideReadSupersedesARunningCheck() async throws {
        let reads = ReadGate()
        let store = ProviderConnectionStore(defaultLoader: { descriptor, _ in
            await reads.read(descriptor.id.rawValue, harness: descriptor.id, state: .signedOut)
        })
        let runtime = try runtime()
        let check = Task { await store.check(defaultsOf: [.codex], savedOf: [], runtimeSelections: runtime) }
        try await waitUntil { await reads.waiting.count == 1 }
        // The Codex account monitor reports a sign-in while the one-shot check still runs.
        store.publishDefaults([snapshot(.codex, .signedIn)])
        XCTAssertFalse(store.isCheckingDefault(.codex))
        await reads.open()
        await check.value
        XCTAssertEqual(store.defaultSnapshots[.codex]?.state, .signedIn, "The older check's answer is dropped")

        let token = store.beginRead(ofDefault: .codex)
        XCTAssertTrue(store.isLatest(token))
        await store.check(defaultsOf: [.codex], savedOf: [], policy: .refresh, runtimeSelections: runtime)
        XCTAssertFalse(store.finishRead(token, with: snapshot(.codex, .unknown)),
            "A read started before a check is not shown after it")
    }

    // MARK: Helpers

    private func runtime() throws -> RuntimeSelectionStore {
        let suite = testDefaultsSuite("account-scheduler")
        return RuntimeSelectionStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)),
            discoversRuntimes: false, loadsPersistedSelections: false)
    }
}

private func snapshot(_ harness: HarnessKind, _ state: AccountAuthState) -> HarnessAccountSnapshot {
    HarnessAccountSnapshot(id: harness.rawValue, harness: harness, providerID: nil, state: state,
        accountLabel: state == .signedIn ? "person@example.test" : nil, detail: "", credentialOwner: "",
        checkedAt: Date(), usage: [], canLogin: state != .signedIn, canLogout: state == .signedIn)
}

/// Holds reads until opened and counts them per key. A nil state answers signed out for the
/// first read of a key and signed in after.
private actor ReadGate {
    private var isOpen: Bool
    private(set) var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var counts: [String: Int] = [:]

    init(opened: Bool = false) { isOpen = opened }

    func read(_ key: String, harness: HarnessKind, state: AccountAuthState?) async -> HarnessAccountSnapshot {
        counts[key, default: 0] += 1
        let number = counts[key] ?? 1
        if !isOpen { await withCheckedContinuation { waiting.append($0) } }
        return snapshot(harness, state ?? (number == 1 ? .signedOut : .signedIn))
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting.removeAll()
    }
}
