import AppKit
import Network
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// A message's HTML fetches nothing from the network until the person shows its images: a remote
/// image, the usual tracking pixel, reaches its server only after that.
@MainActor
final class MailHTMLBodyTests: XCTestCase {
    func testRemoteImagesAreFetchedOnlyOnceShown() async throws {
        let server = try await PixelServer.start()
        defer { server.stop() }
        let html = #"<p>Quarterly report</p><img src="http://127.0.0.1:\#(server.port)/pixel.gif" width="1" height="1">"#
        XCTAssertTrue(MailHTMLBody.hasRemoteContent(html))

        let blocked = MeasuredHTML()
        let host = WindowlessRender.Host(MeasuredHTMLView(html: html, allowsRemoteContent: false, measured: blocked)
            .frame(width: 600, height: 400), size: NSSize(width: 600, height: 400))
        defer { host.close() }
        try await waitUntil { blocked.height != nil }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(server.requests, 0, "Nothing is fetched before the person shows the images")

        let shown = MeasuredHTML()
        let second = WindowlessRender.Host(MeasuredHTMLView(html: html, allowsRemoteContent: true, measured: shown)
            .frame(width: 600, height: 400), size: NSSize(width: 600, height: 400))
        defer { second.close() }
        try await waitUntil { server.requests > 0 }
    }
}

@MainActor @Observable
private final class MeasuredHTML {
    var height: CGFloat?
}

private struct MeasuredHTMLView: View {
    let html: String
    let allowsRemoteContent: Bool
    let measured: MeasuredHTML
    @State private var height: CGFloat = 0

    var body: some View {
        MailHTMLBody(html: html, allowsRemoteContent: allowsRemoteContent, openLink: { _ in }, height: $height)
            .onChange(of: height) { _, height in measured.height = height }
    }
}

/// An HTTP server on 127.0.0.1 that answers every request with a one-pixel GIF and counts them.
private final class PixelServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var count = 0
    private(set) var port: UInt16 = 0

    var requests: Int { lock.withLock { count } }

    private init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    static func start() async throws -> PixelServer {
        let server = try PixelServer()
        let ready = AsyncStream<UInt16>.makeStream()
        server.listener.stateUpdateHandler = { [listener = server.listener] state in
            if case .ready = state, let port = listener.port?.rawValue {
                ready.continuation.yield(port)
                ready.continuation.finish()
            }
        }
        server.listener.newConnectionHandler = { [server] connection in server.serve(connection) }
        server.listener.start(queue: .global())
        var iterator = ready.stream.makeAsyncIterator()
        let port = await iterator.next()
        server.port = try XCTUnwrap(port)
        return server
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty else { connection.cancel(); return }
            self.lock.withLock { self.count += 1 }
            let gif = Data(base64Encoded: "R0lGODlhAQABAAAAACw=")!
            var response = Data("HTTP/1.1 200 OK\r\nContent-Type: image/gif\r\nContent-Length: \(gif.count)\r\nConnection: close\r\n\r\n".utf8)
            response.append(gif)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
