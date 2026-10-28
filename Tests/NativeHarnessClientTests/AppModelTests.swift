import Foundation
import os
import XCTest
@testable import NativeHarnessClient

@MainActor
final class AppModelTests: XCTestCase {
    func testSideChatInheritsFrozenHistoryOnlyOnFirstProviderSubmission() async throws {
        let parent = SessionRecord(harness: .openCode, workspaceURL: URL(filePath: "/tmp/side-context"),
                                   runtimeExecutableURL: URL(filePath: "/tmp/opencode"), title: "Source")
        let adapter = FakeHarnessAdapter(kind: .openCode)
        let model = AppModel(
            store: SessionStore(sessions: [parent], repository: InMemorySessionRepository(sessions: [parent])),
            runtimeSelections: RuntimeSelectionStore(defaults: UserDefaults(suiteName: testDefaultsSuite("SideContext"))!),
            registry: HarnessRegistry { _, _ in adapter },
            initialTranscripts: [parent.id: [TranscriptEntry(content: .user(text: "Keep migration reversible.")),
                                            TranscriptEntry(content: .assistant(text: "Use per-session storage.", isStreaming: false))]],
            restoresIndexOnLaunch: false
        )
        let prepared = await model.branch(parent, placement: .sidePanel)
        let child = try XCTUnwrap(prepared)
        XCTAssertEqual(child.inheritedContext?.sourceSessionID, parent.id)
        XCTAssertEqual(model.transcriptBySessionID[child.id]?.count, 2)
        await model.send("Later main conversation", to: parent)
        await model.send("Explain the storage choice", to: child)
        let lastPrompt = await adapter.lastSentPrompt()
        let first = try XCTUnwrap(lastPrompt)
        XCTAssertTrue(first.contains("Keep migration reversible."))
        XCTAssertTrue(first.contains("Use per-session storage."))
        XCTAssertTrue(first.hasSuffix("Explain the storage choice"))
        XCTAssertFalse(first.contains("Later main conversation"))
        XCTAssertEqual(model.store.sessions.first(where: { $0.id == child.id })?.inheritedContext?.isDelivered, true)
        // The side chat's first turn ends; a message sent while it ran would wait for that.
        await adapter.emit(.sessionStatusChanged(.ready), for: child.id, sequence: 1)
        try await waitUntil { model.store.sessions.first(where: { $0.id == child.id })?.status == .ready }
        await model.send("A follow-up", to: child)
        let followup = await adapter.lastSentPrompt()
        XCTAssertEqual(followup, "A follow-up")
        XCTAssertFalse(model.transcriptBySessionID[parent.id]?.contains {
            $0.content == .user(text: "Explain the storage choice")
        } == true)
        await model.shutdown()
    }

    func testCodexSideChatUsesNativeForkWithoutMovingMainSelectionOrSubmitting() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let model = try composerRefreshModel(adapter: adapter)
        let created = await model.createSession(harness: .codex, workspaceURL: URL(filePath: "/tmp/side-fork"),
                                                runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Main")
        let parent = try XCTUnwrap(created)
        let prepared = await model.branch(parent, placement: .sidePanel)
        let child = try XCTUnwrap(prepared)
        XCTAssertEqual(model.store.selectedSessionID, parent.id)
        XCTAssertNotEqual(child.providerSessionID, parent.providerSessionID)
        XCTAssertNil(child.inheritedContext)
        XCTAssertNil(child.parentTaskID, "A side chat lives in its parent's side panel, not nested in the sidebar")
        let forks = await adapter.forkedFromSessionIDs
        let prompts = await adapter.sentPrompts
        let creates = await adapter.createCount
        XCTAssertEqual(forks, [parent.id])
        XCTAssertTrue(prompts.isEmpty)
        XCTAssertEqual(creates, 1)
        await model.shutdown()
    }

