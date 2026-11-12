import Foundation
import WinSDK

/// Installing and updating the Windows app with Velopack (docs/PLATFORM_PORTABILITY.md, "Installing and updating
/// the Windows app"). What `Windows/scripts/pack.ps1` packs carries Velopack's library beside the executable and the
/// feed its updates come from in `YardletUpdateFeed`; a build run from its build folder, or a folder gathered without
/// them, has no updater, as a Mac build without a feed URL has none.
///
/// As Sparkle does on the Mac: an installed app looks for an update when it opens and once a day after, downloads
/// what it finds in the background, and puts it in place once the app quits. A downloaded update the app did not
/// get to put in place, because it ended some other way, goes in the next time it opens.
@MainActor
final class WindowsUpdater {
    /// Sparkle's default interval between checks.
    static let checkInterval: Duration = .seconds(24 * 60 * 60)
    /// The file beside the executable that names the feed: a GitHub repository whose releases carry the Windows
    /// packages, or a Velopack feed's address or folder.
    nonisolated static let feedFileName = "YardletUpdateFeed"

    private let manager: VelopackManager
    private let log: @MainActor (String) -> Void
    private var checks: Task<Void, Never>?

    /// Nil unless this is an installed app whose packaging named a feed.
    static func installed(log: @escaping @MainActor (String) -> Void) -> WindowsUpdater? {
        guard let library = VelopackLibrary.shared,
              let feed = feed(besides: Bundle.main.executableURL),
              let manager = VelopackManager(library: library, feed: feed) else { return nil }
        return WindowsUpdater(manager: manager, log: log)
    }

    private init(manager: VelopackManager, log: @escaping @MainActor (String) -> Void) {
        self.manager = manager
        self.log = log
    }

