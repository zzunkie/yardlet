import Dispatch
import Foundation
import Glibc

/// `yardlet`, the Linux host's command (docs/LINUX_HOST.md). `yardlet host start` runs the host in the foreground;
/// the other commands reach the running host over its control socket.
@main
enum YardletCommand {
    static let usage = """
    usage: yardlet host start [--name NAME]   Run the host in the foreground until it is stopped.
           yardlet host status [--json]       Show the running host: its paths, devices and harnesses.
           yardlet host pair [--no-wait]      Show a link and a QR code that pair a device with this host.
           yardlet host project add FOLDER    Make FOLDER a project that devices can start tasks in.
           yardlet host project list          List the projects.
           yardlet --version
    """

    @MainActor
    static func main() {
        exit(run(Array(CommandLine.arguments.dropFirst())))
    }

    @MainActor
    static func run(_ arguments: [String]) -> Int32 {
        switch arguments.first {
        case "--version", "version":
            print("yardlet \(LinuxHostVersion.current)")
            return 0
        case "--help", "-h", "help", nil:
            print(usage)
            return arguments.isEmpty ? 2 : 0
        case "host":
            return host(Array(arguments.dropFirst()))
        default:
            return refuse("unknown command: \(arguments[0])")
        }
    }

    @MainActor
    private static func host(_ arguments: [String]) -> Int32 {
        let options = Array(arguments.dropFirst())
        switch arguments.first {
        case "start":
            guard options.isEmpty || (options.count == 2 && options[0] == "--name" && !options[1].isEmpty) else {
                return refuse("usage: yardlet host start [--name NAME]")
            }
            LinuxHost.run(name: options.count == 2 ? options[1] : nil)
        case "status":
            return status(json: options == ["--json"])
        case "pair":
            return pair(waits: !options.contains("--no-wait"), json: options.contains("--json"))
        case "project":
            return project(options)
        default:
            return refuse(usage)
        }
    }

    private static func refuse(_ message: String) -> Int32 {
        HostOutput.error(message)
        return 2
    }

    private static func fail(_ error: any Error) -> Int32 {
        HostOutput.error("\(error)")
        if case HostControlClient.Failure.notRunning = error { return 3 }
        return 1
    }

    // MARK: - status

    private static func status(json: Bool) -> Int32 {
        let reply: HostControlReply
        do {
            reply = try HostControlClient.send(HostControlRequest(command: .status))
        } catch {
            if case HostControlClient.Failure.notRunning = error, let pid = HostLock.runningProcessID() {
                HostOutput.error("A Yardlet host runs (process \(pid)) but does not answer on its control socket.")
                return 1
            }
            return fail(error)
        }
        guard let status = reply.status else { return 1 }
        if json {
            print(String(decoding: (try? JSONEncoder.hostControl.encode(status)) ?? Data(), as: UTF8.self))
            return 0
        }
        print(describe(status))
        return 0
    }

    static func describe(_ status: HostStatus) -> String {
        var lines = ["Yardlet host \(status.version), running as \(status.name) (process \(status.processID))",
                     "Data: \(status.dataFolder)"]
        let remote = status.remote
        switch remote.direct {
        case "ready":
            let addresses = remote.addresses.isEmpty ? "no Tailscale or private address yet" : remote.addresses.joined(separator: ", ")
            lines.append("Direct: listening on port \(remote.port.map(String.init) ?? "?"): \(addresses)")
        case "failed": lines.append("Direct: failed: \(remote.directFailure ?? "unknown")")
        default: lines.append("Direct: \(remote.direct)")
        }
        if let relay = remote.relay {
            lines.append("Relay: \(relay)" + (remote.relayFailure.map { ": \($0)" } ?? ""))
        } else {
            lines.append("Relay: none configured")
        }
        lines.append("Paired devices: \(status.devices.count)")
        for device in status.devices {
            let state = device.connected ? "connected" + (device.path.map { " through \($0)" } ?? "") : "not connected"
            lines.append("  \(device.name)\(device.platform.map { " (\($0))" } ?? ""): \(state)")
        }
        let found = status.harnesses.filter { $0.runtime != nil }
        lines.append("Harnesses: \(found.isEmpty ? "none found on the PATH" : "")")
        for harness in found { lines.append("  \(harness.name): \(harness.runtime ?? "")") }
        lines.append("Projects: \(status.projects.count)")
        for project in status.projects { lines.append("  \(project.name): \(project.folder)") }
        lines.append("Tasks: \(status.tasks), \(status.runningTasks) running")
        return lines.joined(separator: "\n")
    }

    // MARK: - pair

    @MainActor
    private static func pair(waits: Bool, json: Bool) -> Int32 {
        let pairing: HostStatus.Pairing
        do {
            guard let opened = try HostControlClient.send(HostControlRequest(command: .pair)).pairing,
                  let link = opened.link else { return 1 }
            pairing = opened
            if json {
                print(String(decoding: (try? JSONEncoder.hostControl.encode(opened)) ?? Data(), as: UTF8.self))
            } else {
                print("Open this link on the device, or scan the code with the Yardlet app:\n")
                print(link)
                if let expiresAt = opened.expiresAt {
                    print("\nThe link works once, until \(expiresAt.formatted(date: .omitted, time: .shortened)).")
                }
            }
        } catch {
            return fail(error)
        }
        guard waits else { return 0 }
        // Control-C stops waiting and closes the pairing.
        LinuxSignals.handle([SIGINT], on: .global()) { _ in
            _ = try? HostControlClient.send(HostControlRequest(command: .cancelPairing))
            exit(130)
        }
        if !json { print("Waiting for the device… (Control-C stops)") }
        fflush(nil)
        let deadline = (pairing.expiresAt ?? Date().addingTimeInterval(300)).addingTimeInterval(5)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
            guard let status = try? HostControlClient.send(HostControlRequest(command: .status)).status else { continue }
            guard status.pairing?.link == nil else { continue }
            if let device = status.pairing?.pairedDevice {
                print(json ? #"{"paired":"\#(device)"}"# : "Paired with \(device).")
                return 0
            }
            break
        }
        HostOutput.error("The pairing ended without a device.")
        return 1
    }

    // MARK: - project

    private static func project(_ arguments: [String]) -> Int32 {
        let request: HostControlRequest
        switch arguments.first {
        case "add" where arguments.count == 2:
            let path = URL(filePath: arguments[1], directoryHint: .isDirectory,
                           relativeTo: URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory))
            request = HostControlRequest(command: .addProject, path: path.standardizedFileURL.path(percentEncoded: false))
        case "list" where arguments.count == 1:
            request = HostControlRequest(command: .projects)
        default:
            return refuse("usage: yardlet host project add FOLDER | yardlet host project list")
        }
        do {
            let projects = try HostControlClient.send(request).projects ?? []
            if projects.isEmpty { print("No projects. Add one with `yardlet host project add FOLDER`.") }
            for project in projects { print("\(project.name)\t\(project.folder)") }
            return 0
        } catch {
            return fail(error)
        }
    }
}
