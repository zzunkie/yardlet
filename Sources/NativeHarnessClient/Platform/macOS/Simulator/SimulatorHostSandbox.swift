import Darwin
import Foundation

/// The sandbox the simulator host runs in. The helper drives Xcode's private frameworks with gestures that can come
/// from a model, so it gets no more than that takes: it reads only its own bundle, the Xcode it was given,
/// CoreSimulator and the simulator runtimes and device types; it writes only Metal's shader cache; it reaches only
/// Yardlet's surface port beyond the services Apple's base profile lets every process reach; and it has no network.
/// Nothing in the person's home folder is readable but file metadata, and the helper takes typed commands only.
///
/// `sandbox-exec` applies the profile as it starts the helper, in the same process, so the helper stays responsible
/// for itself (`DisclaimedSpawn`). Without `sandbox-exec` the helper does not start.
enum SimulatorHostSandbox {
    static let launcher = URL(filePath: "/usr/bin/sandbox-exec")

    /// Seatbelt rules (SBPL). The parameters are canonical paths and the surface port's bootstrap name.
    static let profile = """
    (version 1)
    (deny default)
    ; dyld, the system's frameworks and the services every process reaches (Apple's base profile), and the GPU.
    (import "system.sb")
    (system-graphics)
    (allow file-read-metadata)
    (allow process-info* (target self))
    (allow signal (target self))
    (allow sysctl-read)
    (allow user-preference-read)
    (allow process-exec (literal (param "EXECUTABLE")))
    (allow file-read*
        (subpath (param "HELPER"))
        (subpath (param "XCODE"))
        (subpath "/Library/Developer/PrivateFrameworks")
        (subpath "/Library/Developer/CoreSimulator/Profiles")
        (subpath "/private/var/run/com.apple.security.cryptexd/mnt"))
    (allow file-read* file-write* (subpath (param "METAL_CACHE")))
    (allow mach-lookup (global-name (param "SURFACE_PORT")))
    (deny network*)
    """

    /// What to start: `sandbox-exec` with the profile, then the helper's executable and its arguments.
    static func launch(executable: URL, arguments: [String], developerDirectory: URL,
                       surfacePort: String) throws -> (executable: URL, arguments: [String]) {
        guard FileManager.default.isExecutableFile(atPath: launcher.path(percentEncoded: false)) else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "this macOS has no sandbox-exec"])
        }
        let helper = canonical(executable.path(percentEncoded: false))
        // The helper's app bundle, or the executable alone outside one.
        let bundle = helper.range(of: ".app/", options: .backwards).map { String(helper[..<$0.lowerBound]) + ".app" } ?? helper
        // The Xcode bundle around Contents/Developer.
        let xcode = canonical(developerDirectory.deletingLastPathComponent().deletingLastPathComponent().path(percentEncoded: false))
        var cache = [CChar](repeating: 0, count: Int(PATH_MAX))
        let cacheLength = confstr(_CS_DARWIN_USER_CACHE_DIR, &cache, cache.count)
        let cacheDirectory = cacheLength > 1
            ? String(decoding: cache.prefix(cacheLength - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : NSTemporaryDirectory()
        let parameters = [
            "EXECUTABLE": helper,
            "HELPER": bundle,
            "XCODE": xcode,
            "METAL_CACHE": canonical(cacheDirectory) + "/com.apple.metal",
            "SURFACE_PORT": surfacePort
        ]
        let defines = parameters.sorted { $0.key < $1.key }.flatMap { ["-D", "\($0.key)=\($0.value)"] }
        return (launcher, ["-p", profile] + defines + [helper] + arguments)
    }

    /// The path with its links resolved as the kernel sees it (`/private/var/…` for `/var/…`), which is what the
    /// sandbox matches; Foundation's resolution would drop `/private`.
    private static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private typealias Check = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32) -> Int32
    private static let check: Check? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_check")
        .map { unsafeBitCast($0, to: Check.self) }

    /// Whether the process runs in a sandbox, for QA (libsystem_sandbox's `sandbox_check` with no operation).
    static func isSandboxed(_ process: pid_t) -> Bool? {
        check.map { $0(process, nil, 0) == 1 }
    }
}
