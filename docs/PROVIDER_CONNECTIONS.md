# Harness, model provider and account connections (2026-09-15)

The need: see the remaining usage of several accounts, choose the account directly, and use a structure that is not
limited to ChatGPT. Harness connections are kept apart from model provider authentication, and each harness is
connected only through the paths it actually supports. No arbitrary model proxy and no OAuth token conversion or
copying are added.

The latest screen flow and design decisions follow [ACCOUNT_SELECTION_UX.md](ACCOUNT_SELECTION_UX.md).

## What the user does

- In **Settings › Accounts → Add account** (the sidebar's **Connections** opens this section), the user connects a
  separate account, or points to an existing CLI account folder in the advanced settings. Existing sign-ins appear in
  the same list, and the name and folder are optional. A new folder is created and the harness's official sign-in and
  provider setup opens. A new Claude folder keeps only the sign-in's own files and links the rest to the default folder
  ("Account folder shape, finding sign-ins and removing accounts" below); other harnesses' new folders start empty. The
  CLI keeps owning secret values.
- In **Choose account** next to the project and harness of a new task, the user chooses after seeing the remaining
  limits and reset times. The choice is kept with the draft, and the account binding is fixed just before submission.
- Resuming, forking and side chats of a task use the saved account environment together with the native session ID.
  Changing the default account for new tasks does not change the account of existing tasks.
- Claude Code can switch, from **Choose account** in the task menu, only to an account that uses the same conversation
  history folder (2026-10-06). It is allowed only when the `projects` of the two account folders point, through links,
  to the same real folder, so the session ID and history location stay the same and no file is moved or copied. Session
  Switch account folders have this structure (`projects` and the like link to `~/.claude`, and only the sign-in is kept
  per account). If the CLI of the target account does not confirm the sign-in in `auth status`, the switch does not
  happen. It does not switch during a turn in progress or while waiting for approval, and after the switch it
  reconnects with the same session ID.
- When usage is not published, it is shown as not available. Short-term and long-term limits are shown separately,
  not combined, and a limit without a number is not turned into 0.

## Support boundaries

| Harness | Model supply path | Extra account environment | Remaining limits | Changing the account of an existing task |
|---|---|---|---|---|
| Codex | The default OpenAI service or a provider set in the CLI | CODEX_HOME | primary/secondary of the account the App Server publishes | Choose the environment in a new task |
| Claude Code | The default Anthropic service or a provider set in the CLI | CLAUDE_CONFIG_DIR | 5-hour, weekly and per-model weekly limits from the CLI `get_usage` control request | Choose among accounts that share the same history folder |
| Pi | A separate model provider | PI_CODING_AGENT_DIR, provider choice | Not shown when the CLI does not publish it | Choose the environment in a new task |
| OpenCode | A separate model provider | Per-account XDG data/config/state/cache | The existing CLI lookup boundary | Choose the environment in a new task |
| Hermes Agent | A separate model provider | HERMES_HOME | No safe structured lookup | Choose the environment in a new task |
| Other harnesses | The default or external provider settings that the CLI owns | Keep the existing connection | Only public lookups verified before | No extra paths are made up |

The Gemini CLI entry was removed in an earlier installed build, and it is separate from choosing a Google model
provider in other harnesses such as Pi. Gajae Code and Oh My Pi (including Deep Agents Code) were dropped from the
default list on 2026-10-23. The Gajae records in the evidence section below stay as the evidence of that time.

For OpenCode, Yardlet hosts the provider and authentication method choice of the official `auth login`. For Pi, it
looks up the provider that the user specifies or that is set in Pi's own settings.json. Without a setting, it does not
assume ChatGPT as the default provider. The default Pi connection and adding a new Pi account choose the provider
first. Pi's authentication method choice screen is also recognized as waiting for input.
Pi's explicit provider sign-in keeps the existing
`auth check --provider … --json --no-refresh` completion detection and the guard against cancellation and late replies.

## Storage and process contract

`~/.yardlet/provider-connections.json` stores only the name, harness, provider ID, account folder and selector. Tokens
and API keys are never read or copied. The file uses atomic write and 0600 permissions, and a failed read never
overwrites the original file. A new account folder is 0700.

`account-snapshots.json` in the same folder (2026-10-08) holds the latest lookup results, so the account list shows
them as soon as it opens. For each connection ID (`native:<harness>` for the default sign-in) it keeps only whether the
account is signed in (`signedIn`/`signedOut`), the account name, organization and plan line that the CLI reported, the
limit rows (name, used ratio, display text, reset time and kind of evidence) and the lookup time. It keeps no tokens,
credentials, account folder paths, CLI output or per-task token usage. It uses atomic write and 0600; when it cannot
be read, it starts empty and the next lookup writes it anew. When a lookup confirms sign-in or sign-out, the entry is
rewritten, and when action is needed (a missing folder and the like), it is removed. When a lookup cannot finish
(time-out, error), the screen keeps the last sign-in value but marks it "Couldn't refresh", and when there is no
runtime, it shows that state as is. A sign-in remembered from the last run is not a candidate for automatically
replacing the default account of new tasks (`replaceSignedOutDefaultSelection`). Only what this run confirmed is used.
The account chip in the new task composer uses the account name remembered with a signed-in state in the same file. So
the name stays visible while the next run checks again. This name is for display only and has nothing to do with
binding, selection or credentials. Before the check, with no remembered name, it shows "Checking account…". (The
`account-labels.json` that a branch kept separately was folded into this file at merge and is not created.)

Reading and checking have one owner, `ProviderConnectionStore` (2026-10-08, B5). It holds the values of the default
sign-ins and saved accounts, `AccountReadingStatus` and the checking indicator, and the account screen
(`AccountCenterModel`) handles only the sign-in console. A check starts only through
`check(defaultsOf:savedOf:connectionIDs:policy:checkUsage:runtimeSelections:)`.
- If a check of the same account (`native:<harness>` for the default sign-in, the connection ID for a saved account,
  the per-account-home list for GJC) is already running, no new CLI process starts; it waits for that check.
- There is one freshness rule: a value that a check in this run confirmed as "current" within the last minute is not
  checked again when the list opens (`ifStale`). Values remembered from the last run and "Couldn't refresh" values are
  always checked again. The refresh button (`refresh`) checks again even when the value is fresh, but joins a check
  that is running.
- After the sign-in console ends or the runtime changes (`restart`), the answers of checks started before are
  discarded and a new check runs. Only the answers of checks or reads started later (Codex account notifications, the
  Pi sign-in check) stay on screen.
- The Codex default sign-in is read in the same environment as the app's Codex tasks (`CodexEnvironmentManager`). The
  Codex account notification monitor runs on a single App Server, only while the account screen is open.

SQLite's nullable `connection_binding` preserves `SessionRecord.connection`. A null value in past tasks keeps the
existing native/yardlet scope meaning. Importing native history does not treat tasks with a different provider ID,
scope or account binding as the same task. If a registered folder has disappeared or a GJC account is gone, it does not
fall back to the default account.

A separate environment does not receive the parent process's model API keys, OAuth overrides or model routing
overrides. HOME and the general development tool environment are kept. A provider adapter can be configured in the
harness's own settings, but Yardlet does not guarantee an arbitrary provider connection for an arbitrary engine.
Existing tasks are not moved to another account folder, and native conversations are not duplicated.

Each harness has one runtime that reads its accounts and starts its new tasks (2026-10-27). Unless the person chose
one, it is the newest version among the installs on this Mac; a runtime the person chose is kept, and Settings ›
CLI Updates offers a newer install found elsewhere. Installs are looked for in the desktop apps' bundles and where the
person's shell would find them, not only in Yardlet's own `PATH`, which has only the system's folders when Yardlet
opens from the Dock: `~/.local/bin`, the package managers' folders (bun, Volta, Cargo, Deno, `~/.npm-global/bin`,
pnpm, each Node version of nvm), Homebrew, `/usr/local/bin`, `PATH` and the system. The same account can see different models depending on the
runtime's version: the App Server's `model/list` answered one user's older Codex without the GPT-6.1 models. Creating a
task records its runtime on the task only; it does not become the harness's choice. Choosing a runtime with Choose…
under Runtime and connection details checks the accounts again with `restart`.

