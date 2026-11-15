import Foundation
import WinSDK

/// The Windows App Runtime's packages the app carries, put in place for this Windows user when any is missing, so
/// no one installs the runtime on their own (docs/PLATFORM_PORTABILITY.md, "Installing and updating the Windows
/// app"). `Windows/scripts/pack.ps1` puts the x64 packages of the Windows App SDK's Runtime package in
/// `WindowsAppRuntime` beside the executable: the framework the app starts against, its Main and Singleton packages
/// and its DDLM, with `MSIX.identities`, which names each file's package as its manifest does
/// (`Windows/scripts/generate-bindings.ps1`; Microsoft's `MSIX.inventory` names the DDLM and the Singleton by a pattern).
///
/// A package is there when this user has one of its family for x64 at that version or later; a later one is used as
/// it is, as the Windows App SDK's own deployment does. The rest are added with Windows' package manager
/// (`PackageManager.AddPackageAsync`), the framework first, as Microsoft's runtime installer adds them, and the
/// Singleton, whose notifications process may be running, with that process shut down, as the Windows App SDK
/// replaces it. A PC can have the framework alone, as
/// an app from the Store brings it; without the Singleton an app without a package cannot register for
/// notifications ("Class not registered", seen on a PC), and without the framework it does not start.
///
/// It runs while Velopack's Setup and Update.exe wait on the app's install and update hooks (`VelopackStart`), inside
/// their time limit, and again as the app starts, before the Windows App Runtime does, for a hook that ran out of
/// time or a copy not installed by Setup. When nothing is missing it reads the user's packages and adds nothing.
enum WindowsAppRuntimeDeployment {
    /// The folder beside the executable that holds the packages, and the file in it that names them.
    static let folderName = "WindowsAppRuntime"
    static let inventoryName = "MSIX.identities"

    /// One package the app carries, as `MSIX.identities` names it: `<file>=<package full name>`, the full name being
    /// `<name>_<version>_<architecture>_<resource>_<publisher ID>`.
    struct Package: Equatable, Sendable {
        let file: String
        let name: String
        let version: [UInt16]
        let architecture: String
        let publisherID: String

        var familyName: String { "\(name)_\(publisherID)" }
        var isSingleton: Bool { name.contains(".Singleton") }

        /// The framework comes first and the others after it, in the order Microsoft's installer adds them.
        var order: Int {
            if name.contains(".Main") { return 1 }
            if isSingleton { return 2 }
            if name.contains(".DDLM") { return 3 }
            return 0
        }

        init?(file: String, fullName: String) {
            let parts = fullName.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 5, let version = Self.version(parts[1]) else { return nil }
            self.file = file
            name = parts[0]
            self.version = version
            architecture = parts[2].lowercased()
            publisherID = parts[4]
        }

        /// Whether an installed package's full name is this one at its version or later, for x64 or any architecture.
        func isSatisfied(by fullName: String) -> Bool {
            guard let installed = Package(file: "", fullName: fullName), installed.familyName == familyName,
                  installed.architecture == architecture || installed.architecture == "neutral" else { return false }
            return installed.version.lexicographicallyPrecedes(version) == false
        }

        static func version(_ text: String) -> [UInt16]? {
            let parts = text.split(separator: ".").map { UInt16($0) }
            guard parts.count == 4, !parts.contains(nil) else { return nil }
            return parts.compactMap { $0 }
        }
    }