    /// A task records the runtime it was created with; the harness's runtime stays the person's
    /// choice or its newest install, so a task made from an older runtime does not pin it.
    func testCreatingATaskDoesNotChooseItsRuntimeForTheHarness() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests")))
        let adapter = FakeHarnessAdapter(kind: .codex)
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry { _, _ in adapter }, restoresIndexOnLaunch: false
        )
        let created = await model.createSession(harness: .codex, workspaceURL: URL(filePath: "/tmp/runtime-choice"),
                                                runtimeExecutableURL: URL(filePath: "/usr/bin/true"), title: "Older runtime")
        XCTAssertEqual(created?.runtimeExecutableURL, URL(filePath: "/usr/bin/true"))
        XCTAssertNil(model.runtimeSelections.selectedURL(for: .codex))
        XCTAssertNil(defaults.string(forKey: "runtime.codex.executablePath"))
        await model.shutdown()
    }

    func testSideChatOpensWithoutSelectingOrAttachingAndKeepsDraftsIndependent() async throws {
        let parent = SessionRecord(harness: .openCode, workspaceURL: URL(filePath: "/tmp/side-chat"),
                                   runtimeExecutableURL: URL(filePath: "/tmp/opencode"), title: "Main conversation")
        let adapter = FakeHarnessAdapter(kind: .openCode)
        let model = try composerRefreshModel(adapter: adapter, sessions: [parent])
        model.composerDrafts.tasks.draft(for: parent.id).text = "  Main draft 👩🏽‍💻\n"
        async let first = model.branch(parent, placement: .sidePanel)
        async let second = model.branch(parent, placement: .sidePanel)
        let results = await [first, second]
        let child = try XCTUnwrap(results.compactMap { $0 }.first)
        XCTAssertNotEqual(child.id, parent.id)
        XCTAssertEqual(model.store.sessions.count, 2)
        XCTAssertEqual(model.store.selectedSessionID, parent.id)
        XCTAssertEqual(child.harness, parent.harness)
        XCTAssertEqual(child.workspaceURL, parent.workspaceURL)
        XCTAssertEqual(child.environmentScope, parent.environmentScope)
        XCTAssertNil(child.providerSessionID)
        XCTAssertFalse(model.isAttached(child.id))
        let creates = await adapter.createCount
        let probes = await adapter.probeCount
        XCTAssertEqual(creates, 0)
        XCTAssertEqual(probes, 0)
        model.composerDrafts.tasks.draft(for: child.id).text = "Side draft\nsecond line"
        let reopened = await model.branch(parent, placement: .sidePanel)
        XCTAssertEqual(reopened?.id, child.id)
        XCTAssertEqual(model.composerDrafts.tasks.draft(for: parent.id).text, "  Main draft 👩🏽‍💻\n")
        XCTAssertEqual(model.composerDrafts.tasks.draft(for: child.id).text, "Side draft\nsecond line")
        await model.send("Only the side conversation", to: child)
        XCTAssertTrue(model.isAttached(child.id))
        XCTAssertFalse(model.isAttached(parent.id))
        XCTAssertNil(model.transcriptBySessionID[parent.id])
        XCTAssertEqual(model.store.selectedSessionID, parent.id)
        let prompts = await adapter.sentPrompts
        XCTAssertEqual(prompts, ["Only the side conversation"])
        let workspace = model.taskWorkspaces.state(for: parent.id)
        workspace.setPanels(.init(trailingSurfaceID: "sideChat"))
        model.setShowsTasks(true, inWindow: UUID())
        XCTAssertTrue(model.isSessionVisible(child.id))
        await adapter.emit(.turnCompleted, for: child.id, sequence: 10)
        try await waitUntil {
            model.store.sessions.first(where: { $0.id == child.id })?.completionState == .completed
        }
        XCTAssertFalse(try XCTUnwrap(model.store.sessions.first(where: { $0.id == child.id })).hasUnreadUpdate)
        workspace.setPanels(.init())
        XCTAssertFalse(model.isSessionVisible(child.id))
        XCTAssertTrue(model.isAttached(child.id))
        await adapter.emit(.error(message: "Side chat failed", recoverable: true), for: child.id, sequence: 11)
        try await waitUntil {
            model.store.sessions.first(where: { $0.id == child.id })?.hasUnreadUpdate == true
        }
        XCTAssertTrue(try XCTUnwrap(model.store.sessions.first(where: { $0.id == child.id })).hasUnreadUpdate)
        XCTAssertNil(model.errorBySessionID[parent.id])
        await model.shutdown()
    }

    func testDeletedSideChatCanBeReplacedWithoutDeletingParentOrItsDraft() async throws {
        let parent = SessionRecord(harness: .openCode, workspaceURL: URL(filePath: "/tmp/side-chat"),
                                   runtimeExecutableURL: URL(filePath: "/tmp/opencode"), title: "Parent")
        let model = try composerRefreshModel(adapter: FakeHarnessAdapter(kind: .openCode), sessions: [parent])
        let prepared = await model.branch(parent, placement: .sidePanel)
        let child = try XCTUnwrap(prepared)
        model.composerDrafts.tasks.draft(for: parent.id).text = "Keep parent input"
        await model.delete(child)
        let replacement = await model.branch(parent, placement: .sidePanel)
        XCTAssertNotNil(replacement)
        XCTAssertNotEqual(replacement?.id, child.id)
        XCTAssertEqual(model.store.sessions.count, 2)
        XCTAssertEqual(model.store.selectedSessionID, parent.id)
        XCTAssertEqual(model.composerDrafts.tasks.draft(for: parent.id).text, "Keep parent input")
        await model.delete(parent)
        XCTAssertTrue(model.store.sessions.contains { $0.id == replacement?.id })
        await model.shutdown()
    }

    /// Branch support follows the task's adapter, not its harness name: a Claude task whose adapter
    /// has no native fork offers no fork, and its side chat starts from a reading snapshot.
    func testBranchSupportFollowsTheAdapterNotTheHarnessName() async throws {
        let parent = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/branch-capability"),
                                   runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Source")
        let adapter = FakeHarnessAdapter(kind: .claudeCode)
        let model = AppModel(
            store: SessionStore(sessions: [parent], repository: InMemorySessionRepository(sessions: [parent])),
            runtimeSelections: RuntimeSelectionStore(defaults: UserDefaults(suiteName: testDefaultsSuite("BranchCapability"))!),
            registry: HarnessRegistry { _, _ in adapter },
            initialTranscripts: [parent.id: [TranscriptEntry(content: .user(text: "Keep the boundary."))]],
            restoresIndexOnLaunch: false
        )
        XCTAssertFalse(model.canBranch(parent))
        let fork = await model.branch(parent)
        XCTAssertNil(fork)
        XCTAssertFalse(model.canBranch(parent))
        let blankSideChat = await model.branch(parent, at: .start, placement: .sidePanel)
        XCTAssertNil(blankSideChat, "A side chat carries the whole conversation")
        let side = await model.branch(parent, placement: .sidePanel)
        let child = try XCTUnwrap(side)
        XCTAssertEqual(child.inheritedContext?.sourceSessionID, parent.id)
        XCTAssertNil(child.inheritedContext?.nativeForkSource)
        XCTAssertEqual(model.store.sessions.count, 2)
        XCTAssertEqual(model.store.selectedSessionID, parent.id)
        let probes = await adapter.probeCount
        let forks = await adapter.forkedFromSessionIDs
        XCTAssertEqual(probes, 0)
        XCTAssertTrue(forks.isEmpty)
        await model.shutdown()
    }

    /// The palette's Fork task appears once the task's adapter answers, without attaching or
    /// probing the runtime merely to ask.
    func testForkIsOfferedFromTheAdapterWithoutStartingTheRuntime() async throws {
        let parent = SessionRecord(harness: .codex, workspaceURL: URL(filePath: "/tmp/branch-offer"),
                                   runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Source",
                                   providerSessionID: "provider-source")
        let adapter = FakeHarnessAdapter(kind: .codex)
        let model = try composerRefreshModel(adapter: adapter, sessions: [parent])
        XCTAssertFalse(model.canBranch(parent), "The first question is answered after one registry hop")
        try await waitUntil { model.canBranch(parent) }
        XCTAssertTrue(model.canBranch(parent))
        XCTAssertFalse(model.isAttached(parent.id))
        let probes = await adapter.probeCount
        let creates = await adapter.createCount
        let resumes = await adapter.resumeCount
        XCTAssertEqual([probes, creates, resumes], [0, 0, 0])
        await model.shutdown()
    }

    private func composerRefreshModel(adapter: FakeHarnessAdapter, sessions: [SessionRecord] = []) throws -> AppModel {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests")))
        return AppModel(
            store: SessionStore(sessions: sessions, repository: InMemorySessionRepository(sessions: sessions)),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter }, restoresIndexOnLaunch: false
        )
    }

    func testEndedCodexStreamDetachesThroughYHPAndRetainsDraftForResume() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests")))
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in
                YHPCodexCompatibilityAdapter(adapter: adapter, manifest: HarnessProtocolCompatibilityManifest.codex())
            }
        )
        let created = await model.createSession(harness: .codex, workspaceURL: URL(filePath: "/tmp/stream-end"),
                                                runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Stream recovery")
        let session = try XCTUnwrap(created)
        model.composerDrafts.tasks.draft(for: session.id).text = "  Keep this unsent draft 👩🏽‍💻\n"
        await adapter.emit(.sessionStatusChanged(.running), for: session.id, sequence: 10)
        await adapter.emit(.assistantDelta("Partial response"), for: session.id, sequence: 11)
        await adapter.finishEvents(for: session.id)
        // The handle goes before the failed status is written, so wait for both.
        try await waitUntil { !model.isAttached(session.id) && model.store.sessions.first?.status == .failed }
        XCTAssertFalse(model.isAttached(session.id))
        XCTAssertEqual(model.store.sessions.first?.status, .failed)
        XCTAssertTrue(model.activeLocalSessions.isEmpty)
        XCTAssertTrue(model.transcriptBySessionID[session.id]?.contains {
            $0.content == .assistant(text: "Partial response", isStreaming: false)
        } == true)
        XCTAssertEqual(model.composerDrafts.tasks.draft(for: session.id).text, "  Keep this unsent draft 👩🏽‍💻\n")
        await model.resume(try XCTUnwrap(model.store.sessions.first))
        XCTAssertTrue(model.isAttached(session.id))
        let resumes = await adapter.resumeCount
        let prompts = await adapter.sentPrompts
        XCTAssertEqual(resumes, 1)
        XCTAssertTrue(prompts.isEmpty)
        XCTAssertNil(model.errorBySessionID[session.id])
        await model.shutdown()
    }

    /// The memory saver lets an idle Codex task's thread go, unless the thread keeps a background
    /// terminal (listed through the YHP wrapper). The account's last task leaves no adapter behind whose App Server ended
    /// with it, so the next message starts a new one and resumes the thread.
    func testTheMemorySaverLetsAnIdleCodexThreadGoAndTheNextMessageResumesIt() async throws {
        final class Made: @unchecked Sendable {
            private let lock = NSLock()
            private var adapters: [FakeHarnessAdapter] = []
            func add(_ adapter: FakeHarnessAdapter) { lock.withLock { adapters.append(adapter) } }
            var all: [FakeHarnessAdapter] { lock.withLock { adapters } }
        }
        let made = Made()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests")))
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in
                let adapter = FakeHarnessAdapter(kind: .codex)
                made.add(adapter)
                return YHPCodexCompatibilityAdapter(adapter: adapter, manifest: HarnessProtocolCompatibilityManifest.codex())
            }
        )
        let created = await model.createSession(harness: .codex, workspaceURL: URL(filePath: "/tmp/memory-saver"),
                                                runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Idle")
        let session = try XCTUnwrap(created)
        model.store.selectedSessionID = nil
        let first = try XCTUnwrap(made.all.first)
        await first.setBackgroundTerminals([CodexBackgroundTerminal(processID: "7", itemID: "item", command: "npm run dev",
                                                                    workspacePath: "/tmp/memory-saver")])
        let later = Date().addingTimeInterval(4 * 3_600)
        await model.checkHarnessMemory(now: later, pressure: .normal, physicalMemory: 16 << 30)
        XCTAssertTrue(model.isAttached(session.id), "A background terminal keeps the thread")

        await first.setBackgroundTerminals([])
        await model.checkHarnessMemory(now: later, pressure: .normal, physicalMemory: 16 << 30)
        XCTAssertFalse(model.isAttached(session.id), "Three hours off screen let it go")
        let closes = await first.closeCount
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(model.store.sessions.first?.status, .ready, "Let go to save memory, not failed")

        await model.send("Next step", to: try XCTUnwrap(model.store.sessions.first))
        XCTAssertTrue(model.isAttached(session.id))
        XCTAssertEqual(made.all.count, 2, "A new adapter: the old one's App Server ended with its last task")
        let resumes = await made.all.last?.resumeCount
        XCTAssertEqual(resumes, 1, "The same thread resumes")
        await model.shutdown()
    }

    func testEndedReadyStreamDetachesWithoutManufacturingFailure() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let model = try composerRefreshModel(adapter: adapter)
        let created = await model.createSession(harness: .codex, workspaceURL: URL(filePath: "/tmp/idle-end"),
                                                runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Idle")
        let session = try XCTUnwrap(created)
        await adapter.finishEvents(for: session.id)
        try await waitUntil { !model.isAttached(session.id) }
        XCTAssertFalse(model.isAttached(session.id))
        XCTAssertEqual(model.store.sessions.first?.status, .ready)
        XCTAssertNil(model.errorBySessionID[session.id])
        await model.shutdown()
    }

    func testCodexComposerRefreshDoesNotAttachDetachedTask() async throws {
        let session = SessionRecord(harness: .codex, workspaceURL: URL(filePath: "/tmp/composer"),
                                    runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Detached")
        let adapter = FakeHarnessAdapter(kind: .codex)
        let model = try composerRefreshModel(adapter: adapter, sessions: [session])
        await model.refreshConversationStatus(for: session)
        let probes = await adapter.probeCount
        let resumes = await adapter.resumeCount
        let models = await adapter.composerModelsReads
        XCTAssertEqual(probes, 0)
        XCTAssertEqual(resumes, 0)
        XCTAssertEqual(models, 0)
        XCTAssertNil(model.codexCapabilitiesBySessionID[session.id])
        await model.shutdown()
    }

    func testCodexComposerRefreshReadsOnlyComposerChoicesWithoutSending() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let model = try composerRefreshModel(adapter: adapter)
        let created = await model.createSession(harness: .codex, workspaceURL: URL(filePath: "/tmp/composer"),
                                               runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Composer")
        let session = try XCTUnwrap(created)
        await model.refreshConversationStatus(for: session)
        let models = await adapter.composerModelsReads
        let skills = await adapter.composerSkillsReads
        let plugins = await adapter.composerPluginReads
        let history = await adapter.recentPageLoads
        let prompts = await adapter.sentPrompts
        let submissions = await adapter.codexSubmissions
        XCTAssertEqual(model.codexCapabilitiesBySessionID[session.id]?.modelCatalog.models.map(\.displayName), ["Test Codex"])
        XCTAssertEqual(models, 1)
        XCTAssertEqual(skills, 1)
        XCTAssertEqual(plugins, 0)
        XCTAssertTrue(history.isEmpty)
        XCTAssertTrue(prompts.isEmpty)
        XCTAssertTrue(submissions.isEmpty)
        await model.shutdown()
    }

    func testNewTaskAttachmentsTravelWithTheFirstMessageOnEachHarnessPath() async throws {
        let image = CodexUserInput.localImage(URL(filePath: "/tmp/pasted/image.png"), detail: .auto)
        let mention = CodexUserInput.mention(name: "README.md", path: URL(filePath: "/repo/README.md"))

        // Codex keeps its typed envelopes from the home composer, as from the task composer.
        let codex = FakeHarnessAdapter(kind: .codex)
        let codexModel = try composerRefreshModel(adapter: codex)
        let codexTask = await codexModel.createSession(
            harness: .codex, workspaceURL: URL(filePath: "/tmp/new-task-attachments"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Look",
            initialPrompt: "Look at this", initialAttachments: [image, mention]
        )
        XCTAssertNotNil(codexTask)
        let submissions = await codex.codexSubmissions
        XCTAssertEqual(submissions.map(\.0.inputs), [[.text("Look at this"), image, mention]])
        await codexModel.shutdown()

        // Elsewhere the neutral projection applies: a mention becomes its path line.
        let claude = FakeHarnessAdapter(kind: .claudeCode)
        let claudeModel = try composerRefreshModel(adapter: claude)
        _ = await claudeModel.createSession(
            harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/new-task-attachments"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Look",
            initialPrompt: "Look at this", initialAttachments: [mention]
        )
        let claudePrompts = await claude.sentPrompts
        XCTAssertEqual(claudePrompts, ["Look at this\n@/repo/README.md"])
        await claudeModel.shutdown()
    }

    func testDeletedTaskDoesNotReceiveLateComposerChoices() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let model = try composerRefreshModel(adapter: adapter)
        let created = await model.createSession(harness: .codex, workspaceURL: URL(filePath: "/tmp/composer"),
                                               runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Composer")
        let session = try XCTUnwrap(created)
        await adapter.suspendNextCapabilityModes()
        let refresh = Task { await model.refreshConversationStatus(for: session) }
        try await waitUntil { await adapter.isCapabilityModesBlocked }
        let blocked = await adapter.isCapabilityModesBlocked
        XCTAssertTrue(blocked)
        await model.delete(session)
        await adapter.releaseSuspendedCapabilityModes()
        await refresh.value
        let skills = await adapter.composerSkillsReads
        XCTAssertNil(model.codexCapabilitiesBySessionID[session.id])
        XCTAssertEqual(skills, 0)
        await model.shutdown()
    }

    func testFirstTurnAdoptsProviderGeneratedTitle() async throws {
        let adapter = FakeHarnessAdapter(kind: .openCode)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            sessionTitleResolver: { _ in "Repair streaming and final rendering" },
            sessionTitleRetryCount: 0
        )
        let createdResult = await model.createSession(
            harness: .openCode,
            workspaceURL: URL(filePath: "/tmp/provider-title"),
            runtimeExecutableURL: URL(filePath: "/tmp/opencode"),
            title: "Could you repair streaming?",
            initialPrompt: "Could you repair streaming?"
        )
        let created = try XCTUnwrap(createdResult)
        XCTAssertEqual(created.titleOrigin, .provisional)

        await adapter.emit(.turnCompleted, for: created.id, sequence: 10)
        try await waitUntil {
            model.store.sessions.first(where: { $0.id == created.id })?.titleOrigin == .provider
        }

        let resolved = try XCTUnwrap(model.store.sessions.first(where: { $0.id == created.id }))
        XCTAssertEqual(resolved.title, "Repair streaming and final rendering")
        XCTAssertEqual(resolved.titleOrigin, .provider)
        await model.shutdown()
    }

    /// A long first turn still gets the harness's title while it runs: the title is read once the
    /// turn starts, on screen or not, not only when the turn ends (2026-10-22: child tasks kept their
    /// first words while Claude had already written `ai-title`).
    func testAProvisionalTitleIsReadWhenTheFirstTurnStarts() async throws {
        let adapter = FakeHarnessAdapter(kind: .openCode)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            sessionTitleResolver: { _ in "Measure the remaining lag" },
            sessionTitleRetryCount: 0
        )
        let createdResult = await model.createSession(
            harness: .openCode,
            workspaceURL: URL(filePath: "/tmp/provider-title-running"),
            runtimeExecutableURL: URL(filePath: "/tmp/opencode"),
            title: "Measure the remaining lag in Yardlet(`/Users/me/yardlet`, macOS",
            initialPrompt: "Measure the remaining lag in Yardlet(`/Users/me/yardlet`, macOS SwiftUI app).",
            selectsSession: false
        )
        let created = try XCTUnwrap(createdResult)
        XCTAssertEqual(created.titleOrigin, .provisional)

        await adapter.emit(.sessionStatusChanged(.running), for: created.id, sequence: 10)
        try await waitUntil {
            model.store.sessions.first(where: { $0.id == created.id })?.titleOrigin == .provider
        }
        let resolved = try XCTUnwrap(model.store.sessions.first(where: { $0.id == created.id }))
        XCTAssertEqual(resolved.title, "Measure the remaining lag")
        XCTAssertEqual(resolved.status, .running, "Read while the turn still runs")
        await model.shutdown()
    }

    func testProviderTitleThatArrivesAfterTheFallbackReplacesItAtTheNextTurn() async throws {
        let adapter = FakeHarnessAdapter(kind: .openCode)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let providerTitle = OSAllocatedUnfairLock<String?>(initialState: nil)
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            sessionTitleResolver: { _ in providerTitle.withLock { $0 } },
            sessionTitleRetryCount: 0
        )
        let prompt = "Run test_calc.py to find the failing tests, fix calc.py, and check the status first"
        let createdResult = await model.createSession(
            harness: .openCode,
            workspaceURL: URL(filePath: "/tmp/yardlet-sandbox"),
            runtimeExecutableURL: URL(filePath: "/tmp/opencode"),
            title: prompt,
            initialPrompt: prompt
        )
        let created = try XCTUnwrap(createdResult)

        await adapter.emit(.turnCompleted, for: created.id, sequence: 10)
        try await waitUntil {
            model.store.sessions.first(where: { $0.id == created.id })?.titleOrigin == .automatic
        }
        let fallback = try XCTUnwrap(model.store.sessions.first(where: { $0.id == created.id }))
        XCTAssertEqual(fallback.titleOrigin, .automatic)
        XCTAssertEqual(fallback.title, "yardlet-sandbox · \(prompt)".prefix(72).description)

        providerTitle.withLock { $0 = "Fix failing test_calc.py tests" }
        await adapter.emit(.turnCompleted, for: created.id, sequence: 11)
        try await waitUntil {
            model.store.sessions.first(where: { $0.id == created.id })?.titleOrigin == .provider
        }
        let resolved = try XCTUnwrap(model.store.sessions.first(where: { $0.id == created.id }))
        XCTAssertEqual(resolved.title, "Fix failing test_calc.py tests")
        XCTAssertEqual(resolved.titleOrigin, .provider)
        await model.shutdown()
    }

    func testManualTitleWinsOverLateProviderTitle() async throws {
        let adapter = FakeHarnessAdapter(kind: .openCode)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            sessionTitleResolver: { _ in "Late provider title" },
            sessionTitleRetryCount: 0
        )
        let createdResult = await model.createSession(
            harness: .openCode,
            workspaceURL: URL(filePath: "/tmp/manual-title"),
            runtimeExecutableURL: URL(filePath: "/tmp/opencode"),
            title: "Initial prompt",
            initialPrompt: "Initial prompt"
        )
        let created = try XCTUnwrap(createdResult)

        await model.rename(created, to: "My permanent title")
        await adapter.emit(.turnCompleted, for: created.id, sequence: 10)
        try await Task.sleep(for: .milliseconds(30))

        let resolved = try XCTUnwrap(model.store.sessions.first(where: { $0.id == created.id }))
        XCTAssertEqual(resolved.title, "My permanent title")
        XCTAssertEqual(resolved.titleOrigin, .manual)
        await model.shutdown()
    }

    func testCodexPresentationAdoptsThreadNameWithoutExtraTitleRequest() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            sessionTitleResolver: { _ in nil },
            sessionTitleRetryCount: 0
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/codex-title"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Inspect the task title",
            initialPrompt: "Inspect the task title"
        )
        let created = try XCTUnwrap(createdResult)
        var state = CodexTaskState.empty
        XCTAssertTrue(CodexTaskReducer().applySnapshot(.object([
            "id": .string(created.providerSessionID ?? "provider-thread"),
            "name": .string("Codex Generated Title"),
            "turns": .array([])
        ]), to: &state))
        await adapter.emitPresentation(state, for: created.id)
        try await waitUntil {
            model.store.sessions.first(where: { $0.id == created.id })?.titleOrigin == .provider
        }

        let resolved = try XCTUnwrap(model.store.sessions.first(where: { $0.id == created.id }))
        XCTAssertEqual(resolved.title, "Codex Generated Title")
        XCTAssertEqual(resolved.titleOrigin, .provider)
        await model.shutdown()
    }

    /// A pushed title keeps the schedule a pulled one has, without reading any stored title.
    func testPushedCodexTitleReplacesTheFallbackWithoutReadingStoredTitles() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let storedTitleReads = OSAllocatedUnfairLock(initialState: 0)
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            sessionTitleResolver: { _ in
                storedTitleReads.withLock { $0 += 1 }
                return "Stored title"
            },
            sessionTitleRetryCount: 0,
            restoresIndexOnLaunch: false
        )
        let prompt = "Fix the failing calculator test"
        let workspace = URL(filePath: "/tmp/codex-title-schedule")
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: workspace,
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: prompt,
            initialPrompt: prompt
        )
        let created = try XCTUnwrap(createdResult)

        // No name arrived by the end of the first turn, so the local fallback stands in.
        await adapter.emit(.turnCompleted, for: created.id, sequence: 10)
        try await waitUntil {
            model.store.sessions.first(where: { $0.id == created.id })?.titleOrigin == .automatic
        }
        let fallback = try XCTUnwrap(model.store.sessions.first(where: { $0.id == created.id }))
        XCTAssertEqual(fallback.titleOrigin, .automatic)
        XCTAssertEqual(fallback.title, SessionTitleProjection.fallbackTitle(
            firstUserMessage: prompt, workspaceURL: workspace))

        // The name Codex announces later replaces it, as a late pulled title would.
        var state = CodexTaskState.empty
        XCTAssertTrue(CodexTaskReducer().applySnapshot(.object([
            "id": .string(created.providerSessionID ?? "provider-thread"),
            "name": .string("Fix calculator test"),
            "turns": .array([])
        ]), to: &state))
        await adapter.emitPresentation(state, for: created.id)
        try await waitUntil {
            model.store.sessions.first(where: { $0.id == created.id })?.titleOrigin == .provider
        }
        await model.refreshConversationStatus(for: created)
        await model.refreshVisibleProviderTitles()
        await adapter.emit(.turnCompleted, for: created.id, sequence: 11)
        try await Task.sleep(for: .milliseconds(30))

        let resolved = try XCTUnwrap(model.store.sessions.first(where: { $0.id == created.id }))
        XCTAssertEqual(resolved.title, "Fix calculator test")
        XCTAssertEqual(resolved.titleOrigin, .provider)
        XCTAssertEqual(storedTitleReads.withLock { $0 }, 0)
        await model.shutdown()
    }

    func testRestoreUpgradesOnlyLegacyPromptTitleWithProviderMetadata() async throws {
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let transcriptRepository = UserDefaultsTranscriptRepository(
            defaults: defaults,
            keyPrefix: "title-migration."
        )
        let legacy = SessionRecord(
            harness: .grokBuild,
            workspaceURL: URL(filePath: "/tmp/legacy-title"),
            runtimeExecutableURL: URL(filePath: "/tmp/grok"),
            title: "Check legacy title",
            providerSessionID: "legacy-provider"
        )
        transcriptRepository.save(
            [TranscriptEntry(content: .user(text: "Check legacy title"))],
            for: legacy.id
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository(sessions: [legacy])),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            transcriptRepository: transcriptRepository,
            sessionTitleResolver: { _ in "Provider history title" }
        )

        await model.restoreIndex()

        let restored = try XCTUnwrap(model.store.sessions.first)
        XCTAssertEqual(restored.title, "Provider history title")
        XCTAssertEqual(restored.titleOrigin, .provider)
        await model.shutdown()
    }

    func testIndexRestoreStateCoversTheInitialEmptyStoreWindow() async throws {
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults)
        )

        XCTAssertTrue(model.isRestoringIndex)
        await model.restoreIndex()
        XCTAssertFalse(model.isRestoringIndex)

        let fixtureModel = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            restoresIndexOnLaunch: false
        )
        XCTAssertFalse(fixtureModel.isRestoringIndex)
        await fixtureModel.restoreIndex()
        XCTAssertFalse(fixtureModel.isRestoringIndex)
    }

    func testBackgroundCompletionPostsOneNotificationForNonSelectedTask() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let notifications = RecordingSystemNotificationCenter()
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            systemNotificationCenter: notifications
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/notifications"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Background task"
        )
        let created = try XCTUnwrap(createdResult)
        model.store.selectedSessionID = nil

        await adapter.emit(.sessionStatusChanged(.running), for: created.id, sequence: 9)
        await adapter.emit(.turnCompleted, for: created.id, sequence: 10)
        await adapter.emit(.sessionStatusChanged(.ready), for: created.id, sequence: 11)
        try await waitUntil { !notifications.posts.isEmpty }

        XCTAssertTrue(model.store.sessions.first(where: { $0.id == created.id })?.hasUnreadUpdate == true)
        XCTAssertEqual(notifications.posts.count, 1)
        XCTAssertEqual(notifications.posts.first?.title, L10n.string("Task completed"))

        await adapter.emit(.turnCompleted, for: created.id, sequence: 12)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(notifications.posts.count, 1)
        await model.shutdown()
    }

    func testBackgroundNotificationDoesNotPostAfterTaskDeletionDuringAuthorization() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let notifications = RecordingSystemNotificationCenter()
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            systemNotificationCenter: notifications
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/notification-delete-race"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Notification deletion race"
        )
        let created = try XCTUnwrap(createdResult)
        model.store.selectedSessionID = nil
        notifications.suspendAuthorization()

        await adapter.emit(.sessionStatusChanged(.running), for: created.id, sequence: 9)
        await adapter.emit(.turnCompleted, for: created.id, sequence: 10)
        try await waitUntil { notifications.isAuthorizationBlocked }
        XCTAssertTrue(notifications.isAuthorizationBlocked)

        await model.delete(created)
        notifications.releaseAuthorization()
        try await waitUntil { notifications.didFinishAuthorization }

        XCTAssertTrue(model.store.sessions.isEmpty)
        XCTAssertTrue(notifications.posts.isEmpty)
        await model.shutdown()
    }

    func testRenameDoesNotRecreateErrorAfterTaskDeletionDuringProviderNameUpdate() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter }
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/rename-delete-race"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Rename deletion race"
        )
        let created = try XCTUnwrap(createdResult)
        await adapter.suspendNextThreadName()

        let renameTask = Task {
            await model.rename(created, to: "Renamed after deletion")
        }
        try await waitUntil { await adapter.isThreadNameBlocked }
        let isBlocked = await adapter.isThreadNameBlocked
        XCTAssertTrue(isBlocked)

        await model.delete(created)
        await adapter.releaseSuspendedThreadName()
        await renameTask.value

        XCTAssertTrue(model.store.sessions.isEmpty)
        XCTAssertNil(model.bootstrapError)
        await model.shutdown()
    }

    func testArchiveDoesNotRecreateErrorAfterTaskDeletionDuringProviderArchive() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter }
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/archive-delete-race"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Archive deletion race"
        )
        let created = try XCTUnwrap(createdResult)
        await adapter.suspendNextArchive()

        let archiveTask = Task {
            await model.archive(created)
        }
        try await waitUntil { await adapter.isArchiveBlocked }
        let isBlocked = await adapter.isArchiveBlocked
        XCTAssertTrue(isBlocked)

        await model.delete(created)
        await adapter.releaseSuspendedArchive()
        await archiveTask.value

        XCTAssertTrue(model.store.sessions.isEmpty)
        XCTAssertNil(model.bootstrapError)
        await model.shutdown()
    }

    func testDeleteDoesNotRecreateErrorAfterTaskRemovalDuringProviderDelete() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter }
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/delete-archive-race"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Delete archive race"
        )
        let created = try XCTUnwrap(createdResult)
        await adapter.suspendNextDelete()

        let deleteTask = Task {
            await model.delete(created)
        }
        try await waitUntil { await adapter.isDeleteBlocked }
        let isBlocked = await adapter.isDeleteBlocked
        XCTAssertTrue(isBlocked)

        await model.archive(created)
        await adapter.releaseSuspendedDelete()
        await deleteTask.value

        XCTAssertTrue(model.store.sessions.isEmpty)
        XCTAssertNil(model.bootstrapError)
        await model.shutdown()
    }

    func testDeniedNotificationKeepsUnreadStateWithoutPosting() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let notifications = RecordingSystemNotificationCenter()
        notifications.authorizationValue = .denied
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            systemNotificationCenter: notifications
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/denied-notifications"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Denied background task"
        )
        let created = try XCTUnwrap(createdResult)
        model.store.selectedSessionID = nil

        await adapter.emit(.sessionStatusChanged(.failed), for: created.id, sequence: 10)
        try await waitUntil {
            model.store.sessions.first(where: { $0.id == created.id })?.hasUnreadUpdate == true
        }

        XCTAssertTrue(model.store.sessions.first(where: { $0.id == created.id })?.hasUnreadUpdate == true)
        XCTAssertTrue(notifications.posts.isEmpty)
        await model.shutdown()
    }

    func testHeadlessCapabilityRequestAttachesBeforeExplainingMissingFixtureControls() async throws {
        let session = SessionRecord(
            harness: .cursorAgent,
            workspaceURL: URL(filePath: "/tmp/cursor-project"),
            runtimeExecutableURL: URL(filePath: "/tmp/cursor-agent"),
            title: "Cursor task",
            providerSessionID: "cursor-session"
        )
        let adapter = FakeHarnessAdapter(kind: .cursorAgent)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests")))
        let model = AppModel(
            store: SessionStore(sessions: [session], repository: InMemorySessionRepository(sessions: [session])),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            restoresIndexOnLaunch: false
        )

        await model.loadProviderCapabilities(for: session)

        let probeCount = await adapter.probeCount
        XCTAssertTrue(model.isAttached(session.id))
        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(
            model.providerCapabilitiesBySessionID[session.id]?.selectors.map(\.id),
            [StructuredHeadlessOptionID.executionMode]
        )
        await model.setProviderOption(
            StructuredHeadlessOptionID.executionMode,
            value: "plan",
            for: session
        )
        XCTAssertEqual(
            model.store.sessions.first?.providerOptions[StructuredHeadlessOptionID.executionMode],
            "plan"
        )
        let providerOptions = await adapter.providerOptionSelections
        XCTAssertEqual(providerOptions[StructuredHeadlessOptionID.executionMode], "plan")
        await model.shutdown()
    }

    func testPersistedHeadlessOptionsRestoreBeforeTheNextInvocation() async throws {
        let session = SessionRecord(
            harness: .antigravityCLI,
            workspaceURL: URL(filePath: "/tmp/antigravity-settings-restore"),
            runtimeExecutableURL: URL(filePath: "/tmp/agy"),
            title: "Configured Antigravity task",
            providerSessionID: "agy-session",
            providerOptions: [
                StructuredHeadlessOptionID.executionMode: "plan",
                StructuredHeadlessOptionID.reasoningEffort: "high"
            ]
        )
        let adapter = FakeHarnessAdapter(kind: .antigravityCLI)
        let defaults = try XCTUnwrap(UserDefaults(
            suiteName: testDefaultsSuite("NativeHarnessClientTests")
        ))
        let model = AppModel(
            store: SessionStore(
                sessions: [session],
                repository: InMemorySessionRepository(sessions: [session])
            ),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            restoresIndexOnLaunch: false
        )

        await model.resume(session)

        let restored = await adapter.providerOptionSelections
        XCTAssertEqual(restored[StructuredHeadlessOptionID.executionMode], "plan")
        XCTAssertEqual(restored[StructuredHeadlessOptionID.reasoningEffort], "high")
        await model.shutdown()
    }

    func testHeadlessLiveCapabilitiesDoNotBlockTaskCreateAndSend() async throws {
        for harness in [HarnessKind.cursorAgent, .antigravityCLI] {
            let adapter = FakeHarnessAdapter(kind: harness)
            let defaults = try XCTUnwrap(
                UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
            )
            let model = AppModel(
                store: SessionStore(repository: InMemorySessionRepository()),
                runtimeSelections: RuntimeSelectionStore(defaults: defaults),
                registry: HarnessRegistry { _, _ in adapter },
                restoresIndexOnLaunch: false
            )

            let created = await model.createSession(
                harness: harness,
                workspaceURL: URL(filePath: "/tmp/\(harness.rawValue)-informational-send"),
                runtimeExecutableURL: URL(filePath: "/tmp/\(harness.rawValue)"),
                title: "Headless task",
                initialPrompt: "Run the headless task"
            )
            let session = try XCTUnwrap(created)
            let probeCountAfterSend = await adapter.probeCount

            await model.loadProviderCapabilities(for: session)
            let createCount = await adapter.createCount
            let sentPrompts = await adapter.sentPrompts
            let probeCountAfterCapabilities = await adapter.probeCount

            XCTAssertEqual(createCount, 1)
            XCTAssertEqual(sentPrompts, ["Run the headless task"])
            XCTAssertEqual(probeCountAfterCapabilities, probeCountAfterSend)
            XCTAssertEqual(model.transcriptBySessionID[session.id]?.map(\.content), [
                .user(text: "Run the headless task")
            ])
            XCTAssertEqual(
                model.providerCapabilitiesBySessionID[session.id]?.selectors.map(\.id),
                [StructuredHeadlessOptionID.executionMode]
            )
            await model.shutdown()
        }
    }

    func testInitialPromptShowsRunningWhileHarnessAttachIsInFlight() async throws {
        let adapter = FakeHarnessAdapter(kind: .grokBuild)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            restoresIndexOnLaunch: false
        )
        await adapter.suspendNextCreateSession()

        let creationTask = Task {
            await model.createSession(
                harness: .grokBuild,
                workspaceURL: URL(filePath: "/tmp/optimistic-create"),
                runtimeExecutableURL: URL(filePath: "/tmp/grok"),
                title: "Start immediately",
                initialPrompt: "Start immediately"
            )
        }
        try await waitUntil { await adapter.isCreateBlocked }

        let isCreateBlocked = await adapter.isCreateBlocked
        XCTAssertTrue(isCreateBlocked)
        let inFlight = try XCTUnwrap(model.store.sessions.first)
        XCTAssertEqual(inFlight.status, .running)
        XCTAssertEqual(inFlight.completionState, .none)

        await adapter.releaseSuspendedCreateSession()
        let createdResult = await creationTask.value
        let created = try XCTUnwrap(createdResult)
        XCTAssertEqual(model.store.sessions.first(where: { $0.id == created.id })?.status, .running)
        let createdPrompts = await adapter.sentPrompts
        XCTAssertEqual(createdPrompts, ["Start immediately"])
        await model.shutdown()
    }

    func testDetachedSendsShowRunningWhileHarnessResumeIsInFlight() async throws {
        for harness in [HarnessKind.codex, .grokBuild] {
            let session = SessionRecord(
                harness: harness,
                workspaceURL: URL(filePath: "/tmp/optimistic-\(harness.rawValue)"),
                runtimeExecutableURL: URL(filePath: "/tmp/\(harness.rawValue)"),
                title: "Resume immediately",
                status: .ready,
                providerSessionID: "provider-session",
                completionState: .completed
            )
            let adapter = FakeHarnessAdapter(kind: harness)
            let defaults = try XCTUnwrap(
                UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
            )
            let model = AppModel(
                store: SessionStore(
                    sessions: [session],
                    repository: InMemorySessionRepository(sessions: [session])
                ),
                runtimeSelections: RuntimeSelectionStore(defaults: defaults),
                registry: HarnessRegistry { _, _ in adapter },
                restoresIndexOnLaunch: false
            )
            await adapter.suspendNextResumeSession()

            let sendTask = Task {
                await model.send("Continue immediately", to: session)
            }
            try await waitUntil { await adapter.isResumeBlocked }

            let isResumeBlocked = await adapter.isResumeBlocked
            XCTAssertTrue(isResumeBlocked)
            let inFlight = try XCTUnwrap(model.store.sessions.first)
            XCTAssertEqual(inFlight.status, .running)
            XCTAssertEqual(inFlight.completionState, .none)
            XCTAssertEqual(model.transcriptBySessionID[session.id]?.map(\.content), [
                .user(text: "Continue immediately")
            ])

            await adapter.releaseSuspendedResumeSession()
            await sendTask.value
            XCTAssertEqual(model.store.sessions.first?.status, .running)
            let sentPrompts = await adapter.sentPrompts
            XCTAssertEqual(sentPrompts, ["Continue immediately"])
            await model.shutdown()
        }
    }

    func testStaleProviderCapabilitiesDoNotRecreateUnsupportedStateAfterTaskDeletion() async throws {
        let session = SessionRecord(
            harness: .cursorAgent,
            workspaceURL: URL(filePath: "/tmp/stale-provider-capabilities"),
            runtimeExecutableURL: URL(filePath: "/tmp/cursor-agent"),
            title: "Stale provider capabilities",
            providerSessionID: "cursor-session"
        )
        let adapter = FakeHarnessAdapter(kind: .cursorAgent)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests")))
        let model = AppModel(
            store: SessionStore(sessions: [session], repository: InMemorySessionRepository(sessions: [session])),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            restoresIndexOnLaunch: false
        )

        await model.delete(session)
        let probeCountAfterDelete = await adapter.probeCount
        await model.loadProviderCapabilities(for: session)

        XCTAssertTrue(model.store.sessions.isEmpty)
        XCTAssertNil(model.providerCapabilitiesBySessionID[session.id])
        let probeCount = await adapter.probeCount
        XCTAssertEqual(probeCount, probeCountAfterDelete)
        await model.shutdown()
    }

    func testHomeComposerCreatesSelectedTaskAndSendsInitialPrompt() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let registry = HarnessRegistry { _, _ in adapter }
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: registry
        )

        let created = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/home-composer"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Build the shell",
            initialPrompt: "Build the shell"
        )

        let session = try XCTUnwrap(created)
        XCTAssertEqual(model.store.selectedSessionID, session.id)
        let sentPrompts = await adapter.sentPrompts
        XCTAssertEqual(sentPrompts, ["Build the shell"])
        XCTAssertEqual(model.transcriptBySessionID[session.id]?.map(\.content), [
            .user(text: "Build the shell")
        ])
        await model.shutdown()
    }

    func testAttachedCodexDeleteConfirmsProviderMutationBeforeRemovingLocalState() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter }
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/delete-attached"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Delete me"
        )
        let created = try XCTUnwrap(createdResult)

        await model.delete(created)

        let deletedSessionIDs = await adapter.deletedSessionIDs
        let closeCount = await adapter.closeCount
        XCTAssertEqual(deletedSessionIDs, [created.id])
        XCTAssertTrue(model.store.sessions.isEmpty)
        XCTAssertFalse(model.isAttached(created.id))
        XCTAssertEqual(closeCount, 1)
    }

    func testDetachedCodexDeleteDoesNotWakeRuntimeOrInventProviderMutation() async throws {
        let session = SessionRecord(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/delete-detached"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Detached task",
            providerSessionID: "provider-thread"
        )
        let adapter = FakeHarnessAdapter(kind: .codex)
        let model = AppModel(
            store: SessionStore(
                sessions: [session],
                repository: InMemorySessionRepository(sessions: [session])
            ),
            runtimeSelections: RuntimeSelectionStore(),
            registry: HarnessRegistry { _, _ in adapter },
            restoresIndexOnLaunch: false
        )

        await model.delete(session)

        let probeCount = await adapter.probeCount
        let resumeCount = await adapter.resumeCount
        let deletedSessionIDs = await adapter.deletedSessionIDs
        XCTAssertTrue(model.store.sessions.isEmpty)
        XCTAssertEqual(probeCount, 0)
        XCTAssertEqual(resumeCount, 0)
        XCTAssertTrue(deletedSessionIDs.isEmpty)
    }

    func testCodexStreamingCheckpointsAreBoundedAndInterruptionFlushesLatestText() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let cache = CountingTranscriptCache()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("Yardlet.StreamCheckpoint")))
        let model = AppModel(store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter }, transcriptRepository: cache)
        let created = await model.createSession(harness: .codex, workspaceURL: URL(filePath: "/tmp/checkpoint"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Checkpoint")
        let session = try XCTUnwrap(created)
        func snapshot(_ text: String, status: String) -> CodexTaskState {
            CodexTaskState(thread: CodexTaskDecoder().thread(from: .object([
                "id": .string("checkpoint-thread"), "turns": .array([.object([
                    "id": .string("turn"), "status": .string(status), "items": .array([.object([
                        "id": .string("answer"), "type": .string("agentMessage"), "text": .string(text)
                    ])])
                ])])
            ])))
        }
        // Snapshots are written in the background: reading through the writer waits for the ones
        // already queued, where reading the cache directly can come before them.
        _ = model.transcriptSnapshots.load(for: session.id)
        let savesBefore = cache.saves
        let streamingStarted = ContinuousClock.now
        await adapter.emitPresentation(snapshot("한글 🌿\n", status: "inProgress"), for: session.id)
        try await waitUntil { model.codexPresentationBySessionID[session.id]?.activeTurnID != nil }
        // States arrive in order, so from here the count is the snapshots that follow.
        let shownAtStart = model.publicationCounts.codexStates
        for count in 2...20 {
            await adapter.emitPresentation(snapshot(String(repeating: "한글 🌿\n", count: count), status: "inProgress"), for: session.id)
        }
        try await waitUntil { model.publicationCounts.codexStates - shownAtStart >= 19 }
        _ = model.transcriptSnapshots.load(for: session.id)
        // The turn's start is written at once, then at most one checkpoint a second, however long the
        // twenty snapshots took to arrive.
        let checkpoints = Int((ContinuousClock.now - streamingStarted) / AppModel.codexTranscriptCheckpointInterval)
        XCTAssertLessThanOrEqual(cache.saves - savesBefore, 1 + checkpoints,
                                 "Streaming must not rewrite the entire transcript for every snapshot")
        let finalText = String(repeating: "한글 🌿\n", count: 20).trimmingCharacters(in: .whitespacesAndNewlines)
        await adapter.emitPresentation(snapshot(finalText, status: "interrupted"), for: session.id)
        try await waitUntil { model.codexPresentationBySessionID[session.id]?.activeTurnID == nil }
        // Queued as the turn ended, before any checkpoint could come due.
        XCTAssertEqual(model.transcriptSnapshots.load(for: session.id).last?.content,
                       .assistant(text: finalText, isStreaming: false))
        let savesAfterStop = cache.saves
        // Nothing to wait for here: a checkpoint left running would come due within its interval.
        try await Task.sleep(for: AppModel.codexTranscriptCheckpointInterval + .milliseconds(100))
        XCTAssertEqual(cache.saves, savesAfterStop, "Canceled checkpoint must not overwrite the terminal snapshot")
        await model.shutdown()
    }

    func testUnavailableRestoredModelRetainsRequestUntilUserSelectsAvailableModel() async throws {
        let selection = CodexModelSelection(model: "retired-model", reasoningEffort: "high")
        let session = SessionRecord(harness: .codex, workspaceURL: URL(filePath: "/tmp/retired-model"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Retired model",
            providerSessionID: "old-thread", providerOptions: [CodexModelSelection.storageKey: try XCTUnwrap(selection.storedValue)])
        let adapter = FakeHarnessAdapter(kind: .codex)
        let model = try composerRefreshModel(adapter: adapter, sessions: [session])
        let draft = CodexComposerDraft(inputs: [.text("Keep this exact request 🌿")])
        await model.submitCodex(draft, action: .automatic, to: session)
        let sent = await adapter.codexSubmissions
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(model.followUps.queue(for: session.id).first?.draft, draft)
        XCTAssertEqual(model.followUps.queue(for: session.id).first?.state, .failed)
        await model.selectCodexModel(.init(model: "test-model", reasoningEffort: "low"), for: session)
        await model.submitCodex(CodexComposerDraft(inputs: [.text("Use selected model")]), action: .automatic, to: session)
        let resumed = await adapter.codexSubmissions
        XCTAssertEqual(resumed.count, 1)
        await model.shutdown()
    }

    func testCodexModelSelectionPersistsWithoutSendingAndRestoresBeforeResume() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let repository = InMemorySessionRepository()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("Yardlet.ModelRestore")))
        let model = AppModel(store: SessionStore(repository: repository), runtimeSelections: RuntimeSelectionStore(defaults: defaults), registry: HarnessRegistry { _, _ in adapter })
        let created = await model.createSession(harness: .codex, workspaceURL: URL(filePath: "/tmp/model-restore"), runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Model restore")
        let session = try XCTUnwrap(created)
        let selection = CodexModelSelection(model: "test-model", reasoningEffort: "high")
        await model.selectCodexModel(selection, for: session)
        let saved = try XCTUnwrap(model.store.sessions.first)
        XCTAssertEqual(CodexModelSelection.restored(from: saved.providerOptions), selection)
        let child = await model.branch(saved, placement: .sidePanel)
        XCTAssertEqual(CodexModelSelection.restored(from: try XCTUnwrap(child).providerOptions), selection)
        XCTAssertEqual(model.codexCapabilitiesBySessionID[try XCTUnwrap(child).id]?.modelCatalog.selection, selection)
        let sent = await adapter.sentPrompts
        XCTAssertTrue(sent.isEmpty)
        await model.shutdown()
        let fresh = FakeHarnessAdapter(kind: .codex)
        let restored = AppModel(store: SessionStore(sessions: [saved], repository: repository), runtimeSelections: RuntimeSelectionStore(defaults: defaults), registry: HarnessRegistry { _, _ in fresh })
        await restored.loadCodexModels(for: saved)
        XCTAssertEqual(restored.codexCapabilitiesBySessionID[saved.id]?.modelCatalog.selection, selection)
        let resumedPrompts = await fresh.sentPrompts
        XCTAssertTrue(resumedPrompts.isEmpty)
        await restored.shutdown()
    }

    func testCodexPresentationStreamStaysSeparateFromCommonTranscript() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter }
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/presentation-boundary"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Typed task"
        )
        let created = try XCTUnwrap(createdResult)

        var typedState = CodexTaskState.empty
        XCTAssertTrue(CodexTaskReducer().applySnapshot(.object([
            "id": .string("provider-thread"),
            "turns": .array([])
        ]), to: &typedState))
        await adapter.emitPresentation(typedState, for: created.id)
        try await waitUntil {
            model.codexPresentationBySessionID[created.id]?.thread?.id == "provider-thread"
        }

        XCTAssertEqual(
            model.codexPresentationBySessionID[created.id]?.thread?.id,
            "provider-thread"
        )
        XCTAssertEqual(model.transcriptBySessionID[created.id] ?? [], [])
        await model.shutdown()
    }

    func testDetachedTaskRestoresCodexMessagesWithoutResumingProvider() async throws {
        let repository = InMemorySessionRepository()
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let transcriptRepository = UserDefaultsTranscriptRepository(
            defaults: defaults,
            keyPrefix: "transcript."
        )
        let adapter = FakeHarnessAdapter(kind: .codex)
        let model = AppModel(
            store: SessionStore(repository: repository),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            transcriptRepository: transcriptRepository
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/detached-transcript"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Detached transcript"
        )
        let created = try XCTUnwrap(createdResult)

        let state = CodexTaskState(
            thread: CodexTaskDecoder().thread(from: .object([
                "id": .string(created.providerSessionID ?? "provider-thread"),
                "status": .string("idle"),
                "turns": .array([.object([
                    "id": .string("turn-1"),
                    "status": .string("completed"),
                    "itemsView": .string("full"),
                    "items": .array([
                        .object([
                            "id": .string("user-1"),
                            "type": .string("userMessage"),
                            "content": .array([.object([
                                "type": .string("text"),
                                "text": .string("cached question")
                            ])])
                        ]),
                        .object([
                            "id": .string("assistant-1"),
                            "type": .string("agentMessage"),
                            "text": .string("cached answer"),
                            "phase": .string("final_answer")
                        ])
                    ])
                ])])
            ])),
            approvalsByID: [:],
            serverRequestsByID: [:],
            lastAppliedSequence: 0
        )
        await adapter.emitPresentation(state, for: created.id)
        try await waitUntil { transcriptRepository.load(for: created.id).count == 2 }
        XCTAssertEqual(
            transcriptRepository.load(for: created.id).map(\.content),
            [
                .user(text: "cached question"),
                .assistant(text: "cached answer", isStreaming: false)
            ]
        )
        await model.shutdown()

        let detachedAdapter = FakeHarnessAdapter(kind: .codex)
        let detachedModel = AppModel(
            store: SessionStore(repository: repository),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in detachedAdapter },
            transcriptRepository: transcriptRepository
        )
        await detachedModel.restoreIndex()
        let restored = try XCTUnwrap(detachedModel.store.sessions.first)

        XCTAssertEqual(
            detachedModel.transcriptBySessionID[restored.id]?.map(\.content),
            [
                .user(text: "cached question"),
                .assistant(text: "cached answer", isStreaming: false)
            ]
        )
        XCTAssertFalse(detachedModel.isAttached(restored.id))
        let detachedProbeCount = await detachedAdapter.probeCount
        let detachedResumeCount = await detachedAdapter.resumeCount
        XCTAssertEqual(detachedProbeCount, 0)
        XCTAssertEqual(detachedResumeCount, 0)

        await detachedModel.delete(restored)
        XCTAssertTrue(transcriptRepository.load(for: restored.id).isEmpty)
        await detachedModel.shutdown()
    }

    func testForkedCodexSessionReceivesPresentationStateImmediately() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter }
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/fork-presentation"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Source task"
        )
        let created = try XCTUnwrap(createdResult)

        await model.branch(created)
        let forked = try XCTUnwrap(model.store.selectedSession)
        XCTAssertNotEqual(forked.id, created.id)
        XCTAssertEqual(forked.title, L10n.format("Fork of %@", created.title))
        XCTAssertEqual(forked.environmentScope, created.environmentScope)
        XCTAssertEqual(forked.parentTaskID, created.id, "A fork nests under its task in the sidebar")

        var state = CodexTaskState.empty
        XCTAssertTrue(CodexTaskReducer().applySnapshot(.object([
            "id": .string("forked-provider-thread"),
            "forkedFromId": .string("source-provider-thread"),
            "turns": .array([])
        ]), to: &state))
        await adapter.emitPresentation(state, for: forked.id)

        try await waitUntil {
            model.codexPresentationBySessionID[forked.id]?.thread?.id == "forked-provider-thread"
        }

        XCTAssertEqual(
            model.codexPresentationBySessionID[forked.id]?.thread?.forkedFromID,
            "source-provider-thread"
        )
        await model.shutdown()
    }

    func testSelectedTurnForkKeepsSourceIdentityAndDraftAndInheritsProjectRoots() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let parent = SessionRecord(harness: .codex, workspaceURL: URL(filePath: "/tmp/fork-root"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Original", providerSessionID: "provider-source",
            environmentScope: .yardlet, projectID: UUID(), additionalRoots: ["/tmp/fork-extra"])
        var state = CodexTaskState.empty
        XCTAssertTrue(CodexTaskReducer().applySnapshot(.object([
            "id": .string("provider-source"), "turns": .array([
                .object(["id": .string("selected"), "status": .string("completed"), "items": .array([])]),
                .object(["id": .string("later"), "status": .string("completed"), "items": .array([])])
            ])
        ]), to: &state))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("Yardlet.SelectedFork")))
        let model = AppModel(store: SessionStore(sessions: [parent], repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults), registry: HarnessRegistry { _, _ in adapter },
            initialCodexPresentation: [parent.id: state], transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
            sessionTitleResolver: { _ in nil }, restoresIndexOnLaunch: false)
        model.composerDrafts.tasks.draft(for: parent.id).text = "Parent draft"
        let result = await model.branch(parent, at: .turn("selected"))
        let child = try XCTUnwrap(result)
        let boundaries = await adapter.forkedThroughTurnIDs
        let pages = await adapter.turnPageLoads
        XCTAssertEqual(boundaries, ["selected"])
        XCTAssertEqual(pages.last?.0, child.id)
        XCTAssertEqual(child.projectID, parent.projectID)
        XCTAssertEqual(child.additionalRoots, parent.additionalRoots)
        XCTAssertEqual(child.environmentScope, parent.environmentScope)
        XCTAssertEqual(model.store.sessions.first(where: { $0.id == parent.id })?.providerSessionID, parent.providerSessionID)
        XCTAssertEqual(model.composerDrafts.tasks.draft(for: parent.id).text, "Parent draft")
        XCTAssertEqual(model.store.selectedSessionID, child.id)
        await model.shutdown()
    }

    func testForkedCodexSessionRetainsLocalCapabilitySelections() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter }
        )
        let sourceResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/fork-capabilities"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Capability source"
        )
        let source = try XCTUnwrap(sourceResult)

        await model.loadCodexCapabilities(for: source)
        let preset = try XCTUnwrap(model.codexCapabilitiesBySessionID[source.id]?.modes.first)
        await model.selectCodexMode(preset.id, for: source)
        await model.selectCodexRunLocation(.workspaceWrite, for: source)

        await model.branch(source)
        let forked = try XCTUnwrap(model.store.selectedSession)
        let forkedCapabilities = try XCTUnwrap(
            model.codexCapabilitiesBySessionID[forked.id]
        )
        XCTAssertEqual(forkedCapabilities.modes.map(\.id), [preset.id])
        XCTAssertEqual(forkedCapabilities.selectedModeID, preset.id)
        XCTAssertEqual(forkedCapabilities.selectedRunLocation, .workspaceWrite)
        await model.shutdown()
    }

    func testForkDoesNotRecreateChildAfterSourceTaskDeletion() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter }
        )
        let sourceResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/fork-delete"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Fork deletion source"
        )
        let source = try XCTUnwrap(sourceResult)
        await adapter.suspendNextFork()

        let forkTask = Task {
            await model.branch(source)
        }
        try await waitUntil { await adapter.isForkBlocked }
        let isBlocked = await adapter.isForkBlocked
        XCTAssertTrue(isBlocked)

        await model.delete(source)
        await adapter.releaseSuspendedFork()
        await forkTask.value

        XCTAssertTrue(model.store.sessions.isEmpty)
        XCTAssertNil(model.errorBySessionID[source.id])
        let closeCount = await adapter.closeCount
        XCTAssertEqual(closeCount, 2)
        await model.shutdown()
    }

    func testLoadMoreCodexItemsUsesTurnCursorAndProviderIdentity() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter }
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/item-pagination"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Item pagination"
        )
        let created = try XCTUnwrap(createdResult)

        var state = CodexTaskState.empty
        XCTAssertTrue(CodexTaskReducer().applySnapshot(.object([
            "id": .string("provider-thread"),
            "turns": .array([
                .object([
                    "id": .string("turn-with-more-items"),
                    "status": .string("completed"),
                    "items": .array([])
                ])
            ])
        ]), to: &state))
        state.thread?.turns[0].itemsNextCursor = "items-cursor-2"
        await adapter.emitPresentation(state, for: created.id)
        try await waitUntil {
            model.codexPresentationBySessionID[created.id]?.thread?.turns.first?.itemsNextCursor == "items-cursor-2"
        }

        await model.loadMoreCodexItems(for: created, turnID: "turn-with-more-items")

        let loads = await adapter.itemPageLoads
        XCTAssertEqual(loads.count, 1)
        XCTAssertEqual(loads.first?.localSessionID, created.id)
        XCTAssertEqual(loads.first?.turnID, "turn-with-more-items")
        XCTAssertEqual(loads.first?.cursor, "items-cursor-2")
        XCTAssertEqual(loads.first?.limit, 100)
        await model.shutdown()
    }

    func testLoadMoreCodexTurnsDoesNotRecreateActionErrorAfterTaskDeletionDuringProviderPage() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter }
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/turn-pagination-delete"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Turn pagination deletion"
        )
        let created = try XCTUnwrap(createdResult)

        var state = CodexTaskState.empty
        XCTAssertTrue(CodexTaskReducer().applySnapshot(.object([
            "id": .string("provider-thread"),
            "turns": .array([])
        ]), to: &state))
        state.thread?.turnsNextCursor = "turns-cursor-2"
        await adapter.emitPresentation(state, for: created.id)
        try await waitUntil {
            model.codexPresentationBySessionID[created.id]?.thread?.turnsNextCursor == "turns-cursor-2"
        }

        await adapter.suspendAndFailNextTurnPage()
        let loadTask = Task {
            await model.loadMoreCodexTurns(for: created)
        }
        try await waitUntil { await adapter.isTurnPageBlocked }
        let isTurnPageBlocked = await adapter.isTurnPageBlocked
        XCTAssertTrue(isTurnPageBlocked)

        await model.delete(created)
        await adapter.releaseSuspendedTurnPage()
        await loadTask.value

        XCTAssertTrue(model.store.sessions.isEmpty)
        XCTAssertNil(model.codexCapabilitiesBySessionID[created.id])
        XCTAssertNil(model.errorBySessionID[created.id])
        XCTAssertNil(model.bootstrapError)
        await model.shutdown()
    }

    func testLoadMoreCodexItemsDoesNotRecreateActionErrorAfterTaskDeletionDuringProviderPage() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter }
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/item-pagination-delete"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Item pagination deletion"
        )
        let created = try XCTUnwrap(createdResult)

        var state = CodexTaskState.empty
        XCTAssertTrue(CodexTaskReducer().applySnapshot(.object([
            "id": .string("provider-thread"),
            "turns": .array([
                .object([
                    "id": .string("turn-with-more-items"),
                    "status": .string("completed"),
                    "items": .array([])
                ])
            ])
        ]), to: &state))
        state.thread?.turns[0].itemsNextCursor = "items-cursor-2"
        await adapter.emitPresentation(state, for: created.id)
        try await waitUntil {
            model.codexPresentationBySessionID[created.id]?.thread?.turns.first?.itemsNextCursor == "items-cursor-2"
        }

        await adapter.suspendAndFailNextItemPage()
        let loadTask = Task {
            await model.loadMoreCodexItems(for: created, turnID: "turn-with-more-items")
        }
        try await waitUntil { await adapter.isItemPageBlocked }
        let isItemPageBlocked = await adapter.isItemPageBlocked
        XCTAssertTrue(isItemPageBlocked)

        await model.delete(created)
        await adapter.releaseSuspendedItemPage()
        await loadTask.value

        XCTAssertTrue(model.store.sessions.isEmpty)
        XCTAssertNil(model.codexCapabilitiesBySessionID[created.id])
        XCTAssertNil(model.errorBySessionID[created.id])
        XCTAssertNil(model.bootstrapError)
        await model.shutdown()
    }

    /// The import sheet's Codex list reads the folder's history a page at a time; a row the
    /// provider repeats on the next page shows once. Listing creates no task.
    func testImportListPagesCodexHistoryForTheFolderWithoutRepeats() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter }
        )
        model.runtimeSelections.select(URL(filePath: "/usr/bin/true"), for: .codex)
        let workspace = URL(filePath: "/tmp/recent-pagination")

        let first = try await model.importableConversations(harness: .codex, workspaceURL: workspace, connection: nil)
        XCTAssertEqual(first.conversations.map(\.providerSessionID), ["recent-first"])
        XCTAssertEqual(first.nextCursor, "recent-cursor")
        let next = try await model.importableConversations(harness: .codex, workspaceURL: workspace, connection: nil,
                                                           cursor: first.nextCursor)
        let page = first.appending(next)
        XCTAssertEqual(page.conversations.map(\.providerSessionID), ["recent-first", "recent-second"])
        XCTAssertNil(page.nextCursor)
        let loads = await adapter.recentPageLoads
        XCTAssertEqual(loads.map(\.cursor), [nil, "recent-cursor"])
        XCTAssertEqual(loads.last?.workspaceURL.path, "/tmp/recent-pagination")
        XCTAssertTrue(model.store.sessions.isEmpty)
        await model.shutdown()
    }

    func testCapabilityLoadDoesNotRecreateStateAfterTaskDeletion() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter }
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/capability-load-delete"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Capability deletion"
        )
        let created = try XCTUnwrap(createdResult)
        await adapter.suspendNextCapabilityModes()

        let loadTask = Task {
            await model.loadCodexCapabilities(for: created)
        }
        try await waitUntil { await adapter.isCapabilityModesBlocked }
        let isBlocked = await adapter.isCapabilityModesBlocked
        XCTAssertTrue(isBlocked)

        await model.delete(created)
        await adapter.releaseSuspendedCapabilityModes()
        await loadTask.value

        XCTAssertNil(model.codexCapabilitiesBySessionID[created.id])
        XCTAssertTrue(model.store.sessions.isEmpty)
        await model.shutdown()
    }

    func testCapabilityLoadIgnoresAlreadyDeletedTaskWithoutProviderWake() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter }
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/capability-load-already-deleted"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Already deleted capability"
        )
        let created = try XCTUnwrap(createdResult)

        await model.delete(created)
        let probeCountAfterDelete = await adapter.probeCount
        await model.loadCodexCapabilities(for: created)

        XCTAssertTrue(model.store.sessions.isEmpty)
        XCTAssertNil(model.codexCapabilitiesBySessionID[created.id])
        let probeCount = await adapter.probeCount
        XCTAssertEqual(probeCount, probeCountAfterDelete)
        await model.shutdown()
    }

    func testCodexResponseDoesNotRecreateStateAfterTaskDeletion() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter }
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/codex-response-delete"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Response deletion"
        )
        let created = try XCTUnwrap(createdResult)
        await adapter.suspendNextCodexServerResponse()

        let responseTask = Task {
            await model.respondCodex(
                to: "server-request",
                response: .command(.accept),
                in: created
            )
        }
        try await waitUntil { await adapter.isCodexServerResponseBlocked }
        let isBlocked = await adapter.isCodexServerResponseBlocked
        XCTAssertTrue(isBlocked)

        await model.delete(created)
        await adapter.releaseSuspendedCodexServerResponse()
        await responseTask.value

        XCTAssertNil(model.codexPresentationBySessionID[created.id])
        XCTAssertNil(model.errorBySessionID[created.id])
        XCTAssertTrue(model.store.sessions.isEmpty)
        await model.shutdown()
    }

    func testCodexSubmissionDoesNotRecreateQueueOrErrorAfterTaskDeletion() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter }
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/codex-submit-delete"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Submission deletion"
        )
        let created = try XCTUnwrap(createdResult)
        await adapter.suspendAndFailNextCodexSubmission()

        let submissionTask = Task {
            await model.submitCodex(
                CodexComposerDraft(inputs: [.text("will not survive deletion")]),
                action: .automatic,
                to: created
            )
        }
        try await waitUntil { await adapter.isCodexSubmissionBlocked }
        let isBlocked = await adapter.isCodexSubmissionBlocked
        XCTAssertTrue(isBlocked)

        await model.delete(created)
        await adapter.releaseSuspendedCodexSubmission()
        await submissionTask.value

        XCTAssertTrue(model.followUps.queue(for: created.id).isEmpty)
        XCTAssertNil(model.errorBySessionID[created.id])
        XCTAssertNil(model.transcriptBySessionID[created.id])
        XCTAssertTrue(model.store.sessions.isEmpty)
        await model.shutdown()
    }

    func testCodexModeSelectionDoesNotRecreateCapabilityStateAfterTaskDeletion() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter }
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/codex-mode-delete"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Mode deletion"
        )
        let created = try XCTUnwrap(createdResult)
        await model.loadCodexCapabilities(for: created)
        let preset = try XCTUnwrap(model.codexCapabilitiesBySessionID[created.id]?.modes.first)
        await adapter.suspendNextModeSelection()

        let selectionTask = Task {
            await model.selectCodexMode(preset.id, for: created)
        }
        try await waitUntil { await adapter.isModeSelectionBlocked }
        let isBlocked = await adapter.isModeSelectionBlocked
        XCTAssertTrue(isBlocked)

        await model.delete(created)
        await adapter.releaseSuspendedModeSelection()
        await selectionTask.value

        XCTAssertNil(model.codexCapabilitiesBySessionID[created.id])
        XCTAssertTrue(model.store.sessions.isEmpty)
        await model.shutdown()
    }

    func testInterruptDoesNotRecreateErrorStateAfterTaskDeletion() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter }
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/interrupt-delete"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Interrupt deletion"
        )
        let created = try XCTUnwrap(createdResult)
        await adapter.suspendAndFailNextInterrupt()

        let interruptTask = Task {
            await model.interrupt(created)
        }
        try await waitUntil { await adapter.isInterruptBlocked }
        let isBlocked = await adapter.isInterruptBlocked
        XCTAssertTrue(isBlocked)

        await model.delete(created)
        await adapter.releaseSuspendedInterrupt()
        await interruptTask.value

        XCTAssertNil(model.errorBySessionID[created.id])
        XCTAssertTrue(model.store.sessions.isEmpty)
        await model.shutdown()
    }

    func testAttachDoesNotRecreateHandleAfterTaskDeletion() async throws {
        let session = SessionRecord(
            harness: .cursorAgent,
            workspaceURL: URL(filePath: "/tmp/attach-delete"),
            runtimeExecutableURL: URL(filePath: "/tmp/cursor-agent"),
            title: "Attach deletion",
            providerSessionID: "cursor-session"
        )
        let adapter = FakeHarnessAdapter(kind: .cursorAgent)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(
                sessions: [session],
                repository: InMemorySessionRepository(sessions: [session])
            ),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            restoresIndexOnLaunch: false
        )
        await adapter.suspendNextResumeSession()

        let resumeTask = Task {
            await model.resume(session)
        }
        try await waitUntil { await adapter.isResumeBlocked }
        let isBlocked = await adapter.isResumeBlocked
        XCTAssertTrue(isBlocked)

        await model.delete(session)
        await adapter.releaseSuspendedResumeSession()
        await resumeTask.value

        XCTAssertTrue(model.store.sessions.isEmpty)
        XCTAssertFalse(model.isAttached(session.id))
        XCTAssertNil(model.errorBySessionID[session.id])
        let closeCount = await adapter.closeCount
        XCTAssertEqual(closeCount, 1)
        await model.shutdown()
    }

    func testDeletedTaskRejectsLateHarnessAndPresentationUpdates() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter }
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/late-event-delete"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Late event deletion"
        )
        let created = try XCTUnwrap(createdResult)

        await model.delete(created)
        await adapter.emit(
            .error(message: "late error", recoverable: true),
            for: created.id,
            sequence: 99
        )
        await adapter.emitPresentation(.empty, for: created.id)
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertTrue(model.store.sessions.isEmpty)
        XCTAssertNil(model.eventsBySessionID[created.id])
        XCTAssertNil(model.transcriptBySessionID[created.id])
        XCTAssertNil(model.errorBySessionID[created.id])
        XCTAssertNil(model.codexPresentationBySessionID[created.id])
        await model.shutdown()
    }

    func testCodexPendingApprovalRestoresOnlyWhileProviderContextIsAnswerable() async throws {
        let repository = InMemorySessionRepository()
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let pendingRepository = UserDefaultsCodexPendingServerRequestRepository(
            defaults: defaults,
            keyPrefix: "pending."
        )
        let adapter = FakeHarnessAdapter(kind: .codex)
        let model = AppModel(
            store: SessionStore(repository: repository),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            codexPendingRequestRepository: pendingRepository
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/pending-approval"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Approval recovery"
        )
        let created = try XCTUnwrap(createdResult)

        var state = CodexTaskState.empty
        let reducer = CodexTaskReducer()
        XCTAssertTrue(reducer.applySnapshot(.object([
            "id": .string("provider-pending-thread"),
            "turns": .array([
                .object(["id": .string("turn-pending"), "status": .string("inProgress"), "items": .array([])])
            ])
        ]), to: &state))
        XCTAssertTrue(reducer.applyServerRequest(
            id: .string("approval-1"),
            method: "item/commandExecution/requestApproval",
            params: .object([
                "threadId": .string("provider-pending-thread"),
                "turnId": .string("turn-pending"),
                "command": .string("swift test")
            ]),
            sequence: 1,
            to: &state
        ))
        await adapter.emitPresentation(state, for: created.id)
        try await waitUntil { !pendingRepository.load(for: created.id).isEmpty }
        XCTAssertEqual(pendingRepository.load(for: created.id).map(\.id), ["s:approval-1"])
        await model.shutdown()

        let restoredAdapter = FakeHarnessAdapter(kind: .codex)
        let restoredModel = AppModel(
            store: SessionStore(repository: repository),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in restoredAdapter },
            codexPendingRequestRepository: pendingRepository
        )
        await restoredModel.restoreIndex()
        let persistedSession = try XCTUnwrap(restoredModel.store.sessions.first)
        await restoredModel.resume(persistedSession)
        try await waitUntil {
            restoredModel.codexPresentationBySessionID[persistedSession.id]?.serverRequestsByID.isEmpty == false
        }

        XCTAssertEqual(
            restoredModel.codexPresentationBySessionID[persistedSession.id]?.serverRequestsByID["s:approval-1"]?.kind,
            .commandExecutionApproval
        )
        let restoredRequests = await restoredAdapter.restoredPendingRequests[persistedSession.id]
        XCTAssertEqual(restoredRequests?.map(\.id), ["s:approval-1"])

        await restoredModel.respondCodex(
            to: "s:approval-1",
            response: .command(.acceptForSession),
            in: persistedSession
        )
        let retained = try XCTUnwrap(pendingRepository.load(for: persistedSession.id).first)
        XCTAssertFalse(retained.isPending)
        await restoredModel.shutdown()

        let resolvedAdapter = FakeHarnessAdapter(kind: .codex)
        let resolvedModel = AppModel(
            store: SessionStore(repository: repository),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in resolvedAdapter },
            codexPendingRequestRepository: pendingRepository
        )
        await resolvedModel.restoreIndex()
        let resolvedSession = try XCTUnwrap(resolvedModel.store.sessions.first)
        await resolvedModel.resume(resolvedSession)
        try await waitUntil {
            resolvedModel.codexPresentationBySessionID[resolvedSession.id]?.serverRequestsByID.isEmpty == false
        }

        guard case .resolved = resolvedModel.codexPresentationBySessionID[resolvedSession.id]?
            .serverRequestsByID["s:approval-1"]?.resolution else {
            return XCTFail("resolved approval should remain visible after another resume")
        }
        let answerableAfterResolution = await resolvedAdapter.restoredPendingRequests[resolvedSession.id]
        XCTAssertEqual(answerableAfterResolution, [])
        await resolvedModel.shutdown()

        pendingRepository.save([
            CodexPendingServerRequest(
                CodexServerRequestState(
                    id: "s:approval-expired",
                    method: "item/commandExecution/requestApproval",
                    kind: .commandExecutionApproval,
                    threadID: resolvedSession.providerSessionID,
                    turnID: "turn-expired",
                    itemID: "item-expired",
                    params: .object(["command": .string("touch should-not-run")]),
                    resolution: .pending
                )
            )
        ], for: resolvedSession.id)

        let expiredAdapter = FakeHarnessAdapter(kind: .codex)
        await expiredAdapter.rejectPendingRequestRestoration()
        let expiredModel = AppModel(
            store: SessionStore(repository: repository),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in expiredAdapter },
            codexPendingRequestRepository: pendingRepository
        )
        await expiredModel.restoreIndex()
        let expiredSession = try XCTUnwrap(expiredModel.store.sessions.first)
        await expiredModel.resume(expiredSession)
        try await waitUntil {
            expiredModel.codexPresentationBySessionID[expiredSession.id]?.serverRequestsByID["s:approval-expired"] != nil
        }

        guard case let .rejected(code, message) = expiredModel.codexPresentationBySessionID[
            expiredSession.id
        ]?.serverRequestsByID["s:approval-expired"]?.resolution else {
            return XCTFail("approval without a live provider context should expire")
        }
        XCTAssertEqual(code, CodexPendingServerRequest.expiredRuntimeCode)
        XCTAssertEqual(
            message,
            L10n.string("Approval expired because the provider runtime stopped.")
        )
        XCTAssertFalse(try XCTUnwrap(pendingRepository.load(for: expiredSession.id).first).isPending)
        let expiredDecisions = await expiredAdapter.permissionDecisions
        XCTAssertTrue(expiredDecisions.isEmpty)
        await expiredModel.shutdown()
    }

    func testInterruptedAnswerSurvivesMissingProviderItemAndYieldsToProviderHistory() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("Yardlet.InterruptedAnswer")))
        let timeline = UserDefaultsCodexTimelineItemRepository(defaults: defaults)
        let adapter = FakeHarnessAdapter(kind: .codex)
        let model = AppModel(store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults), registry: HarnessRegistry { _, _ in adapter },
            codexTimelineItemRepository: timeline)
        let created = await model.createSession(harness: .codex, workspaceURL: URL(filePath: "/tmp/partial-answer"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Partial answer")
        let session = try XCTUnwrap(created)
        func state(text: String?) -> CodexTaskState {
            let items: [JSONValue] = text.map { [.object(["id": .string("answer"), "type": .string("agentMessage"), "text": .string($0)])] } ?? []
            return CodexTaskState(thread: CodexTaskDecoder().thread(from: .object([
                "id": .string("thread"), "turns": .array([.object([
                    "id": .string("interrupted-turn"), "status": .string("interrupted"), "items": .array(items)
                ])])
            ])))
        }
        var partial = state(text: "Initial text")
        partial.thread?.turns[0].items[0].content = .agentMessage(.init(text: "Observed partial answer 🌿", phase: .finalAnswer, memoryCitation: nil))
        await adapter.emitPresentation(partial, for: session.id)
        try await waitUntil { !timeline.load(for: session.id).isEmpty }
        let saved = try XCTUnwrap(timeline.load(for: session.id).first)
        XCTAssertEqual(saved.pageEntry.item.content, partial.thread?.turns[0].items[0].content)
        await adapter.emitPresentation(state(text: nil), for: session.id)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.codexPresentationBySessionID[session.id]?.thread?.turns[0].items.first?.content, partial.thread?.turns[0].items[0].content)
        let provider = state(text: "Provider history wins")
        await adapter.emitPresentation(provider, for: session.id)
        try await waitUntil {
            model.codexPresentationBySessionID[session.id]?.thread?.turns[0].items.first?.content
                != partial.thread?.turns[0].items[0].content
        }
        XCTAssertEqual(model.codexPresentationBySessionID[session.id]?.thread?.turns[0].items.first?.content, provider.thread?.turns[0].items[0].content)
        await model.shutdown()
    }

    /// A running command once showed only "In progress": each publication merged the saved copy
    /// of its card, written before the output streamed, over the live card.
    func testARunningCommandKeepsItsStreamedOutputAcrossPublications() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("Yardlet.LiveCommandOutput")))
        let timeline = UserDefaultsCodexTimelineItemRepository(defaults: defaults)
        let adapter = FakeHarnessAdapter(kind: .codex)
        let model = AppModel(store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults), registry: HarnessRegistry { _, _ in adapter },
            codexTimelineItemRepository: timeline)
        let created = await model.createSession(harness: .codex, workspaceURL: URL(filePath: "/tmp/live-output"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Live output")
        let session = try XCTUnwrap(created)
        func state(output: String?) -> CodexTaskState {
            var state = CodexTaskState(thread: CodexTaskDecoder().thread(from: .object([
                "id": .string("thread"), "turns": .array([.object([
                    "id": .string("turn"), "status": .string("inProgress"), "items": .array([])
                ])])
            ])))
            // The provider frame keeps `aggregatedOutput` null; streamed output lives in content.
            var item = CodexTaskDecoder().item(from: .object([
                "id": .string("command"), "type": .string("commandExecution"), "command": .string("swift build"),
                "cwd": .string("/tmp/live-output"), "status": .string("inProgress"), "aggregatedOutput": .null
            ]), fallbackID: "command", lifecycle: .inProgress)
            if let output, case var .commandExecution(command) = item.content {
                command.aggregatedOutput = output
                item.content = .commandExecution(command)
            }
            state.thread?.turns[0].items = [item]
            return state
        }
        func shownOutput() -> String? {
            guard case let .commandExecution(command) = model.codexPresentationBySessionID[session.id]?
                .thread?.turns.first?.items.first?.content else { return nil }
            return command.aggregatedOutput
        }
        await adapter.emitPresentation(state(output: nil), for: session.id)
        try await waitUntil { !timeline.load(for: session.id).isEmpty }
        XCTAssertEqual(timeline.load(for: session.id).map(\.id), ["command"])
        for output in ["Compiling 1/3\n", "Compiling 1/3\nCompiling 2/3\n"] {
            await adapter.emitPresentation(state(output: output), for: session.id)
            try await waitUntil { shownOutput() == output }
            XCTAssertEqual(shownOutput(), output)
        }
        // The saved copy follows the live output, so a restart keeps what was seen. Output that
        // only streams into a saved card is written once a second rather than on every state.
        func savedOutput() -> String? {
            guard case let .commandExecution(saved) = timeline.load(for: session.id).first?.pageEntry.item.content
            else { return nil }
            return saved.aggregatedOutput
        }
        try await waitUntil { savedOutput() == "Compiling 1/3\nCompiling 2/3\n" }
        XCTAssertEqual(savedOutput(), "Compiling 1/3\nCompiling 2/3\n")
        await model.shutdown()
    }

    func testImplementingAPlanLeavesPlanModeAndSendsTheCodexAppsRequest() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("Yardlet.ImplementPlan")))
        let adapter = FakeHarnessAdapter(kind: .codex)
        await adapter.offerDefaultMode()
        let model = AppModel(store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults), registry: HarnessRegistry { _, _ in adapter })
        let created = await model.createSession(harness: .codex, workspaceURL: URL(filePath: "/tmp/implement-plan"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Plan")
        let session = try XCTUnwrap(created)

        await model.implementCodexPlan("# Plan\n1. Ship it", in: session)

        let selections = await adapter.selectedCollaborationPresets
        let selected = try XCTUnwrap(selections.last ?? nil)
        XCTAssertEqual(selected.mode, "default")
        XCTAssertEqual(model.codexCapabilitiesBySessionID[session.id]?.selectedModeID, selected.id)
        let submissions = await adapter.codexSubmissions
        XCTAssertEqual(submissions.count, 1)
        XCTAssertEqual(submissions.last?.0.text, "PLEASE IMPLEMENT THIS PLAN:\n# Plan\n1. Ship it")
        XCTAssertEqual(submissions.last?.1, .start)
        await model.shutdown()
    }

    func testCodexNonNarrativeTimelineItemsPersistAcrossProviderResumeGap() async throws {
        let repository = InMemorySessionRepository()
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let timelineRepository = UserDefaultsCodexTimelineItemRepository(
            defaults: defaults,
            keyPrefix: "timeline."
        )
        let adapter = FakeHarnessAdapter(kind: .codex)
        let model = AppModel(
            store: SessionStore(repository: repository),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            codexTimelineItemRepository: timelineRepository
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/timeline-recovery"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Timeline recovery"
        )
        let created = try XCTUnwrap(createdResult)

        let providerState = CodexTaskState(
            thread: CodexTaskDecoder().thread(from: .object([
                "id": .string(created.providerSessionID ?? "provider-timeline-thread"),
                "turns": .array([.object([
                    "id": .string("turn-command"),
                    "status": .string("completed"),
                    "itemsView": .string("full"),
                    "items": .array([.object([
                        "id": .string("command-1"),
                        "type": .string("commandExecution"),
                        "command": .string("swift test"),
                        "cwd": .string("/tmp/timeline-recovery"),
                        "status": .string("completed")
                    ])])
                ])])
            ])),
            approvalsByID: [:],
            serverRequestsByID: [:],
            lastAppliedSequence: 0
        )
        await adapter.emitPresentation(providerState, for: created.id)
        try await waitUntil { !timelineRepository.load(for: created.id).isEmpty }
        XCTAssertEqual(timelineRepository.load(for: created.id).map(\.id), ["command-1"])
        await model.shutdown()

        // Cards saved in preferences, as before they had files, come back from the file the next
        // launch moves them to, and leave the preferences.
        let cardFolder = FileManager.default.temporaryDirectory
            .appending(path: "YardletCodexCards-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cardFolder) }
        let cardFiles = FileCodexTimelineItemRepository(directoryURL: cardFolder)
        cardFiles.moveCards(from: timelineRepository)
        XCTAssertNil(defaults.object(forKey: "timeline.\(created.id.uuidString)"))

        let resumedAdapter = FakeHarnessAdapter(kind: .codex)
        var narrativeOnly = providerState
        narrativeOnly.thread?.turns[0].items = []
        await resumedAdapter.emitPresentation(narrativeOnly, for: created.id)
        let resumedModel = AppModel(
            store: SessionStore(repository: repository),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in resumedAdapter },
            codexTimelineItemRepository: cardFiles
        )
        await resumedModel.restoreIndex()
        let resumedSession = try XCTUnwrap(resumedModel.store.sessions.first)
        await resumedModel.resume(resumedSession)
        try await waitUntil {
            resumedModel.codexPresentationBySessionID[resumedSession.id]?.thread?.turns.first?.items.isEmpty == false
        }

        let restoredItems = resumedModel.codexPresentationBySessionID[resumedSession.id]?
            .thread?.turns.first?.items ?? []
        XCTAssertEqual(restoredItems.map(\.id), ["command-1"])
        guard case .commandExecution = restoredItems.first?.content else {
            return XCTFail("command card should be reconstructed from app-local activity history")
        }
        await resumedModel.shutdown()

        let latestOnlyAdapter = FakeHarnessAdapter(kind: .codex)
        var latestOnly = providerState
        latestOnly.thread?.turns = [CodexTaskDecoder().turn(from: .object([
            "id": .string("turn-latest"),
            "status": .string("completed"),
            "itemsView": .string("full"),
            "items": .array([])
        ]), fallbackID: "turn-latest")!]
        await latestOnlyAdapter.emitPresentation(latestOnly, for: created.id)
        let latestOnlyModel = AppModel(
            store: SessionStore(repository: repository),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in latestOnlyAdapter },
            codexTimelineItemRepository: cardFiles
        )
        await latestOnlyModel.restoreIndex()
        let latestSession = try XCTUnwrap(latestOnlyModel.store.sessions.first)
        await latestOnlyModel.resume(latestSession)
        try await waitUntil {
            latestOnlyModel.codexPresentationBySessionID[latestSession.id]?.thread?.turns.first?.id == "turn-latest"
        }
        XCTAssertEqual(
            latestOnlyModel.codexPresentationBySessionID[latestSession.id]?.thread?.turns.map(\.id),
            ["turn-latest"]
        )
        await latestOnlyModel.shutdown()
    }

    func testOpeningTypedSubagentThreadResumesItAsAChildTaskWithoutStartingATurn() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let source = SessionRecord(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/subagent-project"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Parent task",
            providerSessionID: "parent-thread"
        )
        let repository = InMemorySessionRepository(sessions: [source])
        let model = AppModel(
            store: SessionStore(sessions: [source], repository: repository),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            restoresIndexOnLaunch: false
        )

        await model.openCodexSubagent(threadID: "child-thread", from: source)

        let child = try XCTUnwrap(model.store.sessions.first(where: { $0.providerSessionID == "child-thread" }))
        XCTAssertEqual(model.store.selectedSessionID, child.id)
        XCTAssertTrue(child.title.contains("child-thread"))
        XCTAssertEqual(child.parentTaskID, source.id, "An opened subagent nests under the task it came from")
        let resumeCount = await adapter.resumeCount
        let submissionCount = await adapter.codexSubmissions.count
        XCTAssertEqual(resumeCount, 1)
        XCTAssertEqual(submissionCount, 0)
        await model.shutdown()
    }

    func testOpeningSubagentDoesNotRecreateChildAfterSourceTaskDeletion() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let source = SessionRecord(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/subagent-delete"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Subagent deletion source",
            providerSessionID: "parent-thread"
        )
        let repository = InMemorySessionRepository(sessions: [source])
        let model = AppModel(
            store: SessionStore(sessions: [source], repository: repository),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            restoresIndexOnLaunch: false
        )
        await adapter.suspendNextResumeSession()

        let openTask = Task {
            await model.openCodexSubagent(threadID: "child-thread", from: source)
        }
        try await waitUntil { await adapter.isResumeBlocked }
        let isBlocked = await adapter.isResumeBlocked
        XCTAssertTrue(isBlocked)

        await model.delete(source)
        await adapter.releaseSuspendedResumeSession()
        await openTask.value

        XCTAssertTrue(model.store.sessions.isEmpty)
        XCTAssertNil(model.errorBySessionID[source.id])
        let closeCount = await adapter.closeCount
        XCTAssertEqual(closeCount, 1)
        await model.shutdown()
    }

    /// An imported conversation's task starts detached; one deleted while it first resumes stays
    /// deleted: no task, no error, and the runtime it started is closed.
    func testAnImportedTaskDeletedWhileItFirstResumesStaysDeleted() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            restoresIndexOnLaunch: false
        )
        model.runtimeSelections.select(URL(filePath: "/usr/bin/true"), for: .codex)
        let conversation = ImportableConversation(codex: CodexThreadSummary(
            id: "imported-thread",
            title: "Imported thread",
            preview: "Imported preview",
            workspaceURL: URL(filePath: "/tmp/import-delete"),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            forkedFromID: nil
        ))
        let detached = await model.importConversation(conversation, connection: nil)
        let created = try XCTUnwrap(detached)
        XCTAssertFalse(model.isAttached(created.id), "Importing starts no runtime")
        await adapter.suspendNextResumeSession()

        let resumeTask = Task {
            await model.resume(created)
        }
        try await waitUntil { await adapter.isResumeBlocked }
        let isBlocked = await adapter.isResumeBlocked
        XCTAssertTrue(isBlocked)

        let imported = try XCTUnwrap(model.store.sessions.first { $0.providerSessionID == conversation.providerSessionID })
        XCTAssertEqual(imported.environmentScope, .native)
        await model.delete(imported)
        await adapter.releaseSuspendedResumeSession()
        await resumeTask.value

        XCTAssertTrue(model.store.sessions.isEmpty)
        XCTAssertNil(model.errorBySessionID[imported.id])
        XCTAssertNil(model.bootstrapError)
        let closeCount = await adapter.closeCount
        XCTAssertEqual(closeCount, 1)
        await model.shutdown()
    }

    func testImportDoesNotPersistHistorySelectionAfterImportedTaskDeletion() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let selectionRepository = UserDefaultsCodexHistorySelectionRepository(
            defaults: defaults,
            keyPrefix: "history."
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            codexHistorySelectionRepository: selectionRepository,
            restoresIndexOnLaunch: false
        )
        model.runtimeSelections.select(URL(filePath: "/usr/bin/true"), for: .codex)
        let conversation = ImportableConversation(codex: CodexThreadSummary(
            id: "imported-selection-thread",
            title: "Imported selection task",
            preview: "needle",
            workspaceURL: URL(filePath: "/tmp/import-selection-delete"),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            forkedFromID: nil
        ), snippet: "needle")
        let selection = CodexHistorySearchSelection(
            query: "needle",
            snippet: "needle",
            threadID: conversation.providerSessionID
        )
        await adapter.suspendNextSearchOccurrences()

        let importTask = Task {
            await model.importConversation(conversation, connection: nil, historySelection: selection)
        }
        try await waitUntil { await adapter.isSearchOccurrencesBlocked }
        let isBlocked = await adapter.isSearchOccurrencesBlocked
        XCTAssertTrue(isBlocked)

        let imported = try XCTUnwrap(
            model.store.sessions.first(where: { $0.providerSessionID == conversation.providerSessionID })
        )
        XCTAssertEqual(imported.environmentScope, .native)
        await model.delete(imported)
        await adapter.releaseSuspendedSearchOccurrences()
        let result = await importTask.value

        XCTAssertNil(result)
        XCTAssertTrue(model.store.sessions.isEmpty)
        XCTAssertNil(model.codexHistorySelectionBySessionID[imported.id])
        XCTAssertNil(selectionRepository.load(for: imported.id))
        XCTAssertNil(model.bootstrapError)
        await model.shutdown()
    }

    func testCompletedHistoricalCodexTurnCannotBeRetriedAsANewUserMessage() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            restoresIndexOnLaunch: false
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/retry-project"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Retry task"
        )
        let created = try XCTUnwrap(createdResult)
        let turn = CodexTurnState(
            id: "historical-turn",
            status: .completed,
            startedAt: nil,
            completedAt: nil,
            durationMilliseconds: nil,
            itemsView: .full,
            items: [CodexItemState(
                id: "historical-user",
                lifecycle: .completed,
                startedAt: nil,
                completedAt: nil,
                content: .userMessage(CodexUserMessageItem(
                    content: [.object([
                        "type": .string("text"),
                        "text": .string("retry the historical turn")
                    ])],
                    clientID: "client-1"
                )),
                raw: .object([:])
            )],
            itemsNextCursor: nil,
            plan: nil,
            tokenUsage: nil,
            error: nil,
            raw: .object([:])
        )

        await model.retryTurn(turn.id, in: created)

        let submissions = await adapter.codexSubmissions
        XCTAssertTrue(submissions.isEmpty)
        await model.shutdown()
    }

    func testUnsupportedCodexActionDoesNotRecreateErrorStateAfterTaskDeletion() async throws {
        let session = SessionRecord(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/deleted-action"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Deleted action"
        )
        let model = AppModel(
            store: SessionStore(
                sessions: [session],
                repository: InMemorySessionRepository(sessions: [session])
            ),
            runtimeSelections: RuntimeSelectionStore(),
            restoresIndexOnLaunch: false
        )
        await model.delete(session)

        let turn = CodexTurnState(
            id: "deleted-turn",
            status: .completed,
            startedAt: nil,
            completedAt: nil,
            durationMilliseconds: nil,
            itemsView: .full,
            items: [CodexItemState(
                id: "future-input",
                lifecycle: .completed,
                startedAt: nil,
                completedAt: nil,
                content: .userMessage(CodexUserMessageItem(
                    content: [],
                    clientID: nil
                )),
                raw: .object([:])
            )],
            itemsNextCursor: nil,
            plan: nil,
            tokenUsage: nil,
            error: nil,
            raw: .object([:])
        )

        await model.retryTurn(turn.id, in: session)

        XCTAssertNil(model.codexCapabilitiesBySessionID[session.id])
        XCTAssertNil(model.errorBySessionID[session.id])
        await model.shutdown()
    }

    func testTwoHarnessSessionsAttachAndRestoreWithoutEagerRuntimeWake() async throws {
        let repository = InMemorySessionRepository()
        let codexAdapter = FakeHarnessAdapter(kind: .codex)
        let claudeAdapter = FakeHarnessAdapter(kind: .claudeCode)
        let registry = HarnessRegistry { harness, _ in
            harness == .codex ? codexAdapter : claudeAdapter
        }
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: repository),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: registry
        )

        await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/shared-project"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Codex session"
        )
        await model.createSession(
            harness: .claudeCode,
            workspaceURL: URL(filePath: "/tmp/shared-project"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"),
            title: "Claude session"
        )

        XCTAssertEqual(model.store.sessions.count, 2)
        XCTAssertEqual(Set(model.store.sessions.map(\.harness)), Set([.codex, .claudeCode]))
        XCTAssertTrue(model.store.sessions.allSatisfy { $0.providerSessionID != nil })
        XCTAssertTrue(model.store.sessions.allSatisfy { model.isAttached($0.id) })
        XCTAssertEqual(model.store.workspaceGroups.count, 1)
        let codexCreateCount = await codexAdapter.createCount
        let claudeCreateCount = await claudeAdapter.createCount
        XCTAssertEqual(codexCreateCount, 1)
        XCTAssertEqual(claudeCreateCount, 1)

        let codexSession = try XCTUnwrap(
            model.store.sessions.first(where: { $0.harness == .codex })
        )
        let claudeSession = try XCTUnwrap(
            model.store.sessions.first(where: { $0.harness == .claudeCode })
        )
        await model.send("codex prompt", to: codexSession)
        await model.send("claude prompt", to: claudeSession)
        await codexAdapter.emit(
            .assistantDelta("codex reply"),
            for: codexSession.id,
            sequence: 1
        )
        await claudeAdapter.emit(
            .assistantDelta("claude reply"),
            for: claudeSession.id,
            sequence: 1
        )
        let codexTranscript: [TranscriptEntryContent] = [
            .user(text: "codex prompt"),
            .assistant(text: "codex reply", isStreaming: true)
        ]
        let claudeTranscript: [TranscriptEntryContent] = [
            .user(text: "claude prompt"),
            .assistant(text: "claude reply", isStreaming: true)
        ]
        try await waitUntil {
            model.transcriptBySessionID[codexSession.id]?.map(\.content) == codexTranscript
                && model.transcriptBySessionID[claudeSession.id]?.map(\.content) == claudeTranscript
        }
        XCTAssertEqual(model.transcriptBySessionID[codexSession.id]?.map(\.content), codexTranscript)
        XCTAssertEqual(model.transcriptBySessionID[claudeSession.id]?.map(\.content), claudeTranscript)

        let restoredCodexAdapter = FakeHarnessAdapter(kind: .codex)
        let restoredClaudeAdapter = FakeHarnessAdapter(kind: .claudeCode)
        let restoredRegistry = HarnessRegistry { harness, _ in
            harness == .codex ? restoredCodexAdapter : restoredClaudeAdapter
        }
        let restoredModel = AppModel(
            store: SessionStore(repository: repository),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: restoredRegistry
        )
        await restoredModel.restoreIndex()

        XCTAssertEqual(
            Set(restoredModel.store.sessions.map(\.id)),
            Set(model.store.sessions.map(\.id))
        )
        XCTAssertTrue(model.store.sessions.allSatisfy { $0.status == .running })
        XCTAssertTrue(restoredModel.store.sessions.allSatisfy { $0.status == .ready })
        for restored in restoredModel.store.sessions {
            let live = try XCTUnwrap(model.store.sessions.first(where: { $0.id == restored.id }))
            XCTAssertEqual(restored.harness, live.harness)
            XCTAssertEqual(restored.providerSessionID, live.providerSessionID)
            XCTAssertEqual(restored.title, live.title)
            XCTAssertEqual(restored.completionState, live.completionState)
        }
        XCTAssertTrue(restoredModel.store.sessions.allSatisfy {
            !restoredModel.isAttached($0.id)
        })
        let restoredCodexProbeCount = await restoredCodexAdapter.probeCount
        let restoredClaudeProbeCount = await restoredClaudeAdapter.probeCount
        XCTAssertEqual(restoredCodexProbeCount, 0)
        XCTAssertEqual(restoredClaudeProbeCount, 0)

        let restoredCodex = try XCTUnwrap(
            restoredModel.store.sessions.first(where: { $0.harness == .codex })
        )
        await restoredModel.resume(restoredCodex)
        XCTAssertTrue(restoredModel.isAttached(restoredCodex.id))
        let restoredCodexResumeCount = await restoredCodexAdapter.resumeCount
        XCTAssertEqual(restoredCodexResumeCount, 1)
        XCTAssertEqual(
            restoredModel.store.sessions.first(where: { $0.id == codexSession.id })?
                .providerSessionID,
            codexSession.providerSessionID
        )

        await model.shutdown()
        let codexCloseCount = await codexAdapter.closeCount
        let claudeCloseCount = await claudeAdapter.closeCount
        XCTAssertEqual(codexCloseCount, 1)
        XCTAssertEqual(claudeCloseCount, 1)
        await restoredModel.shutdown()
    }

    func testFourHarnessSessionsSharePersistedIdentityAcrossTheSameShell() async throws {
        let repository = InMemorySessionRepository()
        let harnesses: [HarnessKind] = [.codex, .claudeCode, .openCode, .pi]
        let adapters = Dictionary(uniqueKeysWithValues: harnesses.map { ($0, FakeHarnessAdapter(kind: $0)) })
        let registry = HarnessRegistry { harness, _ in
            adapters[harness]!
        }
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: repository),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: registry
        )

        for harness in harnesses {
            await model.createSession(
                harness: harness,
                workspaceURL: URL(filePath: "/tmp/four-harness-shell"),
                runtimeExecutableURL: URL(filePath: "/tmp/\(harness.rawValue)"),
                title: "\(harness.displayName) fixture"
            )
        }

        let persisted = Dictionary(
            uniqueKeysWithValues: model.store.sessions.map { ($0.harness, ($0.id, $0.providerSessionID)) }
        )
        XCTAssertEqual(Set(persisted.keys), Set(harnesses))
        XCTAssertEqual(persisted.count, 4)
        XCTAssertTrue(persisted.values.allSatisfy { $0.1 != nil })
        XCTAssertEqual(model.store.workspaceGroups.count, 1)
        XCTAssertTrue(model.store.sessions.allSatisfy { model.isAttached($0.id) })

        for session in model.store.sessions {
            await model.send("hello (session.harness.rawValue)", to: session)
            await adapters[session.harness]?.emit(
                .assistantDelta("reply (session.harness.rawValue)"),
                for: session.id,
                sequence: 1
            )
        }
        let reply = TranscriptEntryContent.assistant(text: "reply (session.harness.rawValue)", isStreaming: true)
        try await waitUntil {
            model.store.sessions.allSatisfy { model.transcriptBySessionID[$0.id]?.last?.content == reply }
        }
        for session in model.store.sessions {
            XCTAssertEqual(model.transcriptBySessionID[session.id]?.last?.content, reply)
        }

        let restoredAdapters = Dictionary(
            uniqueKeysWithValues: harnesses.map { ($0, FakeHarnessAdapter(kind: $0)) }
        )
        let restoredRegistry = HarnessRegistry { harness, _ in
            restoredAdapters[harness]!
        }
        let restoredModel = AppModel(
            store: SessionStore(repository: repository),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: restoredRegistry
        )
        await restoredModel.restoreIndex()

        let restored = Dictionary(
            uniqueKeysWithValues: restoredModel.store.sessions.map { ($0.harness, ($0.id, $0.providerSessionID)) }
        )
        XCTAssertEqual(Set(restored.keys), Set(persisted.keys))
        for harness in harnesses {
            XCTAssertEqual(restored[harness]?.0, persisted[harness]?.0)
            XCTAssertEqual(restored[harness]?.1, persisted[harness]?.1)
        }
        XCTAssertTrue(restoredModel.store.sessions.allSatisfy { !restoredModel.isAttached($0.id) })
        for adapter in restoredAdapters.values {
            let probeCount = await adapter.probeCount
            XCTAssertEqual(probeCount, 0)
        }

        await model.shutdown()
        await restoredModel.shutdown()
    }

    func testActiveLocalSessionsExposeOnlyRunningAndApprovalWorkForQuitWarning() throws {
        let running = SessionRecord(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/running"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Running task",
            status: .running
        )
        let approval = SessionRecord(
            harness: .claudeCode,
            workspaceURL: URL(filePath: "/tmp/approval"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"),
            title: "Approval task",
            status: .waitingForApproval
        )
        let ready = SessionRecord(
            harness: .pi,
            workspaceURL: URL(filePath: "/tmp/ready"),
            runtimeExecutableURL: URL(filePath: "/tmp/pi"),
            title: "Ready task",
            status: .ready
        )
        let model = AppModel(
            store: SessionStore(
                sessions: [running, approval, ready],
                repository: InMemorySessionRepository(sessions: [running, approval, ready])
            ),
            runtimeSelections: RuntimeSelectionStore(),
            restoresIndexOnLaunch: false
        )

        XCTAssertEqual(
            Set(model.activeLocalSessions.map(\.id)),
            Set([running.id, approval.id])
        )
        XCTAssertFalse(model.activeLocalSessions.contains(where: { $0.id == ready.id }))
    }

    func testBackgroundCompletionMarksOnlyNonSelectedTaskUnread() async throws {
        let codexAdapter = FakeHarnessAdapter(kind: .codex)
        let claudeAdapter = FakeHarnessAdapter(kind: .claudeCode)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { harness, _ in
                harness == .codex ? codexAdapter : claudeAdapter
            }
        )
        let firstResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/unread-codex"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Background Codex"
        )
        let first = try XCTUnwrap(firstResult)
        _ = await model.createSession(
            harness: .claudeCode,
            workspaceURL: URL(filePath: "/tmp/unread-claude"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"),
            title: "Selected Claude"
        )

        await codexAdapter.emit(.sessionStatusChanged(.running), for: first.id, sequence: 1)
        await codexAdapter.emit(.turnCompleted, for: first.id, sequence: 2)
        await codexAdapter.emit(.sessionStatusChanged(.ready), for: first.id, sequence: 3)
        try await waitUntil {
            model.store.sessions.first(where: { $0.id == first.id })?.hasUnreadUpdate == true
        }
        XCTAssertTrue(model.store.sessions.first(where: { $0.id == first.id })?.hasUnreadUpdate == true)
        XCTAssertEqual(model.store.sessions.first(where: { $0.id == first.id })?.completionState, .completed)
        await model.shutdown()
    }

    func testCodexAutomaticSubmissionUsesPersistedClientQueueWhileTurnIsActive() async throws {
        let repository = InMemorySessionRepository()
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        defaults.set(CodexFollowUpMode.queue.rawValue, forKey: CodexFollowUpMode.preferenceKey)
        let queueRepository = UserDefaultsCodexQueueRepository(
            defaults: defaults,
            keyPrefix: "queue."
        )
        let model = AppModel(
            store: SessionStore(repository: repository),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            codexQueueRepository: queueRepository,
            preferences: defaults
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/queue-project"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Queue task"
        )
        let session = try XCTUnwrap(createdResult)

        await model.send("first", to: session)
        await model.send("second", to: session)

        let initialSubmissionCount = await adapter.codexSubmissions.count
        XCTAssertEqual(initialSubmissionCount, 1)
        XCTAssertEqual(model.followUps.queue(for: session.id).map(\.draft.text), ["second"])

        let restoredModel = AppModel(
            store: SessionStore(repository: repository),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            codexQueueRepository: queueRepository
        )
        await restoredModel.restoreIndex()
        let restoredSession = try XCTUnwrap(restoredModel.store.sessions.first)
        XCTAssertEqual(restoredModel.followUps.queue(for: restoredSession.id).map(\.draft.text), ["second"])

        await model.shutdown()
        await restoredModel.shutdown()
    }

    func testCodexSteerFailsClosedWithoutAnActiveProviderTurn() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter }
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/steer-precondition"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Steer precondition"
        )
        let session = try XCTUnwrap(createdResult)

        await model.submitCodex(
            CodexComposerDraft(inputs: [.text("Continue the active turn")]),
            action: .steer,
            to: session
        )

        let submissions = await adapter.codexSubmissions
        XCTAssertTrue(submissions.isEmpty)
        let failedQueue = model.followUps.queue(for: session.id)
        XCTAssertEqual(failedQueue.count, 1)
        XCTAssertEqual(failedQueue.first?.state, .failed)
        XCTAssertEqual(
            failedQueue.first?.failureMessage,
            L10n.string("Codex steer requires an active turn")
        )
        await model.shutdown()
    }

    func testCodexAutomaticFollowUpSteersTheRunningTurnByDefault() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue."),
            preferences: defaults
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/steer-default"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Steer by default"
        )
        let session = try XCTUnwrap(createdResult)

        await model.send("first", to: session)
        await adapter.emit(.sessionStatusChanged(.waitingForApproval), for: session.id, sequence: 1)
        try await waitUntil { model.store.sessions.first?.status == .waitingForApproval }
        await model.send("second", to: session)

        let submissions = await adapter.codexSubmissions
        XCTAssertEqual(submissions.map(\.1), [.start, .steer(expectedTurnID: "fake-turn-1")])
        XCTAssertEqual(submissions.last?.0.text, "second")
        XCTAssertTrue(model.followUps.queue(for: session.id).isEmpty)
        // A follow-up does not take the task out of its pending approval.
        XCTAssertEqual(model.store.sessions.first?.status, .waitingForApproval)
        await model.shutdown()
    }

    func testCodexInterruptPausesTheQueueUntilResume() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        defaults.set(CodexFollowUpMode.queue.rawValue, forKey: CodexFollowUpMode.preferenceKey)
        let queueRepository = UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue.")
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            codexQueueRepository: queueRepository,
            preferences: defaults
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/queue-pause"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Queue pause"
        )
        let session = try XCTUnwrap(createdResult)
        await model.send("first", to: session)
        await model.send("second", to: session)
        XCTAssertEqual(model.followUps.queue(for: session.id).map(\.draft.text), ["second"])

        await model.interrupt(session)
        XCTAssertTrue(model.followUps.isPaused(session.id))
        XCTAssertTrue(queueRepository.isPaused(for: session.id))
        await adapter.emit(.sessionStatusChanged(.ready), for: session.id, sequence: 1)
        try await waitUntil { model.store.sessions.first?.status == .ready }
        try await Task.sleep(for: .milliseconds(50))
        var submissionCount = await adapter.codexSubmissions.count
        XCTAssertEqual(submissionCount, 1)
        XCTAssertEqual(model.followUps.queue(for: session.id).map(\.draft.text), ["second"])

        model.resumeQueue(for: session)
        try await waitUntil { await adapter.codexSubmissions.count >= 2 }
        submissionCount = await adapter.codexSubmissions.count
        XCTAssertEqual(submissionCount, 2)
        let resumed = await adapter.codexSubmissions.last
        XCTAssertEqual(resumed?.0.text, "second")
        XCTAssertEqual(resumed?.1, .start)
        try await waitUntil { model.followUps.queue(for: session.id).isEmpty }
        XCTAssertTrue(model.followUps.queue(for: session.id).isEmpty)
        XCTAssertFalse(model.followUps.isPaused(session.id))
        XCTAssertFalse(queueRepository.isPaused(for: session.id))
        // The queue's own send starts the turn as any send does, as Claude Code's queue does.
        XCTAssertEqual(model.store.sessions.first?.status, .running)
        await model.shutdown()
    }

    func testPausedCodexQueueSurvivesRestartAndClearsWithItsLastMessage() async throws {
        let session = SessionRecord(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/queue-pause-restart"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Paused queue restart"
        )
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let queueRepository = UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue.")
        let queued = CodexQueuedSubmission(draft: CodexComposerDraft(inputs: [.text("held")]))
        queueRepository.save([queued], for: session.id)
        queueRepository.setPaused(true, for: session.id)
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository(sessions: [session])),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            codexQueueRepository: queueRepository,
            preferences: defaults
        )
        await model.restoreIndex()
        let restored = try XCTUnwrap(model.store.sessions.first)

        XCTAssertTrue(model.followUps.isPaused(restored.id))
        await model.removeQueued(queued.id, for: restored)
        XCTAssertFalse(model.followUps.isPaused(restored.id))
        XCTAssertFalse(queueRepository.isPaused(for: session.id))
        await model.shutdown()
    }

    func testQueuedCodexMessageSteersTheRunningTurnOrStartsTheNextOne() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        defaults.set(CodexFollowUpMode.queue.rawValue, forKey: CodexFollowUpMode.preferenceKey)
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue."),
            preferences: defaults
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/queue-steer"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Queue steer"
        )
        var session = try XCTUnwrap(createdResult)
        await model.send("first", to: session)
        await model.send("second", to: session)
        await model.send("third", to: session)
        let queue = model.followUps.queue(for: session.id)
        XCTAssertEqual(queue.map(\.draft.text), ["second", "third"])

        session = try XCTUnwrap(model.store.sessions.first)
        await model.sendQueuedNow(try XCTUnwrap(queue.last?.id), for: session)
        var submissions = await adapter.codexSubmissions
        XCTAssertEqual(submissions.last?.1, .steer(expectedTurnID: "fake-turn-1"))
        XCTAssertEqual(submissions.last?.0.text, "third")
        XCTAssertEqual(model.followUps.queue(for: session.id).map(\.draft.text), ["second"])

        // After an interrupt the queue holds; Steer on an item sends it as the next turn.
        await model.interrupt(session)
        await adapter.emit(.sessionStatusChanged(.ready), for: session.id, sequence: 1)
        try await waitUntil { model.store.sessions.first?.status == .ready }
        session = try XCTUnwrap(model.store.sessions.first)
        await model.sendQueuedNow(try XCTUnwrap(queue.first?.id), for: session)
        submissions = await adapter.codexSubmissions
        XCTAssertEqual(submissions.map(\.1).last, .start)
        XCTAssertEqual(submissions.last?.0.text, "second")
        XCTAssertEqual(submissions.count, 3)
        XCTAssertTrue(model.followUps.queue(for: session.id).isEmpty)
        XCTAssertFalse(model.followUps.isPaused(session.id))
        XCTAssertEqual(model.store.sessions.first?.status, .running)
        await model.shutdown()
    }

    func testEditingAQueuedCodexMessageNeverReplacesAnotherDraft() async throws {
        let session = SessionRecord(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/queue-edit"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Queue edit"
        )
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(sessions: [session], repository: InMemorySessionRepository(sessions: [session])),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue."),
            restoresIndexOnLaunch: false
        )
        let image = CodexUserInput.localImage(URL(filePath: "/tmp/queued.png"), detail: .auto)
        await model.submitCodex(CodexComposerDraft(inputs: [.text("queued"), image]), action: .queue, to: session)
        let queued = try XCTUnwrap(model.followUps.queue(for: session.id).last?.id)
        let composer = model.composerDrafts.tasks.draft(for: session.id)
        composer.text = "still typing"

        XCTAssertNil(model.editQueued(queued, for: session))
        XCTAssertEqual(composer.text, "still typing")
        XCTAssertEqual(composer.notice, L10n.string("Send or clear the current draft before editing a queued message."))
        XCTAssertEqual(model.followUps.queue(for: session.id).map(\.id), [queued])

        composer.clear()
        let edited = model.editQueued(queued, for: session)
        XCTAssertEqual(edited?.text, "queued")
        XCTAssertEqual(composer.text, "queued")
        XCTAssertEqual(composer.attachments, [image])
        XCTAssertTrue(model.followUps.queue(for: session.id).isEmpty)
        await model.shutdown()
    }

    func testCodexQueueDrainKeepsMessagesQueuedWhileItSends() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue."),
            preferences: defaults
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/queue-drain-race"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Queue drain race"
        )
        let session = try XCTUnwrap(createdResult)
        await model.submitCodex(CodexComposerDraft(inputs: [.text("sending")]), action: .queue, to: session)
        await adapter.suspendNextCodexSubmissionUntilReleased()
        await adapter.emit(.sessionStatusChanged(.ready), for: session.id, sequence: 1)
        try await waitUntil { await adapter.isCodexSubmissionBlocked }
        let isBlocked = await adapter.isCodexSubmissionBlocked
        XCTAssertTrue(isBlocked)

        await model.submitCodex(CodexComposerDraft(inputs: [.text("added while sending")]), action: .queue, to: session)
        await adapter.releaseSuspendedCodexSubmission()
        try await waitUntil { model.followUps.queue(for: session.id).count == 1 }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.followUps.queue(for: session.id).map(\.draft.text), ["added while sending"])
        await model.shutdown()
    }

    func testFinalCodexErrorFailsOnceWithoutAlsoReportingCompletion() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let notifications = RecordingSystemNotificationCenter()
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            systemNotificationCenter: notifications
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/final-error"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Final error"
        )
        let created = try XCTUnwrap(createdResult)
        model.store.selectedSessionID = nil

        await adapter.emit(.sessionStatusChanged(.running), for: created.id, sequence: 1)
        await adapter.emit(.error(message: "You've hit your usage limit.", recoverable: false), for: created.id, sequence: 2)
        await adapter.emit(.turnCompleted, for: created.id, sequence: 3)
        await adapter.emit(.sessionStatusChanged(.ready), for: created.id, sequence: 4)
        try await waitUntil { model.store.sessions.first?.status == .ready }
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(notifications.posts.map(\.title), [L10n.string("Task failed")])
        XCTAssertNotEqual(model.store.sessions.first?.completionState, .completed)
        await model.shutdown()
    }

    func testStaleCodexSubmissionDoesNotRecreateTranscriptOrQueueAfterTaskDeletion() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let queueRepository = UserDefaultsCodexQueueRepository(
            defaults: defaults,
            keyPrefix: "queue."
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            codexQueueRepository: queueRepository
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/stale-codex-submit"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Stale Codex submit"
        )
        let session = try XCTUnwrap(createdResult)

        await model.delete(session)
        let probeCountAfterDelete = await adapter.probeCount
        await model.submitCodex(
            CodexComposerDraft(inputs: [.text("stale draft")]),
            action: .queue,
            to: session
        )
        await model.submitFollowUp(HarnessUserInput(text: "stale queue"), action: .queue, to: session)

        XCTAssertTrue(model.store.sessions.isEmpty)
        XCTAssertTrue(model.followUps.queue(for: session.id).isEmpty)
        XCTAssertNil(model.transcriptBySessionID[session.id])
        XCTAssertNil(model.errorBySessionID[session.id])
        XCTAssertNil(defaults.object(forKey: "queue.\(session.id.uuidString)"))
        let probeCount = await adapter.probeCount
        XCTAssertEqual(probeCount, probeCountAfterDelete)
        await model.shutdown()
    }

    func testStaleNonCodexSendDoesNotRecreateTranscriptAfterTaskDeletion() async throws {
        let adapter = FakeHarnessAdapter(kind: .claudeCode)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter }
        )
        let createdResult = await model.createSession(
            harness: .claudeCode,
            workspaceURL: URL(filePath: "/tmp/stale-noncodex-send"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"),
            title: "Stale non-Codex send"
        )
        let session = try XCTUnwrap(createdResult)

        await model.delete(session)
        let probeCountAfterDelete = await adapter.probeCount
        await model.send("stale non-Codex prompt", to: session)

        XCTAssertTrue(model.store.sessions.isEmpty)
        XCTAssertNil(model.transcriptBySessionID[session.id])
        XCTAssertNil(model.errorBySessionID[session.id])
        let probeCount = await adapter.probeCount
        XCTAssertEqual(probeCount, probeCountAfterDelete)
        await model.shutdown()
    }

    func testStaleTaskActionsDoNotMutateAfterTaskDeletion() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter }
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/stale-task-actions"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Stale task actions"
        )
        let session = try XCTUnwrap(createdResult)

        await model.delete(session)
        let probeCountAfterDelete = await adapter.probeCount
        await model.interrupt(session)
        await model.respond(to: "permission", decision: .allow, in: session)
        await model.respondCodex(
            to: "server-request",
            response: .command(.accept),
            in: session
        )
        await model.archive(session)
        await model.delete(session)
        await model.rename(session, to: "should not persist")

        XCTAssertTrue(model.store.sessions.isEmpty)
        XCTAssertNil(model.bootstrapError)
        XCTAssertNil(model.transcriptBySessionID[session.id])
        let probeCount = await adapter.probeCount
        XCTAssertEqual(probeCount, probeCountAfterDelete)
        await model.shutdown()
    }

    func testCodexQueueDispatchesOnReadyWithoutReordering() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue.")
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/queue-project"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Queue dispatch"
        )
        let session = try XCTUnwrap(createdResult)
        await model.send("first", to: session)
        await model.submitCodex(
            CodexComposerDraft(inputs: [.text("second")]),
            action: .queue,
            to: session
        )
        await model.submitCodex(
            CodexComposerDraft(inputs: [.text("third")]),
            action: .queue,
            to: session
        )
        await adapter.emit(
            .sessionStatusChanged(.ready),
            for: session.id,
            sequence: 1
        )
        try await waitUntil { await adapter.codexSubmissions.count >= 2 }
        let submissionCount = await adapter.codexSubmissions.count
        XCTAssertEqual(submissionCount, 2)
        XCTAssertEqual(model.followUps.queue(for: session.id).map(\.draft.text), ["third"])
        await model.shutdown()
    }

    func testCodexQueueDrainDoesNotPersistFailureAfterDeletionCancellation() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let queueRepository = UserDefaultsCodexQueueRepository(
            defaults: defaults,
            keyPrefix: "queue."
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            codexQueueRepository: queueRepository
        )
        let createdResult = await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/queue-cancellation-error"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Queue cancellation"
        )
        let session = try XCTUnwrap(createdResult)

        await model.submitCodex(CodexComposerDraft(inputs: [.text("cancel while failing")]), action: .queue, to: session)
        await adapter.suspendAndFailNextCodexSubmission()
        await adapter.emit(.sessionStatusChanged(.ready), for: session.id, sequence: 1)
        try await waitUntil { await adapter.isCodexSubmissionBlocked }
        let isBlocked = await adapter.isCodexSubmissionBlocked
        XCTAssertTrue(isBlocked)

        await model.delete(session)
        await adapter.releaseSuspendedCodexSubmission()
        try await waitUntil { await adapter.isCodexSubmissionBlocked == false }

        XCTAssertTrue(model.store.sessions.isEmpty)
        XCTAssertTrue(model.followUps.queue(for: session.id).isEmpty)
        XCTAssertNil(model.errorBySessionID[session.id])
        XCTAssertNil(defaults.object(forKey: "queue.\(session.id.uuidString)"))
        await model.shutdown()
    }

    func testCodexQueueActionsPersistMoveCancelAndRetryState() async throws {
        let session = SessionRecord(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/queue-actions"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Queue actions"
        )
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let queueRepository = UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue.")
        let model = AppModel(
            store: SessionStore(
                sessions: [session],
                repository: InMemorySessionRepository(sessions: [session])
            ),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            codexQueueRepository: queueRepository,
            restoresIndexOnLaunch: false
        )

        await model.submitFollowUp(HarnessUserInput(text: "first"), action: .queue, to: session)
        await model.submitFollowUp(HarnessUserInput(text: "second"), action: .queue, to: session)
        let first = try XCTUnwrap(model.followUps.queue(for: session.id).first?.id)
        let second = try XCTUnwrap(model.followUps.queue(for: session.id).last?.id)
        model.moveQueued(first, in: session, to: 1)
        XCTAssertEqual(model.followUps.queue(for: session.id).map(\.draft.text), ["second", "first"])
        await model.removeQueued(second, for: session)
        XCTAssertEqual(model.followUps.queue(for: session.id).map(\.draft.text), ["first"])

        // A message that could not be sent; the queue keeps it, failed, until Retry.
        let failed = QueuedFollowUp(draft: CodexComposerDraft(inputs: [.text("failed")]), state: .failed,
                                    failureMessage: "temporary")
        model.followUps.append(failed, to: session.id)
        model.retryQueued(failed.id, for: session)
        XCTAssertEqual(model.followUps.queue(for: session.id).last?.state, .pending)
        XCTAssertNil(model.followUps.queue(for: session.id).last?.failureMessage)
        XCTAssertEqual(queueRepository.load(for: session.id), model.followUps.queue(for: session.id))
    }

    func testAdapterEventsReachCoalescedCommonTranscript() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let registry = HarnessRegistry { _, _ in adapter }
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: registry
        )
        await model.createSession(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/project"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Transcript"
        )
        let session = try XCTUnwrap(model.store.selectedSession)

        await model.send("hello", to: session)
        await adapter.emit(.assistantDelta("wor"), for: session.id, sequence: 1)
        await adapter.emit(.assistantDelta("ld"), for: session.id, sequence: 2)
        let transcript: [TranscriptEntryContent] = [
            .user(text: "hello"),
            .assistant(text: "world", isStreaming: true)
        ]
        try await waitUntil { model.transcriptBySessionID[session.id]?.map(\.content) == transcript }

        XCTAssertEqual(model.transcriptBySessionID[session.id]?.map(\.content), transcript)
        let sentPrompts = await adapter.sentPrompts
        XCTAssertEqual(sentPrompts, ["hello"])

        let permission = PermissionRequest(
            id: "permission-1",
            title: "Run command",
            detail: nil,
            command: "git status"
        )
        await adapter.emit(.permissionRequested(permission), for: session.id, sequence: 3)
        try await waitUntil {
            model.eventsBySessionID[session.id]?.contains { $0.payload == .permissionRequested(permission) } == true
        }
        await model.respond(to: permission.id, decision: .deny, in: session)

        XCTAssertTrue(model.transcriptBySessionID[session.id]?.contains { entry in
            entry.content == .permission(permission, state: .denied)
        } == true)
        let decisions = await adapter.permissionDecisions
        XCTAssertEqual(decisions[permission.id], .deny)
    }

    func testProviderUsageUpdatesConversationStateWithoutTranscriptNoise() async throws {
        let adapter = FakeHarnessAdapter(kind: .claudeCode)
        let registry = HarnessRegistry { _, _ in adapter }
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: registry
        )
        await model.createSession(
            harness: .claudeCode,
            workspaceURL: URL(filePath: "/tmp/project"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"),
            title: "Usage"
        )
        let session = try XCTUnwrap(model.store.selectedSession)
        let usage = HarnessProtocolUsage(
            inputTokens: 1_000,
            cachedInputTokens: 700,
            outputTokens: 50,
            reasoningTokens: 20,
            totalCostUSD: nil,
            contextWindowTokens: 200_000,
            contextUsedTokens: 12_000,
            extensionValues: [:]
        )

        await adapter.emit(.usageUpdated(usage), for: session.id, sequence: 1)
        try await waitUntil { model.providerUsageBySessionID[session.id] != nil }

        XCTAssertEqual(model.providerUsageBySessionID[session.id], usage)
        XCTAssertTrue(model.transcriptBySessionID[session.id]?.isEmpty ?? true)
    }

    func testLocalMessageFlushesQueuedAssistantDeltaBeforeAppendingUser() async throws {
        let adapter = FakeHarnessAdapter(kind: .claudeCode)
        let registry = HarnessRegistry { _, _ in adapter }
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: registry
        )
        await model.createSession(
            harness: .claudeCode,
            workspaceURL: URL(filePath: "/tmp/project"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"),
            title: "Ordered transcript"
        )
        let session = try XCTUnwrap(model.store.selectedSession)

        await model.send("first", to: session)
        await adapter.emit(.assistantDelta("answer"), for: session.id, sequence: 1)
        try await waitUntil {
            model.eventsBySessionID[session.id]?.contains { $0.payload == .assistantDelta("answer") } == true
        }
        await model.send("follow-up", to: session)

        XCTAssertEqual(model.transcriptBySessionID[session.id]?.map(\.content), [
            .user(text: "first"),
            .assistant(text: "answer", isStreaming: false),
            .user(text: "follow-up")
        ])
    }
}

