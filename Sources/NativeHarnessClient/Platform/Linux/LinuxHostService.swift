import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Glibc

/// `yardlet host service install` and `uninstall` (docs/LINUX_HOST.md, "Keeping it running"): the host as a systemd
/// user service, `yardlet-host.service` in `~/.config/systemd/user/`, which starts it now and at every boot. Linger keeps
/// the person's systemd running while they are logged out, so the service also runs after they log out and before
/// they log in; `install` turns it on when it is off and writes that it did in the unit (`X-YardletEnabledLinger`, a key
/// systemd ignores), and `uninstall` turns it off only then. `uninstall` removes the unit and lists what stays.
enum LinuxHostService {
    static let unitName = "yardlet-host.service"
    /// The unit's own record that Yardlet turned linger on.
    static let lingerKey = "X-YardletEnabledLinger"

    static func unitFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let config = environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? URL(filePath: $0, directoryHint: .isDirectory) : nil }
            ?? LinuxHostPaths.home(environment: environment).appending(path: ".config", directoryHint: .isDirectory)
        return config.appending(path: "systemd/user", directoryHint: .isDirectory).appending(path: unitName)
    }

    /// The unit for a host started as `yardlet host start` with `options`, from `executable`.
    static func unit(executable: String, options: [String], enabledLinger: Bool) -> String {
        let command = ([executable, "host", "start"] + options).map(quoted).joined(separator: " ")
        return """
        [Unit]
        Description=Yardlet host
        Documentation=https://github.com/zzunkie/yardlet/blob/main/docs/LINUX_HOST.md
        After=network-online.target
        Wants=network-online.target
        \(enabledLinger ? "\(lingerKey)=yes\n" : "")
        [Service]
        Type=simple
        ExecStart=\(command)
        Restart=on-failure
        RestartSec=5
        # The harnesses the host started, and what they started, end with it.
        KillMode=control-group
        TimeoutStopSec=30

        [Install]
        WantedBy=default.target

        """
    }

    /// A word of ExecStart, quoted as systemd reads it when it holds a space, a quote or a backslash.
    static func quoted(_ word: String) -> String {
        guard word.contains(where: { " \t\"'\\".contains($0) }) else { return word }
        return "\"" + word.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func install(options: [String]) -> Int32 {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path(percentEncoded: false) else {
            HostOutput.error("The host's own program could not be found.")
            return 1
        }
        guard systemctl(["show-environment"], quiet: true) == 0 else {
            HostOutput.error("""
            systemd's user manager does not answer from this shell, so the service cannot be installed. Log in to \
            this computer with a session of your own (SSH does), or run `sudo loginctl enable-linger \(userName)` and \
            log in again.
            """)
            return 1
        }
        if let pid = HostLock.runningProcessID(), !serviceIsActive() {
            HostOutput.error("A Yardlet host already runs (process \(pid)). Stop it first: the service would start a second one.")
            return 1
        }
        // A unit installed before keeps its record of who turned linger on.
        let previous = (try? String(contentsOf: unitFile(), encoding: .utf8)) ?? ""
        var enabledLinger = previous.contains("\(lingerKey)=yes")
        var lingerNote: String?
        switch linger() {
        case false?:
            if loginctl(["enable-linger"]) == 0 {
                enabledLinger = true
                lingerNote = "Turned on linger, so the host runs while you are logged out."
            } else {
                lingerNote = "Linger is off, so the host stops when you log out. Run `sudo loginctl enable-linger \(userName)` to keep it running."
            }
        case nil:
            lingerNote = "Whether linger is on could not be read; without it the host stops when you log out."
        case true?:
            break
        }
        let file = unitFile()
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try unit(executable: executable, options: options, enabledLinger: enabledLinger)
                .write(to: file, atomically: true, encoding: .utf8)
        } catch {
            HostOutput.error("\(file.path(percentEncoded: false)) could not be written: \(error)")
            return 1
        }
        guard systemctl(["daemon-reload"]) == 0, systemctl(["enable", unitName]) == 0,
              systemctl(["restart", unitName]) == 0 else {
            HostOutput.error("systemd did not start the service; `systemctl --user status \(unitName)` says why.")
            return 1
        }
        HostOutput.line("Installed \(file.path(percentEncoded: false)); the host runs now and at every boot.")
        if let lingerNote { HostOutput.line(lingerNote) }
        HostOutput.line("Its output is in `journalctl --user -u \(unitName)`. Pair a device with `yardlet host pair`.")
        return 0
    }

    static func uninstall() -> Int32 {
        let file = unitFile()
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else {
            HostOutput.error("No service is installed (\(file.path(percentEncoded: false)) is not there).")
            return 1
        }
        _ = systemctl(["disable", "--now", unitName])
        do { try FileManager.default.removeItem(at: file) } catch {
            HostOutput.error("\(file.path(percentEncoded: false)) could not be removed: \(error)")
            return 1
        }
        _ = systemctl(["daemon-reload"])
        HostOutput.line("Stopped and removed the service.")
        if text.contains("\(lingerKey)=yes") {
            if loginctl(["disable-linger"]) == 0 {
                HostOutput.line("Turned linger off again, as Yardlet had turned it on.")
            } else {
                HostOutput.line("Linger, which Yardlet had turned on, could not be turned off: run `loginctl disable-linger`.")
            }
        }
        HostOutput.line(whatStays())
        return 0
    }

    /// What `uninstall` leaves, for the person to keep or remove.
    static func whatStays() -> String {
        let home = LinuxHostPaths.home().path(percentEncoded: false)
        func short(_ path: String) -> String {
            path.hasPrefix(home) ? "~" + path.dropFirst(home.hasSuffix("/") ? home.count - 1 : home.count) : path
        }
        var lines = ["These stay until you remove them:",
                     "  \(short(LinuxHostPaths.dataRootLocation().path(percentEncoded: false)))  the tasks, transcripts, projects, and the remote's keys and paired devices"]
        if let program = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() {
            lines.append("  \(short(program.path(percentEncoded: false)))  the program, with `~/.local/bin/yardlet` when install.sh put it there")
        }
        let config = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? LinuxHostPaths.home().appending(path: ".config").path(percentEncoded: false)
        lines.append("  \(short(config + "/yardlet.plist"))  the preferences")
        lines.append("  each harness's own sign-in and history (~/.claude, ~/.codex and the like), which belong to the harness")
        return lines.joined(separator: "\n")
    }

    static func serviceIsActive() -> Bool {
        systemctl(["is-active", "--quiet", unitName], quiet: true) == 0
    }

    /// Whether linger is on for this account, nil when loginctl cannot say.
    static func linger() -> Bool? {
        let (code, output) = run("/usr/bin/env", ["loginctl", "show-user", userName, "--property=Linger", "--value"])
        guard code == 0 else { return nil }
        switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "yes": return true
        case "no": return false
        default: return nil
        }
    }

    static var userName: String {
        if let entry = getpwuid(getuid()), let name = entry.pointee.pw_name { return String(cString: name) }
        return ProcessInfo.processInfo.environment["USER"] ?? "\(getuid())"
    }

    @discardableResult
    static func systemctl(_ arguments: [String], quiet: Bool = false) -> Int32 {
        let (code, output) = run("/usr/bin/env", ["systemctl", "--user"] + arguments)
        if code != 0, !quiet, !output.isEmpty { HostOutput.error(output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return code
    }

    static func loginctl(_ arguments: [String]) -> Int32 {
        run("/usr/bin/env", ["loginctl"] + arguments).code
    }

    /// Runs a system command to its end and returns its exit code with what it wrote, both streams together.
    static func run(_ executable: String, _ arguments: [String]) -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (127, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// `yardlet host update` (docs/LINUX_HOST.md, "Updating"): runs the installer of the latest release, as installing did,
/// which replaces the program when the release's package differs from the one installed and restarts the service when
/// it runs. The installer and the package come from GitHub Releases over HTTPS, the package checked against the
/// SHA-256 the release lists beside it; `YARDLET_HOST_DOWNLOAD` names another place, for a check of the update.
enum LinuxHostUpdate {
    static let defaultDownload = "https://github.com/zzunkie/yardlet/releases/latest/download"
    static let installerName = "yardlet-host-install.sh"

    static func run() -> Int32 {
        let base = ProcessInfo.processInfo.environment["YARDLET_HOST_DOWNLOAD"] ?? defaultDownload
        guard let url = URL(string: base + "/" + installerName) else { return 1 }
        let folder = FileManager.default.temporaryDirectory.appending(path: "yardlet-update-\(UUID().uuidString)",
                                                                      directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appending(path: installerName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try download(url).write(to: script)
        } catch {
            HostOutput.error("The installer could not be downloaded from \(url.absoluteString): \(error)")
            return 1
        }
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [script.path(percentEncoded: false)]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["YARDLET_HOST_DOWNLOAD": base, "YARDLET_HOST_UPDATING": LinuxHostVersion.current]) { $1 }
        do { try process.run() } catch {
            HostOutput.error("The installer could not run: \(error)")
            return 1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// The body of a GET, refused unless it is a 200.
    static func download(_ url: URL) throws -> Data {
        if url.isFileURL { return try Data(contentsOf: url) }
        final class Outcome: @unchecked Sendable {
            let done = DispatchSemaphore(value: 0)
            var result: Result<Data, any Error> = .failure(URLError(.unknown))
        }
        let outcome = Outcome()
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            if let error {
                outcome.result = .failure(error)
            } else if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                outcome.result = .failure(URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"]))
            } else {
                outcome.result = .success(data ?? Data())
            }
            outcome.done.signal()
        }
        task.resume()
        outcome.done.wait()
        return try outcome.result.get()
    }
}
