# Harness, model provider and account connections

Yardlet shows the remaining usage of several accounts and lets the person choose the account for each task, for every
harness rather than one provider. Harness connections are kept apart from model provider authentication, and each harness is
connected only through the paths it actually supports. No arbitrary model proxy and no OAuth token conversion or
copying are added.

The screen flow is in [ACCOUNT_SELECTION_UX.md](ACCOUNT_SELECTION_UX.md).

## What the user does

- In **Settings › Harness Accounts → Add account** (the sidebar's account menu opens this section too), the user connects a
  separate account, or points to an existing CLI account folder in the advanced settings. Existing sign-ins appear in
  the same list, and the name and folder are optional. A new folder is created and the harness's official sign-in and
  provider setup opens. A new Claude folder keeps only the sign-in's own files and links the rest to the default folder
  ("Account folder shape, finding sign-ins and removing accounts" below); other harnesses' new folders start empty. The
  CLI keeps owning secret values.
- In **Choose account** next to the project and harness of a new task, the user chooses after seeing the remaining
  limits and reset times. The choice is kept with the draft, and the account binding is fixed just before submission.
  When more than one of the harness's accounts is in automatic assignment, the menu starts with **Automatic**, chosen
  until the person chooses an account: the task then starts on the account `AccountRouting.pick` picks when it is sent,
  after the same check of the readings an agent's child task gets, and a line above the composer's controls names the
  account and why ("work@example.com · Chosen automatically · 5 hour limit 12% used · Resets 3:00 PM"), before sending
  and while the task starts. The task's hover card keeps the reason. An account the person chooses stands until they
  choose Automatic again. A task started from the phone follows the same choice. **Choose the account for new tasks
  automatically** in Settings › Harness Accounts turns Automatic off; the menu is then as it was without it, and only that
  setting is kept.
- Resuming, forking and side chats of a task use the saved account environment together with the native session ID.
  Changing the default account for new tasks does not change the account of existing tasks.
- Claude Code can switch, from **Choose account** in the task menu, only to an account that uses the same conversation
  history folder. It is allowed only when the `projects` of the two account folders point, through links,
  to the same real folder, so the session ID and history location stay the same and no file is moved or copied. Session
  Switch account folders have this structure (`projects` and the like link to `~/.claude`, and only the sign-in is kept
  per account). If the CLI of the target account does not confirm the sign-in in `auth status`, the switch does not
  happen. After the switch it reconnects with the same session ID.
- An account chosen while the task is in a turn or waiting for approval takes effect when that turn ends
  (`AppModel.chooseAccount`), since switching closes the task's CLI. Until then the task keeps working where it is, a
  line above the composer says "Moving to <account> after this turn" with **Cancel**, and Return queues what the person
  sends (⌘Return still delivers it at Claude's next step). Once the turn has ended (finished, stopped or failed), the
  switch waits for what moving an account's tasks waits for ("Removing an account" below), except that the messages
  and shell output Yardlet holds go after the switch instead, on the new account. While something keeps it waiting
  after the turn, the line names it (`AccountMoveBlocker`): "Moving to <account> when its background work ends", or
  when its shell command ends, the agents it runs finish, the message on its way is delivered, its request is
  answered, the message being edited is done, or another change under way ends. A message the person sends then waits
  too, as do one from another task and a schedule's run (`TaskContinuationCoordinator.holdUntilAccountMoves`). A move
  Yardlet chose itself ("Moving tasks to an account with room" below) is different: it never holds up the person.
  Background work lives in the task's CLI and goes on after a turn a limit or an error ended, as after any other: when
  that CLI closes first (the person switched the idle task at once, say, or it exited), what ran in it shows as stopped
  (`AppModel.detachRuntime`, `ClaudeSessionProjection.processEnded`), so the waiting switch goes ahead and the
  messages follow (`ClaudeUsageLimitAppModelTests.testWhatWaitsForAMoveGoesOnceTheRuntimeRunningItsBackgroundWorkCloses`).
  A switch refused then (the target
  signed out, or no longer sharing the history) says why above the composer, as an immediate one does, and what was
  queued for the new account waits paused until the person resumes it. The choice is not kept across a quit. The
  Claude app has the same notice for a task that moves to another computer ("Moving to {place} after this turn"); for
  accounts it keeps one account for the whole app and lets a switch go ahead, keeping working sessions of the previous
  account running out of the list, and Codex also keeps one account for all threads. Evidence: the strings and code in
  their app bundles.
- When usage is not published, it is shown as not available. Short-term and long-term limits are shown separately,
  not combined, and a limit without a number is not turned into 0.
- A login that cannot work says so before anything is sent ("Signing in when a login is missing" below): the account
  row and the chip read "Not signed in", and the new-task screen offers **Sign in** above the composer's controls.

## Support boundaries

| Harness | Model supply path | Extra account environment | Remaining limits | Changing the account of an existing task |
|---|---|---|---|---|
| Codex | The default OpenAI service or a provider set in the CLI | CODEX_HOME | primary/secondary of the account the App Server publishes | Choose the environment in a new task |
| Claude Code | The default Anthropic service or a provider set in the CLI | CLAUDE_CONFIG_DIR | 5-hour, weekly and per-model weekly limits from the CLI `get_usage` control request | Choose among accounts that share the same history folder |
| Pi | A separate model provider | PI_CODING_AGENT_DIR, provider choice | Not shown when the CLI does not publish it | Choose the environment in a new task |
| OpenCode | A separate model provider | Per-account XDG data/config/state/cache | The existing CLI lookup boundary | Choose the environment in a new task |
| Hermes Agent | A separate model provider | HERMES_HOME | No safe structured lookup | Choose the environment in a new task |
| Kimi Code | Its own service or a provider set in the CLI | KIMI_CODE_HOME | Not shown; the CLI publishes none | Choose the environment in a new task |
| Grok Build | Its own service | GROK_HOME | Not shown; the CLI publishes none | Choose the environment in a new task |
| Other harnesses | The default or external provider settings that the CLI owns | Keep the existing connection | Only public lookups verified before | No extra paths are made up |

An extra account environment is offered only where the CLI officially moves its sign-in and its history together
("Which CLIs can keep a second account" below).

Gemini CLI, Gajae Code, Oh My Pi and Deep Agents Code are no longer built in (`HarnessKind.retired`): their saved
tasks still load under their identifiers, and Yardlet's own settings for them are dropped. Choosing a Google model
provider in another harness such as Pi is separate from the removed Gemini CLI entry.

For OpenCode, Yardlet hosts the provider and authentication method choice of the official `auth login`. For Pi, it
looks up the provider that the user specifies or that is set in Pi's own settings.json. Without a setting, it does not
assume ChatGPT as the default provider. The default Pi connection and adding a new Pi account choose the provider
first. Pi's authentication method choice screen is also recognized as waiting for input.
Pi's explicit provider sign-in keeps the existing
`auth check --provider … --json --no-refresh` completion detection and the guard against cancellation and late replies.
Antigravity CLI has no sign-in command: Yardlet starts `agy` itself, answers its login method picker with the default
Google OAuth choice, and `agy` opens the browser. `agy` stays in its chat after signing in, so the console finishes when
the keychain item appears, checked once a second without reading the credential, under the same guard as Pi. The
console's terminal keeps its size while the CLI details are hidden, since a full-screen picker such as `agy`'s draws
nothing in a terminal one row tall.

## Storage and process contract

`~/.yardlet/provider-connections.json` stores only the name, harness, provider ID, account folder and selector. Tokens
and API keys are never read or copied. The file uses atomic write and 0600 permissions, and a failed read never
overwrites the original file. A new account folder is 0700.

`account-snapshots.json` in the same folder holds the latest lookup results, so the account list shows
them as soon as it opens. For each connection ID (`native:<harness>` for the default sign-in) it keeps only whether the
account is signed in (`signedIn`/`signedOut`), the account name, organization and plan line that the CLI reported, the
limit rows (name, used ratio, display text, reset time and kind of evidence) and the lookup time. It keeps no tokens,
credentials, account folder paths, CLI output or per-task token usage. It uses atomic write and 0600, encoded and
written off the main thread with Yardlet's other small state files (`StateFileWriter`); a Claude session's limit
report that changes no row writes nothing. When it cannot be read, it starts empty and the next lookup writes it anew. When a lookup confirms sign-in or sign-out, the entry is
rewritten, and when action is needed (a missing folder and the like), it is removed. When a lookup cannot finish
(time-out, error), the screen keeps the last sign-in value but marks it "Couldn't refresh", and when there is no
runtime, it shows that state as is. A sign-in remembered from the last run is not a candidate for automatically
replacing the default account of new tasks (`replaceSignedOutDefaultSelection`). Only what this run confirmed is used.
The account chip in the new task composer uses the account name remembered with a signed-in state in the same file. So
the name stays visible while the next run checks again. This name is for display only and has nothing to do with
binding, selection or credentials. Before the check, with no remembered name, it shows "Checking account…".

Reading and checking have one owner, `ProviderConnectionStore`. It holds the values of the default
sign-ins and saved accounts, `AccountReadingStatus` and the checking indicator, and the account screen
(`AccountCenterModel`) handles only the sign-in console. A check starts only through
`check(defaultsOf:savedOf:connectionIDs:policy:checkUsage:runtimeSelections:)`.
- If a check of the same account (`native:<harness>` for the default sign-in, the connection ID for a saved account)
  is already running, no new CLI process starts; it waits for that check.
- There is one freshness rule: a value that a check in this run confirmed as "current" within the last minute is not
  checked again when the list opens (`ifStale`). Values remembered from the last run and "Couldn't refresh" values are
  always checked again. The refresh button (`refresh`) checks again even when the value is fresh, but joins a check
  that is running.
- After the sign-in console ends or the runtime changes (`restart`), the answers of checks started before are
  discarded and a new check runs. Only the answers of checks or reads started later (Codex account notifications, the
  Pi and Antigravity sign-in checks) stay on screen.
- The Codex default sign-in is read in the same environment as the app's Codex tasks (`CodexEnvironmentManager`). The
  Codex account notification monitor runs on a single App Server, only while the account screen is open.

SQLite's nullable `connection_binding` preserves `SessionRecord.connection`. A null value in past tasks keeps the
existing native/yardlet scope meaning. Importing native history does not treat tasks with a different provider ID,
scope or account binding as the same task. If a registered folder has disappeared, it does not fall back to the default
account.

A separate environment does not receive the parent process's model API keys, OAuth overrides or model routing
overrides. HOME and the general development tool environment are kept. A provider adapter can be configured in the
harness's own settings, but Yardlet does not guarantee an arbitrary provider connection for an arbitrary engine.
Existing tasks are not moved to another account folder, and native conversations are not duplicated.

Each harness has one runtime that reads its accounts and starts its tasks, new and saved. Unless the person chose
one, it is the newest version among the installs on this Mac; a runtime the person chose is kept, and Settings ›
CLI Updates offers a newer install found elsewhere. Installs are looked for in the desktop apps' bundles and where the
person's shell would find them, not only in Yardlet's own `PATH`, which has only the system's folders when Yardlet
opens from the Dock: `~/.local/bin`, the package managers' folders (bun, Volta, Cargo, Deno, `~/.npm-global/bin`,
pnpm, asdf's and mise's shims, each Node version of nvm), Claude Code's older `~/.claude/local`, Homebrew,
`/usr/local/bin`, the `PATH` the login shell sets (`LoginShellPath`, read in the background at launch, which
`findNewest()` waits for) and the system. `--version`, status checks and limit reads run with the same `PATH`, so a CLI
installed as a Node script finds `node`. The same account can see different models depending on the
runtime's version: the App Server's `model/list` answered one user's older Codex without the GPT-6.1 models. The
versions are read off the main thread at launch, only for installs that changed since the last launch; until then the
choice rests on the versions read before. The window and the task list do not wait for the read, but the launch's
work that starts a runtime does (work a quit cut off, scheduled tasks, following the Claude app's and Codex's lists),
so it neither starts an older install nor keeps that install's App Server for the session. A task records the
runtime it last started with, as a record only: it is not run and does not become the harness's choice
(docs/NATIVE_SESSION_STORAGE.md, "Runtime paths"). Choosing a runtime with Choose…
under Runtime and connection details checks the accounts again with `restart`.

Switching accounts rechecks the binding and task state, closes that handle and resumes with the same provider session
ID. Other tasks' handles and drafts stay. A closed ACP transport is not reused.

## Which CLIs can keep a second account

A harness takes an extra account environment (`HarnessConnectionCapabilities.supportsSeparateHome`) only when its CLI
officially moves both its sign-in and its conversation history to another folder, so a task's session ID always lives in
the account folder it was saved in. Yardlet makes no other route: no Keychain items are renamed or swapped and no
credential is copied between folders. As the CLIs' documentation and these versions show:

| CLI | Official route | Where the sign-in is kept | History moves with it | Extra account |
|---|---|---|---|---|
| Kimi Code 0.36 | `KIMI_CODE_HOME` ("all Kimi Code data lands under the new path: config, sessions, logs, OAuth credentials", Kimi Code docs, "Data locations") | `credentials/<name>.json` in that folder | Yes, `sessions/` | Yes |
| Grok Build 1.0.70 | `GROK_HOME` ("Override config directory", its user guide, "Configuration") | `auth.json` in that folder | Yes, `sessions/` | Yes |
| OpenCode 1.19, Hermes Agent 0.21, Pi 0.84 | XDG folders, `HERMES_HOME`, `PI_CODING_AGENT_DIR` | A file in that folder | Yes | Yes (Hermes: a folder inside `~/.hermes` falls back to the default sign-in for providers it lacks, so Yardlet's folders are elsewhere) |
| Cursor Agent 2026.08 | `CURSOR_CONFIG_DIR` moves the settings and chats only | macOS Keychain items with fixed names (`cursor-access-token` and the like) | Chats only | No: two folders would share one sign-in |
| Antigravity CLI 1.4 | None documented | One OS keyring item (service `gemini`, account `antigravity`) | — | No |
| Muse Code 1.4 | None documented (the binary reads the XDG folders) | macOS Keychain by default, with a pointer file in the config folder; whether the item differs per folder is not known | With `XDG_DATA_HOME` | Not offered until two sign-ins are seen to stay apart |

Where no route exists, another account means signing out and signing in to the other one with the CLI. An extra Kimi
Code or Grok Build account starts in an empty folder of its own and keeps its own history, as a Codex account does:
its tasks do not move to another account, and automatic assignment leaves it out until the person includes it. In an
empty folder each CLI writes only there (checked with `kimi acp` and `grok agent stdio` answering `initialize` and an
empty `session/list`), and Grok Build updates itself only when run from that folder's own `bin/grok`, so no copy of the
runtime lands in an account folder. Titles, Grok Build's session details and its transcript repair read a task's
history in its account's folder (`ProviderSessionTitlePaths.forAccount`). Importing reads the chosen account's folder
too: the import list's `session/list` and the replay's `session/load` run in that account's environment, and the task
imported keeps that account ([NATIVE_SESSION_STORAGE.md](NATIVE_SESSION_STORAGE.md), "Importing conversations from
other apps").

## Signing in when a login is missing

The Claude app runs Claude Code with its own sign-in, which it hands to the CLI it starts as an environment variable and
keeps nowhere the CLI looks. Someone who only ever used the app has history in `~/.claude`, which Yardlet reads and
imports, and no Claude Code login, so the first turn would end in the CLI's "Not logged in · Please run /login". Yardlet
never reads or reuses the app's sign-in. It reads under `~/Library/Application Support/Claude` only: the session and
schedule lists, the scratch folders' path, and the bundled CLI it can run.

- **Before a turn.** `claude auth status` answers without a prompt, a turn or a token renewal. A login it reports as
  signed out reads "Not signed in" on its row and the chip (a login with no name is never shown as a working account:
  a default login reads by its state, "Default login" when it works but names no address). The new-task screen says what
  is needed and offers **Sign in**, the harness's own `claude auth login`. A Claude task on a login read as signed out
  reads it once more and, still signed out, fails at once with no CLI started (`AppModel.isSignedOut`,
  `HarnessSignInRequired`). The CLI waits for its MCP servers before its first turn, up to 30 seconds for one that
  does not answer, so a failure left to the turn would take that long to say the same.
- **Status checks.** A Claude check has 30 seconds. When it cannot finish, or names no address, the account comes from
  `oauthAccount` in the login's `.claude.json`, which needs no prompt; a CLI signed in with a key or a token from elsewhere
  has no account, so a name left there by an earlier sign-in is not used.
- **A turn the CLI refused.** Claude Code's refusal that names `/login` is the error card alone, without the same words
  as an answer (`ClaudeSessionProjection`, `ProviderSignIn.asksToSignIn`); `/login` is a screen tasks here do not have.
  The card offers **Sign in** and, when another signed-in account shares the task's history (`TaskAccountSwitch`),
  **Continue with** that account, which moves the task as the task menu does. Its details keep the CLI's words, the
  sidebar's help and the notification say the same as the card, and the account is read again. A key the CLI rejects
  ("Fix external API key") stays a plain error: a sign-in does not fix it.
- **After a sign-in.** The first reading of a login as signed in after any other (`ProviderConnectionStore.onSignedIn`)
  makes it usable at once. A saved account replaces a default login that is signed out, or a Claude one that could not
  be confirmed, as the account new tasks start on; a choice the person made stands. A CLI that found no login keeps
  running on that answer, so each idle one on that login ends, on screen or not, and the task's next message resumes the
  same conversation (`AppModel.continueTasks`). Its provider ID, history and binding stay. A task that failed for the
  sign-in reads ready again. A task is not moved to another account without the person's click.
- **A login only the terminal has.** `claude` in a terminal can be signed in from something an app does not get: an API
  key or token a profile exports, or another `CLAUDE_CONFIG_DIR`, whose login is in its own Keychain item (the item name
  ends in a digest of the folder). Yardlet takes only `PATH` from the login shell, and the same read says, by name and
  without the value, which of `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY` and
  `ANTHROPIC_AUTH_TOKEN` it sets (`LoginShellPath.claudeSignInNames`). The signed-out line then says so. Nothing is copied.
- **An app opened by an agent.** `open` hands the calling shell's variables to the app, and an agent's session has
  its own. They are dropped at launch (`HostSessionEnvironment`): the `CLAUDE_CODE_*` family, which holds the Claude
  app's token, and the API key, token, base URL and headers that session runs with.
- **Renewals are not cut off.** A renewal gets a new refresh token and retires the old one, and Claude Code, told that a
  stored refresh token is dead, clears the login from the store every program on that login shares. So a CLI read for its
  limits is never stopped first: the end of its input ends it, also at the time limit, and only one still running 20
  seconds later is stopped (`ClaudeUsageProbe`). `auth status` contacts no server, so its time limit cuts nothing off.
- **What is recorded.** `~/.yardlet/logs/account-checks.log` (one JSON object a line, 0600, the newest half kept past
  512 KiB) holds each Claude status check and each refused turn: the program, the config folder, state, exit code, how
  long it took, the CLI's `authMethod` and `apiProvider`, and for a login that was not found, whether its Keychain item
  exists (identity only, never its value) and the shell variables above by name. It holds no credential, address or CLI
  output, and nothing sends it.

## Claude plan limit lookup

When a Claude account is signed in, Yardlet runs the official CLI in that account's environment with
`-p --input-format stream-json --output-format stream-json --verbose --strict-mcp-config` and sends only the
`initialize` and `get_usage` control requests. It looks up usage with Claude Code's own sign-in, there are no model
requests and no conversation history writes, and Yardlet does not handle tokens. It is the same method that Session
Switch 0.5.0 uses. Because the CLI treats the usage endpoint as nonessential traffic,
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` is removed for this lookup only. It runs in an empty temporary folder, which
is deleted at the end. The response's `limits` rows (`session` for 5 hours, `weekly` for the week, per-model weekly when
`scope.model` is present) come first; without them, `five_hour`, `seven_day` and `model_scoped` are read. An unknown
group is not shown as a limit. `rate_limits_available: false` (API keys and the like) or a failed lookup shows "Claude
Code did not report plan limits for this login." and is not turned into 0.

## Antigravity account and plan limit lookup

Yardlet reads Antigravity CLI's sign-in with `AGY_CLI_CDE_AUTH_ACTION=check agy`
(`HarnessAccountBroker.antigravitySnapshot`). Signed in, `agy` checks its stored login without starting a model turn or
opening a browser, prints `Already authenticated as <email>.` (or `Already authenticated.`) and exits 0; Yardlet takes
only the address from that line. Any other answer (signed out, offline, no answer in time, an `agy` without the action)
leaves the sign-in to whether the `gemini`/`antigravity` keychain item exists, which Yardlet checks without reading its
value. While signed in, Yardlet then runs `agy --print /usage --output-format json` (`AntigravityUsage`). The CLI
answers this command without a model turn and keeps no conversation for it (`num_turns` 0, an empty
`conversation_id`); like any `agy` run it writes its own log. Both runs set `AGY_CLI_DISABLE_AUTO_UPDATE`, so a reading
never starts `agy`'s own updater. The models share limits by group ("Gemini Models", "Claude and GPT models"), and
each group lists buckets with the share left (`remaining_fraction`) and when it refills (`reset_time`). Each bucket is
one row, named by its group without the word "models" and by its window's length ("Gemini · 7 day limit", "Gemini · 5
hour limit"), as Claude's and Codex's windows are named. The length comes
from the bucket's `window` (`weekly`, `daily`, or a count and a unit such as `5h`) or, when that is not one, from the
end of its `id`, which names the window too (`gemini-weekly`, `gemini-5h`); a bucket whose length neither gives keeps
the CLI's own name. An answer that is not `SUCCESS`, or none, shows no rows rather than 0. AI credits (`/credits`) are
not read. Each row keeps its group (`AccountUsageMetric.modelGroup`, which Codex's buckets fill too when an account has
several), and choosing an account counts a group's limits only for the models in it (`AccountRouting`): a task on
`claude-opus-5-5` has room while only the Gemini group is spent, and the reverse. A model is in a group when its name
holds the group's name or one of its families ("Claude", "GPT"). A task whose model is not known, or is in no group of the
reading, could be in any, so every group's limits count for it.

## Continuing after a usage limit

A Claude Code task a plan limit stopped ends its turn on a limit card. Settings › Harness Accounts' **Continue automatically at
usage limit**, on unless turned off as Claude Code 2.1.291's own setting of that name is, arms the card's
"Auto-continue when limits reset" as the limit stops the turn, when the limit resets within a day. One that resets
later, such as a weekly limit days out, waits for the person to turn it on on its card, as Claude Code does not wait past
a day. Once the reset has passed the card offers Resume instead. Either sends the Claude app's own continue message under
the task's own account, and only while the task still stands at that card.

- An armed continue is saved and armed again after a relaunch, within a day of its reset. Claude Code drops its own wait
  when it relaunches.
- Turning the setting off disarms the continues it armed; a card the person armed keeps waiting. Nothing is left but
  the setting's value.
- While a continue waits for a reset still ahead, what another task (`send_message_to_task`), a schedule's run or CI
  auto-fix sends waits in the task's queue and goes right after the continue, as Claude Code holds what comes during
  its wait. The person's own message goes at once and takes over from the wait; if its turn hits the limit again, the
  card it ends on is armed in its place.
- A card read back from Claude's saved conversation takes its limit and reset from the CLI's words ("You've hit your
  session limit · resets 3:50am (Asia/Seoul)"): the saved records keep no limit report.

A Codex limit card names no reset and the Codex app offers no continue on it, so it has neither.

## Usage limit resets

A Codex account can hold banked resets of its plan limits. The App Server reports them in the
`account/rateLimits/read` answer Yardlet already reads for the limits (`rateLimitResetCredits`: `availableCount` and,
for each available reset, an opaque `id`, a `title` and `expiresAt`), so counting them takes no extra request.
Settings › Harness Accounts shows "N resets available" under the account's limits, the sidebar account menu and the menu bar
item add the count to the account's Usage line, and a Codex task's limit card offers "Use a reset (N left)" for the
account the task runs under. Each place opens the same confirmation: the limits a reset restores (the general `codex`
limit, not a model's own), the reset it takes (the one that expires first) and how many are left after it.

Only after the person confirms does Yardlet send `account/rateLimitResetCredit/consume` with an `idempotencyKey` and
that reset's `creditId` to that account's own App Server. The answers are `reset`; `nothingToReset`, when no limit is
close enough to its cap and nothing was used; `noCredit`; and `alreadyRedeemed`, an attempt sent again that had
already gone through, which reads as a reset. A use that got no answer keeps its key, and trying again sends the same
key, so one press never uses two resets. After an answer Yardlet checks the account again. No agent tool can use a
reset. For a personal ChatGPT plan the confirmation also links "Buy an instant reset…" to
`https://chatgpt.com/codex/purchase/reset`, the page the Codex app opens; Yardlet takes no payment.

Claude Code offers banked resets to some accounts behind a server-side flag, but only in its interactive
`/limit-reset` panel: no control request reads or uses them, and `get_usage` carries no count. Yardlet does not read
Claude's OAuth token to call the service itself, so Claude accounts show no resets. The same path takes them once
Claude Code reports them.

## Moving tasks to an account with room

**Settings › Harness Accounts → Move tasks to an account with room** (`AccountMovePreference`, on by default, shown once a
Claude Code account is saved besides the default login) lets Claude Code tasks leave an account that is nearly out of
its limit on their own. Only Claude Code tasks move, to the accounts Continue with another account offers them
(`TaskAccountSwitch`) that automatic assignment may use and that are signed in, and only when `AccountRouting.pick`
picks one with room that offers the task's model (`AppModel.accountWithRoom`); the provider session, scope and history
stay. A task on a model only its own plan offers therefore waits for its reset as one with no room elsewhere does.

What a move costs decides when one happens. Claude Code asks for a prompt cache that lives an hour after a
conversation's last request (`AccountRouting.promptCacheLifetime`), and caches are kept per account; only Claude
Code's own system prompt is cached across accounts. A task that moves while its cache lives makes the new account
process its whole conversation again at the cache-writing price, many times what an ordinary request costs; once the
cache has expired, the next request does that anyway, wherever the task is. So (`AccountRouting.move`):

1. An idle task on a nearly spent account whose cache has expired moves at no cost. It moves as an account's tasks
   move when the account leaves the list (`moveSettledTask`): a task without a runtime does not start its CLI.
2. A task a limit stopped moves and continues on the new account (the same message as Continue with another account,
   `UsageLimitContinuation.afterAccountSwitch`), unless the limit resets before its cache expires: then it stays, and
   its limit card is armed to continue at the reset, as "Continuing after a usage limit" above arms it (kept the same
   way, so it outlasts a relaunch). With no account with room it waits for the reset too, when the CLI named one. It
   waits only for a reset within a day, as Claude Code does; a continue the setting there already armed for that reset
   stays as it is, and only one the person armed keeps a task from moving.
3. A task whose cache lives stays on a nearly spent account until a limit stops it or its cache expires.

A task waiting for its reset that moves under rule 1 continues on the new account at once. A move never cuts into a
turn: it goes through the path of an account chosen during one (`TaskContinuationCoordinator.moveAutomatically`), so a task with
background work or a message on its way moves once that is over, with a line above the composer that says what the
move waits for ("Moving to <account> when its background work ends") and Cancel. The card a move continues from is
the one a stopped task continues from (`UsageLimitContinuation.card`). A turn that starts meanwhile cancels the move,
since it writes the cache again on the current account. Such a move never holds up the person, and never waits
forever (`AccountMoveHold`):

- A message the person sends meanwhile goes at once, on the current account, and calls the move off
  (`AppModel.send`). What another task, a schedule or auto-fix sent before waits in the queue and follows that turn,
  as what is queued during a limit's wait does ("Continuing after a usage limit" above).
- A move still waiting ten minutes after Yardlet chose it (`AccountMoveHold.yardletWaitLimit`) is given up, not
  forced: forcing it would end what still runs in the CLI, such as a dev server. The task stays where it is, and
  what was queued behind the move goes there
  (`ClaudeUsageLimitAppModelTests.testAMoveYardletChoseGivesWayToThePersonAndIsGivenUpAtItsDeadline`).

A move the person cancels, or one given up at its deadline, is not made again until the task works again.
A task that moved keeps why, in its hover card ("Switched from <account>: nearly out of its limit").

Nothing is read for this beyond what Yardlet holds: the accounts' readings, which a running task's own limit reports
keep current; an idle task's last activity (`SessionRecord.updatedAt`, never earlier than its last request but for an
idle compaction's, below); and, for a task a limit just stopped, the last answer, thinking or tool call before the
limit card in the conversation it holds (a compaction after it left nothing cached). Yardlet looks at one task when its
turn ends, at the tasks on nearly spent accounts when the set of Claude Code accounts with room changes (`ProviderConnectionStore.onReadingsChange`),
and once at the moment the next of those tasks' caches expires or a nearly spent limit resets; there is no periodic
scan.

While the setting is on, a schedule's run that continues a task whose cache lives leaves it on its account (see
[NATIVE_SESSION_STORAGE.md](NATIVE_SESSION_STORAGE.md), "Schedules and nearly spent accounts"). On or off, a run moves
its task first only when a move here would go at once (`AppModel.canMoveAutomatically` and `settlesForAccountMove`):
a task with background work, hosted runs or a message on its way stays, and the run goes on its account; a task already
waiting to move keeps that move, and the run's message goes after it; and one whose automatic move the person cancelled
stays until it works again. Turned off, Yardlet
looks at nothing, cancels the moves it was waiting to make, disarms the continues it armed, also before a relaunch, and
schedules move runs as they did before. Moving right after a compaction would also cost nothing, but a compaction happens inside a turn.
An idle compaction (next section) leaves the task's last activity as it was, so a task compacted while idle still
moves at the hour, once the compaction has ended.

Tests: `AccountRoutingTests.testATaskMovesOnlyWhenItsCacheIsLostAnywayOrALimitStoppedIt` (the rule),
`ClaudeUsageLimitAppModelTests.testALimitThatResetsAfterTheCacheExpiresMovesTheTaskToAnAccountWithRoom`,
`testALimitThatResetsBeforeTheCacheExpiresWaitsForTheReset` (with and without room elsewhere, and turning the setting
off), `testAnIdleTaskLeavesANearlySpentAccountOnceItsCacheHasExpired`,
`ScheduledTaskTests.testAContinuingRunMovesItsTaskOffANearlySpentAccountFirst`,
`ClaudeUsageLimitAppModelTests.testAScheduledRunLeavesATaskWhoseMoveWouldWaitOnItsAccount`, and the renders
`ClaudeProviderNoticeRenderingTests.testAnAutomaticMoveWaitsForTheResetOrSaysWhereTheTaskGoes`
(`.build/claude-provider-notices-qa/automatic-move-*.png`) and Settings › Harness Accounts in
`AccountListRenderingTests.testEachModeDrawsTheSameRows` (`.build/account-list-qa/manage-*.png`).

## Compacting idle Claude Code tasks

**Settings › General → Idle compaction** (`IdleCompactionPreference`, on by default, under Tasks) does for Claude Code
tasks what Claude Code's own `idleCompaction` setting does in its terminal and in the apps it recognizes: a long
conversation left idle is compacted shortly before its 1-hour prompt cache expires, so the next message does not write
the whole conversation to the cache again. Claude Code itself never does it in Yardlet's sessions: it compacts while
idle only in an interactive session or one an app on its list launched, and Yardlet runs it headless under its own
entrypoint, which it does not change. Nothing is written to Claude Code's settings.

The rules are Claude Code's (2.1.322; `IdleCompaction`). After a turn ends, the task's timer is armed from the last
request of the main conversation, as the CLI's stream reported it (`ClaudeAdapter`: the `message_start` usage, and its
`message_delta` output): only when that request used the 1-hour cache (it wrote 1-hour cache tokens, or wrote none and
the request before it did), and to fire nine tenths of the way to the cache's expiry, about 54 minutes after the
request. When it fires, Yardlet asks the CLI, without a turn, whether it compacts automatically at all
(`get_context_usage`'s `isAutoCompactEnabled`, which counts `autoCompactEnabled`, `DISABLE_COMPACT` and
`DISABLE_AUTO_COMPACT`) and for its effective settings (`get_settings`), and compacts only when every one of Claude
Code's conditions holds, else records which failed in the task coordination log (`idle-compaction`, with Claude Code's
own word for it):