@MainActor
private final class RecordingSystemNotificationCenter: SystemNotificationCenter {
    var authorizationValue: SystemNotificationAuthorization = .authorized
    private(set) var didRequestAuthorization = false
    private(set) var posts: [(title: String, body: String, identifier: String)] = []
    private var suspendNextAuthorization = false
    private var authorizationContinuation: CheckedContinuation<Void, Never>?
    private(set) var isAuthorizationBlocked = false
    private(set) var didFinishAuthorization = false

    func authorization() async -> SystemNotificationAuthorization {
        if suspendNextAuthorization {
            suspendNextAuthorization = false
            isAuthorizationBlocked = true
            await withCheckedContinuation { continuation in
                authorizationContinuation = continuation
            }
            isAuthorizationBlocked = false
        }
        didFinishAuthorization = true
        return authorizationValue
    }

    func suspendAuthorization() {
        didFinishAuthorization = false
        suspendNextAuthorization = true
    }

    func releaseAuthorization() {
        authorizationContinuation?.resume()
        authorizationContinuation = nil
    }

    func requestAuthorization() async -> Bool {
        didRequestAuthorization = true
        authorizationValue = .authorized
        return true
    }

    func post(title: String, body: String, identifier: String) async {
        posts.append((title, body, identifier))
    }
}

