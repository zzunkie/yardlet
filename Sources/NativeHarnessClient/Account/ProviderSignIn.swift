import Foundation

/// A harness that cannot work until the person signs in: how its CLI says so, and how Yardlet does.
/// Each CLI keeps its own login, and Yardlet only runs its sign-in; nothing here reads a credential.
enum ProviderSignIn {
    /// A CLI's words for a turn only a new sign-in lets run.
    ///
    /// Claude Code 2.1.325 names `/login`, its own screen, which a task in Yardlet does not have ("Not
    /// logged in · Please run /login"). Run without a screen, as Yardlet runs it, it words what that
    /// screen sends to `/login` as "Failed to authenticate": "…: OAuth session expired and could not be
    /// refreshed", "…: OAuth token revoked…", "…: this login reached its time limit…", "Failed to
    /// authenticate. API Error: 401 …". When its host signs it in, it asks to "Sign in again to continue".
    /// A key or a cloud credential it rejects ("Fix external API key", "AWS credentials expired or
    /// invalid") and a refresh another process holds ("…or sign in again") are other failures and stay
    /// as they are.
    ///
    /// Codex 0.169.0, after its server refused a refresh: "Your access token could not be refreshed
    /// because your refresh token has expired. Please log out and sign in again." or "…Please sign in
    /// again."; after its retries of a request sent with no login (0.166.0): "unexpected status 401
    /// Unauthorized: Missing bearer or basic authentication in header".
    ///
    /// Kiro CLI 3.5.0 answers every ACP request but `initialize` with "Authentication required. Not
    /// logged in. Set the KIRO_API_KEY environment variable or run `kiro-cli login` first. …", and
    /// a prompt of a session whose sign-in is gone with "Sign in to Kiro to send a prompt."
    private static let cliWords = [
        "Please run /login", "Run /login", "Failed to authenticate", "Sign in again to continue",
        "Please log out and sign in again", "Please sign in again", "Missing bearer or basic authentication",
        "run `kiro-cli login` first", "Sign in to Kiro to send a prompt",
    ]
    /// Antigravity CLI 1.5.9 refuses a session it has no login for with ACP's `auth_required` error,
    /// whose message is these words alone. Claude Code starts other errors with them, about a connector.
    private static let acpAuthRequired = "Authentication required"

    /// Whether a login read as signed out means a turn cannot run. These CLIs answer for every way
    /// they sign in: `claude auth status`, Codex's `account/read`, which leaves a provider that needs
    /// no sign-in unread (`HarnessAccountBroker.codexSnapshot`), and Antigravity's check. Another
    /// harness may run without what its reading looks for, as OpenCode does on a key in its
    /// environment, so there the turn decides.
    static func readingDecidesTurns(_ harness: HarnessKind) -> Bool {
        harness == .claudeCode || harness == .codex || harness == .antigravityCLI
    }

    /// What a task that failed for its sign-in says where only one line can: a sidebar row's help, a
    /// notification.
    static var prompt: String { L10n.string("Not signed in. Sign in, then send your message again.") }
    /// The same line under a heading that already says it.
    static var nextStep: String { L10n.string("Sign in, then send your message again.") }

    static func asksToSignIn(_ message: String) -> Bool {
        cliWords.contains { message.contains($0) } || message == acpAuthRequired || message == prompt
    }

    /// What a login read as signed out needs. The Claude app runs Claude Code with its own sign-in,
    /// which reaches no other program, so someone who only ever used the app signs in once here.
    static func neededHere(_ harness: HarnessKind) -> String {
        switch harness {
        case .claudeCode: L10n.string("Claude Code needs a one-time sign-in here. The Claude app keeps its own sign-in.")
        case .codex, .antigravityCLI: L10n.format("Sign in to %@ to start a task here.", harness.displayName)
        default: L10n.string("No usable runtime-owned account was found.")
        }
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
