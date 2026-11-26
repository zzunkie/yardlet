import SwiftUI
import YardletRemote

/// A task's mark, as the Mac's sidebar draws it (`indicator`, docs/REMOTE_PROTOCOL.md §4.1),
/// using Yardlet's restricted status indicator colors.
struct TaskMark: View {
    let indicator: RemoteIndicator?

    var body: some View {
        Group {
            switch indicator {
            case .awaitingApproval?: StatusDot(color: YardletPalette.Status.approval)
            case .needsInput?: StatusDot(color: YardletPalette.Status.question)
            case .unread?: StatusDot(color: YardletPalette.Status.unread)
            case .running?: StatusDot(color: YardletPalette.Status.running)
            case .failed?:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(YardletPalette.Status.failed)
            case .usageLimit?:
                Image(systemName: "gauge.with.dots.needle.100percent")
                    .font(.system(size: 11))
                    .foregroundStyle(YardletPalette.Status.limit)
            case nil:
                Color.clear
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityLabel(label)
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
    /// "now", "5m ago", "3h ago", "Tue", "Oct 3": how long ago, as a list says it.
    static func shortAge(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return String(localized: "now") }
        if seconds < 86_400 {
            let unit: Duration.UnitsFormatStyle.Unit = seconds < 3600 ? .minutes : .hours
            let age = Duration.seconds(seconds).formatted(.units(allowed: [unit], width: .narrow))
            return String(localized: "\(age) ago", comment: "How long ago, in a list: 5m ago")
        }
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
        if let text = Self.text(session) {
            HStack(spacing: 8) {
                if case .connecting = session.connection {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "wifi.exclamationmark")
                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                }
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                Spacer(minLength: 0)
                if case .unreachable = session.connection {
                    Button("Retry") { session.reconnectNow() }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(YardletPalette.onSurface)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(YardletPalette.surfaceContainerLow)
            .overlay(alignment: .bottom) {
                Rectangle().fill(YardletPalette.outlineVariant).frame(height: 0.5)
            }
        }
    }

    /// What the connection to the Mac is doing, or nil once it is up.
    static func text(_ session: HostSession) -> String? {
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
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(YardletPalette.Status.limit)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(YardletPalette.onSurface)
                Spacer(minLength: 0)
                Button {
                    session.commandError = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                }
                .accessibilityLabel("Dismiss")
            }
            .padding(12)
            .background(YardletPalette.surfaceContainerHigh,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.75)
            )
            .padding(.horizontal, 12)
            .task(id: message) {
                // Gone after a while; not when the banner is merely drawn again, which cancels this.
                do { try await Task.sleep(for: .seconds(6)) } catch { return }
                if session.commandError == message { session.commandError = nil }
            }
        }
    }
}

extension View {
    /// `.borderedProminent` on the app's monochrome accent, which is near white in dark mode, where the system's white
    /// label would not read: the label takes `onPrimary`, as a card's primary answer does.
    func prominentButton() -> some View {
        buttonStyle(.borderedProminent)
            .tint(YardletPalette.primary)
            .foregroundStyle(YardletPalette.onPrimary)
    }
}

/// A page of the Mac's that could not be read: why, and Try Again, in place of a loading card that would never end.
struct ReadFailureCard: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        MonochromeCard(fill: YardletPalette.surfaceContainerLow, padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Couldn't load")
                    .font(.headline)
                    .foregroundStyle(YardletPalette.onSurface)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again", action: retry)
                    .prominentButton()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
