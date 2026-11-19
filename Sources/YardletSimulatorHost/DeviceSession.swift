import CoreGraphics
import Foundation
import ImageIO
import IOSurface
import UniformTypeIdentifiers
import YardletSimulatorHostProtocol

/// One device the helper shows and drives: its shown screen, the frames copied for Yardlet, screenshots and input.
/// Frames and screen changes run on the session's queue; input runs on a queue of its own, so a screenshot or a copy
/// never holds up a touch.
final class DeviceSession: @unchecked Sendable {
    let id: UUID
    private let kit: SimulatorKit
    private let device: AnyObject
    private let output: EventOutput
    private let surfacePort: SurfacePort?
    private let copier: FrameCopier?
    private let queue: DispatchQueue
    private let inputQueue: DispatchQueue
    private let input: HIDInput
    private let callbackID = UUID()
    private let scale: Double
    private let onShutdown: @Sendable (UUID) -> Void
    private var notificationHandler: UInt64 = 0

    // On `queue`.
    private var screenDescriptor: AnyObject?
    private var screen: SimulatorScreen?
    private var framebuffer: IOSurfaceRef?
    private var subscriptions: [Int: CGSize] = [:]
    private var pool: SurfacePool?
    private var poolGeneration: UInt64 = 0
    private var copying = false
    private var copyAgain = false
    private var sequence: UInt64 = 0
    private var ended = false

    init(id: UUID, device: AnyObject, kit: SimulatorKit, output: EventOutput, surfacePort: SurfacePort?, copier: FrameCopier?,
         onShutdown: @escaping @Sendable (UUID) -> Void) throws {
        self.id = id
        self.device = device
        self.kit = kit
        self.output = output
        self.surfacePort = surfacePort
        self.copier = copier
        self.onShutdown = onShutdown
        let label = "Yardlet simulator \(id.uuidString.prefix(8))"
        queue = DispatchQueue(label: label)
        inputQueue = DispatchQueue(label: label + " input", qos: .userInteractive)
        let type = ObjC.object(device, "deviceType")
        scale = type.map { Double(ObjC.float($0, "mainScreenScale")) }.flatMap { $0 > 0 ? $0 : nil } ?? 1
        input = try HIDInput(kit: kit, device: device)
    }

    /// Finds the shown screen and starts following it. Answers with `attached` or throws.
    func start() throws {
        try queue.sync {
            guard let (descriptor, screen) = shownScreen() else { throw HostError("the device shows no screen") }
            follow(descriptor, screen: screen)
        }
        watchState()
        output.write(.attached(device: id, screen: queue.sync { screen! }))
    }

    /// Stops following the screen and the device; frames still in flight are dropped.
    func end() {
        queue.sync {
            guard !ended else { return }
            ended = true
            unfollowScreen()
            subscriptions.removeAll()
            pool = nil
        }
        if notificationHandler != 0 {
            typealias Unregister = @convention(c) (AnyObject, Selector, UInt64, UnsafeMutablePointer<Unmanaged<NSError>?>?) -> ObjCBool
            let (unregister, selector) = ObjC.implementation(device, "unregisterNotificationHandler:error:", as: Unregister.self)
            _ = unregister(device, selector, notificationHandler, nil)
            notificationHandler = 0
        }
    }

    // MARK: Frames

    func startFrames(subscription: Int, pixelWidth: Int, pixelHeight: Int) {
        queue.async { [self] in
            guard !ended else { return }
            subscriptions[subscription] = CGSize(width: max(1, pixelWidth), height: max(1, pixelHeight))
            // The screen as it is now: the device sends nothing until something on it changes.
            frameDrawn()
        }
    }

    func stopFrames(subscription: Int) {
        queue.async { [self] in
            subscriptions[subscription] = nil
            if subscriptions.isEmpty { pool = nil }
        }
    }

    /// On `queue`, for each frame the device draws: one copy at a time, and at most one more after it, however many
    /// frames came meanwhile.
    private func frameDrawn() {
        guard !ended, !subscriptions.isEmpty else { return }
        if copying {
            copyAgain = true
            return
        }
        copyFrame()
    }

