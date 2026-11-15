import Foundation
import WinSDK

/// The time zone Windows is set to, for Foundation (docs/PLATFORM_PORTABILITY.md, "The Windows app").
///
/// Foundation on Windows names the current time zone from `GetTimeZoneInformation`'s `StandardName` (confirmed in
/// swift-foundation's source), which Windows writes in its display language, Korean on a Korean PC, while ICU maps
/// only the zone's registry name, "Korea Standard Time". On such a PC `TimeZone.current` is GMT, so a chat's
/// folder, a schedule and every time the app shows were a day or hours off. The system's ICU (`icu.dll`, Windows 10
/// 1903 and later) reads the zone by its registry name and the region and names it as Foundation does
/// (`Asia/Seoul`). Foundation reads `TZ` before Windows' setting and keeps the zone it found, so `TZ` names that zone
/// only while Foundation reads it again and is then taken away: no program the app starts inherits it, where a C
/// runtime that reads `TZ` its own way would take `Asia/Seoul` for UTC. Nothing changes when `TZ` is already set or
/// the system's ICU is missing.
enum WindowsTimeZone {
    /// Run before anything else reads a time; says what Foundation reads now, for the event log.
    static func adopt() -> String {
        if let set = ProcessInfo.processInfo.environment["TZ"] { return "time zone: \(TimeZone.current.identifier) (TZ \(set))" }
        guard let identifier = systemIdentifier() else { return "time zone: \(TimeZone.current.identifier) (no system ICU)" }
        setTZ(identifier)
        NSTimeZone.resetSystemTimeZone()
        let found = TimeZone.current.identifier
        setTZ(nil)
        return "time zone: \(found)"
    }

    private static func setTZ(_ value: String?) {
        "TZ".withCString(encodedAs: UTF16.self) { name in
            if let value {
                _ = value.withCString(encodedAs: UTF16.self) { SetEnvironmentVariableW(name, $0) }
            } else {
                _ = SetEnvironmentVariableW(name, nil)
            }
        }
    }

    /// ICU's `ucal_getDefaultTimeZone`: the IANA name of the zone Windows is set to.
    private typealias DefaultTimeZone = @convention(c) (UnsafeMutablePointer<UInt16>?, Int32, UnsafeMutablePointer<Int32>?) -> Int32

    private static func systemIdentifier() -> String? {
        let places = DWORD(LOAD_LIBRARY_SEARCH_SYSTEM32)
        guard let module = "icu.dll".withCString(encodedAs: UTF16.self, { LoadLibraryExW($0, nil, places) }),
              let address = GetProcAddress(module, "ucal_getDefaultTimeZone") else { return nil }
        let defaultTimeZone = unsafeBitCast(address, to: DefaultTimeZone.self)
        var name = [UInt16](repeating: 0, count: 128)
        var status: Int32 = 0
        let length = defaultTimeZone(&name, Int32(name.count), &status)
        // A UErrorCode above zero is a failure; below zero, a warning.
        guard status <= 0, length > 0, Int(length) <= name.count else { return nil }
        let identifier = String(decoding: name.prefix(Int(length)), as: UTF16.self)
        return TimeZone(identifier: identifier) == nil ? nil : identifier
    }
}
