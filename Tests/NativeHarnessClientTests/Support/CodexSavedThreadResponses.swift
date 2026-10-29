import Foundation
@testable import NativeHarnessClient

/// What a real App Server (codex-cli 0.157.1) answers for a saved thread a detached task reads:
/// `thread/read` without its turns (`includeTurns: false` gives `turns: []` and the rollout `path`),
/// and `thread/turns/list` pages asked newest first (`data` newest first, `nextCursor` for the turns
/// before the page, `backwardsCursor` for the ones after it).
enum CodexSavedThreadResponses {
    /// The `thread/read` result for `thread` without its turns.
    static func metadata(_ thread: JSONValue) -> JSONValue {
        guard case var .object(fields) = thread else { return .object(["thread": thread]) }
        fields["turns"] = .array([])
        return .object(["thread": .object(fields)])
    }

    /// The `thread/turns/list` result for `thread`'s turns before `cursor` ("before-<index>", nil for
    /// the newest), `limit` of them, newest first.
    static func page(_ thread: JSONValue, before cursor: String? = nil, limit: Int = 5) -> JSONValue {
        let turns = thread["turns"]?.arrayValue ?? []
        let end = cursor.flatMap { Int($0.dropFirst("before-".count)) } ?? turns.count
        let start = max(0, end - limit)
        return .object([
            "data": .array(Array(turns[start..<end].reversed())),
            "nextCursor": start > 0 ? .string("before-\(start)") : .null,
            "backwardsCursor": .string("after-\(end)")
        ])
    }
}

/// An App Server holding saved threads, which answers each read by the thread and cursor it names, as
/// a real one does: tasks may read their threads in any order, and the same page again.
actor CodexSavedThreadsTransport: CodexTransport {
    private let threads: [String: JSONValue]
    private let stream: AsyncStream<CodexRawFrame>
    private let continuation: AsyncStream<CodexRawFrame>.Continuation

    init(threads: [String: JSONValue]) {
        self.threads = threads
        (stream, continuation) = AsyncStream<CodexRawFrame>.makeStream()
    }

    func start() async throws {}

    func request(_ request: CodexRPCRequest) async throws -> CodexRPCIncomingMessage {
        let thread = request.params["threadId"]?.stringValue.flatMap { threads[$0] }
        let result: JSONValue
        switch (request.method, thread) {
        case ("initialize", _):
            result = .object(["platformOs": .string("macos")])
        case let ("thread/read", thread?):
            result = CodexSavedThreadResponses.metadata(thread)
        case let ("thread/turns/list", thread?):
            let limit = request.params["limit"]?.integerValue.map(Int.init) ?? 5
            result = CodexSavedThreadResponses.page(thread, before: request.params["cursor"]?.stringValue, limit: limit)
        default:
            throw HarnessAdapterError.invalidProviderEvent("No saved thread answers \(request.method)")
        }
        return CodexRPCIncomingMessage(id: request.id, method: nil, params: nil, result: result, error: nil,
                                       emittedAtMs: nil)
    }

    func sendResponse(_ response: CodexRPCResponse) async throws {}
    func sendErrorResponse(_ response: CodexRPCErrorResponse) async throws {}
    func notifications() async -> AsyncStream<CodexRawFrame> { stream }
    func stop() async { continuation.finish() }
}
