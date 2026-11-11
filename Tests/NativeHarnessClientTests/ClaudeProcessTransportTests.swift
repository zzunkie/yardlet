import XCTest
@testable import NativeHarnessClient

final class ClaudeProcessTransportTests: XCTestCase {
    /// What the CLI writes just before it exits still reaches the task: the answer to the request
    /// that was waiting, every frame after it, and only then the end of the stream. A CLI that ends
    /// a turn and exits writes its result this way.
    func testWhatTheCLIWritesJustBeforeItExitsIsDelivered() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "yardlet-claude-exit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "fake-claude")
        let frames = 2_000
        let script = """
        #!/bin/sh
        IFS= read -r request
        printf '%s\\n' '{"type":"control_response","response":{"subtype":"success","request_id":"initialize-1","response":{"ready":true}}}'
        i=0
        while [ $i -lt \(frames) ]; do
          printf '%s\\n' '{"type":"assistant","index":'$i'}'
          i=$((i + 1))
        done
        printf '%s\\n' '{"type":"result","subtype":"success"}'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let transport = ClaudeProcessTransport(executableURL: executable, requestTimeout: .seconds(20))
        try await transport.start(ClaudeLaunchConfiguration(providerSessionID: "session-1", workspaceURL: root,
                                                            resumesExistingSession: false))
        let messages = await transport.messages()
        let received = Task {
            var values: [JSONValue] = []
            for await frame in messages { values.append(frame.value) }
            return values
        }
        let response = try await transport.request(ClaudeProtocol.initialize(id: "initialize-1"), id: "initialize-1")
        XCTAssertEqual(response["ready"], .bool(true))

        let values = await received.value
        XCTAssertEqual(values.count, frames + 1)
        XCTAssertEqual(values.last?["type"], .string("result"))
        XCTAssertEqual(values.compactMap { $0["index"]?.integerValue }, (0..<frames).map(Int64.init))
        await transport.stop()
    }
}
