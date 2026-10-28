import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Renders the follow-up queue and reconnect surfaces offscreen; no provider, window server
/// interaction, or app launch is involved.
@MainActor
final class CodexFollowUpRenderingTests: XCTestCase {
    private var directory: URL {
        WindowlessRender.repositoryRoot.appending(path: ".build/codex-followup-qa")
    }

    func testPausedQueueOffersResumeAndEachQueuedMessageItsActions() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let queue = [
            CodexQueuedSubmission(draft: CodexComposerDraft(inputs: [.text("Also update the README")])),
            CodexQueuedSubmission(
                draft: CodexComposerDraft(inputs: [.text("Run the tests again")]),
                state: .failed, failureMessage: "Codex steer requires an active turn"
            )
        ]
        for appearance in [ColorScheme.light, .dark] {
            let composer = PromptComposer(
                harness: .codex, composerDraft: TaskComposerDraft(),
                isRunning: true, canSteer: true, codexQueue: queue, isCodexQueuePaused: true,
                actions: ComposerActions(
                    submitCodex: { _, _ in }, removeQueued: { _ in }, retryQueued: { _ in },
                    moveQueued: { _, _ in }, sendQueuedNow: { _ in }, editQueued: { _ in nil }, resumeQueue: {}
                )
            )
            .frame(width: 760)
            .background(ParityTheme.canvas)
            .environment(\.colorScheme, appearance)
            let bitmap = try render(composer, size: NSSize(width: 760, height: 220))
            try write(bitmap, "composer-queue-\(appearance == .dark ? "dark" : "light").png")
        }
    }

    func testRunningTurnShowsReconnectAndAFailedTurnSaysUsageLimitPlainly() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let decoder = CodexTaskDecoder()
        var thread = try XCTUnwrap(decoder.thread(from: .object(["id": .string("thread")])))
        var failed = try XCTUnwrap(decoder.turn(from: .object([
            "id": .string("failed"), "status": .string("failed"),
            "items": .array([.object(["id": .string("ask"), "type": .string("userMessage"),
                                      "content": .array([.object(["type": .string("text"), "text": .string("Fix the tests")])])])]),
            "error": .object([
                "message": .string("Your limit resets at 3:05 PM."),
                "codexErrorInfo": .string("usageLimitExceeded")
            ])
        ]), fallbackID: "failed"))
        failed.status = .failed
        var running = try XCTUnwrap(decoder.turn(from: .object([
            "id": .string("running"), "status": .string("inProgress"),
            "items": .array([.object(["id": .string("ask-2"), "type": .string("userMessage"),
                                      "content": .array([.object(["type": .string("text"), "text": .string("Try again")])])])])
        ]), fallbackID: "running"))
        running.retryingError = .object(["message": .string("Reconnecting... 2/5")])
        thread.turns = [failed, running]
        for appearance in [ColorScheme.light, .dark] {
            let timeline = TaskConversationView(
                harness: .codex, workspaceURL: URL(filePath: "/tmp/qa"), entries: [],
                codexTaskState: CodexTaskState(thread: thread), actions: ConversationActions(retryTurn: { _ in })
            )
            .frame(width: 760, height: 520)
            .background(ParityTheme.canvas)
            .environment(\.colorScheme, appearance)
            let bitmap = try render(timeline, size: NSSize(width: 760, height: 520))
            try write(bitmap, "timeline-errors-\(appearance == .dark ? "dark" : "light").png")
        }
    }

    func testGeneralSettingsOffersQueueOrSteerForFollowUps() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = SettingsCenterView(notificationCenter: SilentNotificationCenter())
            .environment(\.colorScheme, .light)
        let bitmap = try render(settings, size: NSSize(width: 760, height: 560))
        try write(bitmap, "settings-general-light.png")
    }

    private func render<Content: View>(_ view: Content, size: NSSize) throws -> NSBitmapImageRep {
        let bitmap = try WindowlessRender.hosted(view, size: size, passes: 6).bitmap
        XCTAssertTrue(WindowlessRender.drawsContent(bitmap, step: 4, from: 4, background: (1, 1)))
        return bitmap
    }

    private func write(_ bitmap: NSBitmapImageRep, _ name: String) throws {
        try WindowlessRender.writePNG(bitmap, to: directory.appending(path: name))
    }
}

private final class SilentNotificationCenter: SystemNotificationCenter {
    func authorization() async -> SystemNotificationAuthorization { .authorized }
    func requestAuthorization() async -> Bool { true }
    func post(title: String, body: String, identifier: String) async {}
}
