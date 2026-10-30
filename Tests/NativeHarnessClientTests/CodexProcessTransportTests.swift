import XCTest
@testable import NativeHarnessClient

final class CodexProcessTransportTests: XCTestCase {
    func testRPCFailureShowsProviderMessageAndKeepsStructuredDiagnostics() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "yardlet-rpc-error-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "local-rpc")
        let script = #"""
        #!/bin/sh
        IFS= read -r request
        printf '%s\n' '{"id":10,"error":{"code":-32000,"message":"Side chat could not be opened.","data":{"detail":"retained diagnostic"}}}'
        IFS= read -r request
        printf '%s\n' '{"id":11,"result":{"retried":true}}'
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let transport = CodexProcessTransport(executableURL: executable, requestTimeout: .seconds(2))
        do {
            _ = try await transport.request(.init(id: 10, method: "thread/fork", params: .object([:])))
            XCTFail("The failed fork must not report success")
        } catch let error as CodexRPCRequestFailure {
            XCTAssertEqual(error.requestID, 10)
            XCTAssertEqual(error.payload["code"], .integer(-32000))
            XCTAssertEqual(error.payload["data"]?["detail"], .string("retained diagnostic"))
            XCTAssertEqual(error.localizedDescription, "Side chat could not be opened.")
        } catch {
            await transport.stop()
            throw error
        }
        let retried = try await transport.request(.init(id: 11, method: "thread/fork", params: .object([:])))
        XCTAssertEqual(retried.result?["retried"], .bool(true))
        await transport.stop()
    }

    /// A response many pipe reads long (a whole thread with its turns can be tens of megabytes) is
    /// read in time that grows with its size: the transport looks for the end of the line only in
    /// what each read adds, not again through everything it buffered.
    func testALargeResponseIsReadInOnePass() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "yardlet-rpc-large-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "local-rpc")
        let size = 64 << 20
        let script = """
        #!/bin/sh
        IFS= read -r request
        printf '%s' '{"id":12,"result":{"text":"'
        head -c \(size) /dev/zero | tr '\\0' 'a'
        printf '%s\\n' '"}}'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let transport = CodexProcessTransport(executableURL: executable, requestTimeout: .seconds(120))
        let start = ContinuousClock.now
        let response = try await transport.request(.init(id: 12, method: "thread/read", params: .object([:])))
        let elapsed = ContinuousClock.now - start
        await transport.stop()
        XCTAssertEqual(response.result?["text"]?.stringValue?.utf8.count, size)
        XCTAssertLessThan(elapsed, .seconds(30), "\(size >> 20) MB took \(elapsed)")
    }

    func testMalformedRPCFailureDoesNotDisplayImplementationOrDiagnosticPayload() {
        for payload in [JSONValue.null, .object(["message": .string(" \n "),
                                               "data": .string("internal detail")]),
                        .object(["message": .integer(5)]), .array([.string("internal detail")])] {
            let error = CodexRPCRequestFailure(requestID: 1, payload: payload)
            XCTAssertEqual(error.localizedDescription, L10n.format("%@ could not complete the request", "Codex"))
        }
        XCTAssertEqual(CodexRPCRequestFailure(requestID: 1, payload: .string("  Please try again.  "))
            .localizedDescription, "Please try again.")
    }

    // MARK: - A send that ends says why

    /// A request the App Server never answers ends with the request it was and how long Yardlet
    /// waited, which the task shows, instead of an ID only Yardlet knows.
    func testARequestThatIsNeverAnsweredSaysWhichRequestItWas() async throws {
        let executable = try script("""
        #!/bin/sh
        IFS= read -r request
        sleep 30
        """)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let transport = CodexProcessTransport(executableURL: executable, requestTimeout: .seconds(1))
        do {
            _ = try await transport.request(.init(id: 20, method: "turn/start", params: .object([:])))
            XCTFail("An unanswered request must not report success")
        } catch {
            XCTAssertEqual(error.localizedDescription,
                           L10n.format("Codex did not answer %@ within %lld seconds.", "turn/start", Int64(1)))
        }
        await transport.stop()
    }

    /// An App Server that exits while a request waits ends that request with its exit status and
    /// the last thing it wrote to stderr.
    func testAnAppServerThatExitsEndsTheWaitingRequestWithItsOwnWords() async throws {
        let executable = try script("""
        #!/bin/sh
        IFS= read -r request
        echo 'fatal: state database is locked' >&2
        exit 3
        """)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let transport = CodexProcessTransport(executableURL: executable, requestTimeout: .seconds(20))
        do {
            _ = try await transport.request(.init(id: 21, method: "thread/resume", params: .object([:])))
            XCTFail("A request whose App Server exited must not report success")
        } catch let error as HarnessAdapterError {
            guard case let .processExited(code, message) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(code, 3)
            XCTAssertTrue(message.contains("fatal: state database is locked"), message)
            XCTAssertTrue(error.localizedDescription.contains("fatal: state database is locked"))
        }
        await transport.stop()
    }

    /// An App Server that stopped reading before Yardlet wrote (it exited, or closed its input) makes the request fail;
    /// the write must not end Yardlet with SIGPIPE, as it did in a test process whose fake CLI exited at once.
    func testARequestToAnAppServerThatStoppedReadingFailsWithoutEndingYardlet() async throws {
        let executable = try script("""
        #!/bin/sh
        exec 0<&-
        touch "$0.closed"
        sleep 20
        """)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let transport = CodexProcessTransport(executableURL: executable, requestTimeout: .seconds(20))
        try await transport.start()
        try await waitUntil { FileManager.default.fileExists(atPath: executable.path + ".closed") }
        do {
            _ = try await transport.request(.init(id: 22, method: "thread/list", params: .object([:])))
            XCTFail("A request nobody read must not report success")
        } catch {}
        await transport.stop()
    }

    /// `emittedAtMs` is only a diagnostic timestamp: a frame that carries it as a fraction or a
    /// string is still read, so its response still answers its request.
    func testAReplyWithAnUnexpectedTimestampStillAnswersItsRequest() async throws {
        let executable = try script(#"""
        #!/bin/sh
        IFS= read -r request
        printf '%s\n' '{"method":"thread/readState/changed","params":{"threadId":"t"},"emittedAtMs":"soon"}'
        printf '%s\n' '{"id":22,"result":{"ok":true},"emittedAtMs":1792144844123.5}'
        """#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let transport = CodexProcessTransport(executableURL: executable, requestTimeout: .seconds(5))
        let response = try await transport.request(.init(id: 22, method: "thread/read", params: .object([:])))
        XCTAssertEqual(response.result?["ok"], .bool(true))
        XCTAssertEqual(response.emittedAtMs, 1_792_144_844_123)
        await transport.stop()
    }

    private func script(_ text: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "yardlet-rpc-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appending(path: "local-rpc")
        try Data(text.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }
}
