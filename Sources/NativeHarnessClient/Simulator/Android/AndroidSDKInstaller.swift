import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Gets an Android SDK for the simulator panel without Java: Google's package lists (the repository and its Google
/// Play system images) name each package's archive, size, SHA-1 and license. Yardlet downloads the missing ones,
/// checks each against its SHA-1, unpacks it where sdkmanager would (each archive holds one folder with its
/// `source.properties`, which Android Studio and sdkmanager read), writes the license's acceptance as sdkmanager does
/// (the SHA-1 of its text in `licenses/<id>`), and makes one AVD as Android Studio's files describe it. What is
/// already in the SDK folder stays: the folder is the one Android Studio or the environment names, else Android
/// Studio's own place, made then. Removing a package removes only the folder at the revision Yardlet unpacked.
struct AndroidSDKInstaller: SimulatorInstaller {
    static let repositoryURL = URL(string: "https://dl.google.com/android/repository/repository2-3.xml")!
    static let systemImagesURL = URL(string: "https://dl.google.com/android/repository/sys-img/google_apis_playstore/sys-img2-3.xml")!
    static let avdName = "Yardlet_Phone"

    var environment: [String: String] = ProcessInfo.processInfo.environment
    var loginShellPath: @Sendable () -> String? = { LoginShellPath.value }
    var home = FileManager.default.homeDirectoryForCurrentUser
    var host = AndroidSDKHost.current
    var fetch: @Sendable (URL) async throws -> Data = AndroidSDKDownload.data
    /// Downloads into a file, reporting the bytes written so far, and returns the file's SHA-1.
    var download: @Sendable (URL, URL, @escaping @Sendable (Int64) -> Void) async throws -> String = AndroidSDKDownload.file
    var extract: @Sendable (URL, URL) async throws -> Void = AndroidSDKDownload.extract

    var platform: SimulatorPlatform { .android }

    func offer(for check: SimulatorPlatformCheck) async throws -> SimulatorInstallOffer? {
        guard check.availability == .sdkMissing else { return nil }
        let plan = try await makePlan()
        guard !plan.isEmpty else { return nil }
        return .download(name: L10n.string("Android SDK and emulator"), bytes: plan.bytes, licenses: plan.licenses)
    }

