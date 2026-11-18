import Crypto
import Foundation

/// A connection to a TCP port on this computer's loopback address, which an adb forward tunnel carries to a socket
/// on the device. Each platform's layer opens one (`Platform/macOS`); tests give scripted ones.
protocol LoopbackSocket: AnyObject, Sendable {
    /// The next bytes, waiting for some; empty once the other end closed.
    func read() async throws -> Data
    func write(_ data: Data) async throws
    func close()
}

protocol LoopbackSocketOpening: Sendable {
    func open(port: Int) async throws -> any LoopbackSocket
}

/// The scrcpy server's `adb shell`, which runs as long as the server does.
protocol ScrcpyServerProcess: AnyObject, Sendable {
    var isRunning: Bool { get }
    /// The last of what the server printed, for a failure's message.
    var output: String { get }
    func terminate()
}

/// Starts the server's `adb shell`: adb, then its arguments.
typealias ScrcpyServerStarter = @Sendable (URL, [String]) throws -> any ScrcpyServerProcess

/// One device's screen and input through the scrcpy server (`ScrcpyServer`): the server pushed to the device and
/// started over `adb shell`, a forward tunnel to its socket, the video socket's H.264 packets handed to `video`, and
/// control messages sent on the control socket. Nothing touches the main thread: the packets go to the platform's
/// decoder from this actor.
///
/// The server removes its file from the device as it starts, and ends when its sockets close; `stop()` closes
/// them, ends the `adb shell` that started it and removes the tunnel.
actor ScrcpySession {
    let serial: String
    private let adb: URL
    private let serverFile: URL
    private let video: ScrcpyVideoOptions
    private let runner: any CLICommandRunning
    private let sockets: any LoopbackSocketOpening
    private let startServerProcess: ScrcpyServerStarter
    private let checkServerFile: @Sendable (URL) throws -> Void
    private let scid = UInt32.random(in: 0...0x7FFF_FFFF)

    private var server: (any ScrcpyServerProcess)?
    private var tunnelPort: Int?
    private var videoSocket: (any LoopbackSocket)?
    private var controlSocket: (any LoopbackSocket)?
    private var readers: [Task<Void, Never>] = []
    private var ended = false
    private var endHandler: (@Sendable (String?) -> Void)?

    /// The device's name, from the server.
    private(set) var deviceName: String?
    /// The size of the frames the stream sends now, in the pixels positions are given in.
    private(set) var frameSize: (width: Int, height: Int)?

    init(adb: URL, serial: String, serverFile: URL, video: ScrcpyVideoOptions = ScrcpyVideoOptions(),
         runner: any CLICommandRunning = LiveCLICommandRunner(),
         sockets: any LoopbackSocketOpening = LiveLoopbackSockets(),
         startServer: @escaping ScrcpyServerStarter = { try AdbShellServer(adb: $0, arguments: $1) },
         checkServerFile: @escaping @Sendable (URL) throws -> Void = { try ScrcpySession.verify(serverFile: $0) }) {
        self.adb = adb
        self.serial = serial
        self.serverFile = serverFile
        self.video = video
        self.runner = runner
        self.sockets = sockets
        startServerProcess = startServer
        self.checkServerFile = checkServerFile
    }

    /// The server file is the pinned release's, byte for byte.
    static func verify(serverFile: URL) throws {
        let data = try Data(contentsOf: serverFile)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count == ScrcpyServer.byteCount, digest == ScrcpyServer.sha256 else {
            throw ScrcpyProtocolError("The scrcpy server is not version \(ScrcpyServer.version)")
        }
    }

    /// Starts the server and connects; returns once the stream's first bytes can be read. `video` gets the stream,
    /// `deviceMessage` what the device sends back, and `ended` once, when the session ends other than by `stop()`,
    /// with what went wrong.
    func start(video: @escaping @Sendable (ScrcpyVideoEvent) -> Void,
               deviceMessage: @escaping @Sendable (ScrcpyDeviceMessage) -> Void = { _ in },
               ended: @escaping @Sendable (String?) -> Void = { _ in }) async throws {
        try checkServerFile(serverFile)
        endHandler = ended
        do {
            try await adbCommand(["push", serverFile.nativePath, ScrcpyServer.devicePath(scid: scid)], timeout: .seconds(60))
            // `tcp:0` lets adb choose a free port, which it prints.
            let forward = try await adbCommand(["forward", "tcp:0", "localabstract:" + ScrcpyServer.socketName(scid: scid)],
                                               timeout: .seconds(15))
            guard let port = Int(forward.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw ScrcpyProtocolError("adb did not name a forwarded port")
            }
            tunnelPort = port
            server = try startServerProcess(adb, ["-s", serial] + ScrcpyServer.shellArguments(scid: scid, video: self.video))
            let videoSocket = try await connectFirstSocket(port: port)
            self.videoSocket = videoSocket
            controlSocket = try await sockets.open(port: port)
            var reader = ScrcpyVideoStreamReader()
            var head = Data()
            while head.count < ScrcpyServer.deviceNameLength {
                let bytes = try await videoSocket.read()
                guard !bytes.isEmpty else { throw ScrcpyProtocolError("The server closed the stream: \(serverOutput)") }
                head.append(bytes)
            }
            deviceName = String(decoding: head.prefix(ScrcpyServer.deviceNameLength).prefix { $0 != 0 }, as: UTF8.self)
            let first = try reader.read(Data(head.dropFirst(ScrcpyServer.deviceNameLength)))
            // Connected: the tunnel is not needed any more.
            await removeTunnel()
            first.forEach { handle($0, video) }
            readers = [
                Task { [weak self] in await self?.readVideo(from: videoSocket, reader: reader, to: video) },
                Task { [weak self] in await self?.readControl(deviceMessage) }
            ]
        } catch {
            await stop()
            throw error
        }
    }

    func send(_ message: ScrcpyControlMessage) async throws {
        guard let controlSocket, !ended else { throw ScrcpyProtocolError("The session has ended") }
        try await controlSocket.write(message.encoded)
    }

    /// Ends the session and everything it started; `ended` is not called.
    func stop() async {
        endHandler = nil
        await finish()
    }

    // MARK: - Private

    private func handle(_ event: ScrcpyVideoEvent, _ video: @Sendable (ScrcpyVideoEvent) -> Void) {
        if case let .session(width, height) = event { frameSize = (width, height) }
        video(event)
    }

    private func readVideo(from socket: any LoopbackSocket, reader: ScrcpyVideoStreamReader,
                           to video: @escaping @Sendable (ScrcpyVideoEvent) -> Void) async {
        var reader = reader
        do {
            while !ended {
                let bytes = try await socket.read()
                guard !bytes.isEmpty else { return await end(nil) }
                for event in try reader.read(bytes) { handle(event, video) }
            }
        } catch {
            await end(String(describing: error))
        }
    }

    private func readControl(_ deviceMessage: @escaping @Sendable (ScrcpyDeviceMessage) -> Void) async {
        guard let socket = controlSocket else { return }
        var buffer = Data()
        do {
            while !ended {
                let bytes = try await socket.read()
                guard !bytes.isEmpty else { return await end(nil) }
                buffer.append(bytes)
                while let (message, length) = try ScrcpyDeviceMessage.parse(buffer) {
                    buffer = Data(buffer.dropFirst(length))
                    deviceMessage(message)
                }
            }
        } catch {
            await end(String(describing: error))
        }
    }

    private func end(_ problem: String?) async {
        guard !ended else { return }
        let handler = endHandler
        endHandler = nil
        await finish()
        handler?(problem)
    }

    private func finish() async {
        ended = true
        readers.forEach { $0.cancel() }
        readers = []
        videoSocket?.close()
        controlSocket?.close()
        videoSocket = nil
        controlSocket = nil
        if let server, server.isRunning { server.terminate() }
        server = nil
        await removeTunnel()
    }

    private func removeTunnel() async {
        guard let port = tunnelPort else { return }
        tunnelPort = nil
        _ = try? await adbCommand(["forward", "--remove", "tcp:\(port)"], timeout: .seconds(10))
    }

    /// The first socket of a forward tunnel connects as soon as adb listens, before the server does; the server's
    /// one byte says it is there.
    private func connectFirstSocket(port: Int) async throws -> any LoopbackSocket {
        for _ in 0..<100 {
            if let server, !server.isRunning {
                throw ScrcpyProtocolError("The server ended: \(serverOutput)")
            }
            if let socket = try? await sockets.open(port: port) {
                // adb may hold a connection open with nothing behind it: a read that waits too long is closed.
                let timer = Task {
                    try await Task.sleep(for: .seconds(2))
                    socket.close()
                }
                let byte = try? await socket.read()
                timer.cancel()
                if let byte, !byte.isEmpty {
                    // The dummy byte, and whatever followed it.
                    if byte.count > 1 { return PrefixedLoopbackSocket(socket, prefix: byte.dropFirst()) }
                    return socket
                }
                socket.close()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ScrcpyProtocolError("The server did not answer: \(serverOutput)")
    }

    @discardableResult
    private func adbCommand(_ arguments: [String], timeout: Duration) async throws -> String {
        let result = await runner.run(CLICommand(executable: adb, arguments: ["-s", serial] + arguments, timeout: timeout))
        guard result.succeeded else { throw ScrcpyProtocolError(result.failureSummary) }
        return result.stdout
    }

    private var serverOutput: String { server?.output ?? "" }
}

/// The server's `adb shell` as a child process, its output kept in part.
final class AdbShellServer: ScrcpyServerProcess, @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var kept = Data()

    init(adb: URL, arguments: [String]) throws {
        let output = Pipe()
        process.executableURL = adb
        process.arguments = arguments
        process.standardInput = FileHandle.childNullDevice()
        process.standardOutput = output
        process.standardError = output
        process.environment = RuntimeProcessEnvironment.values(executableURL: adb)
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            guard !bytes.isEmpty else { return handle.readabilityHandler = nil }
            self?.keep(bytes)
        }
        try NativeProcessTree.run(process)
    }

    private func keep(_ bytes: Data) {
        lock.withLock {
            kept.append(bytes)
            if kept.count > 4096 { kept = Data(kept.suffix(4096)) }
        }
    }

    var isRunning: Bool { process.isRunning }
    var output: String {
        lock.withLock { String(decoding: kept, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func terminate() { NativeProcessTree.terminate(process: process) }
}

/// A socket whose first read returns bytes already read from it.
private final class PrefixedLoopbackSocket: LoopbackSocket, @unchecked Sendable {
    private let socket: any LoopbackSocket
    private let lock = NSLock()
    private var prefix: Data?

    init(_ socket: any LoopbackSocket, prefix: Data) {
        self.socket = socket
        self.prefix = Data(prefix)
    }

    func read() async throws -> Data {
        if let prefix = lock.withLock({ () -> Data? in defer { self.prefix = nil }; return self.prefix }) { return prefix }
        return try await socket.read()
    }

    func write(_ data: Data) async throws { try await socket.write(data) }
    func close() { socket.close() }
}
