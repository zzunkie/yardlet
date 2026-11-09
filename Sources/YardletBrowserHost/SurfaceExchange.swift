import Foundation
import IOSurface
import Metal
import YardletSurfacePort

/// Host-owned IOSurfaces handed to Yardlet. CEF's own paint surfaces come from a pool and are only
/// valid during the paint callback, so every frame is copied into one of these. A surface still on
/// screen in Yardlet (`IOSurfaceIsInUse`) is never overwritten.
@MainActor
final class SurfaceExchange {
    private let remotePort: mach_port_t
    private let token: [UInt8]
    private var rings: [String: SurfaceRing] = [:]
    private let device = MTLCreateSystemDefaultDevice()
    private lazy var queue = device?.makeCommandQueue()
    private(set) var copyMilliseconds: [Double] = []
    private(set) var sendFailures = 0

    init?(portName: String, token: [UInt8]) {
        var port: mach_port_t = 0
        guard token.count == Int(YardletSurfaceTokenLength),
              yardlet_surface_port_look_up(portName, &port) == KERN_SUCCESS else { return nil }
        remotePort = port
        self.token = token
    }

    /// Copies a CPU paint (BGRA, top-left origin) and returns the surface Yardlet should show.
    func surface(copyingBuffer buffer: UnsafeRawPointer, width: Int, height: Int, key: String) -> IOSurfaceRef? {
        let start = DispatchTime.now().uptimeNanoseconds
        guard let target = ring(for: key, width: width, height: height, pixelFormat: SurfaceRing.bgra).next() else { return nil }
        IOSurfaceLock(target, [], nil)
        let destination = IOSurfaceGetBaseAddress(target)
        let destinationRowBytes = IOSurfaceGetBytesPerRow(target)
        let sourceRowBytes = width * 4
        for row in 0..<height {
            memcpy(destination + row * destinationRowBytes, buffer + row * sourceRowBytes, sourceRowBytes)
        }
        IOSurfaceUnlock(target, [], nil)
        record(since: start)
        return deliver(target, in: rings[key])
    }

    /// Copies a GPU paint with a Metal blit and waits for it, because CEF reuses the source as
    /// soon as the paint callback returns.
    func surface(copyingSurface source: IOSurfaceRef, format: Int32, key: String) -> IOSurfaceRef? {
        let start = DispatchTime.now().uptimeNanoseconds
        let width = IOSurfaceGetWidth(source)
        let height = IOSurfaceGetHeight(source)
        let isRGBA = format == 0
        let pixelFormat: MTLPixelFormat = isRGBA ? .rgba8Unorm : .bgra8Unorm
        guard let device, let queue,
              let target = ring(for: key, width: width, height: height,
                                pixelFormat: isRGBA ? SurfaceRing.rgba : SurfaceRing.bgra).next() else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let sourceTexture = device.makeTexture(descriptor: descriptor, iosurface: source, plane: 0),
              let targetTexture = device.makeTexture(descriptor: descriptor, iosurface: target, plane: 0),
              let commands = queue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: sourceTexture, to: targetTexture)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        record(since: start)
        return deliver(target, in: rings[key])
    }

    /// Drops a layer's ring. Its surfaces live on only while Yardlet still shows one; an IOSurface
    /// ID freed this way can come back on a new surface, which is then sent again because the new
    /// ring has not sent it.
    func forget(key: String) {
        rings.removeValue(forKey: key)
    }

    private func ring(for key: String, width: Int, height: Int, pixelFormat: OSType) -> SurfaceRing {
        if let ring = rings[key], ring.width == width, ring.height == height, ring.pixelFormat == pixelFormat {
            return ring
        }
        let ring = SurfaceRing(width: width, height: height, pixelFormat: pixelFormat)
        rings[key] = ring
        return ring
    }

    /// Sends the surface's port to Yardlet the first time this ring delivers it.
    private func deliver(_ surface: IOSurfaceRef, in ring: SurfaceRing?) -> IOSurfaceRef? {
        guard let ring else { return nil }
        if !ring.wasSent(surface) {
            let started = DispatchTime.now().uptimeNanoseconds
            let result = yardlet_surface_port_send(remotePort, surface, token)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            if elapsed > 50 {
                HostLog.write(String(format: "surface send took %.0f ms (result %d)", elapsed, result))
            }
            guard result == KERN_SUCCESS else {
                sendFailures += 1
                return nil
            }
            ring.markSent(surface)
        }
        return surface
    }

    private func record(since start: UInt64) {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        if elapsed > 50 { HostLog.write(String(format: "frame copy took %.0f ms", elapsed)) }
        copyMilliseconds.append(elapsed)
        if copyMilliseconds.count > 5000 { copyMilliseconds.removeFirst(1000) }
    }
}

/// Up to four same-sized surfaces used in turn, skipping any the window server still shows.
@MainActor
final class SurfaceRing {
    static let bgra: OSType = 0x4247_5241  // 'BGRA'
    static let rgba: OSType = 0x5247_4241  // 'RGBA'
    static let capacity = 4

    let width: Int
    let height: Int
    let pixelFormat: OSType
    private var surfaces: [(surface: IOSurfaceRef, lastUsed: UInt64, sent: Bool)] = []
    private var counter: UInt64 = 0

    init(width: Int, height: Int, pixelFormat: OSType) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
    }

    func next() -> IOSurfaceRef? {
        counter += 1
        let byAge = surfaces.indices.sorted { surfaces[$0].lastUsed < surfaces[$1].lastUsed }
        // Never the most recent one: Yardlet may not have shown it yet.
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

    func wasSent(_ surface: IOSurfaceRef) -> Bool {
        surfaces.first { $0.surface === surface }?.sent ?? false
    }

    func markSent(_ surface: IOSurfaceRef) {
        guard let index = surfaces.firstIndex(where: { $0.surface === surface }) else { return }
        surfaces[index].sent = true
    }
}
