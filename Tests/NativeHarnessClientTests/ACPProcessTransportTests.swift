import XCTest
@testable import NativeHarnessClient

final class ACPProcessTransportTests: XCTestCase {
    /// What an agent writes just before it exits still reaches the task: the answer to the request
    /// that was waiting and every update after it, then the end of the stream. After that a send
    /// fails with the agent's exit status and its last words.
    func testWhatTheAgentWritesJustBeforeItExitsIsDelivered() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "yardlet-acp-exit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "fake-agent")
        let updates = 2_000
        let script = """
        #!/bin/sh
        IFS= read -r request
        printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"ready":true}}'
        i=0
        while [ $i -lt \(updates) ]; do
          printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"index":'$i'}}'
          i=$((i + 1))
        done
        printf '%s\\n' 'agent: out of credit' >&2
        exit 5
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let transport = ACPProcessTransport(executableURL: executable, requestTimeout: .seconds(20))
        try await transport.start(ACPLaunchConfiguration(arguments: [], workspaceURL: root))
        let messages = await transport.messages()
        let received = Task {
            var values: [JSONValue] = []
            for await frame in messages { values.append(frame.value) }
            return values
        }
        let result = try await transport.request(
            .object(["jsonrpc": .string("2.0"), "id": .integer(1), "method": .string("initialize")]), id: 1)
        XCTAssertEqual(result["ready"], .bool(true))

        let values = await received.value
        XCTAssertEqual(values.compactMap { $0["params"]?["index"]?.integerValue }, (0..<updates).map(Int64.init))
        do {
            try await transport.send(.object(["jsonrpc": .string("2.0"), "method": .string("session/cancel")]))
            XCTFail("A send to an agent that exited must fail")
        } catch {
            XCTAssertEqual(error as? HarnessAdapterError, .processExited(code: 5, message: "agent: out of credit"))
        }
        await transport.stop()
    }
}
