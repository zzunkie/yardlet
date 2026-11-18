// Yardlet Simulator Host: shows and drives iOS simulators for Yardlet through Xcode's SimulatorKit, outside Yardlet,
// so a change in Xcode's private frameworks can end this helper but not Yardlet. Yardlet starts it with pipes on
// standard input and output, the Xcode to use, and a Mach bootstrap name for IOSurfaces; the end of input ends it.
// It holds no permission of its own: Yardlet starts it as responsible for itself, so it inherits none of Yardlet's.

import Darwin
import Foundation
import YardletSimulatorHostProtocol

// An event written after Yardlet is gone fails with EPIPE instead of ending the helper mid-write.
signal(SIGPIPE, SIG_IGN)

let arguments = HostArguments.parse()
let output = EventOutput()

guard !arguments.developerDirectory.isEmpty else {
    HostLog.write("no --developer-dir")
    exit(2)
}

let kit: SimulatorKit
switch SimulatorKit.load(developerDirectory: arguments.developerDirectory) {
case .loaded(let loaded):
    kit = loaded
case .unsupported(let xcode, let missing):
    HostLog.write("Xcode \(xcode) lacks \(missing.joined(separator: ", "))")
    output.write(.unsupported(xcode: xcode, missing: missing))
    exit(3)
}

let surfacePort = SurfacePort(name: arguments.surfacePortName, token: arguments.surfaceToken)
if surfacePort == nil, !arguments.surfacePortName.isEmpty {
    HostLog.write("Mach bootstrap name \(arguments.surfacePortName) was not found; no frames will be sent")
}
let host = SimulatorHost(kit: kit, output: output, surfacePort: surfacePort, idleExit: arguments.idleExit)
output.write(.ready(xcode: kit.xcodeVersion, capabilities: kit.capabilities))

CommandReader.start(
    onCommand: { host.receive($0) },
    onInvalid: { HostLog.write($0) },
    onEnd: {
        host.endAll()
        exit(0)
    }
)

let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
signal(SIGTERM, SIG_IGN)
terminate.setEventHandler {
    host.endAll()
    exit(0)
}
terminate.resume()

dispatchMain()
