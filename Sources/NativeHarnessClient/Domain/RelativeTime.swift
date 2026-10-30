import Foundation

/// "now" and "11 hr. ago" in the person's language. Apple's Foundation says them with
/// `RelativeDateTimeFormatter`; Foundation elsewhere has only `Date.RelativeFormatStyle`.
enum RelativeTime {
    /// "now", as a time that has come.
    static func now(locale: Locale = .current) -> String {
        #if canImport(Darwin)
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .named
        return formatter.localizedString(fromTimeInterval: 0)
        #else
        return Date().formatted(Date.RelativeFormatStyle(presentation: .named, locale: locale))
        #endif
    }

    /// How long before `now` the date was, abbreviated: "11 hr. ago".
    static func ago(_ date: Date, relativeTo now: Date, locale: Locale = .current) -> String {
        #if canImport(Darwin)
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .numeric
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
        #else
        return Date.AnchoredRelativeFormatStyle(anchor: now, presentation: .numeric, unitsStyle: .abbreviated,
                                                locale: locale, capitalizationContext: .middleOfSentence).format(date)
        #endif
    }
}