actor FakeHarnessAdapter: HarnessAdapter, CodexCapabilityProviding, CodexPresentationProviding, CodexComposerProviding, CodexPendingServerRequestValidating, ProviderCapabilityProviding {
    nonisolated let kind: HarnessKind
    private(set) var probeCount = 0
    private(set) var composerModelsReads = 0
    private var modelSelections: [UUID: CodexModelSelection] = [:]
    private(set) var composerModesReads = 0
    private(set) var composerSkillsReads = 0
    private(set) var composerPluginReads = 0
    private(set) var createCount = 0
    private(set) var resumeCount = 0
    private(set) var closeCount = 0
    /// What the thread lists as its background terminals (`CodexBackgroundTerminalControlling`).
    private var backgroundTerminalList: [CodexBackgroundTerminal] = []
    func setBackgroundTerminals(_ terminals: [CodexBackgroundTerminal]) { backgroundTerminalList = terminals }
    private(set) var sentPrompts: [String] = []
    private(set) var forkedFromSessionIDs: [UUID] = []
    private(set) var forkedThroughTurnIDs: [String?] = []
    func lastSentPrompt() -> String? { sentPrompts.last }
    private(set) var codexSubmissions: [(CodexComposerDraft, CodexTurnSubmission)] = []
    private var suspendNextCodexSubmission = false
    private var failSuspendedCodexSubmission = false
    private var suspendedCodexSubmissionContinuation: CheckedContinuation<Void, Never>?
    private(set) var isCodexSubmissionBlocked = false
    private var suspendNextRecentPage = false
    private var suspendedRecentPageContinuation: CheckedContinuation<Void, Never>?
    private(set) var isRecentPageBlocked = false
    private var suspendNextTurnPageLoad = false
    private var failSuspendedTurnPage = false
    private var suspendedTurnPageContinuation: CheckedContinuation<Void, Never>?
    private(set) var isTurnPageBlocked = false
    private var suspendNextItemPageLoad = false
    private var failSuspendedItemPage = false
    private var suspendedItemPageContinuation: CheckedContinuation<Void, Never>?
    private(set) var isItemPageBlocked = false
    private var suspendNextCapabilityModesLoad = false
    private var suspendedCapabilityModesContinuation: CheckedContinuation<Void, Never>?
    private(set) var isCapabilityModesBlocked = false
    private var suspendNextCodexServerResponseLoad = false
    private var suspendedCodexServerResponseContinuation: CheckedContinuation<Void, Never>?
    private(set) var isCodexServerResponseBlocked = false
    private var suspendNextModeSelectionLoad = false
    private var suspendedModeSelectionContinuation: CheckedContinuation<Void, Never>?
    private(set) var isModeSelectionBlocked = false
    private var suspendNextInterrupt = false
    private var failSuspendedInterrupt = false
    private var suspendedInterruptContinuation: CheckedContinuation<Void, Never>?
    private(set) var isInterruptBlocked = false
    private var suspendNextResume = false
    private var suspendedResumeContinuation: CheckedContinuation<Void, Never>?
    private(set) var isResumeBlocked = false
    private var suspendNextCreate = false
    private var suspendedCreateContinuation: CheckedContinuation<Void, Never>?
    private(set) var isCreateBlocked = false
    private var suspendNextForkLoad = false
    private var suspendedForkContinuation: CheckedContinuation<Void, Never>?
    private(set) var isForkBlocked = false
    private var suspendNextSearchOccurrencesLoad = false
    private var suspendedSearchOccurrencesContinuation: CheckedContinuation<Void, Never>?
    private(set) var isSearchOccurrencesBlocked = false
    private var suspendNextThreadNameLoad = false
    private var suspendedThreadNameContinuation: CheckedContinuation<Void, Never>?
    private(set) var isThreadNameBlocked = false
    private var suspendNextArchiveLoad = false
    private var suspendedArchiveContinuation: CheckedContinuation<Void, Never>?
    private(set) var isArchiveBlocked = false
    private var suspendNextDeleteLoad = false
    private var suspendedDeleteContinuation: CheckedContinuation<Void, Never>?
    private(set) var isDeleteBlocked = false
    private(set) var restoredPendingRequests: [UUID: [CodexPendingServerRequest]] = [:]
    private var rejectsPendingRequestRestoration = false
    private(set) var permissionDecisions: [String: PermissionDecision] = [:]
    private(set) var archivedSessionIDs: [UUID] = []
    private(set) var interruptedSessionIDs: [UUID] = []
    private(set) var deletedSessionIDs: [UUID] = []
    private(set) var providerOptionSelections: [String: String] = [:]
    private(set) var itemPageLoads: [(localSessionID: UUID, turnID: String?, cursor: String?, limit: Int64?)] = []
    private(set) var turnPageLoads: [(localSessionID: UUID, cursor: String?, limit: Int64?)] = []
    private(set) var recentPageLoads: [(workspaceURL: URL, cursor: String?, limit: Int64)] = []
    private var handles: [UUID: HarnessSessionHandle] = [:]
    private var streams: [UUID: AsyncStream<HarnessEventEnvelope>] = [:]
    private var continuations: [UUID: AsyncStream<HarnessEventEnvelope>.Continuation] = [:]
    private var codexPresentationStates: [UUID: CodexTaskState] = [:]
    private var codexPresentationContinuations: [UUID: AsyncStream<CodexTaskState>.Continuation] = [:]
    private var activeCodexTurnIDs: [UUID: String] = [:]

    init(kind: HarnessKind) {
        self.kind = kind
    }

    func probeRuntime() async throws -> HarnessRuntimeDescriptor {
        probeCount += 1
        return HarnessRuntimeDescriptor(
            harness: kind,
            executableURL: URL(filePath: "/tmp/\(kind.rawValue)"),
            version: "test",
            capabilities: HarnessCapabilities(
                canResume: true,
                canInterrupt: true,
                hasStructuredPermissions: true,
                hasStructuredActivities: true,
                hasPlans: true,
                acceptsImages: true,
                hasSubagents: true
            ),
            fingerprint: "test-\(kind.rawValue)"
        )
    }

    func createSession(_ request: CreateHarnessSessionRequest) async throws -> HarnessSessionHandle {
        createCount += 1
        if suspendNextCreate {
            suspendNextCreate = false
            isCreateBlocked = true
            await withCheckedContinuation { continuation in
                suspendedCreateContinuation = continuation
            }
            isCreateBlocked = false
        }
        let handle = HarnessSessionHandle(
            harness: kind,
            localSessionID: request.localSessionID,
            providerSessionID: "\(kind.rawValue)-provider-\(request.localSessionID.uuidString)",
            workspaceURL: request.workspaceURL
        )
        handles[request.localSessionID] = handle
        createEventStream(for: request.localSessionID)
        return handle
    }

    func resumeSession(
        providerSessionID: String,
        localSessionID: UUID,
        workspaceURL: URL
    ) async throws -> HarnessSessionHandle {
        resumeCount += 1
        if suspendNextResume {
            suspendNextResume = false
            isResumeBlocked = true
            await withCheckedContinuation { continuation in
                suspendedResumeContinuation = continuation
            }
            isResumeBlocked = false
        }
        let handle = HarnessSessionHandle(
            harness: kind,
            localSessionID: localSessionID,
            providerSessionID: providerSessionID,
            workspaceURL: workspaceURL
        )
        handles[localSessionID] = handle
        createEventStream(for: localSessionID)
        return handle
    }

    func send(_ prompt: String, to session: HarnessSessionHandle) async throws {
        if failingSends > 0 {
            failingSends -= 1
            throw HarnessAdapterError.capabilityUnavailable("The harness refused the message")
        }
        sentPrompts.append(prompt)
    }

    private var failingSends = 0
    /// The next plain send throws before the harness takes the message.
    func failNextSend() { failingSends += 1 }

    func submit(
        _ draft: CodexComposerDraft,
        submission: CodexTurnSubmission,
        to session: HarnessSessionHandle
    ) async throws {
        codexSubmissions.append((draft, submission))
        if suspendNextCodexSubmission {
            suspendNextCodexSubmission = false
            isCodexSubmissionBlocked = true
            await withCheckedContinuation { continuation in
                suspendedCodexSubmissionContinuation = continuation
            }
            isCodexSubmissionBlocked = false
            if failSuspendedCodexSubmission {
                failSuspendedCodexSubmission = false
                throw HarnessAdapterError.invalidProviderEvent(
                    "submission ignored cancellation"
                )
            }
        }
        if case .start = submission {
            activeCodexTurnIDs[session.localSessionID] = "fake-turn-\(codexSubmissions.count)"
        }
        sentPrompts.append(draft.text)
    }

    func suspendAndFailNextCodexSubmission() {
        suspendNextCodexSubmission = true
        failSuspendedCodexSubmission = true
    }

    func suspendNextCodexSubmissionUntilReleased() {
        suspendNextCodexSubmission = true
    }

    func releaseSuspendedCodexSubmission() {
        suspendedCodexSubmissionContinuation?.resume()
        suspendedCodexSubmissionContinuation = nil
    }

    func suspendNextRecentThreadsPage() {
        suspendNextRecentPage = true
    }

    func releaseSuspendedRecentThreadsPage() {
        suspendedRecentPageContinuation?.resume()
        suspendedRecentPageContinuation = nil
    }

    func suspendAndFailNextTurnPage() {
        suspendNextTurnPageLoad = true
        failSuspendedTurnPage = true
    }

    func releaseSuspendedTurnPage() {
        suspendedTurnPageContinuation?.resume()
        suspendedTurnPageContinuation = nil
    }

    func suspendAndFailNextItemPage() {
        suspendNextItemPageLoad = true
        failSuspendedItemPage = true
    }

    func releaseSuspendedItemPage() {
        suspendedItemPageContinuation?.resume()
        suspendedItemPageContinuation = nil
    }

    func suspendNextCapabilityModes() {
        suspendNextCapabilityModesLoad = true
    }

    func releaseSuspendedCapabilityModes() {
        suspendedCapabilityModesContinuation?.resume()
        suspendedCapabilityModesContinuation = nil
    }

    func suspendNextCodexServerResponse() {
        suspendNextCodexServerResponseLoad = true
    }

    func releaseSuspendedCodexServerResponse() {
        suspendedCodexServerResponseContinuation?.resume()
        suspendedCodexServerResponseContinuation = nil
    }

    func suspendNextModeSelection() {
        suspendNextModeSelectionLoad = true
    }

    func releaseSuspendedModeSelection() {
        suspendedModeSelectionContinuation?.resume()
        suspendedModeSelectionContinuation = nil
    }

    func suspendAndFailNextInterrupt() {
        suspendNextInterrupt = true
        failSuspendedInterrupt = true
    }

    func releaseSuspendedInterrupt() {
        suspendedInterruptContinuation?.resume()
        suspendedInterruptContinuation = nil
    }

    func suspendNextResumeSession() {
        suspendNextResume = true
    }

    func releaseSuspendedResumeSession() {
        suspendedResumeContinuation?.resume()
        suspendedResumeContinuation = nil
    }

    func suspendNextCreateSession() {
        suspendNextCreate = true
    }

    func releaseSuspendedCreateSession() {
        suspendedCreateContinuation?.resume()
        suspendedCreateContinuation = nil
    }

    func suspendNextFork() {
        suspendNextForkLoad = true
    }

    func releaseSuspendedFork() {
        suspendedForkContinuation?.resume()
        suspendedForkContinuation = nil
    }

    func suspendNextSearchOccurrences() {
        suspendNextSearchOccurrencesLoad = true
    }

    func releaseSuspendedSearchOccurrences() {
        suspendedSearchOccurrencesContinuation?.resume()
        suspendedSearchOccurrencesContinuation = nil
    }

    func suspendNextThreadName() {
        suspendNextThreadNameLoad = true
    }

    func releaseSuspendedThreadName() {
        suspendedThreadNameContinuation?.resume()
        suspendedThreadNameContinuation = nil
    }

    func suspendNextArchive() {
        suspendNextArchiveLoad = true
    }

    func releaseSuspendedArchive() {
        suspendedArchiveContinuation?.resume()
        suspendedArchiveContinuation = nil
    }

    func suspendNextDelete() {
        suspendNextDeleteLoad = true
    }

    func releaseSuspendedDelete() {
        suspendedDeleteContinuation?.resume()
        suspendedDeleteContinuation = nil
    }

    func modelCatalog(for session: HarnessSessionHandle) async throws -> CodexModelCatalog {
        composerModelsReads += 1
        if suspendNextCapabilityModesLoad {
            suspendNextCapabilityModesLoad = false
            isCapabilityModesBlocked = true
            await withCheckedContinuation { suspendedCapabilityModesContinuation = $0 }
            isCapabilityModesBlocked = false
        }
        return CodexModelCatalog(models: [CodexModelOption(
            id: "test-model", model: "test-model", displayName: "Test Codex",
            defaultReasoningEffort: "low", supportedReasoningEfforts: ["low", "high"], isDefault: true
        )], selection: modelSelections[session.localSessionID] ?? .init(model: "test-model", reasoningEffort: "low"))
    }

    func selectModel(_ selection: CodexModelSelection, for session: HarnessSessionHandle) async throws -> CodexModelCatalog {
        guard selection.model == "test-model" else {
            throw HarnessAdapterError.capabilityUnavailable("Model is no longer available")
        }
        modelSelections[session.localSessionID] = selection
        return try await modelCatalog(for: session)
    }

    func collaborationModes() async throws -> [CodexCollaborationPreset] {
        composerModesReads += 1
        if suspendNextCapabilityModesLoad {
            suspendNextCapabilityModesLoad = false
            isCapabilityModesBlocked = true
            await withCheckedContinuation { continuation in
                suspendedCapabilityModesContinuation = continuation
            }
            isCapabilityModesBlocked = false
        }
        return [CodexCollaborationPreset(
            name: "Plan",
            mode: "plan",
            model: "gpt-5",
            reasoningEffort: "high"
        )] + (offersDefaultMode ? [CodexCollaborationPreset(
            name: "Default",
            mode: "default",
            model: "gpt-5",
            reasoningEffort: "medium"
        )] : [])
    }
    private var offersDefaultMode = false
    private(set) var selectedCollaborationPresets: [CodexCollaborationPreset?] = []
    func offerDefaultMode() { offersDefaultMode = true }
    func skills(in workspaceURL: URL) async throws -> [CodexSkillSummary] { composerSkillsReads += 1; return [] }
    func plugins(in workspaceURL: URL) async throws -> [CodexPluginSummary] { composerPluginReads += 1; return [] }
    func recentThreads(in workspaceURL: URL) async throws -> [CodexThreadSummary] { [] }
    func recentThreadsPage(
        in workspaceURL: URL,
        cursor: String?,
        limit: Int64
    ) async throws -> CodexRecentThreadsPage {
        recentPageLoads.append((workspaceURL, cursor, limit))
        if suspendNextRecentPage {
            suspendNextRecentPage = false
            isRecentPageBlocked = true
            await withCheckedContinuation { continuation in
                suspendedRecentPageContinuation = continuation
            }
            isRecentPageBlocked = false
        }
        let id = cursor == nil ? "recent-first" : "recent-second"
        let title = cursor == nil ? "First recent" : "Second recent"
        let threads = cursor == nil
            ? [CodexThreadSummary(
                id: id,
                title: title,
                preview: title,
                workspaceURL: workspaceURL,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                forkedFromID: nil
            )]
            : [
                CodexThreadSummary(
                    id: "recent-first",
                    title: "First recent",
                    preview: "First recent",
                    workspaceURL: workspaceURL,
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    forkedFromID: nil
                ),
                CodexThreadSummary(
                    id: id,
                    title: title,
                    preview: title,
                    workspaceURL: workspaceURL,
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    forkedFromID: nil
                )
            ]
        return CodexRecentThreadsPage(
            threads: threads,
            nextCursor: cursor == nil ? "recent-cursor" : nil
        )
    }
    func searchThreads(
        in workspaceURL: URL,
        searchTerm: String,
        cursor: String?,
        limit: Int64
    ) async throws -> CodexThreadSearchPage {
        CodexThreadSearchPage(matches: [], nextCursor: nil)
    }
    func searchOccurrences(
        threadID: String,
        searchTerm: String,
        cursor: String?,
        limit: Int64
    ) async throws -> CodexThreadSearchOccurrencesPage {
        if suspendNextSearchOccurrencesLoad {
            suspendNextSearchOccurrencesLoad = false
            isSearchOccurrencesBlocked = true
            await withCheckedContinuation { continuation in
                suspendedSearchOccurrencesContinuation = continuation
            }
            isSearchOccurrencesBlocked = false
        }
        return CodexThreadSearchOccurrencesPage(
            occurrences: [CodexThreadSearchOccurrence(
                turnID: "history-turn",
                itemID: "history-item",
                snippet: searchTerm,
                snippetMatchRange: CodexTextRange(start: 0, end: searchTerm.utf16.count),
                turnCursor: "history-turn-cursor"
            )],
            nextCursor: nil
        )
    }
    func setThreadName(_ name: String, for session: HarnessSessionHandle) async throws {
        if suspendNextThreadNameLoad {
            suspendNextThreadNameLoad = false
            isThreadNameBlocked = true
            await withCheckedContinuation { continuation in
                suspendedThreadNameContinuation = continuation
            }
            isThreadNameBlocked = false
        }
    }
    func archiveThread(_ session: HarnessSessionHandle) async throws {
        if suspendNextArchiveLoad {
            suspendNextArchiveLoad = false
            isArchiveBlocked = true
            await withCheckedContinuation { continuation in
                suspendedArchiveContinuation = continuation
            }
            isArchiveBlocked = false
        }
        archivedSessionIDs.append(session.localSessionID)
    }
    func deleteThread(_ session: HarnessSessionHandle) async throws {
        if suspendNextDeleteLoad {
            suspendNextDeleteLoad = false
            isDeleteBlocked = true
            await withCheckedContinuation { continuation in
                suspendedDeleteContinuation = continuation
            }
            isDeleteBlocked = false
        }
        deletedSessionIDs.append(session.localSessionID)
    }
    func selectCollaborationMode(
        _ preset: CodexCollaborationPreset?,
        for session: HarnessSessionHandle
    ) async throws {
        selectedCollaborationPresets.append(preset)
        if suspendNextModeSelectionLoad {
            suspendNextModeSelectionLoad = false
            isModeSelectionBlocked = true
            await withCheckedContinuation { continuation in
                suspendedModeSelectionContinuation = continuation
            }
            isModeSelectionBlocked = false
        }
    }
    func selectRunLocation(
        _ location: CodexRunLocation,
        for session: HarnessSessionHandle
    ) async throws {}
    func fork(
        _ session: HarnessSessionHandle,
        newLocalSessionID: UUID
    ) async throws -> HarnessSessionHandle {
        forkedFromSessionIDs.append(session.localSessionID)
        if suspendNextForkLoad {
            suspendNextForkLoad = false
            isForkBlocked = true
            await withCheckedContinuation { continuation in
                suspendedForkContinuation = continuation
            }
            isForkBlocked = false
        }
        return HarnessSessionHandle(
            harness: kind,
            localSessionID: newLocalSessionID,
            providerSessionID: "fork-(newLocalSessionID.uuidString)",
            workspaceURL: session.workspaceURL
        )
    }

    func fork(_ session: HarnessSessionHandle, newLocalSessionID: UUID,
        throughTurnID: String?) async throws -> HarnessSessionHandle {
        forkedThroughTurnIDs.append(throughTurnID)
        return try await fork(session, newLocalSessionID: newLocalSessionID)
    }
    func startWorkingTreeReview(in session: HarnessSessionHandle) async throws {}

    func activeTurnID(for session: HarnessSessionHandle) -> String? {
        activeCodexTurnIDs[session.localSessionID]
    }

    func answerablePendingServerRequestIDs(
        _ requests: [CodexPendingServerRequest],
        for session: HarnessSessionHandle
    ) -> Set<String> {
        restoredPendingRequests[session.localSessionID] = requests
        return rejectsPendingRequestRestoration ? [] : Set(requests.map(\.id))
    }

    func rejectPendingRequestRestoration() {
        rejectsPendingRequestRestoration = true
    }
    func interrupt(_ session: HarnessSessionHandle) async throws {
        interruptedSessionIDs.append(session.localSessionID)
        if suspendNextInterrupt {
            suspendNextInterrupt = false
            isInterruptBlocked = true
            await withCheckedContinuation { continuation in
                suspendedInterruptContinuation = continuation
            }
            isInterruptBlocked = false
            if failSuspendedInterrupt {
                failSuspendedInterrupt = false
                throw HarnessAdapterError.invalidProviderEvent(
                    "interrupt ignored cancellation"
                )
            }
        }
    }
    func respond(
        to permissionRequestID: String,
        decision: PermissionDecision,
        in session: HarnessSessionHandle
    ) async throws {
        permissionDecisions[permissionRequestID] = decision
    }

    func providerCapabilities(
        for session: HarnessSessionHandle
    ) async throws -> ProviderCapabilityState {
        let current = providerOptionSelections[StructuredHeadlessOptionID.executionMode]
            ?? "default"
        return ProviderCapabilityState(selectors: [ProviderCapabilitySelector(
            id: StructuredHeadlessOptionID.executionMode,
            name: "Execution mode",
            description: nil,
            category: "mode",
            currentValue: current,
            choices: [
                ProviderCapabilityChoice(value: "default", name: "Default", description: nil),
                ProviderCapabilityChoice(value: "plan", name: "Plan", description: nil)
            ]
        )])
    }

    func setProviderOption(
        id: String,
        value: String,
        in session: HarnessSessionHandle
    ) async throws -> ProviderCapabilityState {
        providerOptionSelections[id] = value
        return try await providerCapabilities(for: session)
    }

    func performProviderAction(
        id: String,
        in session: HarnessSessionHandle
    ) async throws -> ProviderCapabilityState {
        throw HarnessAdapterError.capabilityUnavailable("fixture action unavailable")
    }

    func presentationState(for session: HarnessSessionHandle) throws -> CodexTaskState {
        codexPresentationStates[session.localSessionID] ?? .empty
    }

    func refreshPresentationState(
        for session: HarnessSessionHandle
    ) async throws -> CodexTaskState {
        try presentationState(for: session)
    }

    func loadTurns(
        for session: HarnessSessionHandle,
        cursor: String?,
        limit: Int64?
    ) async throws -> CodexTurnPage {
        turnPageLoads.append((session.localSessionID, cursor, limit))
        if suspendNextTurnPageLoad {
            suspendNextTurnPageLoad = false
            isTurnPageBlocked = true
            await withCheckedContinuation { continuation in
                suspendedTurnPageContinuation = continuation
            }
            isTurnPageBlocked = false
            if failSuspendedTurnPage {
                failSuspendedTurnPage = false
                throw HarnessAdapterError.invalidProviderEvent(
                    "turn page ignored cancellation"
                )
            }
        }
        return CodexTurnPage(turns: [], nextCursor: nil, backwardsCursor: nil)
    }

    func loadItems(
        for session: HarnessSessionHandle,
        turnID: String?,
        cursor: String?,
        limit: Int64?
    ) async throws -> CodexItemPage {
        itemPageLoads.append((session.localSessionID, turnID, cursor, limit))
        if suspendNextItemPageLoad {
            suspendNextItemPageLoad = false
            isItemPageBlocked = true
            await withCheckedContinuation { continuation in
                suspendedItemPageContinuation = continuation
            }
            isItemPageBlocked = false
            if failSuspendedItemPage {
                failSuspendedItemPage = false
                throw HarnessAdapterError.invalidProviderEvent(
                    "item page ignored cancellation"
                )
            }
        }
        return CodexItemPage(entries: [], nextCursor: nil, backwardsCursor: nil)
    }

    func presentationStates(
        for session: HarnessSessionHandle
    ) async throws -> AsyncStream<CodexTaskState> {
        let pair = AsyncStream<CodexTaskState>.makeStream()
        pair.continuation.yield(codexPresentationStates[session.localSessionID] ?? .empty)
        codexPresentationContinuations[session.localSessionID]?.finish()
        codexPresentationContinuations[session.localSessionID] = pair.continuation
        return pair.stream
    }

    func respond(
        to serverRequestID: String,
        response: CodexServerRequestResponse,
        in session: HarnessSessionHandle
    ) async throws {
        if suspendNextCodexServerResponseLoad {
            suspendNextCodexServerResponseLoad = false
            isCodexServerResponseBlocked = true
            await withCheckedContinuation { continuation in
                suspendedCodexServerResponseContinuation = continuation
            }
            isCodexServerResponseBlocked = false
        }
    }

    func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> {
        streams[session.localSessionID] ?? AsyncStream { $0.finish() }
    }

    func close(_ session: HarnessSessionHandle) async {
        closeCount += 1
        handles.removeValue(forKey: session.localSessionID)
        streams.removeValue(forKey: session.localSessionID)
        continuations.removeValue(forKey: session.localSessionID)?.finish()
        codexPresentationStates.removeValue(forKey: session.localSessionID)
        codexPresentationContinuations.removeValue(forKey: session.localSessionID)?.finish()
        activeCodexTurnIDs.removeValue(forKey: session.localSessionID)
    }

    func emit(
        _ payload: HarnessEventPayload,
        for localSessionID: UUID,
        sequence: UInt64
    ) {
        if case .sessionStatusChanged(.ready) = payload {
            activeCodexTurnIDs.removeValue(forKey: localSessionID)
        }
        continuations[localSessionID]?.yield(
            HarnessEventEnvelope(
                localSessionID: localSessionID,
                sequence: sequence,
                payload: payload
            )
        )
    }

    func finishEvents(for localSessionID: UUID) {
        continuations[localSessionID]?.finish()
    }

    func emitPresentation(_ state: CodexTaskState, for localSessionID: UUID) {
        codexPresentationStates[localSessionID] = state
        codexPresentationContinuations[localSessionID]?.yield(state)
    }

    private func createEventStream(for localSessionID: UUID) {
        let pair = AsyncStream<HarnessEventEnvelope>.makeStream()
        streams[localSessionID] = pair.stream
        continuations[localSessionID] = pair.continuation
    }
}

