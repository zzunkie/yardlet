import Foundation

/// Gets what iOS simulators are missing on this Mac. Without Xcode it opens Xcode's App Store page, as only the
/// App Store installs it. Xcode's first launch asks for an administrator password, so the person does that. Without
/// an iOS runtime it runs Xcode's own `xcodebuild -downloadPlatform iOS`, after showing its size, which Apple's public
/// list of simulator runtimes gives for the runtime this Xcode's SDK names. The runtime it installed is the one
/// `simctl runtime list` did not have before; removing it is `simctl runtime delete`.
struct MacIOSRuntimeInstaller: SimulatorInstaller {
    static let appStoreURL = URL(string: "macappstore://apps.apple.com/app/xcode/id497799835")!
    static let runtimeIndexURL = URL(string: "https://devimages-cdn.apple.com/downloads/xcode/simulators/index2.dvtdownloadableindex")!

    var runner: any CLICommandRunning = LiveCLICommandRunner()
    /// Apple's list of simulator runtimes.
    var fetchIndex: @Sendable () async throws -> Data = {
        let (data, response) = try await URLSession.shared.data(from: MacIOSRuntimeInstaller.runtimeIndexURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SimulatorInstallError(message: "The list of simulator runtimes is not available.")
        }
        return data
    }
    /// Runs a program, handing each line of its output on as it comes; returns its exit status.
    var stream: @Sendable (URL, [String], [String: String], @escaping @Sendable (String) -> Void) async throws -> Int32
        = StreamingCLIProcess.run(_:_:_:_:)
    /// The Xcode to check and remove runtimes with, once the switch turns off.
    var currentToolchain: @Sendable () async -> SimulatorToolchain? = { await MacIOSSimulatorBackend().check().toolchain }
    var architecture = StreamingCLIProcess.hostArchitecture

    var platform: SimulatorPlatform { .iOS }

    func offer(for check: SimulatorPlatformCheck) async throws -> SimulatorInstallOffer? {
        switch check.availability {
        case .xcodeMissing:
            return .openStore(Self.appStoreURL)
        case .runtimeMissing:
            guard let toolchain = check.toolchain else { return nil }
            let runtime = await expectedRuntime(with: toolchain)
            return .download(name: runtime?.name ?? L10n.string("iOS Simulator Runtime"), bytes: runtime?.bytes,
                             licenses: [])
        case .available, .xcodeNotSetUp, .xcodeNotSupportedYet, .sdkMissing:
            return nil
        }
    }

    func install(_ offer: SimulatorInstallOffer, for check: SimulatorPlatformCheck,
                 progress: @escaping @Sendable (SimulatorInstallProgress) -> Void) async throws -> [SimulatorInstalledItem] {
        guard case let .download(name, bytes, _) = offer, let toolchain = check.toolchain else { return [] }
        let before = await runtimes(with: toolchain)
        var arguments = ["-downloadPlatform", "iOS"]
        // Apple lists the runtimes for Apple silicon apart from the universal ones; ask for the one sized above.
        if architecture == "arm64" { arguments += ["-architectureVariant", "arm64"] }
        let lastLines = LastLines()
        let status = try await stream(URL(filePath: toolchain.directory).appending(path: "usr/bin/xcodebuild"), arguments,
                                      ["DEVELOPER_DIR": toolchain.directory]) { line in
            lastLines.add(line)
            if let reading = SimulatorInstallOutput.progress(in: line) { progress(reading) }
        }
        try Task.checkCancellation()
        guard status == 0 else {
            throw SimulatorInstallError(message: lastLines.last ?? "xcodebuild -downloadPlatform iOS ended with status \(status).")
        }
        let after = await runtimes(with: toolchain)
        return after.filter { before[$0.key] == nil && $0.value.isIOS }.keys.sorted()
            .map { SimulatorInstalledItem.iOSRuntime(identifier: $0, name: name, bytes: bytes) }
    }

    func isStillInstalled(_ item: SimulatorInstalledItem) async -> Bool {
        guard case let .iOSRuntime(identifier, _, _) = item, let toolchain = await currentToolchain() else { return false }
        return await runtimes(with: toolchain)[identifier]?.deletable == true
    }

    func remove(_ item: SimulatorInstalledItem) async throws {
        guard case let .iOSRuntime(identifier, _, _) = item else { return }
        guard let toolchain = await currentToolchain() else {
            throw SimulatorInstallError(message: L10n.string("Xcode can't be found."))
        }
        let result = await runner.run(CLICommand(executable: URL(filePath: "/usr/bin/xcrun"),
                                                 arguments: ["simctl", "runtime", "delete", identifier],
                                                 environment: ["DEVELOPER_DIR": toolchain.directory], timeout: .seconds(300)))
        guard result.succeeded else { throw SimulatorInstallError(message: result.failureSummary) }
    }

    // MARK: - Reading

    struct InstalledRuntime: Equatable {
        var platformIdentifier: String
        var deletable: Bool

        var isIOS: Bool { platformIdentifier == "com.apple.platform.iphonesimulator" }
    }

