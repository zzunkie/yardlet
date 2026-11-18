import Darwin
import Foundation
import YardletSimulatorHostProtocol

/// The helper's launch settings: the Xcode in `--developer-dir`, and in the environment the Mach bootstrap name and
/// the per-launch token for handing IOSurfaces to Yardlet (YARDLET_SIMULATOR_HOST_PORT, YARDLET_SIMULATOR_HOST_TOKEN
/// as 64 hex digits). Without a port name the helper sends no frames; screenshots and input still work.
struct HostArguments {
    var developerDirectory = ""
    var surfacePortName = ""
    var surfaceToken: [UInt8] = []
    /// Seconds the helper waits after it lets go of its last device before it ends.
    var idleExit: Double = 60

    static func parse(_ arguments: [String] = CommandLine.arguments,
                      environment: [String: String] = ProcessInfo.processInfo.environment) -> HostArguments {
        var result = HostArguments()
        result.surfacePortName = environment["YARDLET_SIMULATOR_HOST_PORT"] ?? ""
        result.surfaceToken = bytes(fromHex: environment["YARDLET_SIMULATOR_HOST_TOKEN"] ?? "")
        var index = 1
        while index < arguments.count {
            let value = index + 1 < arguments.count ? arguments[index + 1] : ""
            switch arguments[index] {
            case "--developer-dir": result.developerDirectory = value; index += 1
            case "--idle-exit": result.idleExit = Double(value) ?? result.idleExit; index += 1
            default: break
            }
            index += 1
        }
        return result
    }

    private static func bytes(fromHex hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex), next > index {
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return [] }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

/// Writes length-prefixed JSON events to the stream Yardlet reads. Standard output is moved to standard error first,
/// so nothing a framework prints can corrupt the event stream.
final class EventOutput: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private let encoder = JSONEncoder()

    init() {
        descriptor = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
    }

    func write(_ event: SimulatorHostEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? SimulatorHostFraming.frame(event, encoder: encoder) else { return }
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written <= 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += written
            }
        }
    }
}

/// Reads length-prefixed JSON commands from standard input on a thread of its own. A message that does not decode
/// into a command is reported and skipped; the end of input means Yardlet is gone.
enum CommandReader {
    static func start(onCommand: @escaping @Sendable (SimulatorHostCommand) -> Void,
                      onInvalid: @escaping @Sendable (String) -> Void,
                      onEnd: @escaping @Sendable () -> Void) {
        let thread = Thread {
            var reader = SimulatorHostFraming.Reader()
            let decoder = JSONDecoder()
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            reading: while true {
                let count = read(STDIN_FILENO, &chunk, chunk.count)
                if count < 0, errno == EINTR { continue }
                if count <= 0 { break }
                do {
                    for message in try reader.append(Data(chunk[0..<count])) {
                        do {
                            onCommand(try decoder.decode(SimulatorHostCommand.self, from: message))
                        } catch {
                            onInvalid("refused a command: \(error)")
                        }
                    }
                } catch {
                    onInvalid("the command stream broke: \(error)")
                    break reading
                }
            }
            onEnd()
        }
        thread.name = "Yardlet simulator host commands"
        thread.start()
    }
}

/// The helper's own lines on standard error, which Yardlet writes to the helper's log.
enum HostLog {
    static func write(_ line: String) {
        FileHandle.standardError.write(Data(("Yardlet Simulator Host: " + line + "\n").utf8))
    }
}
