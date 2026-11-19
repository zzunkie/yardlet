import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Gets an Android SDK for the simulator panel without Java: Google's package lists (the repository and its Google
/// Play system images) name each package's archive, size, SHA-1 and license. Yardlet downloads the missing ones,
/// checks each against its SHA-1, unpacks it where sdkmanager would (each archive holds one folder with its
/// `source.properties`), writes beside it the `package.xml` sdkmanager writes from the list (`AndroidSDKPackageXML`),
/// writes the license's acceptance as sdkmanager does (`AndroidSDKLicenses`), and makes one AVD as Android Studio's
/// files describe it. What is
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
                if let xml = package.packageXML {
                    try Data(xml.utf8).write(to: destination.appending(path: "package.xml"), options: .atomic)
                }
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
        /// The `package.xml` to write in its folder.
        var packageXML: String?
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
        func add(_ package: AndroidSDKCatalog.Package?, from catalog: AndroidSDKCatalog, archiveFor host: AndroidSDKHost?) {
            guard let package, let archive = package.archives.first(where: {
                ($0.hostOS == nil || $0.hostOS == host?.os) && ($0.hostArch == nil || $0.hostArch == host?.arch)
            }) else { return }
            downloads.append(.init(path: package.path, folder: package.path.replacingOccurrences(of: ";", with: "/"),
                                   revision: package.revision, name: package.displayName, license: package.license,
                                   url: archive.url, size: archive.size, sha1: archive.sha1,
                                   packageXML: AndroidSDKPackageXML.text(for: package, in: catalog)))
        }
        if !fileExists(sdkRoot.appending(path: "platform-tools/\(AndroidSDK.program("adb"))")) {
            add(repository.newestStable(path: "platform-tools"), from: repository, archiveFor: host)
        }
        if !fileExists(sdkRoot.appending(path: "emulator/\(AndroidSDK.program("emulator"))")) {
            add(repository.newestStable(path: "emulator"), from: repository, archiveFor: host)
        }
        var avd: AndroidSDKInstallPlan.AVD?
        if !hasAVDs {
            if let image = installedImages.max(by: { $0.apiLevel < $1.apiLevel }) {
                avd = .init(name: AndroidSDKInstaller.avdName, displayName: "Yardlet Phone (API \(image.apiLevel))",
                            imageFolder: image.folder + "/", apiLevel: image.apiLevel, tag: image.tag,
                            tagDisplay: image.tagDisplay, abi: image.abi)
            } else if let image = systemImages.newestImage(tag: "google_apis_playstore", abi: host.abi) {
                add(image, from: systemImages, archiveFor: nil)
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
        /// The package as the list writes it, `<remotePackage …>…</remotePackage>`.
        var element = ""
    }

    var packages: [Package] = []
    var licenses: [String: String] = [:]
    /// The licenses as the list writes them, and the namespaces its root element declares (`xmlns:sdk="…"`), which a
    /// package's `package.xml` keeps.
    var licenseElements: [String: String] = [:]
    var namespaces: [String] = []

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
        let document = String(decoding: data, as: UTF8.self)
        let reader = Reader(base: base, elements: AndroidSDKPackageXML.elements(named: "remotePackage", in: document))
        SimpleXML.read(document, start: reader.start, text: { reader.text += $0 }, end: reader.end)
        var catalog = reader.catalog
        catalog.namespaces = AndroidSDKPackageXML.namespaces(in: document)
        for element in AndroidSDKPackageXML.elements(named: "license", in: document) {
            if let id = AndroidSDKPackageXML.attribute("id", of: element) { catalog.licenseElements[id] = String(element) }
        }
        return catalog
    }

    private final class Reader {
        let base: URL
        /// The packages as the list writes them, in its order.
        let elements: [Substring]
        private var started = 0
        var catalog = AndroidSDKCatalog()
        private var path: [String] = []
        var text = ""
        private var license: String?
        private var package: Package?
        private var revision: [String: String] = [:]
        private var archive: (os: String?, arch: String?, size: Int64, sha1: String, url: String)?

        init(base: URL, elements: [Substring]) {
            self.base = base
            self.elements = elements
        }

        func start(_ name: String, _ attributes: [String: String]) {
            let element = name.split(separator: ":").last.map(String.init) ?? name
            path.append(element)
            text = ""
            switch element {
            case "license" where package == nil:
                license = attributes["id"]
            case "remotePackage":
                let path = attributes["path"] ?? ""
                let element = started < elements.count ? elements[started] : ""
                started += 1
                package = Package(path: path, revision: "", displayName: "", archives: [],
                                  element: AndroidSDKPackageXML.attribute("path", of: element) == path ? String(element) : "")
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

        func end(_ name: String) {
            let element = path.popLast() ?? name
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let parent = path.last
            switch element {
            case "license" where package == nil:
                // The text as the list holds it, which the person reads; its acceptance hashes the text as
                // sdkmanager reads it (`AndroidSDKLicenses.sdkmanagerText`).
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

/// The `package.xml` sdkmanager writes in each package's folder, which Google's tools read for what is installed (the
/// Android CLI that sdkmanager now hands to knows a package's revision only from it): the list's `remotePackage` as
/// a `localPackage`, without its channel and archives, after its license, under a `repository` root that declares
/// the list's namespaces, so its `xsi:type` keeps its meaning. The list's own text is kept as it is.
enum AndroidSDKPackageXML {
    static let commonNamespace = "http://schemas.android.com/repository/android/common/02"

    static func text(for package: AndroidSDKCatalog.Package, in catalog: AndroidSDKCatalog) -> String? {
        let element = package.element
        guard let open = element.firstIndex(of: ">"),
              let close = element.range(of: "</remotePackage>", options: .backwards) else { return nil }
        var body = String(element[element.index(after: open)..<close.lowerBound])
        for (start, end) in [("<channelRef", "/>"), ("<archives>", "</archives>")] {
            if let from = body.range(of: start), let to = body[from.upperBound...].range(of: end) {
                body.removeSubrange(from.lowerBound..<to.upperBound)
            }
        }
        var declarations = catalog.namespaces
        let declared = declarations.compactMap(declaration)
        let prefix: String
        if let common = declared.first(where: { $0.uri == commonNamespace }) {
            prefix = common.prefix
        } else {
            prefix = declared.contains { $0.prefix == "common" } ? "repository-common" : "common"
            declarations.append("xmlns:\(prefix)=\"\(commonNamespace)\"")
        }
        let license = package.license.flatMap { catalog.licenseElements[$0] }.map { "\n" + $0 } ?? ""
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <\(prefix):repository \(declarations.joined(separator: " "))>\(license)
        <localPackage path="\(package.path)" obsolete="false">\(body)</localPackage>
        </\(prefix):repository>

        """
    }

    /// Each element named `name` as the document writes it, in order, outside comments.
    static func elements(named name: String, in document: String) -> [Substring] {
        var found: [Substring] = []
        var index = document.startIndex
        while let open = document[index...].firstIndex(of: "<") {
            let rest = document[open...]
            if rest.hasPrefix("<!--") {
                index = rest.range(of: "-->")?.upperBound ?? document.endIndex
                continue
            }
            let tag = rest.dropFirst()
            if tag.hasPrefix(name), tag.dropFirst(name.count).first.map({ $0.isWhitespace || $0 == ">" }) == true,
               let close = rest.range(of: "</\(name)>") {
                found.append(document[open..<close.upperBound])
                index = close.upperBound
            } else {
                index = document.index(after: open)
            }
        }
        return found
    }

    /// The namespaces the root element declares, `xmlns:sdk="…"`, as the document writes them.
    static func namespaces(in document: String) -> [String] {
        var index = document.startIndex
        while let open = document[index...].firstIndex(of: "<") {
            let rest = document[open...]
            guard rest.hasPrefix("<?") || rest.hasPrefix("<!") else {
                let tag = rest[..<(rest.firstIndex(of: ">") ?? rest.endIndex)]
                return tag.split(whereSeparator: \.isWhitespace).map(String.init).filter { declaration($0) != nil }
            }
            index = (rest.hasPrefix("<!--") ? rest.range(of: "-->")?.upperBound : rest.firstIndex(of: ">"))
                ?? document.endIndex
        }
        return []
    }

    /// An attribute of an element's start tag, as written.
    static func attribute(_ name: String, of element: Substring) -> String? {
        let tag = element[..<(element.firstIndex(of: ">") ?? element.endIndex)]
        guard let start = tag.range(of: " \(name)=\"") else { return nil }
        return tag[start.upperBound...].split(separator: "\"", maxSplits: 1).first.map(String.init)
    }

    private static func declaration(_ text: String) -> (prefix: String, uri: String)? {
        guard text.hasPrefix("xmlns:"), let equals = text.firstIndex(of: "=") else { return nil }
        let value = text[text.index(after: equals)...]
        guard value.count >= 2, value.first == "\"", value.last == "\"" else { return nil }
        return (String(text[text.index(text.startIndex, offsetBy: 6)..<equals]), String(value.dropFirst().dropLast()))
    }
}

/// Reads XML as Google's package lists write it, without Foundation's XML parser, which on Linux would tie the engine
/// to libxml2: elements with their attributes, text with the predefined and numeric character references, CDATA,
/// comments, and the declaration. Line ends are read as `\n`, as an XML parser hands them on.
enum SimpleXML {
    static func read(_ document: String, start: (String, [String: String]) -> Void, text: (String) -> Void,
                     end: (String) -> Void) {
        let xml = document.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var index = xml.startIndex
        while index < xml.endIndex {
            guard let open = xml[index...].firstIndex(of: "<") else {
                text(decode(xml[index...]))
                return
            }
            if open > index { text(decode(xml[index..<open])) }
            let rest = xml[open...]
            if rest.hasPrefix("<!--") {
                index = rest.range(of: "-->").map(\.upperBound) ?? xml.endIndex
            } else if rest.hasPrefix("<![CDATA[") {
                let body = rest.index(open, offsetBy: 9)
                let close = xml[body...].range(of: "]]>")
                text(String(xml[body..<(close?.lowerBound ?? xml.endIndex)]))
                index = close?.upperBound ?? xml.endIndex
            } else if rest.hasPrefix("<?") || rest.hasPrefix("<!") {
                index = rest.firstIndex(of: ">").map { xml.index(after: $0) } ?? xml.endIndex
            } else {
                guard let close = tagEnd(in: xml, from: open) else { return }
                var tag = xml[xml.index(after: open)..<close]
                index = xml.index(after: close)
                if tag.hasPrefix("/") {
                    end(String(tag.dropFirst()).trimmingCharacters(in: .whitespaces).localName)
                    continue
                }
                let empty = tag.hasSuffix("/")
                if empty { tag = tag.dropLast() }
                let name = String(tag.prefix { !$0.isWhitespace })
                start(name.localName, attributes(tag.dropFirst(name.count)))
                if empty { end(name.localName) }
            }
        }
    }

    /// The `>` that ends the tag starting at `open`, past any `>` inside a quoted attribute value.
    private static func tagEnd(in xml: String, from open: String.Index) -> String.Index? {
        var quote: Character?
        var index = xml.index(after: open)
        while index < xml.endIndex {
            let character = xml[index]
            if let current = quote {
                if character == current { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return index
            }
            index = xml.index(after: index)
        }
        return nil
    }

    private static func attributes(_ text: Substring) -> [String: String] {
        var found: [String: String] = [:]
        var rest = text[...]
        while let equals = rest.firstIndex(of: "=") {
            let name = rest[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = rest[rest.index(after: equals)...].drop { $0.isWhitespace }
            guard let quote = value.first, quote == "\"" || quote == "'" else { break }
            value = value.dropFirst()
            guard let close = value.firstIndex(of: quote) else { break }
            found[name.localName] = decode(value[..<close])
            rest = value[value.index(after: close)...]
        }
        return found
    }

    /// Text with `&lt;`, `&gt;`, `&amp;`, `&quot;`, `&apos;` and `&#…;` references replaced.
    static func decode(_ text: Substring) -> String {
        guard text.contains("&") else { return String(text) }
        var result = ""
        var rest = text
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            guard let semicolon = rest[amp...].firstIndex(of: ";") else { break }
            let entity = rest[rest.index(after: amp)..<semicolon]
            switch entity {
            case "lt": result += "<"
            case "gt": result += ">"
            case "amp": result += "&"
            case "quot": result += "\""
            case "apos": result += "'"
            default:
                let number = entity.hasPrefix("#x") ? UInt32(entity.dropFirst(2), radix: 16)
                    : entity.hasPrefix("#") ? UInt32(entity.dropFirst()) : nil
                if let number, let scalar = Unicode.Scalar(number) {
                    result.unicodeScalars.append(scalar)
                } else {
                    result += rest[amp...semicolon]
                }
            }
            rest = rest[rest.index(after: semicolon)...]
        }
        return result + rest
    }
}

private extension String {
    /// The name without its namespace prefix.
    var localName: String { split(separator: ":").last.map(String.init) ?? self }
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

/// A license's acceptance as sdkmanager writes and reads it: on a line of `licenses/<id>`, the SHA-1 of the license's
/// text as sdkmanager reads it from the list, not as the list holds it. Android Studio, sdkmanager and Gradle take
/// only that hash for an accepted license.
enum AndroidSDKLicenses {
    static func hash(_ license: SimulatorLicense) -> String {
        Insecure.SHA1.hash(data: Data(sdkmanagerText(license.text).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The text as sdkmanager reads a license (its `TrimStringAdapter`): spaces and tabs after whitespace dropped, a
    /// line end that stands alone made a space, runs of spaces made one, and both ends trimmed as Java's `trim` does
    /// (every character up to the space). Paragraph breaks stay.
    static func sdkmanagerText(_ text: String) -> String {
        var value = text.replacingOccurrences(of: #"(?<=[ \t\n\x0B\f\r])[ \t]*"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?<!\n)\n(?!\n)"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        let scalars = value.unicodeScalars
        guard let first = scalars.firstIndex(where: { $0.value > 0x20 }),
              let last = scalars.lastIndex(where: { $0.value > 0x20 }) else { return "" }
        return String(scalars[first...last])
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