    func install(_ offer: SimulatorInstallOffer, for check: SimulatorPlatformCheck,
                 progress: @escaping @Sendable (SimulatorInstallProgress) -> Void) async throws -> [SimulatorInstalledItem] {
        guard case let .download(_, _, accepted) = offer else { return [] }
        let plan = try await makePlan()
        // The person accepted the licenses the offer showed; a list that changed since asks again.
        guard Set(plan.licenses.map(\.text)).isSubset(of: Set(accepted.map(\.text))) else {
            throw SimulatorInstallError(message: L10n.string("The license changed since it was shown. Try again."))
        }
        let files = FileManager.default
        var made: [URL] = []
        var items: [SimulatorInstalledItem] = []
        do {
            if plan.createsSDKRoot {
                try files.createDirectory(at: plan.sdkRoot, withIntermediateDirectories: true)
                made.append(plan.sdkRoot)
                items.append(.androidSDKFolder(path: plan.sdkRoot.nativePath))
            }
            let total = max(plan.bytes, 1)
            var done: Int64 = 0
            for package in plan.downloads {
                try Task.checkCancellation()
                let start = done
                progress(SimulatorInstallProgress(stage: .downloading, fraction: Double(start) / Double(total)))
                let staging = plan.sdkRoot.appending(path: ".temp/yardlet-\(UUID().uuidString)", directoryHint: .isDirectory)
                try files.createDirectory(at: staging, withIntermediateDirectories: true)
                defer { try? files.removeItem(at: staging) }
                let archive = staging.appending(path: "package.zip")
                let sha1 = try await download(package.url, archive) { written in
                    progress(SimulatorInstallProgress(stage: .downloading, fraction: Double(start + written) / Double(total)))
                }
                guard sha1.lowercased() == package.sha1.lowercased() else {
                    throw SimulatorInstallError(message: L10n.format("The download of %@ was damaged.", package.name))
                }
                try Task.checkCancellation()
                progress(SimulatorInstallProgress(stage: .installing, fraction: nil))
                let unpacked = staging.appending(path: "unpacked", directoryHint: .isDirectory)
                try files.createDirectory(at: unpacked, withIntermediateDirectories: true)
                try await extract(archive, unpacked)
                let folders = try files.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
                    .filter { !$0.lastPathComponent.hasPrefix(".") && !$0.lastPathComponent.hasPrefix("__MACOSX") }
                guard folders.count == 1, let top = folders.first else {
                    throw SimulatorInstallError(message: L10n.format("The download of %@ was damaged.", package.name))
                }
                let destination = plan.sdkRoot.appending(path: package.folder, directoryHint: .isDirectory)
                guard !files.fileExists(atPath: destination.nativePath) else {
                    throw SimulatorInstallError(message: L10n.format("%@ is already in the SDK folder.", package.name))
                }
                try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try files.moveItem(at: top, to: destination)
                made.append(destination)
                if let license = plan.licenses.first(where: { $0.id == package.license }) {
                    try AndroidSDKLicenses.accept(license, in: plan.sdkRoot)
                }
                items.append(.androidPackage(sdkRoot: plan.sdkRoot.nativePath, path: package.folder, revision: package.revision,
                                             name: package.name, bytes: package.size))
                done += package.size
            }
            try? files.removeItem(at: plan.sdkRoot.appending(path: ".temp"))
            if let avd = plan.avd {
                let home = AndroidSDKLocator.avdHome(environment: environment, home: home)
                try AndroidAVDFiles.write(avd, in: home)
                made.append(home.appending(path: "\(avd.name).avd"))
                made.append(home.appending(path: "\(avd.name).ini"))
                items.append(.androidAVD(home: home.nativePath, name: avd.name))
            }
            return items
        } catch {
            // Nothing half made stays behind: what this install made goes, newest first.
            for url in made.reversed() { try? files.removeItem(at: url) }
            throw error
        }
    }

    func isStillInstalled(_ item: SimulatorInstalledItem) async -> Bool {
        let files = FileManager.default
        switch item {
        case let .androidPackage(root, path, revision, _, _):
            let properties = URL(filePath: root, directoryHint: .isDirectory).appending(path: "\(path)/source.properties")
            return AndroidSDKPackages.revision(in: properties) == revision
        case let .androidAVD(home, name):
            return files.fileExists(atPath: URL(filePath: home).appending(path: "\(name).ini").nativePath)
        case let .androidSDKFolder(path):
            return files.fileExists(atPath: path)
        case .iOSRuntime:
            return false
        }
    }

    func remove(_ item: SimulatorInstalledItem) async throws {
        let files = FileManager.default
        switch item {
        case let .androidPackage(root, path, _, _, _):
            let sdk = URL(filePath: root, directoryHint: .isDirectory)
            try files.removeItem(at: sdk.appending(path: path, directoryHint: .isDirectory))
            // `system-images/android-36/google_apis_playstore` goes with its last image.
            var parent = sdk.appending(path: path).deletingLastPathComponent()
            while parent.standardizedFileURL.path.count > sdk.standardizedFileURL.path.count,
                  (try? files.contentsOfDirectory(atPath: parent.nativePath))?.allSatisfy({ $0 == ".DS_Store" }) == true {
                try? files.removeItem(at: parent)
                parent = parent.deletingLastPathComponent()
            }
        case let .androidAVD(home, name):
            let folder = URL(filePath: home, directoryHint: .isDirectory)
            try? files.removeItem(at: folder.appending(path: "\(name).avd", directoryHint: .isDirectory))
            try files.removeItem(at: folder.appending(path: "\(name).ini"))
        case let .androidSDKFolder(path):
            // Only once nothing but the licenses Yardlet accepted is left in it.
            let names = (try? files.contentsOfDirectory(atPath: path)) ?? []
            guard names.allSatisfy({ [".DS_Store", "licenses", ".temp"].contains($0) }) else {
                throw SimulatorInstallError(message: L10n.format("%@ holds other files, so it stays.", path))
            }
            try files.removeItem(atPath: path)
        case .iOSRuntime:
            break
        }
    }