GJC lookup runs only the public `accounts list --json` automatically. Pressing **Refresh usage** runs the CLI-owned
`accounts check --json` and then reads the list again. It never opens the auth DB or credential payload directly, and
it does not pass API-key/env rows off as OAuth multi-accounts.
Switching accounts rechecks the binding and task state, closes that handle and resumes with the same provider session
ID. Other tasks' handles and drafts stay. A closed ACP transport is not reused.

## Verification

- Full `swift test`: 669 tests, 660 passed, 9 opt-in live tests excluded, 0 failures.
- With three Codex account folders (including spaces in the path), creation, restart, resume with the same ID, fork and
  keeping the original native home were verified through subprocess + YHP + AppModel + SQLite. It is a fixture without
  authentication.
- With GJC's public inventory and a real ACP subprocess fixture, switching A→B→A, keeping another B task connected, the
  same session ID, keeping the draft, refusing a deleted account and keeping the permission/abort policy were verified.
  No model prompt was sent.
- On the real installed Codex 0.153.4 and Claude Code 2.1.270, empty separate account environments were read with
  `login status`/`auth status`, and they were confirmed not to inherit the existing account.
- Real OAuth sign-ins of the user's three accounts, paid model turns and really exhausting each account's limits were
  not done. Each CLI performs the user's sign-in.
- In a native UI fixture, comparing the limits of three accounts, choosing the default account of a new task and the
  popover's choice of another account taking effect were verified.

