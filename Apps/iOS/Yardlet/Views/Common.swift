import SwiftUI
import YardletRemote

/// A task's mark, as the Mac's sidebar draws it (`indicator`, docs/REMOTE_PROTOCOL.md §4.1).
struct TaskMark: View {
    let indicator: RemoteIndicator?

    var body: some View {
        Group {
            switch indicator {
            case .awaitingApproval?: dot(.green)
            case .needsInput?: dot(.orange)
            case .unread?: dot(.blue)
            case .running?: dot(Color(.systemGray3))
            case .failed?:
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.red)
            case .usageLimit?:
                Image(systemName: "gauge.with.dots.needle.100percent").font(.system(size: 11)).foregroundStyle(.orange)
            case nil:
                Color.clear
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityLabel(label)
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }

    private var label: Text {
        switch indicator {
        case .awaitingApproval?: Text("Awaiting approval")
        case .needsInput?: Text("Awaiting an answer")
        case .unread?: Text("Unread")
        case .running?: Text("Running")
        case .failed?: Text("Failed")
        case .usageLimit?: Text("Stopped at a usage limit")
        case nil: Text(verbatim: "")
        }
    }
}

enum Formatting {
    /// "now", "5m", "3h", "Tue", "Oct 3": how long ago, as a list says it.
    static func shortAge(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return String(localized: "now") }
        if seconds < 3600 { return Duration.seconds(seconds).formatted(.units(allowed: [.minutes], width: .narrow)) }
        if seconds < 86_400 { return Duration.seconds(seconds).formatted(.units(allowed: [.hours], width: .narrow)) }
        if seconds < 7 * 86_400 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// "1m 30s": the work time of a turn.
    static func duration(milliseconds: Int64) -> String {
        let seconds = Double(milliseconds) / 1000
        let units: Set<Duration.UnitsFormatStyle.Unit> = seconds >= 3600 ? [.hours, .minutes] : [.minutes, .seconds]
        return Duration.seconds(seconds.rounded()).formatted(.units(allowed: units, width: .narrow))
    }
}

/// A line under the navigation bar while the Mac cannot be reached.
struct ConnectionBanner: View {
    let session: HostSession

    var body: some View {
        if let text {
            HStack(spacing: 8) {
                if case .connecting = session.connection {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "wifi.exclamationmark").foregroundStyle(.secondary)
                }
                Text(text).font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if case .unreachable = session.connection {
                    Button("Retry") { session.reconnectNow() }.font(.footnote.weight(.semibold))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }

    private var text: String? {
        switch session.connection {
        case .connected: nil
        case .connecting: String(localized: "Connecting to \(session.name)…")
        case .unreachable:
            switch session.closingReason {
            case "disabled"?: String(localized: "Remote connections are off on \(session.name).")
            case "quitting"?: String(localized: "Yardlet quit on \(session.name).")
            default: String(localized: "Can't reach \(session.name). Trying again…")
            }
        case .removed: String(localized: "\(session.name) removed this phone. Pair it again to connect.")
        case .stopped: String(localized: "Not connected")
        }
    }
}

/// A refusal from the Mac, shown for a moment.
struct CommandErrorBanner: View {
    @Bindable var session: HostSession

    var body: some View {
        if let message = session.commandError {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text(message).font(.footnote)
                Spacer(minLength: 0)
                Button {
                    session.commandError = nil
                } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                }
                .accessibilityLabel("Dismiss")
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 12)
            .task(id: message) {
                try? await Task.sleep(for: .seconds(6))
                if session.commandError == message { session.commandError = nil }
            }
        }
    }
}

extension View {
    /// `.borderedProminent` on the app's monochrome accent, which is near white in dark mode, where the system's white
    /// label would not read: the label takes the background's colour, as a card's primary answer does.
    func prominentButton() -> some View {
        buttonStyle(.borderedProminent).foregroundStyle(Color(.systemBackground))
    }
}