    /// What is missing from the SDK folder and how to get it, from Google's lists.
    func makePlan() async throws -> AndroidSDKInstallPlan {
        let candidates = AndroidSDKLocator.candidates(environment: environment, loginShellPath: loginShellPath(), home: home)
        var isFolder: ObjCBool = false
        let existing = candidates.first {
            FileManager.default.fileExists(atPath: $0.nativePath, isDirectory: &isFolder) && isFolder.boolValue
        }
        guard let root = existing ?? candidates.last else {
            throw SimulatorInstallError(message: L10n.string("There is no folder to put the Android SDK in."))
        }
        async let repository = fetch(Self.repositoryURL)
        async let images = fetch(Self.systemImagesURL)
        let avdHome = AndroidSDKLocator.avdHome(environment: environment, home: home)
        let avds = ((try? FileManager.default.contentsOfDirectory(atPath: avdHome.nativePath)) ?? [])
            .filter { $0.hasSuffix(".ini") }
        return AndroidSDKPlanner.plan(
            sdkRoot: root, createsSDKRoot: existing == nil,
            repository: AndroidSDKCatalog.parse(try await repository, base: Self.repositoryURL),
            systemImages: AndroidSDKCatalog.parse(try await images, base: Self.systemImagesURL),
            host: host, hasAVDs: !avds.isEmpty,
            fileExists: { FileManager.default.fileExists(atPath: $0.nativePath) },
            installedImages: AndroidSDKPackages.installedImages(in: root, abi: host.abi))
    }
}

/// The host as Google's lists name it.
struct AndroidSDKHost: Equatable, Sendable {
    var os: String
    var arch: String
    var abi: String

    static var current: AndroidSDKHost {
        #if os(macOS)
        let os = "macosx"
        #elseif os(Windows)
        let os = "windows"
        #else
        let os = "linux"
        #endif
        #if arch(arm64)
        return AndroidSDKHost(os: os, arch: "aarch64", abi: "arm64-v8a")
        #else
        return AndroidSDKHost(os: os, arch: "x64", abi: "x86_64")
        #endif
    }
}

/// What an install gets: the missing packages, the licenses they come under, and the AVD it makes.
struct AndroidSDKInstallPlan: Equatable, Sendable {
    struct Download: Equatable, Sendable {
        /// The SDK path ("system-images;android-36;google_apis_playstore;arm64-v8a"), and the folder it unpacks to.
        var path: String
        var folder: String
        var revision: String
        var name: String
        var license: String?
        var url: URL
        var size: Int64
        var sha1: String
    }

    struct AVD: Equatable, Sendable {
        var name: String
        var displayName: String
        /// The system image's folder in the SDK, `system-images/android-36/google_apis_playstore/arm64-v8a/`.
        var imageFolder: String
        var apiLevel: Int
        var tag: String
        var tagDisplay: String
        var abi: String
    }

    var sdkRoot: URL
    var createsSDKRoot: Bool
    var downloads: [Download]
    var licenses: [SimulatorLicense]
    var avd: AVD?

    var bytes: Int64 { downloads.reduce(0) { $0 + $1.size } }
    var isEmpty: Bool { downloads.isEmpty && avd == nil }
}