Evidence: the accounts CLI, account-inventory and root flags in the official Gajae Code v0.16.0 source; the docs and
CLI source of the installed Pi 0.84.1; the official OpenAI App Server account docs.
Reproduction logs are in `.build/provider-connections-*.log`, and the fixture is in `scripts/fixtures/codex-session-home.py`
(`gjc-account-selection.py` for Gajae was deleted together with Gajae Code on 2026-10-23).

## Claude plan limit lookup (2026-10-06)

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

## Account folder shape, finding sign-ins and removing accounts (2026-10-27)

The user asked that Yardlet alone give the multi-account experience Session Switch gives (continuing a conversation
under another account, automatic assignment), for people who do not use Session Switch; that sign-ins in folders other
than the default (`CODEX_HOME`, `CLAUDE_CONFIG_DIR`) be recognized; and asked whether an account can be removed.

### Claude account folders: what stays per account and what is shared

A Claude folder that **Settings › Accounts → Add another account → Continue to sign in** makes
(`~/.yardlet/connections/<UUID>/claude-code`) has the shape of a Session Switch account folder. Every entry of the
default folder (the config folder of Yardlet's default sign-in: `CLAUDE_CONFIG_DIR`, else `~/.claude`) that is not
per-account below becomes a link to it, and Claude Code makes the per-account entries inside the folder. The new
account's `projects` therefore resolves to the same real folder as the default sign-in's, and it takes part in a task's
account switch (the 2026-10-06 exception) and in automatic assignment from the start. Code:
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

When Settings › Accounts or either import sheet opens, Yardlet looks only in the places below
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

Parallely, a multi-account tool a user reported, is not installed on this Mac, and no public documentation for it was
found (web search, 2026-10-27). It is handled by the general rules 4 and 6 instead of by name: once one of its folders is
saved as an account, the others appear under Accounts You Can Add.

### The organization on an account row

Account rows and account block headers put the organization after the address ("owner@example.com · Personal",
"owner@example.com · Example Team"). claude.ai's default name for a personal organization, "<address>'s Organization",
reads as "Personal" (`AccountIdentityProjection.organizationTitle`). In a narrow row the organization keeps its room and
the address shortens in the middle. The plan line no longer repeats the organization ("Claude Team plan · Example Team"
→ "Claude Team plan"). The sidebar account menu's "address (organization)" is unchanged.

### Removing an account

A saved account row's context menu in Settings › Accounts has two items. The default sign-in (`~/.claude`, `~/.codex`)
keeps only the harness page's sign-out, as before. That sign-out applies only to the default sign-in
(`AccountCenterModel.logout` runs with a broker that has no connection) and never reaches a saved account's folder.

- **Remove from List…:** clears only Yardlet's record of the connection, its last reading, the new-task account choice
  and its automatic-assignment answer (`ProviderConnectionStore.remove`). The sign-in and folder stay. Tasks on that
  account keep their own copy of the binding (`SessionRecord.connection`), so they go on in the same folder with the same
  scope. The confirmation is short: "The login and its folder stay. The N tasks on this account go on in that folder as
  before." This is the only removal for a Session Switch folder.
- **Sign Out and Delete…:** offered only for a Claude or Codex folder Yardlet made (`<connections>/<UUID>/<harness>`,
  `signOutAndDelete`). Yardlet runs that CLI's `auth logout` (Codex: `logout`) in the folder's environment; only when it
  succeeds does it take the account off the list, remove every link in the folder first (only `unlink`), and move the
  `<UUID>` folder to the Trash. When the sign-out fails, nothing changes. When tasks use the folder, the confirmation
  offers only Remove from List. The shared originals (`~/.claude` and the like) and Session Switch folders have no way to
  be deleted from Yardlet.

### Importing conversations from other folders

- Both import sheets (conversations from other apps, and per folder) list found folders in the account choice, marked
  "(folder found)". Importing a conversation under one saves the folder as an account first
  (`ProviderConnectionStore.saveIfFound`). History is not moved or copied.
- "Import Conversations from Other Apps" now chooses a Codex account too; it used to read only the default Codex
  sign-in's threads.
- In the same sheet the Claude list adds, after the Claude app's open sessions, the 200 most recent other conversations in
  the chosen account folder's `projects` (`ClaudeConversationCatalog.recentConversations`). It used to read only the
  Claude app's list, so conversations held in another folder through a terminal or another tool did not appear even when
  that account was chosen. Each conversation's folder is the `cwd` its transcript records.

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
`AccountListRenderingTests.testSettingsNamesOrganizationsAndOffersFoldersFound` (Settings › Accounts and the sheet, light
and dark, `.build/account-list-qa/manage-found-*` and `share-sheet-*`). The confirmations are AppKit alerts that a
windowless render cannot draw, so only their text is given above.