    private func runtimes(with toolchain: SimulatorToolchain) async -> [String: InstalledRuntime] {
        let result = await runner.run(CLICommand(executable: URL(filePath: "/usr/bin/xcrun"),
                                                 arguments: ["simctl", "runtime", "list", "-j"],
                                                 environment: ["DEVELOPER_DIR": toolchain.directory], timeout: .seconds(60)))
        guard result.succeeded else { return [:] }
        return Self.installedRuntimes(from: Data(result.stdout.utf8))
    }

    static func installedRuntimes(from data: Data) -> [String: InstalledRuntime] {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]] else { return [:] }
        return list.mapValues {
            InstalledRuntime(platformIdentifier: $0["platformIdentifier"] as? String ?? "",
                             deletable: $0["deletable"] as? Bool ?? false)
        }
    }

    /// The runtime `xcodebuild -downloadPlatform iOS` gets for this Xcode, from its iOS simulator SDK's build and
    /// Apple's list; nil when either cannot be read.
    private func expectedRuntime(with toolchain: SimulatorToolchain) async -> (name: String, bytes: Int64)? {
        let version = URL(filePath: toolchain.directory).appending(
            path: "Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk/System/Library/CoreServices/SystemVersion.plist")
        guard let plist = (try? Data(contentsOf: version))
                .flatMap({ try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }),
              let build = plist["ProductBuildVersion"] as? String,
              let index = try? await fetchIndex() else { return nil }
        return SimulatorRuntimeIndex.runtime(forSDKBuild: build, architecture: architecture, in: index)
    }
}

/// Apple's list of simulator runtimes (`index2.dvtdownloadableindex`): which runtime builds each SDK build takes,
/// the preferred one first, and each runtime's download.
enum SimulatorRuntimeIndex {
    static func runtime(forSDKBuild build: String, architecture: String, in data: Data) -> (name: String, bytes: Int64)? {
        guard let index = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let mappings = index["sdkToSimulatorMappings"] as? [[String: Any]],
              let downloadables = index["downloadables"] as? [[String: Any]] else { return nil }
        let builds = mappings
            .filter { $0["sdkBuildUpdate"] as? String == build }
            .sorted { ($0["affinity"] as? String == "preferred") && ($1["affinity"] as? String != "preferred") }
            .compactMap { $0["simulatorBuildUpdate"] as? String }
        for runtimeBuild in builds {
            let matching = downloadables.filter {
                $0["platform"] as? String == "com.apple.platform.iphoneos"
                    && ($0["simulatorVersion"] as? [String: Any])?["buildUpdate"] as? String == runtimeBuild
            }
            // On Apple silicon the arm64 runtime, asked for by name; elsewhere one that runs on the Mac's architecture.
            let fits = matching.first { ($0["architectures"] as? [String]) == [architecture] }
                ?? matching.first { ($0["architectures"] as? [String])?.contains(architecture) ?? true }
            if let fits, let name = fits["name"] as? String, let size = fits["fileSize"] as? NSNumber {
                return (name, size.int64Value)
            }
        }
        return nil
    }
}

/// The last line a command printed, kept as it runs to say why it failed.
private final class LastLines: @unchecked Sendable {
    private let lock = NSLock()
    private var line: String?

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.withLock { line = trimmed }
    }

    var last: String? { lock.withLock { line } }
}

/// Runs a program and hands each line of its output on as it comes, a line ending at a newline or a carriage return
/// (as progress lines rewrite themselves). Cancelling the task ends the program.
enum StreamingCLIProcess {
    static var hostArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    static func run(_ executable: URL, arguments: [String], environment: [String: String],
                    onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = FileHandle.childNullDevice()
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let splitter = LineSplitter(onLine: onLine)
        let reader = output.fileHandleForReading
        let exit = try ProcessExit(running: process)
        // Each line is handed on as it comes, and every line, to the end of the output, before this returns.
        let reading = Task.detached {
            while let data = try? reader.read(upToCount: 64 * 1024), !data.isEmpty { splitter.feed(data) }
            splitter.finish()
        }
        await withTaskCancellationHandler {
            await reading.value
        } onCancel: {
            NativeProcessTree.terminate(process: process)
        }
        guard await exit.wait(timeout: .seconds(10)) else { return -1 }
        return process.terminationStatus
    }

    static func run(_ executable: URL, _ arguments: [String], _ environment: [String: String],
                    _ onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        try await run(executable, arguments: arguments, environment: environment, onLine: onLine)
    }

    private final class LineSplitter: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private let onLine: @Sendable (String) -> Void

        init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

        func feed(_ data: Data) {
            let lines: [String] = lock.withLock {
                buffer.append(data)
                var found: [String] = []
                while let end = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    found.append(String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self))
                    buffer.removeSubrange(buffer.startIndex...end)
                }
                return found
            }
            for line in lines where !line.isEmpty { onLine(line) }
        }

        func finish() {
            let rest: String = lock.withLock {
                defer { buffer.removeAll() }
                return String(decoding: buffer, as: UTF8.self)
            }
            if !rest.isEmpty { onLine(rest) }
        }
    }
}