enum AndroidSDKPlanner {
    /// The stable packages missing from `sdkRoot`: platform-tools without adb, the emulator without its program, and
    /// with no AVD at all, the newest Google Play system image for the host (unless one is there) and an AVD on it.
    static func plan(sdkRoot: URL, createsSDKRoot: Bool, repository: AndroidSDKCatalog, systemImages: AndroidSDKCatalog,
                     host: AndroidSDKHost, hasAVDs: Bool, fileExists: (URL) -> Bool,
                     installedImages: [AndroidSDKPackages.InstalledImage]) -> AndroidSDKInstallPlan {
        var downloads: [AndroidSDKInstallPlan.Download] = []
        func add(_ package: AndroidSDKCatalog.Package?, archiveFor host: AndroidSDKHost?) {
            guard let package, let archive = package.archives.first(where: {
                ($0.hostOS == nil || $0.hostOS == host?.os) && ($0.hostArch == nil || $0.hostArch == host?.arch)
            }) else { return }
            downloads.append(.init(path: package.path, folder: package.path.replacingOccurrences(of: ";", with: "/"),
                                   revision: package.revision, name: package.displayName, license: package.license,
                                   url: archive.url, size: archive.size, sha1: archive.sha1))
        }
        if !fileExists(sdkRoot.appending(path: "platform-tools/\(AndroidSDK.program("adb"))")) {
            add(repository.newestStable(path: "platform-tools"), archiveFor: host)
        }
        if !fileExists(sdkRoot.appending(path: "emulator/\(AndroidSDK.program("emulator"))")) {
            add(repository.newestStable(path: "emulator"), archiveFor: host)
        }
        var avd: AndroidSDKInstallPlan.AVD?
        if !hasAVDs {
            if let image = installedImages.max(by: { $0.apiLevel < $1.apiLevel }) {
                avd = .init(name: AndroidSDKInstaller.avdName, displayName: "Yardlet Phone (API \(image.apiLevel))",
                            imageFolder: image.folder + "/", apiLevel: image.apiLevel, tag: image.tag,
                            tagDisplay: image.tagDisplay, abi: image.abi)
            } else if let image = systemImages.newestImage(tag: "google_apis_playstore", abi: host.abi) {
                add(image, archiveFor: nil)
                avd = .init(name: AndroidSDKInstaller.avdName, displayName: "Yardlet Phone (API \(image.apiLevel ?? 0))",
                            imageFolder: image.path.replacingOccurrences(of: ";", with: "/") + "/",
                            apiLevel: image.apiLevel ?? 0, tag: image.tag ?? "google_apis_playstore",
                            tagDisplay: image.tagDisplay ?? "Google Play", abi: host.abi)
            }
        }
        var licenses: [SimulatorLicense] = []
        for id in downloads.compactMap(\.license) where !licenses.contains(where: { $0.id == id }) {
            if let text = repository.licenses[id] ?? systemImages.licenses[id] { licenses.append(.init(id: id, text: text)) }
        }
        return AndroidSDKInstallPlan(sdkRoot: sdkRoot, createsSDKRoot: createsSDKRoot, downloads: downloads,
                                     licenses: licenses, avd: avd)
    }
}

/// One of Google's package lists (`repository2-3.xml`, `sys-img2-3.xml`): the packages with their channel, revision,
/// license, details and archives, and the licenses' texts.
struct AndroidSDKCatalog: Equatable, Sendable {
    struct Archive: Equatable, Sendable {
        var hostOS: String?
        var hostArch: String?
        var size: Int64
        var sha1: String
        var url: URL
    }

    struct Package: Equatable, Sendable {
        var path: String
        var revision: String
        var displayName: String
        var license: String?
        var channel: String?
        var apiLevel: Int?
        var tag: String?
        var tagDisplay: String?
        var abi: String?
        var archives: [Archive]
    }

    var packages: [Package] = []
    var licenses: [String: String] = [:]

