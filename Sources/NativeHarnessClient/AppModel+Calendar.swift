import Foundation
import Observation

/// The calendar follows Settings › General › Calendar and the calendar accounts connected in Settings ›
/// Connectors: turned on, it shows each connected Google Calendar, Outlook Calendar and Apple Calendar account and
/// reads the days a screen shows; turned off, it forgets all it read. Off, nothing of it runs.
extension AppModel {
    func startCalendar(defaults: UserDefaults = .yardlet) {
        guard calendarPreferenceObserver == nil else { return }
        nonisolated(unsafe) let watched = defaults
        calendarPreferenceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                // Any setting posts this; only the calendar's own changes anything here.
                guard let self, CalendarPreference.isOn(in: watched) != self.calendar.isEnabled else { return }
                self.followCalendar(defaults: watched)
            }
        }
        followCalendar(defaults: defaults)
    }

    /// Shows the accounts the setting and the connectors say. While it is on, the next change to the connectors is
    /// followed again.
    func followCalendar(defaults: UserDefaults = .yardlet) {
        let isOn = CalendarPreference.isOn(in: defaults)
        calendar.setEnabled(isOn)
        guard isOn, let connectorCenter else { return }
        let entries: [(CalendarAccount, any CalendarAccountTransport)]
        if calendarFollowsConnectors {
            entries = connectorCenter.calendarAccounts()
        } else {
            calendarFollowsConnectors = true
            nonisolated(unsafe) let defaults = defaults
            entries = withObservationTracking {
                connectorCenter.calendarAccounts()
            } onChange: { [weak self] in
                Task { @MainActor in
                    self?.calendarFollowsConnectors = false
                    self?.followCalendar(defaults: defaults)
                }
            }
        }
        guard entries.map(\.0) != calendar.accounts else { return }
        calendar.setAccounts(entries)
    }
}