    private func copyFrame() {
        guard let copier, let surfacePort, let framebuffer, FrameCopier.pixelFormat(of: framebuffer) != nil,
              let size = FrameCopier.targetSize(screen: CGSize(width: IOSurfaceGetWidth(framebuffer), height: IOSurfaceGetHeight(framebuffer)),
                                                boxes: Array(subscriptions.values)) else { return }
        let format = IOSurfaceGetPixelFormat(framebuffer)
        if pool == nil || pool!.width != size.width || pool!.height != size.height || pool!.pixelFormat != format {
            poolGeneration += 1
            pool = SurfacePool(width: size.width, height: size.height, pixelFormat: format, generation: poolGeneration)
        }
        guard let current = pool, let target = current.next() else { return }
        // Both are used on `queue` alone, once the copy is done.
        nonisolated(unsafe) let copyPool = current, copyTarget = target
        copying = true
        sequence += 1
        let frameSequence = sequence, drawnAt = DispatchTime.now().uptimeNanoseconds
        copier.copy(framebuffer, into: target) { [self] copied in
            queue.async { [self] in
                copying = false
                if copied, !ended, pool === copyPool, let fresh = copyPool.sendIfNew(copyTarget, through: surfacePort) {
                    output.write(.frame(SimulatorFrame(device: id, surface: IOSurfaceGetID(copyTarget), fresh: fresh,
                                                       pool: copyPool.generation, pixelWidth: copyPool.width, pixelHeight: copyPool.height,
                                                       sequence: frameSequence, drawnAt: drawnAt)))
                }
                if copyAgain {
                    copyAgain = false
                    frameDrawn()
                }
            }
        }
    }

    // MARK: Screenshots

    /// The screen at the device's size in points. The device may draw while the pixels are read, so the read is
    /// repeated until the surface's seed shows no change across it.
    /// The app in front's accessibility elements, in points.
    func accessibilityElements(with tree: AccessibilityTree) throws
        -> (elements: [SimulatorAccessibilityElement], truncated: Bool) {
        try tree.elements(of: device)
    }