    /// The newest package at `path` on the stable channel.
    func newestStable(path: String) -> Package? {
        packages.filter { $0.path == path && ($0.channel ?? "channel-0") == "channel-0" }
            .max { AndroidSDKPackages.isOlder($0.revision, than: $1.revision) }
    }

    /// The stable system image with the highest API level for `tag` and `abi`, of a plain `android-<level>`.
    func newestImage(tag: String, abi: String) -> Package? {
        packages.filter {
            let parts = $0.path.split(separator: ";").map(String.init)
            return parts.count == 4 && parts[0] == "system-images" && parts[1] == "android-\($0.apiLevel ?? -1)"
                && parts[2] == tag && parts[3] == abi && ($0.channel ?? "channel-0") == "channel-0"
        }
        .max { ($0.apiLevel ?? 0, $0.revision) < ($1.apiLevel ?? 0, $1.revision) }
    }

    static func parse(_ data: Data, base: URL) -> AndroidSDKCatalog {
        let reader = Reader(base: base)
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.catalog
    }

    private final class Reader: NSObject, XMLParserDelegate {
        let base: URL
        var catalog = AndroidSDKCatalog()
        private var path: [String] = []
        private var text = ""
        private var license: String?
        private var package: Package?
        private var revision: [String: String] = [:]
        private var archive: (os: String?, arch: String?, size: Int64, sha1: String, url: String)?

        init(base: URL) { self.base = base }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            let element = name.split(separator: ":").last.map(String.init) ?? name
            path.append(element)
            text = ""
            switch element {
            case "license" where package == nil:
                license = attributes["id"]
            case "remotePackage":
                package = Package(path: attributes["path"] ?? "", revision: "", displayName: "", archives: [])
                revision = [:]
            case "uses-license":
                package?.license = attributes["ref"]
            case "channelRef":
                package?.channel = attributes["ref"]
            case "archive":
                archive = (nil, nil, 0, "", "")
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let element = path.popLast() ?? name
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let parent = path.last
            switch element {
            case "license" where package == nil:
                // sdkmanager hashes the text as the list holds it, untrimmed.
                if let license { catalog.licenses[license] = text }
                license = nil
            case _ where ["major", "minor", "micro", "preview"].contains(element) && parent == "revision"
                && path.count >= 2 && path[path.count - 2] == "remotePackage":
                revision[element] = value
            case "display-name" where parent == "remotePackage":
                package?.displayName = value
            case "api-level":
                package?.apiLevel = Int(value)
            case "id" where parent == "tag":
                package?.tag = value
            case "display" where parent == "tag":
                package?.tagDisplay = value
            case "abi":
                package?.abi = value
            case "size" where parent == "complete":
                archive?.size = Int64(value) ?? 0
            case "checksum" where parent == "complete":
                archive?.sha1 = value
            case "url" where parent == "complete":
                archive?.url = value
            case "host-os":
                archive?.os = value
            case "host-arch":
                archive?.arch = value
            case "archive":
                if let archive, !archive.url.isEmpty, let url = URL(string: archive.url, relativeTo: base)?.absoluteURL {
                    package?.archives.append(.init(hostOS: archive.os, hostArch: archive.arch, size: archive.size,
                                                   sha1: archive.sha1, url: url))
                }
                archive = nil
            case "remotePackage":
                if var package {
                    package.revision = ["major", "minor", "micro"].compactMap { revision[$0] }.joined(separator: ".")
                    if revision["preview"] == nil { catalog.packages.append(package) }
                }
                package = nil
            default:
                break
            }
            text = ""
        }
    }
}

/// What is unpacked in an SDK folder, read from each package's `source.properties`.
enum AndroidSDKPackages {
    struct InstalledImage: Equatable, Sendable {
        var folder: String
        var apiLevel: Int
        var tag: String
        var tagDisplay: String
        var abi: String
    }

    static func revision(in properties: URL) -> String? {
        values(in: properties)["Pkg.Revision"]
    }

