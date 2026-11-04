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
enum NextMessageSuggestionPreference {
    static let key = "YardletNextMessageSuggestions"

    static func isOn(in defaults: UserDefaults = .yardlet) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
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
