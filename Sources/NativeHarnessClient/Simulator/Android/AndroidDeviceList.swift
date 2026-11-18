import Foundation

/// A device's state as `adb devices` reports it.
enum AdbDeviceState: Equatable, Sendable {
    /// Ready for commands.
    case device
    /// Connected but not answering: an emulator still starting, or a device going away.
    case offline
    /// A device whose person has not allowed this computer's USB debugging key.
    case unauthorized
    /// Any other state: "no permissions", "recovery", "sideload", "bootloader" and the like.
    case other(String)

    init(_ value: String) {
        switch value {
        case "device": self = .device
        case "offline": self = .offline
        case "unauthorized": self = .unauthorized
        default: self = .other(value)
        }
    }
}

/// A line of `adb devices -l`.
struct AdbDevice: Equatable, Sendable {
    var serial: String
    var state: AdbDeviceState
    /// `usb:`, `product:`, `model:`, `device:`, `transport_id:`.
    var properties: [String: String]

    /// An emulator's console port, which its serial names (`emulator-5554`); nil for a real device, over USB or
    /// `adb connect`. Only an emulator is ever sent a command until real devices are offered.
    var emulatorPort: Int? {
        guard serial.hasPrefix("emulator-"), let port = Int(serial.dropFirst("emulator-".count)) else { return nil }
        return port
    }
}

/// The output of adb and the emulator, and the AVDs' own files.
enum AndroidDeviceList {
    /// `adb devices -l`: a header, then a serial, a state and `key:value` properties on each line.
    static func adbDevices(_ output: String) -> [AdbDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("List of devices"), !line.hasPrefix("*") else { return nil }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 2 else { return nil }
            var properties: [String: String] = [:]
            for field in fields.dropFirst(2) {
                guard let colon = field.firstIndex(of: ":"), colon != field.startIndex,
                      field[..<colon].allSatisfy({ $0.isLetter || $0 == "_" }) else { continue }
                properties[String(field[..<colon])] = String(field[field.index(after: colon)...])
            }
            // "no permissions (…)" is a state of two words and more.
            let state = fields[1] == "no" && fields.count > 2 ? "no permissions" : fields[1]
            return AdbDevice(serial: fields[0], state: AdbDeviceState(state), properties: properties)
        }
    }

    /// `emulator -list-avds`: one AVD name a line. The emulator may print notices on the same output, which an AVD's
    /// name, of letters, digits, `.`, `_` and `-`, never matches.
    static func avdNames(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { name in
            !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
        }
    }

    /// `key=value` lines: an AVD's `<name>.ini` and its `config.ini`.
    static func iniValues(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            if values[key] == nil { values[key] = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces) }
        }
        return values
    }

    /// The API level an AVD's `target` or system image names (`android-34`).
    static func apiLevel(target: String?) -> String? {
        guard let target, let range = target.range(of: #"android-(\d+)"#, options: .regularExpression) else { return nil }
        return String(target[range].dropFirst("android-".count))
    }

    /// The emulator's console answer to `avd name` and the like: the value, then "OK".
    static func consoleValue(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0 != "OK" && !$0.hasPrefix("KO") }
    }

    /// The emulator's process ID in its discovery file's name, which `avd discoverypath` answers
    /// (`…/avd/running/pid_46118.ini`).
    static func processID(discoveryPath: String) -> Int32? {
        guard let range = discoveryPath.range(of: #"pid_(\d+)\.ini"#, options: .regularExpression) else { return nil }
        return Int32(discoveryPath[range].dropFirst("pid_".count).dropLast(".ini".count))
    }
}
