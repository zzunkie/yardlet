import Foundation
import YardletRemote

/// The JSON a `calendar` call carries each way (docs/REMOTE_PROTOCOL.md §15.38), in the calendar's own shapes, which
/// both Macs build from the same code.
enum RemoteCalendarWire {
    /// `accounts`: the host's calendar accounts, and the calendars the person showed or hid there.
    struct Accounts: Codable, Equatable {
        var accounts: [CalendarAccount]
        var choices: [String: Bool]
        var showsSchedules: Bool
    }

    /// The arguments of `calendars`, `events` and `respond`.
    struct Call: Codable, Equatable {
        var accountID: UUID
        var calendar: CalendarInfo? = nil
        var from: Date? = nil
        var to: Date? = nil
        var event: CalendarEvent? = nil
        var response: CalendarResponse? = nil
    }

    /// The longest range `events` reads at once: the calendar reads a week, or a day and the six after it.
    static let maxRange: TimeInterval = 62 * 86_400

    static func encode<Value: Encodable>(_ value: Value) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    static func decode<Value: Decodable>(_ type: Value.Type, _ data: Data?) throws -> Value {
        guard let data else { throw RemoteError(.badRequest, "Missing data") }
        do { return try JSONDecoder().decode(type, from: data) } catch { throw RemoteError(.badRequest, "Invalid data") }
    }
}
