import CoreGraphics
import Foundation
import IOSurface
import Metal
import MetalPerformanceShaders
import YardletSurfacePort

/// Copies a device's screen into the helper's own surfaces with the GPU, scaled to the size Yardlet asked for. The
/// simulator draws in place into one IOSurface; a copy of each drawn frame keeps Yardlet's layer from showing a frame
/// half drawn, and the scaling keeps the copy no larger than the panel that shows it.
final class FrameCopier: @unchecked Sendable {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let scaler: MPSImageLanczosScale

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        scaler = MPSImageLanczosScale(device: device)
    }

    /// Starts copying `source` into `target` and calls `completion` on Metal's thread once the copy is done.
    func copy(_ source: IOSurfaceRef, into target: IOSurfaceRef, completion: @escaping @Sendable (Bool) -> Void) {
        guard let format = Self.pixelFormat(of: source), Self.pixelFormat(of: target) == format,
              let sourceTexture = texture(source, format: format, usage: [.shaderRead]),
              let targetTexture = texture(target, format: format, usage: [.shaderRead, .shaderWrite]),
              let commands = queue.makeCommandBuffer() else {
            completion(false)
            return
        }
        if sourceTexture.width == targetTexture.width, sourceTexture.height == targetTexture.height {
            guard let blit = commands.makeBlitCommandEncoder() else {
                completion(false)
                return
            }
            blit.copy(from: sourceTexture, to: targetTexture)
            blit.endEncoding()
        } else {
            scaler.encode(commandBuffer: commands, sourceTexture: sourceTexture, destinationTexture: targetTexture)
        }
        commands.addCompletedHandler { buffer in completion(buffer.status == .completed) }
        commands.commit()
    }

    private func texture(_ surface: IOSurfaceRef, format: MTLPixelFormat, usage: MTLTextureUsage) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface), mipmapped: false)
        descriptor.usage = usage
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
    }

    static let bgra: OSType = 0x4247_5241  // 'BGRA'
    static let rgba: OSType = 0x5247_4241  // 'RGBA'

    static func pixelFormat(of surface: IOSurfaceRef) -> MTLPixelFormat? {
        switch IOSurfaceGetPixelFormat(surface) {
        case bgra: .bgra8Unorm
        case rgba: .rgba8Unorm
        default: nil
        }
    }

    /// The largest size of the screen's shape within every box asked for, and never larger than the screen.
    static func targetSize(screen: CGSize, boxes: [CGSize]) -> (width: Int, height: Int)? {
        guard screen.width > 0, screen.height > 0, !boxes.isEmpty else { return nil }
        let width = boxes.map(\.width).max()!, height = boxes.map(\.height).max()!
        let scale = min(1, width / screen.width, height / screen.height)
        return (max(1, Int((screen.width * scale).rounded())), max(1, Int((screen.height * scale).rounded())))
    }
}

/// Three same-sized surfaces used in turn for one device's frames, skipping the newest (Yardlet may not have shown it
/// yet) and any the window server still shows. Each goes to Yardlet over the Mach port once.
final class SurfacePool {
    static let capacity = 3
    let width: Int
    let height: Int
    let pixelFormat: OSType
    let generation: UInt64
    private var surfaces: [(surface: IOSurfaceRef, lastUsed: UInt64, sent: Bool)] = []
    private var counter: UInt64 = 0

    init(width: Int, height: Int, pixelFormat: OSType, generation: UInt64) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.generation = generation
    }

    func next() -> IOSurfaceRef? {
        counter += 1
        let byAge = surfaces.indices.sorted { surfaces[$0].lastUsed < surfaces[$1].lastUsed }
        if let index = byAge.dropLast().first(where: { !IOSurfaceIsInUse(surfaces[$0].surface) })
            ?? (surfaces.count >= Self.capacity ? byAge.first : nil) {
            surfaces[index].lastUsed = counter
            return surfaces[index].surface
        }
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfacePixelFormat: pixelFormat
        ]
        guard let surface = IOSurfaceCreate(properties as CFDictionary) else { return nil }
        surfaces.append((surface, counter, false))
        return surface
    }

    /// Sends the surface's port the first time; true when it was sent now.
    func sendIfNew(_ surface: IOSurfaceRef, through port: SurfacePort) -> Bool? {
        guard let index = surfaces.firstIndex(where: { $0.surface === surface }) else { return nil }
        if surfaces[index].sent { return false }
        guard port.send(surface) else { return nil }
        surfaces[index].sent = true
        return true
    }
}

/// The send side of the Mach port Yardlet checked in for this launch.
final class SurfacePort: @unchecked Sendable {
    private let remotePort: mach_port_t
    private let token: [UInt8]
    private let lock = NSLock()

    init?(name: String, token: [UInt8]) {
        var port: mach_port_t = 0
        guard !name.isEmpty, token.count == Int(YardletSurfaceTokenLength),
              yardlet_surface_port_look_up(name, &port) == KERN_SUCCESS else { return nil }
        remotePort = port
        self.token = token
    }

    func send(_ surface: IOSurfaceRef) -> Bool {
        lock.withLock { yardlet_surface_port_send(remotePort, surface, token) == KERN_SUCCESS }
    }
}
