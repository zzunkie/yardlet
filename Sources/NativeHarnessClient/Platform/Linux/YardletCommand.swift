import Dispatch
import Foundation
import Glibc
import YardletRemote

/// `yardlet`, the Linux host's command (docs/LINUX_HOST.md). `yardlet host start` runs the host in the foreground;
/// the other commands reach the running host over its control socket.
@main
enum YardletCommand {
    static let usage = """
    usage: yardlet host start [--name NAME] [--every-address]
                                          Run the host in the foreground until it is stopped. It takes
                                          connections on loopback, private and Tailscale addresses, and
                                          on public ones too with --every-address.
           yardlet host status [--json]       Show the running host: its paths, devices and harnesses.
           yardlet host pair [--no-wait]      Show a link and a QR code that pair a device with this host.
           yardlet host project add FOLDER    Make FOLDER a project that devices can start tasks in.
           yardlet host project list          List the projects.
           yardlet host service install [--name NAME] [--every-address]
                                              Run the host as a systemd user service, now and at every boot.
           yardlet host service uninstall     Stop and remove the service, and list what stays.
           yardlet host update                Install the latest release's host, as installing did.
           yardlet host login [HARNESS]       Sign in to a harness (claude, codex, …) from this terminal, or
                                              list the harnesses and their logins.
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
            guard let start = StartOptions(options) else {
                return refuse("usage: yardlet host start [--name NAME] [--every-address]")
            }
            LinuxHost.run(name: start.name, reach: start.reach)
        case "status":
            return status(json: options == ["--json"])
        case "pair":
            return pair(waits: !options.contains("--no-wait"), json: options.contains("--json"))
        case "project":
            return project(options)
        case "service":
            switch options.first {
            case "install":
                let rest = Array(options.dropFirst())
                guard StartOptions(rest) != nil else {
                    return refuse("usage: yardlet host service install [--name NAME] [--every-address]")
                }
                return LinuxHostService.install(options: rest)
            case "uninstall" where options.count == 1:
                return LinuxHostService.uninstall()
            default:
                return refuse("usage: yardlet host service install [--name NAME] [--every-address] | yardlet host service uninstall")
            }
        case "update" where options.isEmpty:
            return LinuxHostUpdate.run()
        case "login" where options.count <= 1:
            return login(options.first)
        default:
            return refuse(usage)
        }
    }

    /// What `start` takes: the name devices see, and whether to listen on every address.
    struct StartOptions: Equatable {
        var name: String?
        var reach: RemoteLinuxListener.Reach = .privateNetworks

        init?(_ arguments: [String]) {
            var rest = arguments[...]
            while let option = rest.popFirst() {
                switch option {
                case "--name":
                    guard let value = rest.popFirst(), !value.isEmpty else { return nil }
                    name = value
                case "--every-address":
                    reach = .everyAddress
                default:
                    return nil
                }
            }
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
        if remote.keysUnread {
            lines.append(remote.keys == "keyring"
                ? "Keys: in the keyring, which cannot be read yet; the host serves once it is unlocked"
                : "Keys: not read yet")
        }
        switch remote.direct {
        case "ready":
            let addresses = remote.addresses.isEmpty ? "no Tailscale or private address yet" : remote.addresses.joined(separator: ", ")
            let scope = remote.listensOn == "all" ? "every address" : "loopback, private and Tailscale addresses"
            lines.append("Direct: listening on port \(remote.port.map(String.init) ?? "?") of \(scope); devices are told \(addresses)")
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
                print("Scan the code with the Yardlet app, or open the link on the device:\n")
                // A terminal shows the code; output to a file or a pipe gets the link alone.
                if isatty(STDOUT_FILENO) == 1, let code = TerminalQRCode.render(link) { print(code + "\n") }
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

    // MARK: - login

    private static func login(_ name: String?) -> Int32 {
        guard let name else {
            do {
                guard let status = try HostControlClient.send(HostControlRequest(command: .status)).status else { return 1 }
                let found = status.harnesses.filter { $0.runtime != nil }
                if found.isEmpty { print("No harness is installed on the PATH the host found.") }
                for harness in found {
                    let command = LinuxHostSignIn.harness(named: harness.id)?.executableName ?? harness.id
                    print("\(command)\t\(harness.name)\t\(harness.account ?? "unknown")")
                }
                return 0
            } catch {
                return fail(error)
            }
        }
        let started: HostSignIn
        do {
            guard let signIn = try HostControlClient.send(HostControlRequest(command: .login, harness: name),
                                                          timeout: 60).signIn else { return 1 }
            started = signIn
        } catch {
            return fail(error)
        }
        if let address = started.address, let code = started.code {
            print("Open \(address) on any device, sign in, and enter this code:\n\n    \(code)\n")
            print("Waiting for the sign-in… (Control-C stops)")
            fflush(nil)
            LinuxSignals.handle([SIGINT], on: .global()) { _ in
                _ = try? HostControlClient.send(HostControlRequest(command: .cancelLogin, harness: name))
                exit(130)
            }
            let deadline = Date().addingTimeInterval(20 * 60)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 2)
                guard let state = try? HostControlClient.send(HostControlRequest(command: .loginState, harness: name)).signIn
                else { continue }
                switch state.state {
                case .signedIn?:
                    print("Signed in.")
                    return 0
                case .failed?:
                    HostOutput.error("The sign-in did not finish\(state.reason.map { ": \($0)" } ?? ".")")
                    return 1
                default:
                    continue
                }
            }
            HostOutput.error("The sign-in did not finish in 20 minutes.")
            return 1
        }
        guard let command = started.command, let executable = command.first else { return 1 }
        if let message = started.message, !message.isEmpty { print(message) }
        // The harness's own sign-in, in this terminal: it prints where to sign in and reads what it needs here.
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = Array(command.dropFirst())
        process.environment = ProcessInfo.processInfo.environment.merging(started.environment ?? [:]) { $1 }
        do { try process.run() } catch {
            HostOutput.error("\(executable) could not start: \(error)")
            return 1
        }
        // Foundation starts the command in a process group of its own, which the terminal would stop for reading it
        // (SIGTTIN): it is made the terminal's foreground group, so Control-C reaches it, and continued if it stopped
        // first, until it ends. Taking the terminal back from the background then needs SIGTTOU blocked, which is
        // done only after the command has ended, so it inherits nothing of it.
        let terminal = isatty(STDIN_FILENO) == 1
        if terminal {
            _ = tcsetpgrp(STDIN_FILENO, process.processIdentifier)
            _ = kill(-process.processIdentifier, SIGCONT)
        }
        process.waitUntilExit()
        if terminal {
            var blocked = sigset_t()
            var previous = sigset_t()
            sigemptyset(&blocked)
            sigaddset(&blocked, SIGTTOU)
            _ = pthread_sigmask(SIG_BLOCK, &blocked, &previous)
            _ = tcsetpgrp(STDIN_FILENO, getpgrp())
            _ = pthread_sigmask(SIG_SETMASK, &previous, nil)
        }
        let state = (try? HostControlClient.send(HostControlRequest(command: .checkAccount, harness: name), timeout: 60))?
            .signIn?.state
        if state == .signedIn {
            print("Signed in.")
            return 0
        }
        HostOutput.error("The harness's login still reads signed out.")
        return process.terminationStatus == 0 ? 1 : process.terminationStatus
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
