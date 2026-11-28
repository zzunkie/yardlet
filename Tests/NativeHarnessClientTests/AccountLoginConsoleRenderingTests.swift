import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

@MainActor
final class AccountLoginConsoleRenderingTests: XCTestCase {
    func testAccountConsoleInBothAppearances() async throws {
        let directory = try WindowlessRender.directory("login-console-qa")
        let size = NSSize(width: 780, height: 620)
        let cases: [(String, HarnessKind, AccountConnectionOperation, AccountConnectionInteraction, String, [String])] = [
            ("signing-out", .claudeCode, .disconnect, .guided,
             "IFS= read -r answer", ["Signing out…"]),
            ("signed-out", .claudeCode, .disconnect, .guided,
             "exit 0", ["Signed out"]),
            ("terminal", .openCode, .disconnect, .terminalRequired,
             #"printf '%s\n' '◆  Select credential' '│  ● Example provider' 'https://auth.example.test/device'; IFS= read -r answer"#,
             ["Hide CLI details", "Enter", "Continue in browser"]),
            ("cursor-code", .cursorAgent, .connect, .guided,
             #"printf '%s\n' 'Open https://auth.example.test/device' 'Matching code: 123 456' 'Check the same code.' '' 'Press q to quit'; IFS= read -r answer"#,
             ["Verification code", "Copy code", "123 456"])
        ]
        for appearance in WindowlessRender.Appearance.allCases {
            for (name, harness, operation, interaction, script, labels) in cases {
                let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("account-console-render")))
                let selections = RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false,
                                                       loadsPersistedSelections: false)
                let store = ProviderConnectionStore()
                store.usesFixtureSnapshots = true
                let command = AccountInteractiveCommand(executableURL: URL(filePath: "/bin/sh"),
                    arguments: ["-c", script], initialInput: nil,
                    operation: operation, interaction: interaction)
                let view = HarnessCenterView(runtimeSelections: selections, connections: store,
                    fixtureSnapshots: [], fixtureLoginHarness: harness, fixtureLoginCommand: command)
                    .environment(\.colorScheme, appearance.colorScheme)
                let host = WindowlessRender.Host(view, size: size, appearance: appearance)
                defer { host.close() }

                let expected = labels.map { $0 == "123 456" ? $0 : L10n.string($0) }
                await host.settle(until: {
                    let text = host.accessibilityElements(visibleOnly: true).map(\.description).joined(separator: "\n")
                    return expected.allSatisfy { text.contains($0) }
                })
                try WindowlessRender.writePNG(try host.capture().bitmap,
                    to: directory.appending(path: "\(name)-\(appearance.suffix).png"))
            }
        }
    }
}