    /// The system images for `abi` in the SDK folder, as `system-images/android-<level>/<tag>/<abi>`.
    static func installedImages(in sdkRoot: URL, abi: String) -> [InstalledImage] {
        let files = FileManager.default
        let images = sdkRoot.appending(path: "system-images", directoryHint: .isDirectory)
        var found: [InstalledImage] = []
        for platform in (try? files.contentsOfDirectory(atPath: images.nativePath)) ?? [] {
            guard platform.hasPrefix("android-"), let level = Int(platform.dropFirst("android-".count)) else { continue }
            for tag in (try? files.contentsOfDirectory(atPath: images.appending(path: platform).nativePath)) ?? [] {
                let folder = "system-images/\(platform)/\(tag)/\(abi)"
                let properties = values(in: sdkRoot.appending(path: "\(folder)/source.properties"))
                guard !properties.isEmpty else { continue }
                found.append(InstalledImage(folder: folder, apiLevel: level, tag: tag,
                                            tagDisplay: properties["SystemImage.TagDisplay"] ?? tag, abi: abi))
            }
        }
        return found
    }

    static func isOlder(_ left: String, than right: String) -> Bool {
        let a = left.split(separator: ".").map { Int($0) ?? 0 }
        let b = right.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x < y }
        }
        return false
    }

    private static func values(in properties: URL) -> [String: String] {
        guard let text = try? String(contentsOf: properties, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            values[line[..<equals].trimmingCharacters(in: .whitespaces)] =
                line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        }
        return values
    }
}