- auto-compact is on (`compaction_off`) and `idleCompaction` is not false (`idle_compaction_off`): a person whose Claude
  Code settings turn either off gets no idle compaction, whatever Yardlet's switch says;
- the task was not set to another model since the request (`prefix_changed`), whose cache would not be the next
  request's;
- the last request used the 1-hour cache (`not_one_hour`), the cache is still warm and the timer is at most a minute
  late (`lapsed`), so a Mac that slept through it does not compact;
- the context, counted as the CLI counts it (input, cache writes, cache reads and output of the last response), is at
  least `max(100000, CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS ?? 200000)` tokens (`small`), the variable read from the CLI's
  effective settings or its environment;
- no request came after the one the timer was armed from (`newer_request`), and the plan limit the CLI last reported is
  `allowed`, not near or at the limit (`near_limit`).

Yardlet adds its own conditions on the task: its runtime is up, nothing in it works or waits (the same test a move to
another account makes: its turn, a question or approval, a message or shell output on its way, a shell command,
background commands or agents, `run_agent` runs, an edit, another change), and no move to another account is waiting
or under way. Anything sent to the task, or a turn it starts, cancels the timer; a turn's end arms it again. There is
one timer per task and no scan: what the timer needs comes from frames the adapter already reads.

The compaction is the composer's Compact session, `/compact`, sent without the person's part: it opens a turn of its
own with no request in the conversation (the turn before keeps its answer as its last word), the compaction marker
says it happened while idle, before the prompt cache expired, and how to turn it off (on remote clients too, as the
marker's `whileIdle`; [REMOTE_PROTOCOL.md](REMOTE_PROTOCOL.md)), and the command's printed output is left out. The
task runs while it compacts, so a message sent meanwhile waits for it as for any turn, and a move to another account
that comes due waits too. It does not mark the task unread, notify, move it up the list, or clear its
suggested next message, and a compaction's end arms no new timer: the CLI forgets its last request at a compaction.
A CLI that starts again, after a relaunch or for any other reason, arms nothing until the task's next turn, as Claude
Code arms only after a turn of its own process; so a task whose cache lapsed meanwhile is not compacted. Claude Code
saves the compaction as the `/compact` it was sent as, which its records cannot tell from one the person sent, so
Yardlet keeps with the task the compactions it made while idle (`SessionRecord.idleCompactions`, by the boundary's
uuid, the latest 50; [NATIVE_SESSION_STORAGE.md](NATIVE_SESSION_STORAGE.md)): read back after a relaunch, they show as
they did live, the marker with its note, without the command or its output.
Turned off, a timer that fires does nothing and none is armed; nothing else is kept.

Not the same as Claude Code: the request time is when its response began streaming rather than when the CLI sent it,
seconds later; Claude Code's cache renewals that Yardlet cannot see can only make Claude Code fire later, never earlier;
and Claude Code also skips while the person typed in its terminal within the last minute, which has no counterpart in
Yardlet's composer.

Tests: `ClaudeProviderStatusTests.testAnIdleTaskCompactsOnlyWhenClaudeCodeWouldBeforeItsCacheExpires` (the stream, the
CLI's answers and every rule), and the renders of the setting in `SettingsRenderingTests.testTheWholeListAndGeneralsHeadingsDraw`
(`.build/settings-qa/general-headings-*.png`) and of the marker in
`ClaudeProviderNoticeRenderingTests.testLimitCardsCompactionMarkersAndNoticeLinesRender`
(`.build/claude-provider-notices-qa/notices-*.png`).

## Account folder shape, finding sign-ins and removing accounts

Yardlet alone gives the multi-account experience Session Switch gives (continuing a conversation under another account,
automatic assignment), for people who do not use Session Switch. This section covers the shape of the account folders
it makes, how sign-ins in folders other than the default (`CODEX_HOME`, `CLAUDE_CONFIG_DIR`) are found, and how an
account is removed.

### Claude account folders: what stays per account and what is shared

A Claude folder that **Settings › Harness Accounts → Add another account → Continue to sign in** makes
(`~/.yardlet/connections/<UUID>/claude-code`) has the shape of a Session Switch account folder. Every entry of the
default folder (the config folder of Yardlet's default sign-in: `CLAUDE_CONFIG_DIR`, else `~/.claude`) that is not
per-account below becomes a link to it, and Claude Code makes the per-account entries inside the folder. The new
account's `projects` therefore resolves to the same real folder as the default sign-in's, and it takes part in a task's
account switch and in automatic assignment from the start. Code:
`Account/ClaudeAccountHome.swift`.

| Entry | Placement | Why |
|---|---|---|
| Every dot file (`.claude.json`, `.claude.json.backup`, `.credentials.json`, `.session_ingress_token`, `.last-cleanup`, ...) | Per account | The sign-in's identity (`oauthAccount`) and secrets. The macOS Keychain item is also named by a hash of the config folder's path (Session Switch 0.5.2 `keychainService`). |
| `backups` | Per account | Backups of that folder's `.claude.json`; sharing them could restore another account's config. |
| `policy-limits.json`, `remote-settings.json` and their signature, stamp and consent files (`policy-limits*`, `remote-settings*`) | Per account | Policy and remote settings the organization sends. |
| `mcp-needs-auth-cache.json`, `mcp-discovery-cache`, `hfi-auth.json`, and any other name containing auth, credential or token | Per account | MCP sign-in state and authentication files; MCP tokens live in the folder's own Keychain item. An unknown new entry with such a name is not shared either. |
| `cache` | Per account | `model-catalog`, `team-discovery.json` and `model-capabilities.json` differ by plan and organization. |
| `statsig`, `telemetry` | Per account | The account's feature flags and unsent events (`1p_failed_events.*`). |
| `projects` | Shared | The conversation history. Continuing under another account with the same session ID needs one real folder. |
| `sessions` | Shared | The registry of running Claude processes (`<pid>.json`). With one history, recognizing a conversation another account's process holds needs one registry too (`ClaudeConversationCatalog.runningSessionIDs`). |
| `plugins`, `skills` | Shared | What an account syncs from claude.ai is kept inside them in `synced/<organization UUID>_<account UUID>` buckets (the bucket name function in Claude Code 2.1.291; three buckets side by side in a maintainer's `~/.claude/plugins/synced`). Installed plugins and the user's own skills belong to the person. |
| `settings.json`, `settings.local.json`, `CLAUDE.md`, `agents`, `commands`, `hooks`, `rules`, `output-styles`, `workflows`, `keybindings.json` | Shared | The person's settings. Writing through a link keeps the link (a Session Switch folder's `settings.json` link stayed in place while the original changed). |
| `history.jsonl`, `file-history`, `shell-snapshots`, `session-env`, `plans`, `todos`, `tasks`, `teams`, `jobs`, `paste-cache`, `image-cache`, `usage-data`, `scheduled-tasks`, `ide`, `chrome`, `debug`, `downloads`, `local`, `state`, `stats-cache.json` and the rest | Shared | Records per session, project or machine. |

Evidence: the strings of the Claude Code 2.1.291 executable (the names under the config folder and their uses, the
`<org>_<account>` bucket name), Session Switch 0.5.2 (the JavaScript in its bundle and its executable's strings), and the
layout of five Session Switch folders on a maintainer's Mac read with `ls -la`. When Session Switch prepares an account
folder it links the default folder's entries the account folder lacks, so folders where the CLI ran before the links were
made keep real `plugins`, `skills`, `sessions` and `cache`, while folders made earlier link `cache` and `telemetry` too.
Session Switch's layout thus differs from folder to folder, so the table follows whether Claude Code ties each entry to
the account.

- **New folder:** the links are made before the sign-in. When the default folder has no `projects` yet, an empty one is
  made there (the folder Claude Code would make in the same place).
- **Afterwards:** a folder Yardlet made that shares its history with the default folder links what the default folder
  gained since each time the account is checked (as Session Switch prepares its folders before each launch). Only missing
  entries and empty folders change. A folder made before this change that keeps its own history changes only when the
  person chooses.
- **Sharing an existing folder:** when a saved Claude account keeps its history apart from the default sign-in, the
  account row's context menu has **Share With the Default Folder…**. Before anything changes, a sheet
  (`Views/AccountHomeShareSheet.swift`) shows the links to add, the empty folders that become links, what stays because
  it has content, and what stays because it links elsewhere. Only links are made; nothing is copied, moved or deleted. An
  empty folder is removed only with `rmdir`, so one that gained content meanwhile stays. When `projects` already holds
  conversations it stays, and the sheet only describes how to merge them (quit Claude Code everywhere, move the folders
  inside into the default folder's `projects`, then share again).

### Finding sign-ins that are not saved

When Settings › Harness Accounts or either import sheet opens, Yardlet looks only in the places below
(`Account/AccountHomeDiscovery.swift`); it does not search the disk. Walking all of `~/Library/Application Support`
would reach protected folders such as Contacts and could raise permission prompts, so it is not done.

1. `CLAUDE_CONFIG_DIR` and `CODEX_HOME` in Yardlet's own environment.
2. Values written in shell files (`~/.zshenv`, `~/.zprofile`, `~/.zshrc`, `~/.zlogin`, `~/.bash_profile`, `~/.bashrc`,
   `~/.profile`, `~/.config/fish/config.fish`): `export VAR=…`, `VAR=… claude` (inside an alias too) and fish's
   `set -gx VAR …`. A value with a variable other than `~` or `$HOME`, a relative path and a commented line are left out.
   The files are only read.
3. `~/.claude` and `~/.codex`, which the Claude and Codex apps use, when the default sign-in is elsewhere.
4. Folders in the home folder named `~/.claude-…`, `~/.claude_…`, `~/.codex-…` or `~/.codex_…` (a common naming for
   accounts split by shell aliases).
5. Session Switch account folders (`~/Library/Application Support/Session Switch/accounts/*`).
6. Folders of the same shape beside a saved Claude or Codex account's folder. Multi-account tools keep their account
   folders side by side, so adding one of a tool's folders shows the others. Folders directly in the home folder are not
   looked beside.

The default folders and saved account folders (the same real folder through links) are left out. A folder found by its
place alone (4 and 6) must hold a sign-in file (Claude `.claude.json`, Codex `auth.json`); a folder a setting names (1
and 2) may hold only history (`projects`, `sessions`). For Claude only the address and organization in `.claude.json`'s
`oauthAccount` are read; for Codex only whether files exist is checked (the contents of `auth.json` are not read). The
folders appear under the account list as **Accounts You Can Add**, with where each was found, and **Add** saves the folder
as it is. For a Claude folder whose history is apart or whose links are missing, the sheet above first shows what would
change and offers **Add As It Is** and **Link and Add**. **Choose existing account folder…**, where the person picks a
folder, stays.

A multi-account tool Yardlet does not know by name is handled by the general rules 4 and 6: once one of its folders is
saved as an account, the others appear under Accounts You Can Add.

### The organization on an account row

Account rows and account block headers put the organization after the address ("owner@example.com · Personal",
"owner@example.com · Example Team"). claude.ai's default name for a personal organization, "<address>'s Organization",
reads as "Personal" (`AccountIdentityProjection.organizationTitle`). In a narrow row the organization keeps its room and
the address shortens in the middle. The plan line no longer repeats the organization ("Claude Team plan · Example Team"
→ "Claude Team plan"). The sidebar account menu's "address (organization)" is unchanged.

The address and its organization come before the limits beside them (`AccountRowColumns`): the limits keep the width
they need while that leaves the address its whole width, and otherwise a limit name longer than six ems, such as
Antigravity CLI's "Claude and GPT · 7 day limit", shortens to as little as four and a half
(`AccountLimitWindowList.nameShortening`). A window's own name ("5 hour limit", "Weekly limit") is never cut, so a Claude
Code or Codex row is drawn as before. The limits popover keeps the full names.

### Removing an account

Each account row in Settings › Harness Accounts has a menu, opened with a right click or with the "…" button under the row's
limits or status (under them, so it takes no width from the account's name). A saved account's menu has two removal
items. The default sign-in (`~/.claude`, `~/.codex`)
is not removed; its row signs it out instead ("Signing the default sign-in out" below). That sign-out applies only to
the default sign-in (`AccountCenterModel.logout` runs with a broker that has no connection) and never reaches a saved
account's folder.

- **Remove from List…:** clears only Yardlet's record of the connection, its last reading, the new-task account choice
  and its automatic-assignment answer (`ProviderConnectionStore.remove`). The sign-in and folder stay. Tasks on that
  account keep their own copy of the binding (`SessionRecord.connection`), so they go on in the same folder with the same
  scope. The confirmation is short: "The login and its folder stay. The N tasks on this account go on in that folder as
  before." N counts archived tasks too, since they keep the binding as well. This is the only removal for a Session
  Switch folder.
- **Moving the tasks first:** when a Claude account with tasks has another saved folder signed in to the
  same account, Remove from List opens a sheet (`Views/AccountRemovalSheet.swift`) instead of the confirmation, as account
  tools offer to hand a removed account's work to another account. It chooses between moving the tasks to that folder
  (the default, with a picker when there are several) and leaving them in this one (Remove from List as above). A folder
  qualifies when its last reading is signed in with the same address and organization as the account's (the same key the
  list groups accounts by; another organization has its own limits) and its `projects` resolve to the same folder
  (`ProviderConnectionStore.taskMoveTargets`). **Move and Remove** (`AppModel.moveTasks(from:to:)`) first asks the
  target folder's own CLI `auth status` and goes on only when it reports signed in to that address and organization.
  Then each task changes as **Choose account** changes one: the binding alone changes, and the provider session ID,
  scope and history stay. Archived tasks move too and stay archived. A listed task that had a runtime gets it back under
  the target's login with the same session ID; one without starts there at its next turn. A task waits while the memory
  saver would keep its runtime, except for being on screen and for session jobs, which the resumed runtime brings back:
  a turn or a question, messages or a shell command on their way, the harness's background commands (closing the
  runtime would end them), subagents it hosts, an edit, its runtime starting, or another change or continuation. It
  moves once that is over, as soon as its turn ends rather than at the move's next look, and the account's row shows
  how many still wait. From
  the target's confirmation on, nothing new starts on the account: automatic assignment and the account lists that
  start or move a task leave it out, the new-task account choice and the schedules that named it move to the target,
  and a task started on it any other way (an agent naming it, a schedule made meanwhile) starts on the target
  (`ProviderConnectionStore.startConnection`). Only when every task has moved does the account leave the list. A task
  that cannot move stays on the account, and the account then stays on the list with the reason on its row and takes
  new tasks again; choosing Remove from List again moves the rest. A confirmed move is kept in Yardlet's preferences
  (`Yardlet.accountTaskMoves`, account → target) until it ends, so after a quit the next launch goes on with it
  (`AppModel.continueAccountTaskMoves`) and asks the target's CLI again. Nothing in either folder is copied, moved or
  deleted.
- **Sign Out and Delete…:** offered only for a Claude, Codex or Grok Build folder Yardlet made
  (`<connections>/<UUID>/<harness>`, `signOutAndDelete`), the CLIs that sign out from the command line without asking.
  Yardlet runs that CLI's `auth logout` (Codex and Grok Build: `logout`) in the folder's environment; only when it
  succeeds does it take the account off the list, remove every link in the folder first (only `unlink`), and move the
  `<UUID>` folder to the Trash. When the sign-out fails, nothing changes. When tasks use the folder, the confirmation
  offers only Remove from List. The shared originals (`~/.claude` and the like) and Session Switch folders have no way to
  be deleted from Yardlet.

### Signing the default sign-in out

While the default sign-in's last reading says its CLI can sign out, its row's menu in Settings › Harness Accounts offers what
the Harnesses page offers beside it (`AccountListProjection.defaultLoginActions`): **Sign Out…** (**Disconnect
Provider…** for OpenCode and Pi, which connect model providers, where connecting another needs no sign-out) and, for an
account sign-in, **Sign In With Another Account…**. A harness that keeps its sign-in in one place and cannot have a
separate account folder (the keychain items of Antigravity CLI and Cursor Agent,
`HarnessConnectionCapabilities.supportsSeparateHome`) changes account only this way.

- Both confirm first, then run the harness's own sign-out command in the sign-in console
  (`HarnessAccountBroker.logoutCommand`), as the Harnesses page does.
- A sign-out that exits (`claude auth logout`, `codex logout`) is finished when it exits with 0. One the CLI does in
  its own terminal and stays open after (`/logout` in Antigravity CLI, Kimi Code and Pi) is finished when the harness's
  credential-free probe reads the default sign-in signed out; the console then stops the CLI, and that reading becomes
  the sign-in's reading.
- Sign In With Another Account then starts the harness's sign-in in a new terminal of the same console. A sign-out that
  fails or is cancelled starts nothing.
- No file, folder, task binding or saved account changes.

The Antigravity CLI row shows the signed-in address that `AGY_CLI_CDE_AUTH_ACTION=check agy` prints
(`Already authenticated as <email>.`); when `agy` prints only `Already authenticated.` or the check falls back to
keychain item presence, the row says "Unknown account". Yardlet never reads the keychain item's value.

### Importing conversations from other folders

- Both import sheets (conversations from other apps, and per folder) list found folders in the account choice, marked
  "(folder found)". Importing a conversation under one saves the folder as an account first
  (`ProviderConnectionStore.saveIfFound`). History is not moved or copied.
- "Import Conversations from Other Apps" chooses a Codex account too, not only the default Codex sign-in's threads.
- In the same sheet the Claude list adds, after the Claude app's open sessions, the 200 most recent other conversations in
  the chosen account folder's `projects` (`ClaudeConversationCatalog.recentConversations`), so
  conversations held in that folder through a terminal or another tool appear too. Each conversation's folder is the `cwd` its transcript records.

### Codex: not given the same shape

Codex 0.163.0 accepts a shared-link layout too: two temporary homes with `sessions` and the like linked, and App Servers
started without a sign-in, both read the same thread with `thread/list` and `thread/read`, and the links stayed (source
`openai/codex` `rust-v0.163.0`). New Codex accounts still keep their own folder.

- Codex resends stored encrypted reasoning (`reasoning.encrypted_content`) and compaction results unchanged in the next
  request (`core/src/client.rs`), and OpenAI's servers reject that ciphertext from any organization other than the one
  that made it with "Encrypted content organization_id did not match the target organization" (a case of switching from a
  ChatGPT sign-in to an API key:
  [community](https://community.openai.com/t/codex-app-cannot-resume-session-after-api-key-switch-encrypted-content-organization-id-mismatch/1374803),
  [LiteLLM incident report](https://docs.litellm.ai/blog/responses-api-encrypted-content-incident)). Codex has no
  recovery that resends without it (no such string in the 0.163 executable;
  [#53713](https://github.com/openai/codex/issues/53713) is open). Continuing from ChatGPT account A to B is supported only
  by user reports ([#50859](https://github.com/openai/codex/issues/50859)). A thread continued under another account
  could become unusable.
- Sharing would also need SQLite moved with `sqlite_home` (`CODEX_SQLITE_HOME`; with file links, corruption recovery moves
  the link and that account alone diverges), `thread-writer-locks`, `rollout-migrations` and `.tmp` shared together with
  `sessions`, and would break a file link to `session_index.jsonl` (rewritten by rename) and the macOS sandbox's writes
  for memory consolidation if `memories` were linked.
- Per account regardless: `auth.json`, `secrets/`, `app-server-daemon/` and `app-server-control/`, `models_cache.json`.
- Confirming it needs two paid turns (one reasoning turn on account A, then the same thread on account B), which the
  user has to approve. Session Switch's Codex support keeps one home and swaps authentication headers per request through
  a proxy, so it carries the same risk, and its help says compatibility of thinking and server threads across accounts is
  not guaranteed. Yardlet adds no proxy (see the first section).

### Verification

`AccountHomeTests` (the new folder shape, sharing an existing folder, the finding rules, importing another folder's
conversations, Remove from List and Sign Out and Delete; a fake that removes instead of using the Trash, and a fake CLI
for the sign-out), `AccountIdentityTests` (the organization), and
`AccountListRenderingTests.testSettingsNamesOrganizationsAndOffersFoldersFound` (Settings › Harness Accounts and the sheet, light
and dark, `.build/account-list-qa/manage-found-*` and `share-sheet-*`). The confirmations are AppKit alerts that a
windowless render cannot draw, so only their text is given above.

Choosing an account during a turn: `ClaudeAccountFolderTests.testSwitchResumesTheSameSessionOnlyUnderASignedInSharedAccount`
(nothing restarts during the turn or while it waits for approval, a cancelled choice leaves the task, the switch at the
turn's end resumes the same session and the message sent meanwhile goes to the new account's runtime, and a refused
switch shows its reason and pauses that message) and `ComposerStreamQARenderingTests` (the line and the composer's
Return, light and dark, `.build/composer-stream-qa/composer-claude-moving-account-*`; both wordings of the line under
a limit warning, `.build/claude-provider-notices-qa/notices-*`).

Signing the default sign-in out: `AccountListTests.testSettingsListsEveryFilteredHarnessGroupedByAccountAndSearchable`
(which rows offer which items) and `AccountListRenderingTests.testTheDefaultLoginSignsOutOrInWithAnotherAccountFromItsRow`
(the row's menu as a right click builds it, and its "…" button; a fake `agy` that stays open after `/logout` with a
fake probe, signing out alone and then signing in with another account; a fake `claude` whose `auth logout` exits;
light and dark, `.build/account-list-qa/default-login-*`).

Moving the tasks first: `ClaudeAccountFolderTests.testMovingAnAccountsTasksKeepsTheirSessionsAndRemovesItOnceAllMoved`
(fake account folders and CLI: which folders qualify, a target whose CLI reports another address takes nothing, not even
new tasks, a task in a turn moves when its turn ends without waiting for the next look, the archived task stays archived
with the new binding saved, only the task that had a runtime resumes, and once the target is confirmed automatic
assignment leaves the account out while the new-task choice, a schedule, an agent naming the account and a task started
on it go to the target), `ClaudeAccountFolderTests.testAMoveAQuitCutOffGoesOnAtTheNextLaunch` (a move cancelled
mid-wait is kept, the relaunched store keeps the account out of new tasks, the move finishes and leaves no preference
behind) and
`AccountListRenderingTests.testRemovingAnAccountOffersToMoveItsTasks` (the sheet and the waiting row, light and dark,
`.build/account-list-qa/move-sheet-*` and `move-waiting-*`). With the Claude Code 2.1.308 CLI and two empty account
folders linking `projects` to one folder, starting the CLI as Yardlet resumes a task (`--resume=<id>`, stream JSON, only
the `initialize` request) found the saved conversation through either folder and answered; an unknown ID ended with "No
conversation found". No sign-in or model turn was involved.
