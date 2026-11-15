import SwiftUI
import YardletRemote

/// What the Mac's window shows above a task's composer (docs/REMOTE_PROTOCOL.md §15.31 `notices`, §15.33 `notice`),
/// in its order: the task's last error, a missing folder, Yardlet's restart or reconnecting, a limit the task nears,
/// the account it moves to with Cancel, and what the Mac's composer says under its text. Recreating a worktree stays
/// on the Mac.
struct TaskNoticesView: View {
    let session: HostSession
    let taskID: String
    @State private var isCancelling = false

    private var notices: RemoteTaskNotices? { session.task(taskID)?.notices }
    private var composerNotice: String? {
        session.composerStates[taskID]?.notice?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    var body: some View {
        // Read here, not only inside the timeline's closure, so a change to either draws the lines again.
        let notices = notices
        let composerNotice = composerNotice
        TimelineView(.everyMinute) { timeline in
            let warning = warning(notices, at: timeline.date)
            if notices?.error != nil || notices?.missingFolder != nil || notices?.resumedAfterRestart == true
                || notices?.reconnecting == true || warning != nil || notices?.accountName != nil || composerNotice != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let error = notices?.error?.nilIfEmpty {
                        Label {
                            Text(error).lineLimit(6).textSelection(.enabled)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    if let path = notices?.missingFolder {
                        line(notices?.worktreeBranch.map {
                            String(localized: "This task's worktree \(path) was removed. Its branch \($0) is still there.")
                        } ?? String(localized: "This task's folder \(path) no longer exists."),
                             symbol: "folder.badge.questionmark", tint: .red)
                    }
                    if notices?.resumedAfterRestart == true {
                        line(String(localized: "Yardlet restarted while this task was working, so it picked up where it left off."),
                             symbol: "arrow.clockwise")
                    }
                    if notices?.reconnecting == true {
                        line(String(localized: "Reconnecting"), symbol: "wifi")
                    }
                    if let warning {
                        line(warning, symbol: "gauge.with.dots.needle.67percent", tint: .orange)
                    }
                    if let account = notices?.accountName {
                        HStack(alignment: .firstTextBaseline) {
                            line(notices?.accountMoveInTurn == true
                                 ? String(localized: "Moving to \(account) after this turn")
                                 : String(localized: "Moving to \(account) when its background work ends"),
                                 symbol: "person.crop.circle.badge.clock")
                            Spacer(minLength: 8)
                            if isCancelling {
                                ProgressView().controlSize(.mini)
                            } else {
                                Button("Cancel") { cancelAccountMove() }
                                    .font(.footnote.weight(.semibold))
                                    .disabled(!session.isConnected)
                            }
                        }
                    }
                    if let composerNotice {
                        line(composerNotice, symbol: "exclamationmark.circle")
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func line(_ text: String, symbol: String, tint: Color = .secondary) -> some View {
        Label {
            Text(text).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.footnote)
    }

    /// A limit the task nears, as the Mac words it, while its window has not reset.
    private func warning(_ notices: RemoteTaskNotices?, at now: Date) -> String? {
        guard let warning = notices?.warning else { return nil }
        let resets = notices?.warningReset.map(session.date)
        if let resets, resets <= now { return nil }
        let used = warning.usedFraction.map { Int(($0 * 100).rounded()) }
        var text: String
        switch warning.window {
        case "session":
            text = used.map { String(localized: "You've used \($0)% of your session limit") }
                ?? String(localized: "Approaching your session limit")
        case "weekly":
            text = used.map { String(localized: "You've used \($0)% of your weekly limit") }
                ?? String(localized: "Approaching your weekly limit")
        case "model" where warning.model != nil && used != nil:
            text = String(localized: "You've used \(used ?? 0)% of your \(warning.model ?? "") limit")
        default:
            text = used.map { String(localized: "You've used \($0)% of your usage limit") }
                ?? String(localized: "Approaching your usage limit")
        }
        if let resets {
            text += " · " + String(localized: "Resets \(resets.formatted(.relative(presentation: .named)))")
        }
        return text
    }

    private func cancelAccountMove() {
        isCancelling = true
        Task {
            await session.perform(.cancelAccountMove(taskID: taskID))
            isCancelling = false
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