    func screenshot(format: SimulatorImageFormat) throws -> SimulatorScreenshot {
        guard let surface = queue.sync(execute: { framebuffer }) else { throw HostError("the device shows no screen") }
        guard FrameCopier.pixelFormat(of: surface) != nil else { throw HostError("the screen's pixel format is not one the helper reads") }
        let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
        let rowBytes = width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        var steady = false
        for _ in 0..<5 where !steady {
            IOSurfaceLock(surface, .readOnly, nil)
            let before = IOSurfaceGetSeed(surface)
            let base = IOSurfaceGetBaseAddress(surface)
            let sourceRowBytes = IOSurfaceGetBytesPerRow(surface)
            pixels.withUnsafeMutableBytes { destination in
                for row in 0..<height {
                    memcpy(destination.baseAddress! + row * rowBytes, base + row * sourceRowBytes, rowBytes)
                }
            }
            steady = IOSurfaceGetSeed(surface) == before
            IOSurfaceUnlock(surface, .readOnly, nil)
        }
        let isRGBA = IOSurfaceGetPixelFormat(surface) == FrameCopier.rgba
        let bitmapInfo: UInt32 = isRGBA
            ? CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            : CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                                  space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
                                  decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw HostError("the screen's pixels made no image")
        }
        let pointWidth = max(1, Int((Double(width) / scale).rounded())), pointHeight = max(1, Int((Double(height) / scale).rounded()))
        guard let context = CGContext(data: nil, width: pointWidth, height: pointHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw HostError("no room for the screenshot")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: pointWidth, height: pointHeight))
        guard let scaled = context.makeImage() else { throw HostError("the screenshot did not scale") }
        let data = NSMutableData()
        let type = format == .png ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw HostError("no \(format.rawValue) encoder")
        }
        let options: [CFString: Any] = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.8] : [:]
        CGImageDestinationAddImage(destination, scaled, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw HostError("the screenshot did not encode") }
        return SimulatorScreenshot(device: id, format: format, width: pointWidth, height: pointHeight, data: data as Data)
    }

    // MARK: Input

    /// Runs input in the order it came, on the input queue.
    func perform(_ action: @escaping @Sendable (HIDInput) throws -> Void) {
        inputQueue.async { [self] in
            do {
                try action(input)
            } catch {
                output.write(.commandFailed(device: id, message: "\(error)"))
            }
        }
    }

    // MARK: Screens

    /// The screen to show: the built-in one (screen type 0) that is on, the lowest ID first. A device with two such
    /// screens, inner and outer, has one on at a time.
    private func shownScreen() -> (AnyObject, SimulatorScreen)? {
        guard let io = ObjC.object(device, "io"), let ports = ObjC.object(io, "ioPorts") as? [AnyObject] else { return nil }
        var candidates: [(descriptor: AnyObject, properties: AnyObject, id: UInt32, on: Bool)] = []
        for port in ports {
            guard let descriptor = ObjC.object(port, "descriptor"),
                  ObjC.conforms(descriptor, to: "SimScreen"), ObjC.conforms(descriptor, to: "SimDisplayIOSurfaceRenderable"),
                  let properties = ObjC.object(descriptor, "screenProperties"),
                  ObjC.uint64(properties, "screenType") == 0 else { continue }
            candidates.append((descriptor, properties, ObjC.uint32(properties, "screenID"), ObjC.int32(properties, "powerState") != 0))
        }
        guard let chosen = candidates.sorted(by: { ($0.on ? 0 : 1, $0.id) < ($1.on ? 0 : 1, $1.id) }).first else { return nil }
        let pixels = ObjC.size(chosen.properties, "pixelSize")
        return (chosen.descriptor, SimulatorScreen(screenID: chosen.id, pixelWidth: Int(pixels.width), pixelHeight: Int(pixels.height),
                                                   scale: scale))
    }

    /// On `queue`.
    private func follow(_ descriptor: AnyObject, screen: SimulatorScreen) {
        unfollowScreen()
        screenDescriptor = descriptor
        self.screen = screen
        framebuffer = ObjC.object(descriptor, "framebufferSurface").map { unsafeDowncast($0, to: IOSurfaceRef.self) }
        typealias Register = @convention(c) (AnyObject, Selector, NSUUID, DispatchQueue,
                                             @escaping @convention(block) () -> Void,
                                             @escaping @convention(block) (AnyObject?, AnyObject?) -> Void,
                                             @escaping @convention(block) (AnyObject?) -> Void) -> Void
        let (register, selector) = ObjC.implementation(
            descriptor, "registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:",
            as: Register.self)
        register(descriptor, selector, callbackID as NSUUID, queue,
                 { [weak self] in self?.frameDrawn() },
                 { [weak self] surface, _ in self?.surfacesChanged(surface) },
                 { [weak self] _ in self?.screensChanged() })
    }

    private func unfollowScreen() {
        guard let descriptor = screenDescriptor else { return }
        typealias Unregister = @convention(c) (AnyObject, Selector, NSUUID) -> Void
        let (unregister, selector) = ObjC.implementation(descriptor, "unregisterScreenCallbacksWithUUID:", as: Unregister.self)
        unregister(descriptor, selector, callbackID as NSUUID)
        screenDescriptor = nil
        framebuffer = nil
    }

    /// On `queue`: the screen draws into another surface now (it changed size, or it was set up again).
    private func surfacesChanged(_ surface: AnyObject?) {
        framebuffer = surface.map { unsafeDowncast($0, to: IOSurfaceRef.self) }
            ?? screenDescriptor.flatMap { ObjC.object($0, "framebufferSurface") }.map { unsafeDowncast($0, to: IOSurfaceRef.self) }
        frameDrawn()
    }

    /// On `queue`: a screen's properties changed. A device with two screens may have turned to the other one.
    private func screensChanged() {
        guard !ended, let (descriptor, shown) = shownScreen(), shown != screen else { return }
        if shown.screenID != screen?.screenID {
            follow(descriptor, screen: shown)
            frameDrawn()
        }
        screen = shown
        output.write(.screenChanged(device: id, screen: shown))
    }

    /// Lets go of the device once it leaves the booted state.
    private func watchState() {
        typealias Register = @convention(c) (AnyObject, Selector, DispatchQueue, @escaping @convention(block) (NSDictionary?) -> Void)
            -> UInt64
        let (register, selector) = ObjC.implementation(device, "registerNotificationHandlerOnQueue:handler:", as: Register.self)
        let id = id, onShutdown = onShutdown, device = device
        notificationHandler = register(device, selector, queue) { _ in
            if ObjC.uint64(device, "state") != DeviceSession.booted { onShutdown(id) }
        }
    }

    /// SimDevice's state while booted.
    static let booted: UInt64 = 3
}
