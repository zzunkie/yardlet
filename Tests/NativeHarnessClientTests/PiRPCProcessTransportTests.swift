import XCTest
@testable import NativeHarnessClient

final class PiRPCProcessTransportTests: XCTestCase {
    /// What an agent writes just before it exits still reaches the task: the answer to the request
    /// that was waiting and every event after it, then the end of the stream. After that a send
    /// fails with the agent's exit status and its last words.
    func testWhatTheAgentWritesJustBeforeItExitsIsDelivered() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "yardlet-pi-exit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "fake-agent")
        let events = 2_000
        let script = """
        #!/bin/sh
        IFS= read -r request
        printf '%s\\r\\n' '{"type":"response","id":"request-1","success":true,"data":{"ready":true}}'
        i=0
        while [ $i -lt \(events) ]; do
          printf '%s\\n' '{"type":"message_update","index":'$i'}'
          i=$((i + 1))
        done
        printf '%s\\n' 'agent: no model configured' >&2
        exit 6
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let transport = PiRPCProcessTransport(executableURL: executable, requestTimeout: .seconds(20))
        try await transport.start(PiRPCLaunchConfiguration(arguments: [], workspaceURL: root))
        let messages = await transport.messages()
        let received = Task {
            var values: [JSONValue] = []
            for await frame in messages { values.append(frame.value) }
            return values
        }
        let response = try await transport.request(
            .object(["type": .string("get_state"), "id": .string("request-1")]), id: "request-1")
        XCTAssertEqual(response["data"]?["ready"], .bool(true))

        let values = await received.value
        XCTAssertEqual(values.compactMap { $0["index"]?.integerValue }, (0..<events).map(Int64.init))
        do {
            try await transport.send(.object(["type": .string("abort")]))
            XCTFail("A send to an agent that exited must fail")
        } catch {
            XCTAssertEqual(error as? HarnessAdapterError,
                           .processExited(code: 6, message: "agent: no model configured"))
        }
        await transport.stop()
    }
}
