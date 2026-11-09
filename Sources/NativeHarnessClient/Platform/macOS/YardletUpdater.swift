import CryptoKit
import Darwin
import Foundation

/// Installs a Yardlet build staged by `scripts/stage-update.sh`. A running app cannot replace its
/// own bundle, so a small installer script waits for Yardlet to quit, swaps the bundles (keeping the
/// previous one for rollback), and opens the new one. Tasks, drafts and history live outside the
/// bundle and are not touched.
enum YardletUpdater {
    struct Candidate: Equatable, Sendable {
        let bundleURL: URL
        let commit: String?
        let hasUncommittedChanges: Bool
        let builtAt: Date?
        let executableDigest: String

        /// The build as Install Update… names it: the commit, and "with uncommitted changes" when it was
        /// built from a changed tree; nil when the manifest names neither.
        var build: String? {
            let words = [commit, hasUncommittedChanges ? L10n.string("with uncommitted changes") : nil].compactMap { $0 }
            return words.isEmpty ? nil : words.joined(separator: " ")
        }
    }

    enum Problem: LocalizedError, Equatable {
        case nothingStaged, otherApp, alreadyInstalled, unverifiedSignature, otherSigner, linked

        var errorDescription: String? {
            switch self {
            case .nothingStaged: L10n.string("Build a release bundle and stage it with scripts/stage-update.sh, then choose Install Update… again.")
            case .otherApp: L10n.string("The staged build is not a Yardlet build.")
            case .alreadyInstalled: L10n.string("The staged build is already installed.")
            case .unverifiedSignature: L10n.string("The staged build's signature could not be verified.")
            case .otherSigner: L10n.string("The staged build is not signed by the developer who signed the installed Yardlet.")
            case .linked: L10n.string("The staged build is a link to another folder, so Yardlet does not install it.")
            }
        }
    }