    /// Checks now and once a day, until an update has downloaded.
    func start() {
        guard checks == nil else { return }
        log("update: current \(manager.currentVersion)")
        let manager = manager
        checks = Task { [weak self] in
            while !Task.isCancelled {
                let outcome = await Task.detached { manager.checkAndDownload() }.value
                guard let self else { return }
                self.log("update: \(outcome.note)")
                if case .downloaded = outcome { return }
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    /// Hands a downloaded update to Velopack's updater, which waits for this process to end and then puts it in
    /// place without showing anything and without opening the app again. Called as the app quits.
    func applyOnExit() {
        checks?.cancel()
        guard let version = manager.applyPendingAfterExit() else { return }
        log("update: applying \(version) once Yardlet quits")
    }

    /// The first line of `YardletUpdateFeed` beside `executable`.
    nonisolated static func feed(besides executable: URL?) -> String? {
        guard let folder = executable?.deletingLastPathComponent(),
              let text = try? String(contentsOf: folder.appending(path: feedFileName), encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces),
              !line.isEmpty else { return nil }
        return line
    }
}

/// Velopack's start, before the Windows App Runtime starts (`XamlApplication.willStart()`). An installer's hook
/// (installed, updated, about to be removed) is answered and the process exits at once, as Velopack's Setup and
/// Update.exe wait for it to; a downloaded update not yet in place goes in, and the app opens again in it; and an
/// installed app takes its shortcut's AppUserModelID, so the taskbar and notifications know it as that shortcut.
/// Nothing happens without Velopack's library beside the executable.
enum VelopackStart {
    static func run() {
        VelopackLibrary.shared?.appRun(nil)
    }
}

/// The update manager of Velopack's C library, made for this app's feed. Its calls block, so checks and downloads
/// run off the main actor; the library takes a lock of its own around a download.
final class VelopackManager: @unchecked Sendable {
    enum Outcome {
        case none
        case downloaded(String)
        case failed(String)

        var note: String {
            switch self {
            case .none: "none"
            case let .downloaded(version): "downloaded \(version)"
            case let .failed(reason): "failed: \(reason)"
            }
        }
    }

    private let library: VelopackLibrary
    private let pointer: UnsafeMutableRawPointer

    /// A GitHub repository's address reads its releases; any other address or a folder is read as a Velopack feed.
    /// Nil when this app was not installed by Velopack, which the library reports by failing.
    init?(library: VelopackLibrary, feed: String) {
        var manager: UnsafeMutableRawPointer?
        let made: Bool
        if Self.isGitHubRepository(feed) {
            guard let source = feed.withCString({ library.newSourceGitHub($0, nil, false) }) else { return nil }
            made = library.newUpdateManagerWithSource(source, nil, nil, &manager)
            library.freeSource(source)
        } else {
            made = feed.withCString { library.newUpdateManager($0, nil, nil, &manager) }
        }
        guard made, let manager else { return nil }
        self.library = library
        pointer = manager
    }

    deinit {
        library.freeUpdateManager(pointer)
    }

    var currentVersion: String {
        library.string { library.getCurrentVersion(pointer, $0, $1) }
    }

    func checkAndDownload() -> Outcome {
        var info: UnsafeMutableRawPointer?
        switch library.checkForUpdates(pointer, &info) {
        case VelopackLibrary.updateAvailable:
            guard let info else { return .failed("no update information") }
            defer { library.freeUpdateInfo(info) }
            // vpkc_update_info_t begins with TargetFullRelease.
            let version = Self.version(of: info.load(as: UnsafeMutableRawPointer?.self))
            guard library.downloadUpdates(pointer, info, nil, nil) else { return .failed(library.lastError) }
            return .downloaded(version)
        case VelopackLibrary.updateError:
            return .failed(library.lastError)
        default:
            return .none
        }
    }

    /// The version handed to the updater, or nil when nothing has downloaded.
    func applyPendingAfterExit() -> String? {
        var asset: UnsafeMutableRawPointer?
        guard library.updatePendingRestart(pointer, &asset), let asset else { return nil }
        defer { library.freeAsset(asset) }
        guard library.waitExitThenApplyUpdates(pointer, asset, true, false, nil, 0) else { return nil }
        return Self.version(of: asset)
    }

    /// vpkc_asset_t's Version, the field after PackageId.
    private static func version(of asset: UnsafeMutableRawPointer?) -> String {
        guard let asset,
              let field = asset.load(fromByteOffset: MemoryLayout<UnsafeRawPointer>.stride,
                                     as: UnsafePointer<CChar>?.self) else { return "?" }
        return String(cString: field)
    }

    static func isGitHubRepository(_ feed: String) -> Bool {
        guard let url = URL(string: feed), url.scheme == "https", url.host() == "github.com" else { return false }
        return url.pathComponents.filter { $0 != "/" }.count == 2
    }
}

/// Velopack's C library (`velopack_libc`, docs/PLATFORM_PORTABILITY.md, "External dependencies"), loaded from beside
/// the executable when packaging put it there. Its functions are looked up by name, so a build without it runs as
/// before and links nothing of it. The types follow the library's `Velopack.h` at the version `pack.ps1` pins.
final class VelopackLibrary: @unchecked Sendable {
    static let fileName = "velopack_libc_win_x64_msvc.dll"
    static let updateError: Int8 = -1
    static let updateAvailable: Int8 = 0

    typealias Pointer = UnsafeMutableRawPointer
    typealias OutPointer = UnsafeMutablePointer<Pointer?>
    typealias Free = @convention(c) (Pointer?) -> Void
    typealias NewSourceGitHub = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Bool) -> Pointer?
    typealias NewUpdateManager = @convention(c) (UnsafePointer<CChar>?, Pointer?, Pointer?, OutPointer?) -> Bool
    typealias NewUpdateManagerWithSource = @convention(c) (Pointer?, Pointer?, Pointer?, OutPointer?) -> Bool
    typealias ManagerString = @convention(c) (Pointer?, UnsafeMutablePointer<CChar>?, Int) -> Int
    typealias CheckForUpdates = @convention(c) (Pointer?, OutPointer?) -> Int8
    /// The manager, the update, and a progress callback with its data, which Yardlet does not pass.
    typealias DownloadUpdates = @convention(c) (Pointer?, Pointer?, Pointer?, Pointer?) -> Bool
    typealias PendingRestart = @convention(c) (Pointer?, OutPointer?) -> Bool
    /// The manager, the asset, silent, restart, and the arguments for the app it opens again.
    typealias WaitExitThenApply = @convention(c) (Pointer?, Pointer?, Bool, Bool,
                                                  UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, Int) -> Bool
    typealias LastError = @convention(c) (UnsafeMutablePointer<CChar>?, Int) -> Int

    let appRun: Free
    let newSourceGitHub: NewSourceGitHub
    let freeSource: Free
    let newUpdateManager: NewUpdateManager
    let newUpdateManagerWithSource: NewUpdateManagerWithSource
    let freeUpdateManager: Free
    let getCurrentVersion: ManagerString
    let checkForUpdates: CheckForUpdates
    let downloadUpdates: DownloadUpdates
    let updatePendingRestart: PendingRestart
    let waitExitThenApplyUpdates: WaitExitThenApply
    let freeUpdateInfo: Free
    let freeAsset: Free
    let getLastError: LastError

    /// Loaded once, looked for only in the executable's folder, with its own dependencies from System32, so no
    /// other folder's copy is taken.
    static let shared: VelopackLibrary? = {
        let places = DWORD(LOAD_LIBRARY_SEARCH_APPLICATION_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32)
        let module = fileName.withCString(encodedAs: UTF16.self) { LoadLibraryExW($0, nil, places) }
        return module.flatMap { VelopackLibrary($0) }
    }()

    private init?(_ module: HMODULE) {
        func load<F>(_ name: String, as _: F.Type) -> F? {
            GetProcAddress(module, name).map { unsafeBitCast($0, to: F.self) }
        }
        guard let appRun = load("vpkc_app_run", as: Free.self),
              let newSourceGitHub = load("vpkc_new_source_github", as: NewSourceGitHub.self),
              let freeSource = load("vpkc_free_source", as: Free.self),
              let newUpdateManager = load("vpkc_new_update_manager", as: NewUpdateManager.self),
              let newUpdateManagerWithSource = load("vpkc_new_update_manager_with_source",
                                                    as: NewUpdateManagerWithSource.self),
              let freeUpdateManager = load("vpkc_free_update_manager", as: Free.self),
              let getCurrentVersion = load("vpkc_get_current_version", as: ManagerString.self),
              let checkForUpdates = load("vpkc_check_for_updates", as: CheckForUpdates.self),
              let downloadUpdates = load("vpkc_download_updates", as: DownloadUpdates.self),
              let updatePendingRestart = load("vpkc_update_pending_restart", as: PendingRestart.self),
              let waitExitThenApplyUpdates = load("vpkc_wait_exit_then_apply_updates", as: WaitExitThenApply.self),
              let freeUpdateInfo = load("vpkc_free_update_info", as: Free.self),
              let freeAsset = load("vpkc_free_asset", as: Free.self),
              let getLastError = load("vpkc_get_last_error", as: LastError.self)
        else { return nil }
        self.appRun = appRun
        self.newSourceGitHub = newSourceGitHub
        self.freeSource = freeSource
        self.newUpdateManager = newUpdateManager
        self.newUpdateManagerWithSource = newUpdateManagerWithSource
        self.freeUpdateManager = freeUpdateManager
        self.getCurrentVersion = getCurrentVersion
        self.checkForUpdates = checkForUpdates
        self.downloadUpdates = downloadUpdates
        self.updatePendingRestart = updatePendingRestart
        self.waitExitThenApplyUpdates = waitExitThenApplyUpdates
        self.freeUpdateInfo = freeUpdateInfo
        self.freeAsset = freeAsset
        self.getLastError = getLastError
    }

    /// The library's last error, for the QA log.
    var lastError: String {
        string { getLastError($0, $1) }
    }

    /// A string the library copies into a buffer. Asked with no buffer, it answers with the string's length; given
    /// one, it copies up to the size passed and ends it with a zero after that, so the buffer has a byte more.
    func string(_ copy: (UnsafeMutablePointer<CChar>?, Int) -> Int) -> String {
        let length = copy(nil, 0)
        guard length > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: length + 2)
        _ = buffer.withUnsafeMutableBufferPointer { copy($0.baseAddress, length + 1) }
        return String(cString: buffer)
    }
}
