import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Help › Report a Problem… opens GitHub's bug report form with only environment facts filled in, and
/// from an error card that error's message with what would identify the person taken out.
@MainActor final class ProblemReportTests: XCTestCase {
    private let facts = ProblemReport.Facts(
        yardlet: "0.11.10 (32), commit 1c1a2901", macOS: "macOS 26.1 (25B78)", isAppleSilicon: true,
        agents: [.init(name: "Claude Code", version: "2.1.304"), .init(name: "Codex", version: "0.163.0"),
                 .init(name: "Antigravity CLI", version: nil)])
    private let redaction = ProblemReport.Redaction(homePath: "/Users/jdoe", userNames: ["jdoe", "Jane Doe"])

    private func fields(_ url: URL) throws -> [String: String] {
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(url.absoluteString.components(separatedBy: "?").first, "https://github.com/zzunkie/yardlet/issues/new")
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    func testTheFormCarriesEnvironmentFactsAndAScrubbedError() throws {
        let general = try fields(ProblemReport.url(facts: facts, redaction: redaction))
        XCTAssertEqual(general, [
            "template": "bug_report.yml", "version": "0.11.10 (32), commit 1c1a2901",
            "macos": "macOS 26.1 (25B78), Apple silicon", "agent": "Claude Code 2.1.304, Codex 0.163.0",
        ], "Agents without a known version are left out, and nothing is written for the person")

        let message = """
            Claude Code exited: /Users/jdoe/.local/bin/claude could not read /Users/shared-mac/work/plan.md \
            for jane.doe+work@example.com (Jane Doe, jdoe) with key sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789 C++
            """
        let url = ProblemReport.url(facts: facts, problem: .init(harness: "Claude Code", message: message),
                                    redaction: redaction)
        let report = try fields(url)
        XCTAssertEqual(report["agent"], "Claude Code 2.1.304", "The agent the error came from")
        let whatHappened = try XCTUnwrap(report["what-happened"])
        XCTAssertTrue(whatHappened.contains(
            "~/.local/bin/claude could not read /Users/<user>/work/plan.md for <email> (<user>, <user>) with key <redacted> C++"),
            whatHappened)
        for leak in ["jdoe", "Jane", "example.com", "sk-ant", "shared-mac"] {
            XCTAssertFalse(url.absoluteString.removingPercentEncoding!.contains(leak), "\(leak) in \(url)")
        }
        XCTAssertFalse(url.query!.contains("+"), "A plus sign is encoded, since GitHub reads it as a space")
    }

    func testALongErrorIsShortenedToFitTheAddress() throws {
        let message = String(repeating: "작업을 시작하지 못했습니다. ", count: 600)
        let url = ProblemReport.url(facts: facts, problem: .init(harness: "Codex", message: message), redaction: redaction)
        XCTAssertLessThanOrEqual(url.absoluteString.count, ProblemReport.maximumURLLength)
        let whatHappened = try XCTUnwrap(fields(url)["what-happened"])
        XCTAssertTrue(whatHappened.hasPrefix("Codex showed this error in Yardlet:\n\n```text\n작업을"), whatHappened)
        XCTAssertTrue(whatHappened.hasSuffix("\n…\n```\n"), "The cut is marked and the block still closes")
    }

}

/// The error card and the new-task start failure offer the same form, drawn in an unshown window into
/// `.build/report-a-problem-qa`. They draw in the Mac's language; `QA_LANGUAGE` names the files.
@MainActor final class ProblemReportRenderingTests: XCTestCase {
    func testErrorsOfferTheReportWithTheirMessage() throws {
        let directory = try WindowlessRender.directory("report-a-problem-qa")
        let language = ProcessInfo.processInfo.environment["QA_LANGUAGE"] ?? "en"
        var reported: [(HarnessKind?, String?)] = []
        let report = YardletReportProblemAction { reported.append(($0, $1)) }
        let message = "Codex App Server ended before it answered thread/start (exit code 1)."

        let cardSize = NSSize(width: 640, height: 330)
        func card(_ appearance: WindowlessRender.Appearance) -> some View {
            TranscriptErrorCard(harness: .codex, message: message, recoverable: true, onShowHarnessSettings: {})
                .padding(16).frame(width: cardSize.width, height: cardSize.height, alignment: .top)
                .background(ParityTheme.canvas).environment(\.colorScheme, appearance.colorScheme)
                .environment(\.yardletReportProblem, report)
        }
        for appearance in WindowlessRender.Appearance.allCases {
            let host = WindowlessRender.Host(card(appearance), size: cardSize, appearance: appearance)
            defer { host.close() }
            host.settle()
            XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Error details")))
            host.settle(passes: 24)
            let capture = try host.capture()
            try WindowlessRender.writePNG(capture.bitmap, to: directory.appending(path: "error-card-\(language)-\(appearance.suffix).png"))
            XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 4, from: 4, background: (1, 1)))
            if appearance == .light {
                XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Report a Problem…")))
                XCTAssertEqual(reported.map(\.0), [.codex])
                XCTAssertEqual(reported.map(\.1), [message])
            }
        }

        let folder = FileManager.default.temporaryDirectory.appending(path: "report-a-problem-\(UUID().uuidString)")
        let workspace = folder.appending(path: "yardlet-sandbox")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let runtime = RuntimeSelectionStore(defaults: SuggestionVolatileDefaults(), discoversRuntimes: false,
                                            loadsPersistedSelections: false)
        let cli = URL(filePath: "/usr/bin/true")
        runtime.select(cli, for: .codex)
        let project = Project(name: "yardlet-sandbox", primaryRoot: workspace)
        let draft = NewTaskDraft()
        draft.workspaceURL = workspace
        draft.projectID = project.id
        draft.harness = .codex
        draft.text = "Explain the build"
        let submission = try XCTUnwrap(draft.beginSubmission(runtimeURL: cli))
        draft.complete(submission, succeeded: false, error: message)
        let homeSize = NSSize(width: 820, height: 330)
        for capture in try WindowlessRender.hostedInBothAppearances("start-failure-\(language)", in: directory, size: homeSize, content: { appearance in
            NewTaskHome(recentSessions: [], projects: [project], draft: draft, runtimeSelections: runtime,
                onSelectSession: { _ in }, onChooseWorkspace: { _ in }, onShowHarnesses: {}, onCreate: { _ in nil })
                .frame(width: homeSize.width, height: homeSize.height)
                .background(ParityTheme.canvas).environment(\.colorScheme, appearance.colorScheme)
                .environment(\.yardletReportProblem, report)
        }) { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 4, from: 4, background: (1, 1))) }
    }
}