/// A license's acceptance as sdkmanager writes it: the SHA-1 of its text on a line of `licenses/<id>`.
enum AndroidSDKLicenses {
    static func hash(_ license: SimulatorLicense) -> String {
        Insecure.SHA1.hash(data: Data(license.text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func accept(_ license: SimulatorLicense, in sdkRoot: URL) throws {
        let folder = sdkRoot.appending(path: "licenses", directoryHint: .isDirectory)
        let file = folder.appending(path: license.id)
        let hash = hash(license)
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        guard !existing.split(whereSeparator: \.isNewline).contains(where: { $0 == hash }) else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data((existing + "\n" + hash).utf8).write(to: file, options: .atomic)
    }
}

/// An AVD as Android Studio writes it: `<name>.ini` pointing at `<name>.avd`, whose `config.ini` names the system
/// image and a phone-sized screen. The emulator makes the device's data from the image when it first starts.
enum AndroidAVDFiles {
    static func write(_ avd: AndroidSDKInstallPlan.AVD, in home: URL) throws {
        let folder = home.appending(path: "\(avd.name).avd", directoryHint: .isDirectory)
        let files = FileManager.default
        guard !files.fileExists(atPath: folder.nativePath),
              !files.fileExists(atPath: home.appending(path: "\(avd.name).ini").nativePath) else {
            throw SimulatorInstallError(message: L10n.format("An AVD named %@ is already there.", avd.name))
        }
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(ini(avd, folder: folder).utf8).write(to: home.appending(path: "\(avd.name).ini"), options: .atomic)
        try Data(config(avd).utf8).write(to: folder.appending(path: "config.ini"), options: .atomic)
    }

    static func ini(_ avd: AndroidSDKInstallPlan.AVD, folder: URL) -> String {
        """
        avd.ini.encoding=UTF-8
        path=\(folder.nativePath)
        path.rel=avd/\(avd.name).avd
        target=android-\(avd.apiLevel)

        """
    }

    static func config(_ avd: AndroidSDKInstallPlan.AVD) -> String {
        let arch = avd.abi == "arm64-v8a" ? "arm64" : avd.abi == "x86_64" ? "x86_64" : avd.abi
        return [
            "AvdId=\(avd.name)",
            "PlayStore.enabled=\(avd.tag.contains("playstore"))",
            "abi.type=\(avd.abi)",
            "avd.ini.displayname=\(avd.displayName)",
            "avd.ini.encoding=UTF-8",
            "disk.dataPartition.size=6442450944",
            "hw.accelerometer=yes",
            "hw.battery=yes",
            "hw.cpu.arch=\(arch)",
            "hw.cpu.ncore=4",
            "hw.gpu.enabled=yes",
            "hw.gpu.mode=auto",
            "hw.keyboard=yes",
            "hw.lcd.density=420",
            "hw.lcd.height=2400",
            "hw.lcd.width=1080",
            "hw.mainKeys=no",
            "hw.ramSize=2048",
            "image.sysdir.1=\(avd.imageFolder)",
            "showDeviceFrame=no",
            "tag.display=\(avd.tagDisplay)",
            "tag.id=\(avd.tag)",
            "vm.heapSize=256",
        ].joined(separator: "\n") + "\n"
    }
}

/// Google's lists and archives over HTTPS, an archive written to a file as it arrives with its SHA-1 taken on the way,
/// and unpacked with the system's own tool.
final class AndroidSDKDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static func data(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SimulatorInstallError(message: L10n.format("%@ can't be read.", url.absoluteString))
        }
        return data
    }

    static func file(from url: URL, to destination: URL, written: @escaping @Sendable (Int64) -> Void) async throws -> String {
        try await AndroidSDKDownload(destination: destination, written: written).run(url)
    }

    /// Unpacks a zip archive into a folder: `ditto` on macOS, keeping the programs' permissions; `tar` on Windows;
    /// `unzip` elsewhere.
    static func extract(_ archive: URL, into folder: URL) async throws {
        #if os(macOS)
        let command = CLICommand(executable: URL(filePath: "/usr/bin/ditto"),
                                 arguments: ["-x", "-k", archive.nativePath, folder.nativePath], timeout: .seconds(1800))
        #elseif os(Windows)
        let command = CLICommand(executable: URL(filePath: "C:\\Windows\\System32\\tar.exe"),
                                 arguments: ["-xf", archive.nativePath, "-C", folder.nativePath], timeout: .seconds(1800))
        #else
        let command = CLICommand(executable: URL(filePath: "/usr/bin/unzip"),
                                 arguments: ["-q", archive.nativePath, "-d", folder.nativePath], timeout: .seconds(1800))
        #endif
        let result = await CLIProcess.run(command)
        guard result.succeeded else { throw SimulatorInstallError(message: result.failureSummary) }
    }

    private let destination: URL
    private let written: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var handle: FileHandle?
    private var hasher = Insecure.SHA1()
    private var count: Int64 = 0
    private var failure: Error?
    private var continuation: CheckedContinuation<String, Error>?

    private init(destination: URL, written: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.written = written
    }

    private func run(_ url: URL) async throws -> String {
        guard FileManager.default.createFile(atPath: destination.nativePath, contents: nil),
              let handle = try? FileHandle(forWritingTo: destination) else {
            throw SimulatorInstallError(message: L10n.format("%@ can't be written.", destination.nativePath))
        }
        self.handle = handle
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            lock.withLock { failure = SimulatorInstallError(message: L10n.format("%@ can't be read.",
                                                                                 response.url?.absoluteString ?? "")) }
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let total: Int64? = lock.withLock {
            do {
                try handle?.write(contentsOf: data)
            } catch {
                failure = error
                dataTask.cancel()
                return nil
            }
            hasher.update(data: data)
            count += Int64(data.count)
            return count
        }
        if let total { written(total) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, result): (CheckedContinuation<String, Error>?, Result<String, Error>) = lock.withLock {
            try? handle?.close()
            handle = nil
            defer { self.continuation = nil }
            if let failure = failure ?? error { return (self.continuation, .failure(failure)) }
            return (self.continuation, .success(hasher.finalize().map { String(format: "%02x", $0) }.joined()))
        }
        continuation?.resume(with: result)
    }
}
