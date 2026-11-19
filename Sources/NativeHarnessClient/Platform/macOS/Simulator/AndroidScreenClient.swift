import Crypto
import Foundation
import ImageIO
import IOSurface
import UniformTypeIdentifiers
import VideoToolbox
import YardletSimulatorHostProtocol

/// A running Android device as a panel shows it: the adb that reaches it and its serial now.
struct AndroidScreenTarget: Hashable, Sendable {
    var identity: SimulatorDeviceIdentity
    var adb: URL
    var serial: String

    /// Nil for a device that is not running: an emulator or a real device, over USB or `adb connect`, with the serial
    /// adb reaches it by now.
    init?(identity: SimulatorDeviceIdentity, adbSerial: String?, adb: URL) {
        guard identity.kind.platform == .android, let adbSerial, !adbSerial.isEmpty else { return nil }
        self.identity = identity
        self.adb = adb
        serial = adbSerial
    }

    init?(device: SimulatorDevice, adb: URL) {
        self.init(identity: device.identity, adbSerial: device.adbSerial, adb: adb)
    }

    /// The device as `SimulatorFrameRouter` and screenshots name it: the same for the same device on the same serial,
    /// so a frame of an emulator that held the serial before is never taken for this one's.
    var frameDevice: UUID {
        var bytes = Array(SHA256.hash(data: Data("\(identity.kind.rawValue)\n\(identity.value)\n\(serial)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // a name-based UUID
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// How a device's stream ended other than by its last panel going.
enum AndroidStreamEnd: Equatable, Sendable {
    /// The app has no scrcpy server to send the device.
    case serverMissing
    /// The server did not start on the device, or Yardlet could not connect to it: what went wrong.
    case couldNotStart(String)
    /// The stream ended after it started: the device stopped, or the connection broke, with what went wrong if known.
    case ended(String?)
}

/// Yardlet's side of Android screens on this Mac, as `SimulatorHostClient` is for iOS: a scrcpy session for each
/// device a panel shows, its stream decoded off the main thread and put on the panels' `SimulatorFrameDisplay`s by a
/// `SimulatorFrameRouter`, the person's touches and keys sent on its control socket, and screenshots in dp.
///
/// A device's stream runs only while a panel shows it or the agents' tools hold it: `showFrames(of:in:pixelWidth:
/// pixelHeight:)` for each panel, `stopShowingFrames(of:in:)` when it goes, `holdForTools(_:)` and `releaseForTools(_:)`
/// for the tools, and the last of them gone ends the session and the server on the device. Per frame the main thread
/// does nothing; it handles only panels coming and going and input.
@MainActor
final class AndroidScreenClient {
    /// Routes each device's frames to the displays that show it.
    let frameRouter = SimulatorFrameRouter()
    /// A device's stream ended other than by its last panel going, and how. Showing it again starts a new stream.
    var onStreamEnded: ((AndroidScreenTarget, AndroidStreamEnd) -> Void)?
    /// The stream started a capture of another size, in pixels: the device turned.
    var onFrameSize: ((AndroidScreenTarget, Int, Int) -> Void)?

    typealias SessionMaker = @Sendable (_ adb: URL, _ serial: String, _ serverFile: URL, ScrcpyVideoOptions) -> ScrcpySession
    typealias ScreenCapture = @Sendable (_ adb: URL, _ serial: String) async -> (exitCode: Int32, stdout: Data, stderr: String)

    private let serverFile: () -> URL?
    private let runner: any CLICommandRunning
    private let makeSession: SessionMaker
    private let captureScreen: ScreenCapture
    private var streams: [AndroidScreenTarget: AndroidScreenStream] = [:]
    /// Each device's displays, with the longer side of the area each fits the screen into, in pixels.
    private var displays: [AndroidScreenTarget: [ObjectIdentifier: (display: SimulatorFrameDisplay, longestSide: Int)]] = [:]
    /// The modifiers each device's stream has held down.
    private var keyboards: [AndroidScreenTarget: AndroidKeyboard] = [:]
    /// The devices the agents' tools keep a stream running for, with or without a panel showing them.
    private var toolHolds: Set<AndroidScreenTarget> = []

    init(serverFile: @escaping () -> URL? = { ScrcpyServer.bundledFile() },
         runner: any CLICommandRunning = LiveCLICommandRunner(),
         makeSession: @escaping SessionMaker = { ScrcpySession(adb: $0, serial: $1, serverFile: $2, video: $3) },
         captureScreen: @escaping ScreenCapture = { adb, serial in
             await CLIProcess.runForData(CLICommand(executable: adb, arguments: ["-s", serial, "exec-out", "screencap", "-p"],
                                                    timeout: .seconds(20)))
         }) {
        self.serverFile = serverFile
        self.runner = runner
        self.makeSession = makeSession
        self.captureScreen = captureScreen
    }

    /// Whether a stream runs for the device now.
    func isStreaming(_ target: AndroidScreenTarget) -> Bool { streams[target] != nil }

    /// The device's screen, in its natural orientation, and its density as pixels per dp.
    func screen(of target: AndroidScreenTarget) async throws -> SimulatorScreen {
        let metrics = try await displayMetrics(of: target)
        return SimulatorScreen(screenID: 0, pixelWidth: metrics.width, pixelHeight: metrics.height,
                               scale: Double(metrics.density) / 160)
    }

    /// Shows the device's screen in `display`, which fits it within `pixelWidth` × `pixelHeight`, until
    /// `stopShowingFrames(of:in:)`; called again, it takes the new size. The stream is as sharp as the largest panel
    /// needs, its longer side at most 1,280 pixels.
    func showFrames(of target: AndroidScreenTarget, in display: SimulatorFrameDisplay, pixelWidth: Int, pixelHeight: Int) {
        displays[target, default: [:]][ObjectIdentifier(display)] = (display, max(pixelWidth, pixelHeight))
        frameRouter.add(display, for: target.frameDevice)
        startStream(target)
    }

    func stopShowingFrames(of target: AndroidScreenTarget, in display: SimulatorFrameDisplay) {
        guard displays[target]?.removeValue(forKey: ObjectIdentifier(display)) != nil else { return }
        frameRouter.remove(display, for: target.frameDevice)
        if displays[target]?.isEmpty == true {
            displays[target] = nil
            if !toolHolds.contains(target) { stopStream(target) }
        }
    }

    // MARK: - Agent tools

    /// The agents' tools use the device: its stream runs, also while no panel shows it, until `releaseForTools(_:)`.
    /// Returns once the stream sends frames, whose size touches are given in.
    func holdForTools(_ target: AndroidScreenTarget, timeout: Duration = .seconds(20)) async throws {
        toolHolds.insert(target)
        if streams[target] == nil { startStream(target) }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            guard toolHolds.contains(target), let stream = streams[target] else {
                throw ScrcpyProtocolError("The emulator's screen stream did not start")
            }
            if stream.frameSize != nil { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ScrcpyProtocolError("The emulator's screen stream sent no frame")
    }

    func releaseForTools(_ target: AndroidScreenTarget) {
        guard toolHolds.remove(target) != nil, displays[target] == nil else { return }
        stopStream(target)
    }

    /// A key by Android's own code (`android.view.KeyEvent`), pressed and let go: Power and the volume keys.
    func press(keycode: UInt32, on target: AndroidScreenTarget) throws {
        let stream = try running(target)
        stream.send(.key(.down, keycode: keycode))
        stream.send(.key(.up, keycode: keycode))
    }

    /// ASCII text typed as key events the device makes from it (scrcpy's text injection), in pieces the server takes.
    func type(_ text: String, on target: AndroidScreenTarget) throws {
        let stream = try running(target)
        var piece = ""
        for character in text {
            if piece.utf8.count + character.utf8.count > ScrcpyControlMessage.textLimit {
                stream.send(.text(piece))
                piece = ""
            }
            piece.append(character)
        }
        if !piece.isEmpty { stream.send(.text(piece)) }
    }

    /// The text on the device's clipboard; nil when it holds none, which the server does not answer.
    func clipboard(of target: AndroidScreenTarget) async throws -> String? {
        let stream = try running(target)
        do {
            let answer = try await stream.request(.getClipboard, timeout: .seconds(1)) {
                if case .clipboard = $0 { true } else { false }
            }
            guard case let .clipboard(text) = answer else { return nil }
            return text
        } catch where streams[target] === stream {
            return nil
        }
    }

    /// Puts the text on the device's clipboard, and pastes it into the focused field when `paste`; returns once the
    /// device says it set the clipboard (after it sent the paste key).
    func setClipboard(_ text: String, paste: Bool, on target: AndroidScreenTarget) async throws {
        let stream = try running(target)
        let sequence = stream.nextSequence()
        _ = try await stream.request(.setClipboard(text, sequence: sequence, paste: paste)) {
            $0 == .clipboardSet(sequence: sequence)
        }
    }

    private func running(_ target: AndroidScreenTarget) throws -> AndroidScreenStream {
        guard let stream = streams[target] else { throw ScrcpyProtocolError("The emulator's screen stream is not running") }
        return stream
    }

    /// A finger on the screen at a point given as fractions of it. Nothing happens while no stream runs.
    func touch(_ phase: SimulatorTouchPhase, at point: SimulatorPoint, on target: AndroidScreenTarget) {
        guard let stream = streams[target], let size = stream.frameSize else { return }
        let action: ScrcpyTouchAction = switch phase {
        case .down: .down
        case .move: .move
        case .up: .up
        }
        let position = ScrcpyPosition(fractionX: point.x, y: point.y, frameWidth: size.width, frameHeight: size.height)
        stream.send(.touch(action, pointer: ScrcpyControlMessage.fingerPointer, at: position, pressure: action == .up ? 0 : 1))
    }

    func press(_ button: AndroidNavigationButton, on target: AndroidScreenTarget) {
        guard let stream = streams[target] else { return }
        stream.send(.key(.down, keycode: button.keycode))
        stream.send(.key(.up, keycode: button.keycode))
    }

    /// A key by its place on the keyboard, as the screen view sends every device one (`SimulatorKeyMap`).
    func key(_ usage: SimulatorKeyUsage, _ phase: SimulatorPressPhase, on target: AndroidScreenTarget) {
        guard let stream = streams[target] else { return }
        keyboards[target, default: AndroidKeyboard()].messages(usage, phase).forEach(stream.send)
    }

    /// The screen at the device's size in dp, so its pixels are the coordinates agents use: the last frame decoded
    /// while a stream runs, otherwise a capture through adb (`screencap`).
    func screenshot(of target: AndroidScreenTarget, format: SimulatorImageFormat) async throws -> SimulatorScreenshot {
        let latest = streams[target]?.decoder.latest
        let metrics = try await displayMetrics(of: target)
        var captured: Data?
        if latest == nil {
            let capture = await captureScreen(target.adb, target.serial)
            guard capture.exitCode == 0, !capture.stdout.isEmpty else {
                throw ScrcpyProtocolError("Could not capture the screen: \(capture.stderr)")
            }
            captured = capture.stdout
        }
        let device = target.frameDevice
        let png = captured
        return try await Task.detached(priority: .userInitiated) {
            guard let image = latest.flatMap(AndroidScreenshot.image(of:)) ?? png.flatMap(AndroidScreenshot.image(png:)) else {
                throw ScrcpyProtocolError("The screen did not make an image")
            }
            let size = metrics.dpSize(frameWidth: image.width, frameHeight: image.height)
            let data = try AndroidScreenshot.encode(image, width: size.width, height: size.height, format: format)
            return SimulatorScreenshot(device: device, format: format, width: size.width, height: size.height, data: data)
        }.value
    }

    /// Ends every stream, as Yardlet quits.
    func stopAll() {
        for target in Array(streams.keys) { stopStream(target) }
        displays.removeAll()
        toolHolds.removeAll()
        frameRouter.removeAll()
    }

    // MARK: - Private

    private func displayMetrics(of target: AndroidScreenTarget) async throws -> AndroidDisplayMetrics {
        let read = await runner.run(CLICommand(executable: target.adb,
                                               arguments: ["-s", target.serial, "shell", AndroidDisplayMetrics.shellCommand],
                                               timeout: .seconds(10)))
        guard read.succeeded, let metrics = AndroidDisplayMetrics.parse(read.stdout) else {
            throw ScrcpyProtocolError("Could not read the screen's size: \(read.failureSummary)")
        }
        return metrics
    }

    private func startStream(_ target: AndroidScreenTarget) {
        // A stream for the tools alone is as sharp as a stream can be, for their screenshots.
        let wanted = ScrcpyVideoOptions(maxSize: displays[target]?.values.map(\.longestSide).max()
            ?? (toolHolds.contains(target) ? ScrcpyVideoOptions().maxSize : 0))
        if let stream = streams[target] {
            // Starting over costs a key frame's wait: only a panel half again as large as the stream takes a new one.
            guard wanted.maxSize * 2 >= stream.video.maxSize * 3 else { return }
            stopStream(target)
        }
        guard let file = serverFile() else {
            onStreamEnded?(target, .serverMissing)
            return
        }
        let stream = AndroidScreenStream(target: target, video: wanted, router: frameRouter,
                                         session: makeSession(target.adb, target.serial, file, wanted)) { width, height in
            Task { @MainActor in self.onFrameSize?(target, width, height) }
        }
        streams[target] = stream
        keyboards[target] = AndroidKeyboard()
        // The client lives as long as the app; the session lets go of its end handler when it ends.
        Task {
            do {
                try await stream.start { problem in
                    Task { @MainActor in self.streamEnded(stream, .ended(problem)) }
                }
            } catch {
                self.streamEnded(stream, .couldNotStart(String(describing: error)))
            }
        }
    }

    private func stopStream(_ target: AndroidScreenTarget) {
        keyboards[target] = nil
        guard let stream = streams.removeValue(forKey: target) else { return }
        frameRouter.forgetLatestFrame(of: target.frameDevice)
        Task { await stream.stop() }
    }

    private func streamEnded(_ stream: AndroidScreenStream, _ end: AndroidStreamEnd) {
        guard streams[stream.target] === stream else { return }
        streams[stream.target] = nil
        keyboards[stream.target] = nil
        frameRouter.forgetLatestFrame(of: stream.target.frameDevice)
        Task { await stream.stop() }
        onStreamEnded?(stream.target, end)
    }
}

/// One device's scrcpy session, its decoder, and its control messages, which go to the device in the order they
/// were sent.
final class AndroidScreenStream: @unchecked Sendable {
    let target: AndroidScreenTarget
    let video: ScrcpyVideoOptions
    let decoder: AndroidVideoDecoder
    private let session: ScrcpySession
    private let messages: AsyncStream<ScrcpyControlMessage>.Continuation
    private let sender: Task<Void, Never>
    private let lock = NSLock()
    private var size: (width: Int, height: Int)?
    /// Requests waiting for the device's answer: what answers each, and its waiter.
    private var waiters: [UUID: (answers: @Sendable (ScrcpyDeviceMessage) -> Bool,
                                 continuation: CheckedContinuation<ScrcpyDeviceMessage, any Error>)] = [:]
    private var sequence: UInt64 = 0

    private let frameSizeChanged: @Sendable (Int, Int) -> Void

    /// `frameSizeChanged` hears of each capture's size, from the session's actor.
    init(target: AndroidScreenTarget, video: ScrcpyVideoOptions, router: SimulatorFrameRouter, session: ScrcpySession,
         frameSizeChanged: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) {
        self.target = target
        self.video = video
        self.frameSizeChanged = frameSizeChanged
        self.session = session
        let (queued, messages) = AsyncStream.makeStream(of: ScrcpyControlMessage.self)
        self.messages = messages
        sender = Task {
            for await message in queued { try? await session.send(message) }
        }
        let device = target.frameDevice
        decoder = AndroidVideoDecoder(output: { frame in
            router.route(SimulatorFrame(device: device, surface: IOSurfaceGetID(frame.surface), fresh: false,
                                        pool: frame.format, pixelWidth: frame.width, pixelHeight: frame.height,
                                        sequence: frame.sequence, drawnAt: frame.decodedAt),
                         surface: frame.surface)
        }, needsKeyFrame: { messages.yield(.resetVideo) })
    }

    /// The size of the frames the stream sends now, which touches are given in.
    var frameSize: (width: Int, height: Int)? { lock.withLock { size } }

    func start(ended: @escaping @Sendable (String?) -> Void) async throws {
        try await session.start(video: { [weak self] event in
            guard let self else { return }
            if case let .session(width, height) = event {
                let changed = self.lock.withLock { () -> Bool in
                    defer { self.size = (width, height) }
                    return self.size.map { $0 != (width, height) } ?? true
                }
                if changed { self.frameSizeChanged(width, height) }
            }
            self.decoder.handle(event)
        }, deviceMessage: { [weak self] message in self?.received(message) }, ended: ended)
    }

    /// A number for a request the device acknowledges, never 0 (scrcpy's "no acknowledgement").
    func nextSequence() -> UInt64 {
        lock.withLock {
            sequence += 1
            return sequence
        }
    }

    /// Sends a control message and waits for the device message that `answers` it, failing after `timeout`.
    func request(_ message: ScrcpyControlMessage, timeout: Duration = .seconds(5),
                 answers: @escaping @Sendable (ScrcpyDeviceMessage) -> Bool) async throws -> ScrcpyDeviceMessage {
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { waiters[id] = (answers, continuation) }
            send(message)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.fail(id, ScrcpyProtocolError("The device did not answer in time"))
            }
        }
    }

    private func received(_ message: ScrcpyDeviceMessage) {
        let waiter = lock.withLock { () -> CheckedContinuation<ScrcpyDeviceMessage, any Error>? in
            guard let id = waiters.first(where: { $0.value.answers(message) })?.key else { return nil }
            return waiters.removeValue(forKey: id)?.continuation
        }
        waiter?.resume(returning: message)
    }

    private func fail(_ id: UUID, _ error: any Error) {
        lock.withLock { waiters.removeValue(forKey: id) }?.continuation.resume(throwing: error)
    }

    func send(_ message: ScrcpyControlMessage) {
        messages.yield(message)
    }

    func stop() async {
        messages.finish()
        sender.cancel()
        let waiting = lock.withLock { () -> [CheckedContinuation<ScrcpyDeviceMessage, any Error>] in
            defer { waiters = [:] }
            return waiters.values.map(\.continuation)
        }
        waiting.forEach { $0.resume(throwing: ScrcpyProtocolError("The emulator's screen stream ended")) }
        await session.stop()
        decoder.close()
    }
}

/// Screenshots of an Android screen: a decoded frame or a PNG from `screencap`, scaled to dp and encoded.
enum AndroidScreenshot {
    static func image(of frame: AndroidVideoDecoder.Frame) -> CGImage? {
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(frame.pixelBuffer, options: nil, imageOut: &image) == noErr else { return nil }
        return image
    }

    static func image(png: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func encode(_ image: CGImage, width: Int, height: Int, format: SimulatorImageFormat) throws -> Data {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw ScrcpyProtocolError("The screenshot could not be drawn")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { throw ScrcpyProtocolError("The screenshot could not be drawn") }
        let data = NSMutableData()
        let type = format == .png ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw ScrcpyProtocolError("The screenshot did not encode")
        }
        // As the iOS host's screenshots.
        let options: [CFString: Any] = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.8] : [:]
        CGImageDestinationAddImage(destination, scaled, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ScrcpyProtocolError("The screenshot did not encode") }
        return data as Data
    }
}