/// The double forks the way the adapter of its kind does: a Codex task's attached thread forks,
/// and every other kind has no native fork, so its side chat starts from a reading snapshot.
extension FakeHarnessAdapter: HarnessSessionBranching {
    nonisolated var sessionBranchMethod: HarnessSessionBranchMethod? { kind == .codex ? .attachedSession : nil }
}

extension FakeHarnessAdapter: HarnessSessionLifecycleProviding {
    func archiveProviderSession(_ session: HarnessSessionHandle) async throws {
        try await archiveThread(session)
    }

    func unarchiveProviderSession(providerSessionID: String) async throws {
        throw HarnessAdapterError.capabilityUnavailable("Codex thread unarchive is unavailable")
    }

    func deleteProviderSession(_ session: HarnessSessionHandle) async throws {
        try await deleteThread(session)
    }

    func renameProviderSession(_ session: HarnessSessionHandle, to title: String) async throws {
        try await setThreadName(title, for: session)
    }
}

/// Saved on the snapshot writer's queue and read on the main thread, so it keeps its state behind a lock.
private final class CountingTranscriptCache: TranscriptRepository {
    private let state = OSAllocatedUnfairLock(initialState: (saves: 0, entries: [UUID: [TranscriptEntry]]()))
    var saves: Int { state.withLock { $0.saves } }
    func load(for sessionID: UUID) -> [TranscriptEntry] { state.withLock { $0.entries[sessionID] ?? [] } }
    func save(_ value: [TranscriptEntry], for sessionID: UUID) {
        state.withLock { $0.saves += 1; $0.entries[sessionID] = value }
    }
    func remove(for sessionID: UUID) { state.withLock { _ = $0.entries.removeValue(forKey: sessionID) } }
}

extension FakeHarnessAdapter: CodexBackgroundTerminalControlling {
    func backgroundTerminals(in session: HarnessSessionHandle) async throws -> [CodexBackgroundTerminal] {
        backgroundTerminalList
    }

    func terminateBackgroundTerminal(processID: String, in session: HarnessSessionHandle) async throws {
        backgroundTerminalList.removeAll { $0.processID == processID }
    }

    func cleanBackgroundTerminals(in session: HarnessSessionHandle) async throws {
        backgroundTerminalList = []
    }
}
