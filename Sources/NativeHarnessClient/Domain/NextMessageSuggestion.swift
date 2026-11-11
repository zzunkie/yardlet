import Foundation

/// "Next message suggestions" in Yardlet's General settings: whether a harness that can predict
/// the person's next message after a turn is asked to, and whether the composer shows what it
/// predicted. On unless turned off, as the Claude app's "Prompt suggestions" (`ccPromptSuggestions`)
/// and the Codex app's "Show predictions" (`composer-predictions-enabled`) are.
///
/// Claude Code makes one when its `initialize` asks (`prompt_suggestion`, one more model request
/// per turn); that ask is a per-process option, so a task started or resumed after the setting
/// changes follows it. A Codex task asks after each turn as the Codex app does
/// (`CodexMessagePrediction`: one short turn on an ephemeral fork), reading the setting at that
/// moment. Nothing is written to the person's settings. The composer reads the setting live, so
/// turning it off hides a suggestion at once.
///
/// Only tasks the person looks at ask, as Claude Code's terminal suggests only while its window has
/// focus. A Claude Code CLI asks when it starts for a task on screen or for the person's own message;
/// one started off screen (another task's message, a schedule, a continuation, an account move) starts
/// again with them once its task comes on screen and nothing keeps it busy
/// (`AppModel.restartToSuggest`), and keeps them until it ends. A Codex turn's end asks while the task
/// is on screen or was within `unseenWindow` (`HarnessTaskSightReceiving`).
enum NextMessageSuggestionPreference {
    static let key = "YardletNextMessageSuggestions"

    /// How long after a task leaves the screen its turns still ask: the memory saver's window, after
    /// which the Codex app lets an unseen conversation go and Yardlet ends an idle Claude Code CLI.
    static let unseenWindow = HarnessMemorySaver.Timing().unseenBeforeRelease

    static func isOn(in defaults: UserDefaults = .yardlet) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    /// Whether a task last on screen at `unseenSince` (nil: on screen now) was seen recently enough to ask.
    static func isSeen(unseenSince: Date?, now: Date = Date()) -> Bool {
        unseenSince.map { now.timeIntervalSince($0) < unseenWindow } ?? true
    }
}

/// What a harness sent as its predicted next message, made fit to show in one line and to put
/// into the composer. The CLI already filters its own (2–12 words, one sentence, under 100
/// characters); Yardlet only trims it and refuses an empty one or one with a line break.
enum NextMessageSuggestionText {
    /// Longer than any the CLI keeps, so a provider change cannot fill the composer with a page.
    static let maximumLength = 300

    static func normalized(_ raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              text.count <= maximumLength, !text.contains(where: \.isNewline) else { return nil }
        return text
    }
}
