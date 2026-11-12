import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The whole main window with the session rail, the side panel (Review) and the terminal all open, at
/// a wide, a laptop and two narrow widths and where the rail and the floating panel come and go, light
/// and dark, into `.build/conversation-width-render/<phase>/` (`CONVERSATION_WIDTH_RENDER` names the
/// phase; without it the test is skipped).
///
/// No provider is contacted and no task attaches. The terminal runs zsh with its own startup folder,
/// and Review reads a Git repository the test makes.
@MainActor
final class ConversationWidthRenderingTests: XCTestCase {
    /// 1800, 1400, 1100 and 1000 points wide; 1407 and 1406, where the rail stands beside the
    /// conversation and the side panel or gives way; 1127 and 1126, where the side panel stands beside
    /// the conversation or floats over its edge.
    private static let widths: [CGFloat] = [1800, 1407, 1406, 1400, 1127, 1126, 1100, 1000]
    private static let height: CGFloat = 900

    private static let reply = """
        The parser test failed because `Lexer.next()` read one character past a closing quote when the \
        string ended the line. I changed the loop to stop at the quote and added a case for a string at the \
        end of the input.

        What changed:

        1. `Lexer.swift`: the string branch returns at the closing quote instead of reading on.
        2. `LexerTests.swift`: a new case, `testAStringAtTheEndOfTheLineEndsThere`.
        3. `README.md`: the command that runs only the parser's tests.

        ```swift
        case "\\"":
            while let next = peek(), next != "\\"" { advance() }
            advance()
            return .string
        ```

        The whole suite passes now, 214 tests in 3.1 seconds. The terminal below shows the last run. \
        Review on the right lists the three files; nothing is staged yet.
        """

    private func git(_ arguments: [String], in folder: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=QA", "-c", "user.email=qa@example.test", "-c", "init.defaultBranch=main"]
            + arguments
        process.currentDirectoryURL = folder
        process.environment = ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "PATH": "/usr/bin:/bin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }

    func testTheConversationWithEveryPanelOpenAtEachWidth() throws {
        guard let phase = ProcessInfo.processInfo.environment["CONVERSATION_WIDTH_RENDER"] else {
            throw XCTSkip("Set CONVERSATION_WIDTH_RENDER to the phase the images are for")
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "yardlet-width-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "notes-app")
        let shellHome = root.appending(path: "shell")
        for directory in [folder, shellHome] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // A prompt that names no account or Mac.
        try Data("PROMPT='%1~ %% '\n".utf8).write(to: shellHome.appending(path: ".zshrc"))
        try Data("# notes-app\n\nA small note taker.\n".utf8).write(to: folder.appending(path: "README.md"))
        try Data("enum Token { case word, string }\n".utf8).write(to: folder.appending(path: "Lexer.swift"))
        try git(["init", "-q"], in: folder)
        try git(["add", "."], in: folder)
        try git(["commit", "-q", "-m", "Start"], in: folder)
        try Data("# notes-app\n\nA small note taker.\n\nRun the parser's tests with `swift test --filter Lexer`.\n".utf8)
            .write(to: folder.appending(path: "README.md"))
        try Data("enum Token { case word, string }\n\n// Stops at the closing quote.\n".utf8)
            .write(to: folder.appending(path: "Lexer.swift"))

        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("ConversationWidthRendering")))
        let task = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/usr/bin/true"),
                                 title: "Fix the failing parser test")
        let model = AppModel(
            store: SessionStore(sessions: [task], repository: InMemorySessionRepository(sessions: [task])),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue."),
            preferences: defaults,
            codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults),
            codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: defaults),
            codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults,
                                                                                         keyPrefix: "history."),
            transcriptRepository: FileTranscriptRepository(directoryURL: root.appending(path: "transcripts")),
            sessionTitleResolver: { _ in nil },
            sessionTitleRetryCount: 0,
            restoresIndexOnLaunch: false
        )
        addTeardownBlock { await model.shutdown() }
        model.transcripts[task.id] = [
            TranscriptEntry(content: .user(text: "The parser test fails on a string at the end of a line. Find why and fix it.")),
            TranscriptEntry(content: .assistant(text: Self.reply, isStreaming: false))
        ]
        model.splits.activate(.session(task.id))
        model.taskWorkspaces.state(for: task.id).setPanels(
            .init(trailingSurfaceID: "diff", isTerminalPresented: true, trailingTabs: ["diff"], recentTrailingTabs: ["diff"]))

        let directory = try WindowlessRender.directory("conversation-width-render/\(phase)")
        // One appearance at a time, the first window drawn once and dropped: the terminal the windows share
        // takes the appearance as it settles.
        for appearance in WindowlessRender.Appearance.allCases {
            for (index, width) in ([Self.widths[0]] + Self.widths).enumerated() {
                let size = NSSize(width: width, height: Self.height)
                let host = WindowlessRender.Host(
                    MainWindow(model: model)
                        .environment(\.terminalShellLaunch, .isolatedZsh(in: shellHome))
                        .frame(width: size.width, height: size.height)
                        .environment(\.colorScheme, appearance.colorScheme)
                        .defaultAppStorage(defaults),
                    size: size, appearance: appearance)
                host.settle(passes: 40, interval: 0.05)
                if index > 0 {
                    try WindowlessRender.writePNG(host.capture().bitmap,
                                                  to: directory.appending(path: "\(Int(width))-\(appearance.suffix).png"))
                }
                host.close()
            }
        }
    }
}
