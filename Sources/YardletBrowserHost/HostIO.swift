import Darwin
import Foundation

/// The browser host's launch settings. Paths come as arguments; the Mach bootstrap name and the
/// per-launch token for IOSurface hand-off come in the environment
/// (YARDLET_BROWSER_HOST_PORT, YARDLET_BROWSER_HOST_TOKEN as 64 hex digits).
struct HostArguments {
    var surfacePortName = ""
    var surfaceToken: [UInt8] = []
    var rootCachePath = ""
    var profilePath = ""
    var downloadsPath = ""
    var locale = "en-US"
    var acceptLanguages = "en-US,en"
    var acceleratedPaint = true
    var frameRate: Int32 = 60
    var switches = ""
    /// DEBUG builds only: a folder where every raw CEF accessibility value is saved (QA fixture).
    var accessibilityRecordPath = ""
    /// DEBUG builds only: the most browsers to open, below the host's own (QA fixture); 0 keeps the host's.
    var browserLimit: Int32 = 0

    static func parse(_ arguments: [String] = CommandLine.arguments,
                      environment: [String: String] = ProcessInfo.processInfo.environment) -> HostArguments {
        var result = HostArguments()
        result.surfacePortName = environment["YARDLET_BROWSER_HOST_PORT"] ?? ""
        result.surfaceToken = Self.bytes(fromHex: environment["YARDLET_BROWSER_HOST_TOKEN"] ?? "")
        var index = 1
        while index < arguments.count {
            let name = arguments[index]
            let value = index + 1 < arguments.count ? arguments[index + 1] : ""
            switch name {
            case "--root-cache": result.rootCachePath = value; index += 1
            case "--profile": result.profilePath = value; index += 1
            case "--downloads": result.downloadsPath = value; index += 1
            case "--locale": result.locale = value; index += 1
            case "--accept-languages": result.acceptLanguages = value; index += 1
            case "--paint": result.acceleratedPaint = value != "software"; index += 1
            case "--frame-rate": result.frameRate = Int32(value) ?? 60; index += 1
            case "--switches": result.switches = value; index += 1
#if DEBUG
            case "--accessibility-record": result.accessibilityRecordPath = value; index += 1
            case "--browser-limit": result.browserLimit = Int32(value) ?? 0; index += 1
#endif
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

/// Paths inside the host bundle (`Yardlet.app/Contents/Frameworks/Yardlet Browser Host.app`), which
/// carries the CEF framework and helper apps in its own Contents/Frameworks. It is CEF's main bundle:
/// the helpers' sandbox profile only lets them read inside it.
struct HostBundleLayout {
    let hostBundle: URL
    let frameworksDirectory: URL

    init(bundle: Bundle = .main) {
        hostBundle = bundle.bundleURL
        frameworksDirectory = hostBundle.appending(path: "Contents/Frameworks", directoryHint: .isDirectory)
    }

    var cefFramework: URL {
        frameworksDirectory.appending(path: "Chromium Embedded Framework.framework", directoryHint: .isDirectory)
    }
    var cefBinary: URL { cefFramework.appending(path: "Chromium Embedded Framework") }
    var helperExecutable: URL {
        frameworksDirectory.appending(path: "Yardlet Helper.app/Contents/MacOS/Yardlet Helper")
    }
}

/// Writes length-prefixed JSON events to the stream Yardlet reads. Standard output is moved to
/// standard error first, so nothing else Chromium prints can corrupt the event stream.
final class EventOutput: @unchecked Sendable {
    private let descriptor: Int32
    /// Events come from the main thread and from the accessibility queue.
    private let lock = NSLock()

    init() {
        descriptor = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
    }

    /// Returns the event's size in bytes.
    @discardableResult
    func write(_ event: [String: Any]) -> Int {
        guard let body = try? JSONSerialization.data(withJSONObject: event) else { return 0 }
        var length = UInt32(body.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(body)
        lock.lock()
        defer { lock.unlock() }
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
        return body.count
    }
}

/// Reads length-prefixed JSON commands from standard input on a background thread and hands each
/// one to the main thread. End of input means Yardlet is gone.
enum CommandReader {
    static func start(onCommand: @escaping @Sendable (Data) -> Void, onEnd: @escaping @Sendable () -> Void) {
        let thread = Thread {
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(STDIN_FILENO, &chunk, chunk.count)
                if count < 0, errno == EINTR { continue }
                if count <= 0 { break }
                buffer.append(chunk, count: count)
                while buffer.count >= 4 {
                    let start = buffer.startIndex
                    let length = buffer[start..<start + 4].reduce(0) { ($0 << 8) | Int($1) }
                    guard buffer.count >= 4 + length else { break }
                    let message = Data(buffer[start + 4..<start + 4 + length])
                    buffer.removeSubrange(start..<start + 4 + length)
                    onCommand(message)
                }
            }
            onEnd()
        }
        thread.name = "Yardlet browser host commands"
        thread.start()
    }
}

/// The host's own lines in host.log (standard error), each after its local time in the form Chromium's lines carry it
/// (`[MMDD/HHMMSS.mmm]`), so that a line reads against what the person saw and when.
enum HostLog {
    static func write(_ line: String) {
        var now = timeval()
        gettimeofday(&now, nil)
        var local = tm()
        var seconds = now.tv_sec
        localtime_r(&seconds, &local)
        let time = String(format: "[%02d%02d/%02d%02d%02d.%03d] ", local.tm_mon + 1, local.tm_mday, local.tm_hour,
                          local.tm_min, local.tm_sec, Int32(now.tv_usec / 1000))
        FileHandle.standardError.write(Data((time + line + "\n").utf8))
    }
}