    /// The packages `inventory` names, the framework first.
    static func packages(inventory: String) -> [Package] {
        inventory.split(whereSeparator: \.isNewline).compactMap { line -> Package? in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { return nil }
            return Package(file: parts[0], fullName: parts[1])
        }.enumerated().sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }.map(\.element)
    }

    /// Adds what is missing, waiting at most `seconds`, and says what it did, for the QA log.
    static func ensure(within seconds: Int) -> String {
        guard let folder = executableFolder.map({ $0 + "\\" + folderName }),
              let inventory = try? String(contentsOfFile: folder + "\\" + inventoryName, encoding: .utf8) else {
            return "runtime: no packages beside the app"
        }
        let carried = packages(inventory: inventory)
        let missing = carried.filter { package in
            !installedFullNames(family: package.familyName).contains(where: package.isSatisfied)
        }
        guard !missing.isEmpty else { return "runtime: in place (\(carried.count) packages)" }
        let outcome = Outcome()
        let finished = DispatchSemaphore(value: 0)
        // The package manager is called on a thread of its own in the multithreaded apartment, which leaves the app's
        // thread for the single-threaded apartment WinUI starts in, and lets a hook give up waiting in time.
        let worker = Thread {
            _ = RoInitialize(RO_INIT_MULTITHREADED)
            outcome.set(add(missing, from: folder))
            RoUninitialize()
            finished.signal()
        }
        worker.start()
        let names = missing.map(\.name).joined(separator: ", ")
        guard finished.wait(timeout: .now() + .seconds(seconds)) == .success else {
            return "runtime: still adding \(names) after \(seconds) s"
        }
        let failures = outcome.failures
        return failures.isEmpty ? "runtime: added \(names)" : "runtime: not added: \(failures.joined(separator: "; "))"
    }

    /// Adds `packages` from `folder` in turn, each once the one before it is in place; the words of each that failed.
    private static func add(_ packages: [Package], from folder: String) -> [String] {
        guard let winRT = WinRT.shared else { return ["combase.dll lacks the calls the package manager needs"] }
        guard let manager = winRT.activate("Windows.Management.Deployment.PackageManager", as: WinRT.packageManagerID),
              let uris = winRT.factory("Windows.Foundation.Uri", as: WinRT.uriFactoryID) else {
            return ["Windows' package manager did not start"]
        }
        defer {
            WinRT.release(manager)
            WinRT.release(uris)
        }
        var failures: [String] = []
        for package in packages {
            // A path, as the Windows App SDK's own deployment hands the package manager one.
            let options: UInt32 = package.isSingleton ? WinRT.forceTargetApplicationShutdown : 0
            if let failure = winRT.addPackage(folder + "\\" + package.file, options: options, manager: manager, uris: uris) {
                failures.append("\(package.name): \(failure)")
            }
        }
        return failures
    }

    /// The Windows Runtime calls the package manager needs, made through its interfaces as C++ makes them: the WinUI
    /// bindings put every Windows namespace in one Swift module, where this namespace's `PackageStatus` and
    /// `Windows.ApplicationModel`'s are one name, so `Windows.Management.Deployment` is not projected. The interfaces'
    /// identifiers and the order of their methods are the Windows SDK's (`windows.management.deployment.idl`,
    /// `windows.foundation.idl`, `asyncinfo.idl`); an object's methods follow `IUnknown`'s three and `IInspectable`'s
    /// three.
    private final class WinRT: @unchecked Sendable {
        typealias Object = UnsafeMutableRawPointer
        typealias Out = UnsafeMutablePointer<Object?>
        typealias ActivateInstance = @convention(c) (Object?, Out?) -> Int32
        typealias GetActivationFactory = @convention(c) (Object?, UnsafePointer<GUID>?, Out?) -> Int32
        typealias CreateString = @convention(c) (UnsafePointer<UInt16>?, UInt32, Out?) -> Int32
        typealias DeleteString = @convention(c) (Object?) -> Int32
        typealias QueryInterface = @convention(c) (Object?, UnsafePointer<GUID>?, Out?) -> Int32
        typealias Release = @convention(c) (Object?) -> UInt32
        /// `IUriRuntimeClassFactory.CreateUri(HSTRING, Uri**)`.
        typealias CreateUri = @convention(c) (Object?, Object?, Out?) -> Int32
        /// `IPackageManager.AddPackageAsync(Uri*, IIterable<Uri*>*, DeploymentOptions, IAsyncOperationWithProgress**)`.
        typealias AddPackageAsync = @convention(c) (Object?, Object?, Object?, UInt32, Out?) -> Int32
        /// `IAsyncInfo`'s `Status` and `ErrorCode`.
        typealias GetValue = @convention(c) (Object?, UnsafeMutablePointer<Int32>?) -> Int32

        static var packageManagerID: GUID { GUID(Data1: 0x9A7D_4B65, Data2: 0x5E8F, Data3: 0x4FC7,
                                                         Data4: (0xA2, 0xE5, 0x7F, 0x69, 0x25, 0xCB, 0x8B, 0x53)) }
        static var uriFactoryID: GUID { GUID(Data1: 0x44A9_796F, Data2: 0x723E, Data3: 0x4FDF,
                                                     Data4: (0xA2, 0x18, 0x03, 0x3E, 0x75, 0xB0, 0xC0, 0x84)) }
        static var asyncInfoID: GUID { GUID(Data1: 0x0000_0036, Data2: 0x0000, Data3: 0x0000,
                                                    Data4: (0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46)) }
        /// `DeploymentOptions.ForceTargetApplicationShutdown`.
        static let forceTargetApplicationShutdown: UInt32 = 0x40
        /// `AsyncStatus`: Started, then Completed, Canceled or Error.
        static let started: Int32 = 0
        static let completed: Int32 = 1

        let activateInstance: ActivateInstance
        let getActivationFactory: GetActivationFactory
        let createString: CreateString
        let deleteString: DeleteString

        /// Loaded once from combase.dll in System32.
        static let shared: WinRT? = {
            let places = DWORD(LOAD_LIBRARY_SEARCH_SYSTEM32)
            guard let module = "combase.dll".withCString(encodedAs: UTF16.self, { LoadLibraryExW($0, nil, places) })
            else { return nil }
            func load<F>(_ name: String, as _: F.Type) -> F? {
                GetProcAddress(module, name).map { unsafeBitCast($0, to: F.self) }
            }
            guard let activate = load("RoActivateInstance", as: ActivateInstance.self),
                  let factory = load("RoGetActivationFactory", as: GetActivationFactory.self),
                  let create = load("WindowsCreateString", as: CreateString.self),
                  let delete = load("WindowsDeleteString", as: DeleteString.self) else { return nil }
            return WinRT(activateInstance: activate, getActivationFactory: factory, createString: create,
                         deleteString: delete)
        }()

        private init(activateInstance: ActivateInstance, getActivationFactory: GetActivationFactory,
                     createString: CreateString, deleteString: DeleteString) {
            self.activateInstance = activateInstance
            self.getActivationFactory = getActivationFactory
            self.createString = createString
            self.deleteString = deleteString
        }

        /// The method at `index` of `object`'s interface.
        static func method<F>(_ object: Object, _ index: Int, as _: F.Type) -> F {
            let table = object.load(as: UnsafeRawPointer.self)
            return unsafeBitCast(table.load(fromByteOffset: index * MemoryLayout<UnsafeRawPointer>.stride,
                                            as: UnsafeRawPointer.self), to: F.self)
        }

        static func release(_ object: Object) {
            _ = method(object, 2, as: Release.self)(object)
        }

        static func query(_ object: Object, _ interface: GUID) -> Object? {
            var interface = interface
            var found: Object?
            guard method(object, 0, as: QueryInterface.self)(object, &interface, &found) >= 0 else { return nil }
            return found
        }

        /// A string the Windows Runtime takes (`HSTRING`), for the call `body` makes with it.
        func withString<T>(_ text: String, _ body: (Object?) -> T) -> T? {
            let units = Array(text.utf16)
            var string: Object?
            let made = units.withUnsafeBufferPointer { createString($0.baseAddress, UInt32($0.count), &string) }
            guard made >= 0 else { return nil }
            defer { _ = deleteString(string) }
            return body(string)
        }

        /// A new object of `className`, asked for `interface`.
        func activate(_ className: String, as interface: GUID) -> Object? {
            var instance: Object?
            guard withString(className, { activateInstance($0, &instance) }).map({ $0 >= 0 }) == true,
                  let instance else { return nil }
            defer { WinRT.release(instance) }
            return WinRT.query(instance, interface)
        }

        /// `className`'s activation factory, as `interface`.
        func factory(_ className: String, as interface: GUID) -> Object? {
            var interface = interface
            var factory: Object?
            guard withString(className, { getActivationFactory($0, &interface, &factory) }).map({ $0 >= 0 }) == true
            else { return nil }
            return factory
        }

        /// Adds the package at `path` and waits until Windows has; nil once it is in place, else why not.
        func addPackage(_ path: String, options: UInt32, manager: Object, uris: Object) -> String? {
            var uri: Object?
            let created = withString(path) { WinRT.method(uris, 6, as: CreateUri.self)(uris, $0, &uri) }
            guard created.map({ $0 >= 0 }) == true, let uri else { return "the file's address: \(Self.hex(created ?? -1))" }
            defer { WinRT.release(uri) }
            var operation: Object?
            let started = WinRT.method(manager, 6, as: AddPackageAsync.self)(manager, uri, nil, options, &operation)
            guard started >= 0, let operation else { return "not started: \(Self.hex(started))" }
            defer { WinRT.release(operation) }
            guard let info = WinRT.query(operation, Self.asyncInfoID) else { return "no status" }
            defer { WinRT.release(info) }
            var status = Self.started
            while status == Self.started {
                Thread.sleep(forTimeInterval: 0.1)
                guard WinRT.method(info, 7, as: GetValue.self)(info, &status) >= 0 else { return "no status" }
            }
            guard status != Self.completed else { return nil }
            var code: Int32 = 0
            _ = WinRT.method(info, 8, as: GetValue.self)(info, &code)
            return "ended with \(Self.hex(code))"
        }

        static func hex(_ code: Int32) -> String {
            String(format: "0x%08X", UInt32(bitPattern: code))
        }
    }

    /// What the worker thread found, read once it has finished.
    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []

        var failures: [String] { lock.withLock { stored } }

        func set(_ failures: [String]) {
            lock.withLock { stored = failures }
        }
    }

    /// The executable's folder as Windows writes it.
    private static var executableFolder: String? {
        var buffer = [UInt16](repeating: 0, count: 32_768)
        let length = Int(GetModuleFileNameW(nil, &buffer, DWORD(buffer.count)))
        guard length > 0, length < buffer.count else { return nil }
        let path = String(decoding: buffer.prefix(length), as: UTF16.self)
        guard let separator = path.lastIndex(of: "\\") else { return nil }
        return String(path[..<separator])
    }

    /// The full names of this user's packages in `family` (kernel32's `GetPackagesByPackageFamily`).
    static func installedFullNames(family: String) -> [String] {
        guard let lookup = packagesByFamily else { return [] }
        return family.withCString(encodedAs: UTF16.self) { familyName in
            var count: UInt32 = 0
            var length: UInt32 = 0
            guard lookup(familyName, &count, nil, &length, nil) == Int32(ERROR_INSUFFICIENT_BUFFER), count > 0 else {
                return []
            }
            var names = [UnsafeMutablePointer<UInt16>?](repeating: nil, count: Int(count))
            var buffer = [UInt16](repeating: 0, count: Int(length))
            return names.withUnsafeMutableBufferPointer { names in
                buffer.withUnsafeMutableBufferPointer { buffer in
                    guard lookup(familyName, &count, names.baseAddress, &length, buffer.baseAddress) == Int32(ERROR_SUCCESS)
                    else { return [] }
                    return names.prefix(Int(count)).compactMap { $0.map { String(decodingCString: $0, as: UTF16.self) } }
                }
            }
        }
    }

    private typealias PackagesByFamily = @convention(c) (
        UnsafePointer<UInt16>?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UnsafeMutablePointer<UInt16>?>?,
        UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt16>?
    ) -> Int32

    private static let packagesByFamily: PackagesByFamily? = {
        guard let kernel = GetModuleHandleW(Array("kernel32.dll".utf16) + [0]),
              let address = GetProcAddress(kernel, "GetPackagesByPackageFamily") else { return nil }
        return unsafeBitCast(address, to: PackagesByFamily.self)
    }()
}
