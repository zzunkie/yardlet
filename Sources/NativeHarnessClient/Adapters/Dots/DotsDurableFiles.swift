import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Why a read of a file on a dot's computer ended: the step it reached, the host's numeric error code
/// when it gave one, and what the person is told. It carries no path, identifier, credential or words of
/// the host's, so it may be printed by a check.
struct DotsRemoteFileError: Error, Equatable, CustomStringConvertible {
    enum Stage: String, Sendable { case initialize, metadata, contents }
    let stage: Stage
    let code: Int64?
    let failure: PersonalAgentFailure

    var description: String { "remote file \(stage.rawValue) \(failure)" + (code.map { " code \($0)" } ?? "") }
}

/// One read of a file a dot's task left on its computer, over the provider's execution-host socket:
/// Yardlet introduces itself under its own name, says it supports no verification of the app, waits
/// for the host to accept that, then asks for the file's metadata and its bytes. Nothing else is sent;
/// any request from the host ends the read, since Yardlet answers none. Only `DotsService` uses it,
/// with a credential it never returns.
enum DotsDurableFiles {
    static let endpoint = URL(string: "wss://codex-cloud-backend.chatgpt.com/")!
    /// The most a file may be. Its bytes arrive whole, Base64 in one message, under the host's 100 MiB
    /// framing; this leaves room for that encoding, and a larger file is refused, never cut short.
    static let maximumBytes = 64 * 1024 * 1024
    static let maximumMessageBytes = 100 * 1024 * 1024
    /// How long the whole read may take, from opening the socket to the last byte.
    static let timeout: TimeInterval = 120

    static let initializeID = "yardlet-initialize"
    static let metadataID = "yardlet-metadata"
    static let readID = "yardlet-read"

    /// The socket's request: the protocol markers the host speaks, with the credential in the last
    /// one as the provider's client sends it, and the account it is for. No cookie, no redirect.
    static func request(token: String, account: String) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.setValue(["codex-app-server", "codex-client.desktop", "openai-bearer." + token].joined(separator: ", "),
                         forHTTPHeaderField: "Sec-WebSocket-Protocol")
        request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("codex", forHTTPHeaderField: "X-OpenAI-Product-Sku")
        request.setValue("Yardlet/PersonalAgents", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        return request
    }

    /// Yardlet as it is: its own name and version, and only the capabilities it has.
    static func initialize(version: String) -> JSONValue {
        .object(["id": .string(initializeID), "method": .string("initialize"), "params": .object([
            "clientInfo": .object(["name": .string("yardlet"), "title": .string("Yardlet"), "version": .string(version)]),
            "capabilities": .object(["experimentalApi": .bool(true), "requestAttestation": .bool(false)])
        ])])
    }

    /// Reads `path` on the computer `environmentID` through an open socket, then closes it. Each step
    /// waits for the answer to its own request: an answer to another of Yardlet's requests, out of turn,
    /// is not taken for it. A failure says at which step, with the host's numeric error code if it gave
    /// one, and never its words.
    static func read(_ path: String, environmentID: String, socket: any DotsEventSocket,
                     version: String) async throws -> Data {
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        socket.resume()
        var stage = DotsRemoteFileError.Stage.initialize
        func fail(_ failure: PersonalAgentFailure, code: Int64? = nil) -> DotsRemoteFileError {
            .init(stage: stage, code: code, failure: failure)
        }
        do { try await send(initialize(version: version), on: socket) } catch { throw fail(.network) }
        let file: JSONValue = .object(["environmentId": .string(environmentID), "path": .string(path)])
        let ids: [DotsRemoteFileError.Stage: String] = [.initialize: initializeID, .metadata: metadataID, .contents: readID]
        while true {
            if Task.isCancelled { throw CancellationError() }
            let message: JSONValue
            do { message = try await receive(socket) }
            catch let failure as PersonalAgentFailure { throw fail(failure) }
            catch { throw Task.isCancelled ? CancellationError() : fail(.network) }
            // A request of the host's own. Yardlet answers none: it says so, and the read ends.
            if let method = message["method"]?.stringValue, let id = message["id"], id != .null {
                try? await send(.object(["id": id, "error": .object([
                    "code": .integer(-32601), "message": .string("Yardlet does not support " + method)
                ])]), on: socket)
                throw fail(method == "attestation/generate" ? .verificationUnsupported : .remoteFile)
            }
            if message["method"] != nil { continue }
            let id = message["id"]?.stringValue
            // An error for a request not Yardlet's is not this read's; one for another step, out of turn, is
            // no answer; one for this step or for no request ends the read here.
            if let error = message["error"], error != .null {
                if let id, !ids.values.contains(id) { continue }
                if let id, id != ids[stage] { throw fail(.invalidResponse) }
                if case let .integer(code)? = error["code"] { throw fail(.remoteFile, code: code) }
                throw fail(.remoteFile)
            }
            guard let id, ids.values.contains(id) else { continue }
            guard id == ids[stage] else { throw fail(.invalidResponse) }
            switch stage {
            case .initialize:
                guard case .object? = message["result"] else { throw fail(.invalidResponse) }
                stage = .metadata
                do { try await send(.object(["id": .string(metadataID), "method": .string("fs/getMetadata"), "params": file]), on: socket) }
                catch { throw fail(.network) }
            case .metadata:
                guard let result = message["result"], case .object = result else { throw fail(.invalidResponse) }
                // A directory or anything else that is not a file is not read.
                guard result["isFile"] == .bool(true) else { throw fail(.remoteFile) }
                stage = .contents
                do { try await send(.object(["id": .string(readID), "method": .string("fs/readFile"), "params": file]), on: socket) }
                catch { throw fail(.network) }
            case .contents:
                do { return try bytes(message["result"]) }
                catch let failure as PersonalAgentFailure { throw fail(failure) }
            }
        }
    }

    /// The bytes of a read's result: Base64 of at most `maximumBytes`, refused whole if larger or
    /// not Base64. An empty file is empty, not missing.
    static func bytes(_ result: JSONValue?) throws -> Data {
        guard let encoded = result?["dataBase64"]?.stringValue else { throw PersonalAgentFailure.invalidResponse }
        guard encoded.utf8.count <= (maximumBytes + 2) / 3 * 4 else { throw PersonalAgentFailure.fileTooLarge }
        guard let data = Data(base64Encoded: encoded) else { throw PersonalAgentFailure.invalidResponse }
        guard data.count <= maximumBytes else { throw PersonalAgentFailure.fileTooLarge }
        return data
    }

    private static func send(_ value: JSONValue, on socket: any DotsEventSocket) async throws {
        let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        do { try await socket.send(.string(text)) } catch { throw PersonalAgentFailure.network }
    }

    private static func receive(_ socket: any DotsEventSocket) async throws -> JSONValue {
        let data: Data
        switch try await socket.receive() {
        case let .data(value): data = value
        case let .string(value): data = Data(value.utf8)
        @unknown default: throw PersonalAgentFailure.invalidResponse
        }
        guard data.count <= maximumMessageBytes, let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object = value else { throw PersonalAgentFailure.invalidResponse }
        return value
    }
}
