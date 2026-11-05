import Foundation
import YardletRemote

/// `--pair LINK --task TITLE --send TEXT`: the fixture as a phone rather than a host, on the engine's client
/// connection. It pairs with the host the link names, connects as a phone does (directly or through the relay,
/// §11.4), lists the host's tasks, opens the one titled TITLE, sends TEXT to it and waits for the answer, printing
/// each step. The answer is the one that names TEXT, as the Windows app's stand-in harness words its answers. It
/// exits 0 once that answer has come in, and 1 when anything fails or `timeout` passes first. The Windows app's
/// host check uses it (Windows/scripts/check-remote-host.ps1).
enum FixturePhone {
    static func run(link text: String, task title: String, message: String, timeout: TimeInterval = 180) async -> Int32 {
        guard let url = URL(string: text), let link = RemoteSecurePairingURL.parse(url) else {
            print("Phone: not a pairing link")
            return 1
        }
        let key = RemoteKeyPair.generate()
        let hello = RemoteHandshakeHello(name: "Fixture phone", platform: "android", appVersion: "fixture")
        do {
            _ = try await RemoteHostConnection.pair(link, clientKey: key, hello: hello)
        } catch {
            print("Phone: pairing failed: \(error)")
            return 1
        }
        print("Phone: paired with \(link.name)")
        let connection = RemoteHostConnection(
            target: RemoteHostTarget(hostKey: link.macKey, direct: link.hosts, relayURL: link.relayURL, room: link.room),
            clientKey: key, hello: hello)
        await connection.start()
        let deadline = Task {
            guard (try? await Task.sleep(for: .seconds(timeout))) != nil else { return }
            print("Phone: no answer in \(Int(timeout)) s")
            await connection.stop()
        }
        defer { deadline.cancel() }
        var taskID: String?
        for await inbound in connection.inbound {
            switch inbound {
            case let .state(.connected(path, _)):
                print("Phone: connected through \(path)")
                _ = await connection.send(id: "snapshot", .snapshot)
            case let .state(.waiting(_, reason)):
                print("Phone: reconnecting: \(reason)")
            case .state(.revoked), .state(.stopped):
                print("Phone: the connection ended")
                return 1
            case let .response(response) where response.re == "snapshot":
                let tasks = response.tasks ?? []
                print("Phone: tasks: \(tasks.count)")
                guard taskID == nil else { continue }
                guard let task = tasks.first(where: { $0.title == title }) else {
                    print("Phone: no task named \(title)")
                    await connection.stop()
                    return 1
                }
                taskID = task.id
                _ = await connection.send(id: "subscribe", .subscribeTask(taskID: task.id))
                _ = await connection.send(id: "send", .sendMessage(taskID: task.id, text: message))
            case let .response(response) where response.re == "send":
                print("Phone: sent: \(response.ok ? "ok" : response.error?.message ?? "refused")")
            case let .event(event):
                // The answer names the message it answers, closing the quote after it; the message itself does not.
                guard taskID != nil, RemoteJSON.string(event).contains("\(message)\u{201D}") else { continue }
                print("Phone: answered")
                await connection.stop()
                return 0
            default:
                continue
            }
        }
        return 1
    }
}
