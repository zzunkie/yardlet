import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Renders Settings › CLI Updates offscreen into `.build/cli-update-qa`, light and dark, from
/// fixture installs and a fake runner.
@MainActor
final class CLIUpdateSettingsRenderingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "yardlet-cli-update-render-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTheCLIUpdatesSectionDrawsEachInstallAfterACheck() async throws {
        let directory = try WindowlessRender.directory("cli-update-qa")
        let center = try await checkedCenter()
        let runtimes = try await chosenHomebrewCodex()
        let chatGPT = try XCTUnwrap(runtimes.newerInstalls[.codex])
        XCTAssertEqual(chatGPT.version, "0.164.0-alpha.11.1")

        XCTAssertEqual(center.rows.map(\.harness), [.codex, .claudeCode, .openCode, .cursorAgent, .antigravityCLI, .grokBuild])
        XCTAssertEqual(center.heldVersion(for: .codex)?.version, "0.157.1")
        XCTAssertEqual(center.row(for: .openCode)?.outcome, .updated(from: "1.2.0", to: "1.3.0"))
        XCTAssertEqual(center.row(for: .grokBuild)?.phase, .waitingForTasks)
        XCTAssertEqual(center.row(for: .cursorAgent)?.decision, .skip(.cannotVerify))
        XCTAssertEqual(center.row(for: .antigravityCLI)?.latest, .upToDate)

        let size = NSSize(width: 820, height: 900)
        let captures = try WindowlessRender.hostedInBothAppearances("cli-updates", in: directory, size: size) { appearance in
            settings(center, runtimes: runtimes).environment(\.colorScheme, appearance.colorScheme)
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }

        let host = WindowlessRender.Host(settings(center, runtimes: runtimes), size: size)
        defer { host.close() }
        host.settle()
        let elements = host.accessibilityElements()
        let labels = elements.map(\.label)
        XCTAssertTrue(labels.contains(L10n.string("CLI automatic updates")), labels.description)
        XCTAssertTrue(labels.contains(L10n.format("Check %@ for updates", "Codex")), labels.description)
        XCTAssertTrue(elements.contains { "\($0.label) \($0.value)".contains(
            L10n.format("Newer version installed: %1$@ · %2$@", "0.164.0-alpha.11.1",
                        L10n.format("Comes with the %@ app", "ChatGPT"))) }, elements.description)

        let notice = try XCTUnwrap(center.notice)
        let bars = try WindowlessRender.hostedInBothAppearances("cli-update-notice", in: directory,
                                                                size: NSSize(width: 820, height: 44)) { appearance in
            WorktreeNoticeBar(message: notice.message, systemImage: "arrow.uturn.backward.circle", onDismiss: {})
                .frame(width: 820, height: 44)
                .background(ParityTheme.canvas)
                .environment(\.colorScheme, appearance.colorScheme)
        }
        for bar in bars { XCTAssertTrue(WindowlessRender.drawsContent(bar.bitmap, step: 4)) }

        // Using it drops the person's choice: Codex follows its newest install again.
        XCTAssertTrue(host.hosting.pressButton(labeled: L10n.format("Use %1$@ %2$@", "Codex", "0.164.0-alpha.11.1")))
        await host.settle { runtimes.selectedURL(for: .codex) == chatGPT.url }
        XCTAssertEqual(runtimes.selectedURL(for: .codex), chatGPT.url)
        XCTAssertNil(runtimes.newerInstalls[.codex])
        // Queued after the check the button started, so that one ends before the fixtures go.
        await center.check(.codex)
    }

    private func settings(_ center: CLIUpdateCenter, runtimes: RuntimeSelectionStore) -> some View {
        SettingsCenterView(size: CGSize(width: 820, height: 900), initialSection: SettingsSection.cliUpdates.rawValue,
                           notificationCenter: MenuBarQuietNotificationCenter(),
                           accounts: SettingsAccountsContext(runtimeSelections: runtimes,
                                                             connections: ProviderConnectionStore(), fixtureSnapshots: []),
                           cliUpdates: center)
    }

    // MARK: - Fixtures

    /// The Homebrew Codex chosen in Settings, and the ChatGPT app's newer one beside it. Versions
    /// come from the fixture files; nothing runs.
    private func chosenHomebrewCodex() async throws -> RuntimeSelectionStore {
        let homebrew = root.appending(path: "opt/homebrew/bin/codex")
        let chatGPT = try write("Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex", version: "0.164.0-alpha.11.1")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("CLIUpdateSettingsRenderingTests.runtimes")))
        let runtimes = RuntimeSelectionStore(defaults: defaults, loadsPersistedSelections: false,
            candidates: { $0 == .codex ? [homebrew, chatGPT] : [] },
            versions: RuntimeVersionCache(defaults: defaults) { Self.version(of: $0) })
        runtimes.select(homebrew, for: .codex)
        await runtimes.findNewest()
        return runtimes
    }

    private func checkedCenter() async throws -> CLIUpdateCenter {
        try write("opt/homebrew/bin/brew")
        try write("opt/homebrew/bin/npm")
        try write("opt/homebrew/Caskroom/codex/0.157.1/bin/codex", version: "0.157.1")
        let codex = try link("opt/homebrew/bin/codex", to: "../Caskroom/codex/0.157.1/bin/codex")
        let claude = try write("home/Library/Application Support/Claude/claude-code/2.1.293/claude.app/Contents/MacOS/claude",
                               version: "2.1.293")
        try write("opt/homebrew/lib/node_modules/opencode-ai/bin/opencode", version: "1.2.0")
        let opencode = try link("opt/homebrew/bin/opencode", to: "../lib/node_modules/opencode-ai/bin/opencode")
        try write("home/.local/share/cursor-agent/versions/2026.08.11-e8db854/cursor-agent", version: "2026.08.11-e8db854")
        let cursor = try link("home/.local/bin/cursor-agent", to: "../share/cursor-agent/versions/2026.08.11-e8db854/cursor-agent")
        let agy = try write("home/.local/bin/agy", version: "1.4.0")
        try write("home/.grok/downloads/grok-1.0.30-macos-aarch64", version: "1.0.30")
        let grok = try link("home/.grok/bin/grok", to: "../downloads/grok-1.0.30-macos-aarch64")

        let base = root!
        let runner = FakeCLIRunner { command in
            let name = command.executable.lastPathComponent
            switch (name, command.arguments) {
            case (_, ["--version"]):
                return Self.ok(Self.version(of: command.executable) ?? "?")
            case ("brew", let arguments) where arguments.first == "outdated":
                return Self.ok(Self.version(of: codex) == "0.157.1"
                    ? #"{"formulae":[],"casks":[{"name":"codex","installed_versions":["0.157.1"],"current_version":"0.163.0"}]}"#
                    : #"{"formulae":[],"casks":[]}"#)
            case ("brew", let arguments) where arguments.first == "upgrade":
                try? Self.writeFile(base.appending(path: "opt/homebrew/Caskroom/codex/0.163.0/bin/codex"), version: "0.163.0")
                try? FileManager.default.removeItem(at: codex)
                try? FileManager.default.createSymbolicLink(atPath: codex.path(percentEncoded: false),
                    withDestinationPath: "../Caskroom/codex/0.163.0/bin/codex")
                try? FileManager.default.removeItem(at: base.appending(path: "opt/homebrew/Caskroom/codex/0.157.1"))
                return Self.ok("")
            case ("npm", let arguments) where arguments.first == "view":
                return Self.ok("\"1.3.0\"")
            case ("npm", let arguments) where arguments.first == "install":
                try? Self.writeFile(base.appending(path: "opt/homebrew/lib/node_modules/opencode-ai/bin/opencode"), version: "1.3.0")
                return Self.ok("")
            case (_, ["update", "--check", "--json"]):
                return Self.ok(#"{"currentVersion":"1.0.30","latestVersion":"1.0.60","updateAvailable":true,"error":null}"#)
            default:
                return Self.ok("")
            }
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("CLIUpdateSettingsRenderingTests")))
        let runtimes: [HarnessKind: URL] = [.codex: codex, .claudeCode: claude, .openCode: opencode,
                                            .cursorAgent: cursor, .antigravityCLI: agy, .grokBuild: grok]
        let center = CLIUpdateCenter(dependencies: .init(
            runtimes: { runtimes },
            busyHarnesses: { [.grokBuild] },
            runner: runner,
            verifier: FakeVerifier(failing: ["0.163.0"], verifiable: [.codex, .claudeCode, .openCode, .antigravityCLI, .grokBuild]),
            overrides: CLIRuntimeOverrides(defaults: defaults),
            defaults: defaults,
            previousVersionsDirectory: root.appending(path: "cli-previous"),
            environment: [:]))
        await center.checkAll()
        return center
    }

    nonisolated private static func ok(_ stdout: String) -> CLICommandResult {
        CLICommandResult(exitCode: 0, stdout: stdout, stderr: "")
    }

    nonisolated private static func version(of url: URL) -> String? {
        guard let text = try? String(contentsOf: url.resolvingSymlinksInPath(), encoding: .utf8),
              let range = text.range(of: #"(?<=# version )\S+"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    nonisolated private static func writeFile(_ url: URL, version: String?) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n# version \(version ?? "none")\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
    }

    @discardableResult
    private func write(_ relative: String, version: String? = nil) throws -> URL {
        let url = root.appending(path: relative)
        try Self.writeFile(url, version: version)
        return url
    }

    private func link(_ relative: String, to destination: String) throws -> URL {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path(percentEncoded: false), withDestinationPath: destination)
        return url
    }
}
