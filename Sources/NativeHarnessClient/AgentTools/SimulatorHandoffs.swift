import Foundation
import Observation

/// A device the agent handed to the person (`simulator_handoff`): what it asks of them, and how it ended.
struct SimulatorHandoff: Equatable, Sendable {
    enum Answer: Equatable, Sendable {
        /// The person's Done.
        case done
        /// The person's Decline.
        case declined
        /// The person sent the task a message instead of answering (`AppModel.answerWaits(_:forPersonsMessageIn:)`).
        case personSentMessage
        /// The agent's turn ended first.
        case turnEnded
    }

    let id: UUID
    let device: SimulatorDeviceIdentity
    var reason: String
    var answer: Answer?

    /// The handoff's notification, by its id.
    var notice: String { "yardlet-simulator-handoff-\(id.uuidString)" }
}

/// Each task's device handed to the person, which the Simulator tab of that device shows in a bar over it with Done and
/// Decline, as a browser tab handed over shows one (`BrowserTab.handOff(reason:)`): a task hands over one of its
/// attached devices at a time.
@MainActor
@Observable
final class SimulatorHandoffs {
    private(set) var byTask: [UUID: SimulatorHandoff] = [:]
    /// A handoff was answered or ended: its notification goes.
    @ObservationIgnored var onSettled: @MainActor (String) -> Void = { _ in }

    func handoff(for task: UUID) -> SimulatorHandoff? { byTask[task] }

    /// The handoff that waits on the person in the task's Simulator tab.
    func waiting(for task: UUID) -> SimulatorHandoff? {
        byTask[task].flatMap { $0.answer == nil ? $0 : nil }
    }

    /// The agent hands the device to the person. A handoff of the same device still waiting for them takes the new
    /// reason, and one they answered after the agent's last wait gave up is returned as it is, so the call reads the
    /// answer. Returns the handoff and whether it is new.
    func handOff(_ device: SimulatorDeviceIdentity, reason: String, for task: UUID) -> (handoff: SimulatorHandoff, isNew: Bool) {
        if var earlier = byTask[task], earlier.device == device, earlier.answer != .turnEnded {
            if earlier.answer == nil, earlier.reason != reason {
                earlier.reason = reason
                byTask[task] = earlier
            }
            return (earlier, false)
        }
        if let earlier = byTask[task] { onSettled(earlier.notice) }
        let new = SimulatorHandoff(id: UUID(), device: device, reason: reason)
        byTask[task] = new
        return (new, true)
    }

    /// The person's answer from the tab's bar or a message, or the end of the agent's turn. False when nothing waits.
    @discardableResult
    func answer(_ answer: SimulatorHandoff.Answer, for task: UUID) -> Bool {
        guard var waiting = byTask[task], waiting.answer == nil else { return false }
        waiting.answer = answer
        byTask[task] = waiting
        onSettled(waiting.notice)
        return true
    }

    /// The agent's wait read the answer, or the device went: the device is the agent's again.
    func end(for task: UUID) {
        guard let ended = byTask.removeValue(forKey: task) else { return }
        if ended.answer == nil { onSettled(ended.notice) }
    }

    /// The task's turn ended: a waiting call reads that the turn ended; an answer no call read belongs to the turn that
    /// ended.
    func turnEnded(for task: UUID) {
        if waiting(for: task) != nil { answer(.turnEnded, for: task) } else { end(for: task) }
    }

    /// The Simulator switch turned off, or every device went.
    func removeAll() {
        for task in Array(byTask.keys) { end(for: task) }
    }
}
