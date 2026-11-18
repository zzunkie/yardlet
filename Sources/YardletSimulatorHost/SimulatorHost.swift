import CoreGraphics
import Foundation
import YardletSimulatorHostProtocol

/// Takes Yardlet's commands, keeps a session for each attached device and ends the helper a while after the last
/// device is let go. Commands are taken in order on one queue; each session's work runs on the session's own queues.
final class SimulatorHost: @unchecked Sendable {
    private let kit: SimulatorKit
    private let output: EventOutput
    private let surfacePort: SurfacePort?
    private let copier = FrameCopier()
    private let idleExit: Double
    private let queue = DispatchQueue(label: "Yardlet simulator host")
    private let screenshotQueue = DispatchQueue(label: "Yardlet simulator host screenshots", qos: .userInitiated,
                                                attributes: .concurrent)
    // On `queue`.
    private var sessions: [UUID: DeviceSession] = [:]
    private var deviceSet: AnyObject?
    private var idleTimer: DispatchWorkItem?

    init(kit: SimulatorKit, output: EventOutput, surfacePort: SurfacePort?, idleExit: Double) {
        self.kit = kit
        self.output = output
        self.surfacePort = surfacePort
        self.idleExit = idleExit
        queue.async { self.scheduleIdleExit() }
    }

    func receive(_ command: SimulatorHostCommand) {
        queue.async { [self] in handle(command) }
    }

    private func handle(_ command: SimulatorHostCommand) {
        switch command {
        case .attach(let device):
            attach(device)
        case .detach(let device):
            detach(device, reason: "Yardlet let go of the device")
        case .startFrames(let device, let subscription, let width, let height):
            session(device)?.startFrames(subscription: subscription, pixelWidth: width, pixelHeight: height)
        case .stopFrames(let device, let subscription):
            sessions[device]?.stopFrames(subscription: subscription)
        case .screenshot(let request, let device, let format):
            guard let session = sessions[device] else {
                output.write(.requestFailed(request: request, message: "the helper has not attached \(device.uuidString)"))
                return
            }
            screenshotQueue.async { [output] in
                do {
                    output.write(.screenshot(request: request, image: try session.screenshot(format: format)))
                } catch {
                    output.write(.requestFailed(request: request, message: "\(error)"))
                }
            }
        case .touch(let device, let phase, let point):
            session(device)?.perform { try $0.touch(phase, at: point) }
        case .button(let device, let button, let phase):
            session(device)?.perform { try $0.button(button, phase) }
        case .key(let device, let usage, let phase):
            session(device)?.perform { try $0.key(usage, phase) }
        case .typeText(let device, let text):
            session(device)?.perform { try $0.type(text) }
        case .diagnose(let request):
            // A preflight asks the person nothing and records nothing. (AXIsProcessTrusted, by contrast, puts a process
            // responsible for itself in the Accessibility list of Privacy & Security.)
            output.write(.diagnosis(request: request, processID: getpid(), screenCaptureAccess: CGPreflightScreenCaptureAccess(),
                                    homeReadable: Self.canReadHome(), networkReachable: Self.canReachNetwork()))
        }
    }

    /// Whether a folder in the home folder opens: ~/Library/Preferences, which no privacy permission guards.
    private static func canReadHome() -> Bool {
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { return false }
        guard let folder = opendir(String(cString: home) + "/Library/Preferences") else { return false }
        closedir(folder)
        return true
    }

    /// Whether a connection may start: to the loopback discard port, which no one answers, so nothing is sent. The
    /// sandbox refuses the connection itself (EPERM); otherwise it is refused by the port or still under way.
    private static func canReachNetwork() -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(9).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0 || (errno != EPERM && errno != EACCES)
    }

    private func session(_ device: UUID) -> DeviceSession? {
        if let session = sessions[device] { return session }
        output.write(.commandFailed(device: device, message: "the helper has not attached \(device.uuidString)"))
        return nil
    }

    private func attach(_ id: UUID) {
        if let session = sessions[id] {
            // Again: the device's screen as it is now.
            session.end()
            sessions[id] = nil
        }
        do {
            let device = try findDevice(id)
            guard ObjC.uint64(device, "state") == DeviceSession.booted else { throw HostError("the device is not booted") }
            let session = try DeviceSession(id: id, device: device, kit: kit, output: output, surfacePort: surfacePort,
                                            copier: copier) { [weak self] id in
                guard let self else { return }
                self.queue.async { self.detach(id, reason: "the device shut down") }
            }
            sessions[id] = session
            idleTimer?.cancel()
            idleTimer = nil
            do {
                try session.start()
            } catch {
                session.end()
                sessions[id] = nil
                throw error
            }
        } catch {
            output.write(.deviceFailed(device: id, message: "\(error)"))
            if sessions.isEmpty { scheduleIdleExit() }
        }
    }

    private func detach(_ id: UUID, reason: String) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        session.end()
        output.write(.detached(device: id, reason: reason))
        if sessions.isEmpty { scheduleIdleExit() }
    }

    private func findDevice(_ id: UUID) throws -> AnyObject {
        if deviceSet == nil {
            typealias Context = @convention(c) (AnyClass, Selector, NSString, UnsafeMutablePointer<Unmanaged<NSError>?>?) -> Unmanaged<AnyObject>?
            typealias DeviceSet = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Unmanaged<NSError>?>?) -> Unmanaged<AnyObject>?
            let contextSelector = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
            let makeContext = unsafeBitCast(
                class_getMethodImplementation(object_getClass(kit.serviceContextClass), contextSelector)!, to: Context.self)
            var error: Unmanaged<NSError>?
            guard let context = makeContext(kit.serviceContextClass, contextSelector, kit.developerDirectory as NSString, &error)?
                .takeUnretainedValue() else {
                throw HostError("CoreSimulator did not start: \(error?.takeUnretainedValue().localizedDescription ?? "no reason given")")
            }
            let (makeSet, setSelector) = ObjC.implementation(context, "defaultDeviceSetWithError:", as: DeviceSet.self)
            guard let set = makeSet(context, setSelector, &error)?.takeUnretainedValue() else {
                throw HostError("CoreSimulator has no device set: \(error?.takeUnretainedValue().localizedDescription ?? "no reason given")")
            }
            deviceSet = set
        }
        guard let devices = ObjC.object(deviceSet!, "devicesByUDID") as? NSDictionary,
              let device = devices[id as NSUUID] as AnyObject? else {
            throw HostError("no simulator has the ID \(id.uuidString)")
        }
        return device
    }

    /// On `queue`.
    private func scheduleIdleExit() {
        idleTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.sessions.isEmpty else { return }
            HostLog.write("no device for \(Int(self.idleExit)) seconds; ending")
            exit(0)
        }
        idleTimer = timer
        queue.asyncAfter(deadline: .now() + idleExit, execute: timer)
    }

    /// Lets go of every device, for the end of the helper.
    func endAll() {
        queue.sync {
            for session in sessions.values { session.end() }
            sessions.removeAll()
        }
    }
}
