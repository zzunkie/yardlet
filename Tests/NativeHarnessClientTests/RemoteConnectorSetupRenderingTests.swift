import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient
@testable import YardletRemote

/// The real remote add form, with no network or sign-in, drawn in `.build/remote-connectors-qa`.
@MainActor
final class RemoteConnectorSetupRenderingTests: XCTestCase {
    private func client() -> RemoteConnectorSetupClient {
        RemoteConnectorSetupClient(host: "Mac Studio", userAgent: FakeUserAgent(), request: { request in
            .failure(request.operationID, RemoteError(.unavailable))
        })
    }

    func testTheRemoteDirectoryAndCredentialFormsDraw() throws {
        let directory = try WindowlessRender.directory("remote-connectors-qa")
        let pages: [(String, String?, RemoteConnectorAddSheet.Authentication?)] = [
            ("directory", nil, nil), ("slack", "slack", nil), ("github", "github", nil),
            ("github-client", "github", .client), ("google", "gmail", nil), ("custom", "custom", nil),
            ("custom-token", "custom", .token)
        ]
        for (name, preset, authentication) in pages {
            let client = client()
            let captures = try WindowlessRender.hostedInBothAppearances("add-\(name)", in: directory,
                size: NSSize(width: 580, height: 660)) { appearance in
                    RemoteConnectorAddSheet(hostName: "Mac Studio", client: client, initialPresetID: preset,
                        initialAuthentication: authentication, onClose: {})
                        .environment(\.colorScheme, appearance.colorScheme)
                }
            for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
            if ["slack", "github-client", "custom-token", "google"].contains(name) {
                let host = WindowlessRender.Host(RemoteConnectorAddSheet(hostName: "Mac Studio", client: client,
                    initialPresetID: preset, initialAuthentication: authentication, onClose: {}),
                    size: NSSize(width: 580, height: 660))
                defer { host.close() }
                host.settle()
                let text = host.accessibilityElements().map { "\($0.label) \($0.value)" }.joined(separator: "\n")
                if name == "google" {
                    XCTAssertTrue(text.contains(L10n.string("Create a Personal Mode client")), text)
                    XCTAssertTrue(text.contains(L10n.string("Client ID")), text)
                } else if name == "custom-token" {
                    XCTAssertFalse(text.contains("Sign-in opens in this computer's browser"))
                } else {
                    XCTAssertTrue(text.contains("http://127.0.0.1:47823/callback"), text)
                    XCTAssertFalse(text.contains("47,823"), "Redirect ports must not be localized")
                }
            }
        }
    }

    func testAddingFromTheRemoteEmptyStateInvokesTheHostCallback() throws {
        let center = ConnectorCenter(environment: .init(repository: InMemoryConnectorRepository(),
            credentials: InMemoryConnectorCredentialStore(), http: FakeConnectorServer(),
            userAgent: nil, sha256: MacOAuthUserAgent.sha256, clientVersion: "test"))
        var additions = 0
        let host = WindowlessRender.Host(ConnectorSettingsView(center: center, isRemote: true,
            onRemoteAdd: { additions += 1 }).padding(20).frame(width: 640, height: 400),
            size: NSSize(width: 640, height: 400))
        defer { host.close() }
        host.settle()
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Add connector")))
        XCTAssertEqual(additions, 1)
        XCTAssertTrue(center.connectors.isEmpty, "The remote projection must not create a local connector")

        let oldHost = WindowlessRender.Host(ConnectorSettingsView(center: center, isRemote: true)
            .padding(20).frame(width: 640, height: 400), size: NSSize(width: 640, height: 400))
        defer { oldHost.close() }
        oldHost.settle()
        XCTAssertFalse(oldHost.accessibilityElements().contains { $0.label == L10n.string("Add connector") })
    }
}