    static var rootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Yardlet/Updates", directoryHint: .isDirectory)
    }

    /// The staged build, if it belongs to this app and differs from the installed one. `digests` reads
    /// each executable's digest; a caller that looks again and again keeps one `ExecutableDigests`.
    static func pending(root: URL = rootURL, bundleIdentifier: String?, installedBundle: URL,
                        digests: ExecutableDigests = ExecutableDigests()) throws -> Candidate {
        let folder = root.appending(path: "Pending", directoryHint: .isDirectory)
        let bundle = folder.appending(path: "Yardlet.app", directoryHint: .isDirectory)
        // Moved into place, a link would leave the installed app in a folder anything can change. Read without a
        // trailing slash, which would follow the link.
        if (try? FileManager.default.destinationOfSymbolicLink(
            atPath: folder.appending(path: "Yardlet.app").path(percentEncoded: false))) != nil {
            throw Problem.linked
        }
        guard let info = NSDictionary(contentsOf: bundle.appending(path: "Contents/Info.plist")) as? [String: Any]
        else { throw Problem.nothingStaged }
        guard let identifier = info["CFBundleIdentifier"] as? String, identifier == bundleIdentifier,
              let digest = digests.digest(of: bundle) else { throw Problem.otherApp }
        guard digest != digests.digest(of: installedBundle) else { throw Problem.alreadyInstalled }
        let manifest = (try? Data(contentsOf: folder.appending(path: "manifest.json")))
            .flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        return Candidate(bundleURL: bundle, commit: manifest?["commit"]?.stringValue,
            hasUncommittedChanges: manifest?["dirty"]?.boolValue == true,
            builtAt: manifest?["builtAt"]?.stringValue.flatMap { ISO8601DateFormatter().date(from: $0) },
            executableDigest: digest)
    }

    /// The staged build's signature must verify, and when the installed app is signed by a team
    /// (Developer ID) the staged build must also satisfy the installed app's designated requirement:
    /// the same identifier from the same team, as Sparkle requires of an update. The keychain items,
    /// permissions and browser cookie key that trust the installed app then trust the update too,
    /// and an ad-hoc or someone else's build cannot replace it. An ad-hoc installed app has no
    /// team, so any verified Yardlet build replaces it, and Install Update… says it cannot tell who
    /// made the build (`makerIsUnknown`).
    static func verifySignature(of bundle: URL, replacing installed: URL? = nil) throws {
        let path = bundle.path(percentEncoded: false)
        guard try codesign(["--verify", "--strict", "--deep", path]).status == 0 else { throw Problem.unverifiedSignature }
        guard let installed, let requirement = try signerRequirement(of: installed) else { return }
        try verify(bundle, satisfies: requirement)
    }

    static func verify(_ bundle: URL, satisfies requirement: String) throws {
        guard try codesign(["--verify", "--strict", "-R", "=" + requirement, bundle.path(percentEncoded: false)]).status == 0
        else { throw Problem.otherSigner }
    }

    /// Whether nothing ties a staged build to the installed app's maker: no team signed it (ad-hoc).
    static func makerIsUnknown(installed: URL) -> Bool {
        ((try? signerRequirement(of: installed)) ?? nil) == nil
    }

    /// The installed app's designated requirement, or nil when no team signed it (ad-hoc).
    static func signerRequirement(of installed: URL) throws -> String? {
        let path = installed.path(percentEncoded: false)
        let details = try codesign(["-dv", path], reading: .error).text
        guard let team = details.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") })?
                .dropFirst("TeamIdentifier=".count), !team.isEmpty, team != "not set" else { return nil }
        let requirement = try codesign(["-d", "-r-", path], reading: .output).text
            .split(separator: "\n").first(where: { $0.hasPrefix("designated => ") })?
            .dropFirst("designated => ".count)
        return requirement.map(String.init)
    }

    private enum Stream { case none, output, error }

    /// Runs codesign and reads at most one of its streams (`-d` writes details to standard error and
    /// the requirement to standard output); the other goes nowhere, so neither pipe can fill up.
    private static func codesign(_ arguments: [String], reading stream: Stream = .none) throws -> (status: Int32, text: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/codesign")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = stream == .output ? pipe : FileHandle.nullDevice
        process.standardError = stream == .error ? pipe : FileHandle.nullDevice
        let exit = try ProcessExit(running: process)
        let data = stream == .none ? Data() : pipe.fileHandleForReading.readDataToEndOfFile()
        // Verifying a whole bundle takes seconds; one that has not ended in minutes counts as failed.
        guard exit.waitBlockingThread(timeout: .seconds(300)) else {
            NativeProcessTree.terminate(process: process)
            return (-1, String(decoding: data, as: UTF8.self))
        }
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Starts the installer, which acts only after `processID` has exited. It runs in its own session
    /// with no inherited descriptors, so ending the app's process group cannot stop it. If the app
    /// never quits, the installer gives up after two minutes without changing anything.
    @discardableResult
    static func launchInstaller(target: URL, processID: Int32, root: URL = rootURL, relaunch: Bool = true) throws -> pid_t {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appending(path: "installer.sh")
        try Data(installerScript.utf8).write(to: script, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path(percentEncoded: false))
        let arguments = ["/bin/sh", script.path(percentEncoded: false), String(processID),
                         target.path(percentEncoded: false), root.path(percentEncoded: false), relaunch ? "1" : "0"]
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        posix_spawnattr_init(&attributes)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawnattr_destroy(&attributes); posix_spawn_file_actions_destroy(&actions) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        let argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, environ)
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO) }
        return pid
    }

    /// SHA-256 of each bundle's executable, read again only when the file changes (another file
    /// number, size or modification date). The staged build is moved into place whole, so a new one
    /// is a new file; looking at an unchanged one reads its Info.plist and the file's attributes.
    final class ExecutableDigests: @unchecked Sendable {
        private struct Stamp: Equatable {
            let device: Int
            let file: Int
            let size: Int
            let modified: Date
        }

        private let lock = NSLock()
        private var known: [String: (stamp: Stamp, digest: String)] = [:]

        func digest(of bundle: URL) -> String? {
            guard let info = NSDictionary(contentsOf: bundle.appending(path: "Contents/Info.plist")) as? [String: Any],
                  let name = info["CFBundleExecutable"] as? String, !name.contains("/") else { return nil }
            let executable = bundle.appending(path: "Contents/MacOS/\(name)")
            let path = executable.path(percentEncoded: false)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let device = attributes[.systemNumber] as? Int, let file = attributes[.systemFileNumber] as? Int,
                  let size = attributes[.size] as? Int, let modified = attributes[.modificationDate] as? Date
            else { return nil }
            let stamp = Stamp(device: device, file: file, size: size, modified: modified)
            if let entry = lock.withLock({ known[path] }), entry.stamp == stamp { return entry.digest }
            guard let data = try? Data(contentsOf: executable, options: .mappedIfSafe) else { return nil }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            lock.withLock { known[path] = (stamp, digest) }
            return digest
        }
    }

    static let installerScript = #"""
    #!/bin/sh
    # Waits for Yardlet to quit, swaps in the staged build, keeps the previous one, and reopens.
    pid=$1 target=$2 root=$3 relaunch=$4
    pending="$root/Pending/Yardlet.app"
    previous="$root/Previous/Yardlet.app"
    log="$root/install.log"
    say() { printf '%s %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$log"; }
    reopen() { if [ "$relaunch" = 1 ]; then /usr/bin/open "$target"; fi; }
    n=0
    while /bin/kill -0 "$pid" 2>/dev/null; do
      n=$((n + 1))
      if [ "$n" -gt 600 ]; then say "Yardlet did not quit; nothing changed"; exit 1; fi
      /bin/sleep 0.2
    done
    # Moved into place, a link or a file linked from elsewhere would stay changeable from outside the app.
    if [ -L "$pending" ] || [ -n "$(/usr/bin/find "$pending" -type f -links +1 -print -quit 2>/dev/null)" ]; then
      say "The staged build is or holds a link to another place; nothing changed"; reopen; exit 1
    fi
    if ! /usr/bin/codesign --verify --strict --deep "$pending" 2>>"$log"; then
      say "The staged build's signature could not be verified; nothing changed"; reopen; exit 1
    fi
    # A team-signed (Developer ID) app is replaced only by a build that meets its designated requirement.
    team=$(/usr/bin/codesign -dv "$target" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')
    if [ -n "$team" ] && [ "$team" != "not set" ]; then
      requirement=$(/usr/bin/codesign -d -r- "$target" 2>/dev/null | /usr/bin/sed -n 's/^designated => //p')
      if [ -z "$requirement" ] || ! /usr/bin/codesign --verify --strict -R "=$requirement" "$pending" 2>>"$log"; then
        say "The staged build is not signed by the installed app's developer ($team); nothing changed"; reopen; exit 1
      fi
    fi
    /bin/mkdir -p "$root/Previous"
    /bin/rm -rf "$previous.old"
    if [ -e "$previous" ]; then /bin/mv "$previous" "$previous.old"; fi
    if ! /bin/mv "$target" "$previous"; then
      if [ -e "$previous.old" ]; then /bin/mv "$previous.old" "$previous"; fi
      say "The installed app could not be moved; nothing changed"; reopen; exit 1
    fi
    if /bin/mv "$pending" "$target"; then
      /bin/rm -rf "$previous.old"
      if [ -e "$root/Pending/manifest.json" ]; then /bin/mv "$root/Pending/manifest.json" "$root/installed.json"; fi
      say "Installed the staged build; the previous app is in $previous"
    else
      /bin/mv "$previous" "$target"
      if [ -e "$previous.old" ]; then /bin/mv "$previous.old" "$previous"; fi
      say "The staged build could not be moved into place; the previous app was restored"
    fi
    reopen
    """#
}
