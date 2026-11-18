import Foundation

/// Loopback connections for the scrcpy session's adb tunnel are the Mac's alone so far (`Platform/macOS`).
struct LiveLoopbackSockets: LoopbackSocketOpening {
    func open(port: Int) async throws -> any LoopbackSocket {
        throw ScrcpyProtocolError("Device screens are not available on this platform yet")
    }
}
