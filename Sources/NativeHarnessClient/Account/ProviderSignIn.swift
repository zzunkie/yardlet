import Foundation

/// A harness that cannot work until the person signs in: how its CLI says so, and how Yardlet does.
/// Each CLI keeps its own login, and Yardlet only runs its sign-in; nothing here reads a credential.
enum ProviderSignIn {
    /// Claude Code's words for a turn it could not authenticate (2.1.318: "Not logged in · Please run
    /// /login", "OAuth token has expired. Please run /login."). `/login` is the CLI's own screen, which
    /// a task in Yardlet does not have; "Fix external API key" is another failure and stays as it is.
    private static let cliWords = ["Please run /login", "Run /login"]

    /// What a task that failed for its sign-in says where only one line can: a sidebar row's help, a
    /// notification.
    static var prompt: String { L10n.string("Not signed in. Sign in, then send your message again.") }
    /// The same line under a heading that already says it.
    static var nextStep: String { L10n.string("Sign in, then send your message again.") }

    static func asksToSignIn(_ message: String) -> Bool {
        cliWords.contains { message.contains($0) } || message == prompt
    }

    /// What a login read as signed out needs. The Claude app runs Claude Code with its own sign-in,
    /// which reaches no other program, so someone who only ever used the app signs in once here.
    static func neededHere(_ harness: HarnessKind) -> String {
        harness == .claudeCode ? L10n.string("Claude Code needs a one-time sign-in here. The Claude app keeps its own sign-in.")
            : L10n.string("No usable runtime-owned account was found.")
    }

    /// The same for a Claude login whose terminal works from something an app does not get: Yardlet
    /// takes only `PATH` from the login shell (`LoginShellPath`), so a key or a config folder a
    /// profile exports stays there. It is named, its value never read, and nothing is copied.
    static func claudeSignedOutDetail(shellVariables: [String]) -> String {
        if shellVariables.contains("CLAUDE_CONFIG_DIR") {
            return L10n.string("Your shell sets CLAUDE_CONFIG_DIR, so Claude Code in Terminal uses another folder. Add that folder in Accounts, or sign in here.")
        }
        if let variable = shellVariables.first {
            return L10n.format("Claude Code in Terminal signs in with %@ from your shell setup, which apps don't get. Sign in here once to use it in Yardlet.", variable)
        }
        return neededHere(.claudeCode)
    }
}

/// A task that would start on a login just read as signed out. It says so at once, instead of
/// starting a CLI whose first turn ends in the same words.
struct HarnessSignInRequired: LocalizedError, Equatable {
    var errorDescription: String? { ProviderSignIn.prompt }
}
