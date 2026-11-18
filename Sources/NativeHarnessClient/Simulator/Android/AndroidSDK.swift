import Foundation

/// An Android SDK with the two programs the simulator panel runs: adb and the emulator. Yardlet ships no SDK; it
/// uses the one the person has, as Android Studio installs it.
struct AndroidSDK: Equatable, Sendable {
    var root: URL

    var adb: URL { root.appending(path: "platform-tools/\(Self.program("adb"))") }
    var emulator: URL { root.appending(path: "emulator/\(Self.program("emulator"))") }
    var toolchain: SimulatorToolchain { SimulatorToolchain(directory: root.nativePath) }

    init(root: URL) { self.root = root }

    /// The SDK a check found, from its toolchain.
    init(toolchain: SimulatorToolchain) {
        root = URL(filePath: toolchain.directory, directoryHint: .isDirectory)
    }

    static func program(_ name: String) -> String {
        #if os(Windows)
        "\(name).exe"
        #else
        name
        #endif
    }
}

/// Where the SDK is: `ANDROID_HOME`, `ANDROID_SDK_ROOT`, the folder whose `platform-tools` or `emulator` the
/// person's login shell puts on its `PATH` (an app opened from the Dock gets no shell variables, and Yardlet reads
/// only the login shell's `PATH`, `LoginShellPath`), then where Android Studio installs it on this platform.
enum AndroidSDKLocator {
    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                       loginShellPath: String? = LoginShellPath.value,
                       home: URL = FileManager.default.homeDirectoryForCurrentUser,
                       isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.nativePath) })
        -> AndroidSDK? {
        candidates(environment: environment, loginShellPath: loginShellPath, home: home)
            .map(AndroidSDK.init(root:))
            .first { isExecutable($0.adb) && isExecutable($0.emulator) }
    }

    static func candidates(environment: [String: String], loginShellPath: String?, home: URL) -> [URL] {
        var found: [URL] = []
        func add(_ path: String?) {
            guard let path, !path.isEmpty else { return }
            let url = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
            if !found.contains(url) { found.append(url) }
        }
        add(environment["ANDROID_HOME"])
        add(environment["ANDROID_SDK_ROOT"])
        for folder in (loginShellPath ?? "").split(separator: pathSeparator).map(String.init) {
            let url = URL(filePath: folder, directoryHint: .isDirectory).standardizedFileURL
            if ["platform-tools", "emulator"].contains(url.lastPathComponent) {
                add(url.deletingLastPathComponent().nativePath)
            }
        }
        #if os(Windows)
        add(environment["LOCALAPPDATA"].map { URL(filePath: $0, directoryHint: .isDirectory).appending(path: "Android/Sdk").nativePath })
        #elseif os(macOS)
        add(home.appending(path: "Library/Android/sdk").nativePath)
        #else
        add(home.appending(path: "Android/Sdk").nativePath)
        #endif
        return found
    }

    /// Where the emulator keeps the AVDs: `ANDROID_AVD_HOME`, else `avd` in `ANDROID_USER_HOME` or
    /// `ANDROID_EMULATOR_HOME`, else `~/.android/avd`.
    static func avdHome(environment: [String: String] = ProcessInfo.processInfo.environment,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let folder = environment["ANDROID_AVD_HOME"], !folder.isEmpty {
            return URL(filePath: folder, directoryHint: .isDirectory)
        }
        for name in ["ANDROID_USER_HOME", "ANDROID_EMULATOR_HOME"] {
            if let folder = environment[name], !folder.isEmpty {
                return URL(filePath: folder, directoryHint: .isDirectory).appending(path: "avd", directoryHint: .isDirectory)
            }
        }
        return home.appending(path: ".android/avd", directoryHint: .isDirectory)
    }

    private static var pathSeparator: Character {
        #if os(Windows)
        ";"
        #else
        ":"
        #endif
    }
}
