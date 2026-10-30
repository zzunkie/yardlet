# Native harness session storage

Each harness keeps its conversations, sign-in and settings where its own CLI puts them. Yardlet keeps a link index and
its own interface state beside them, reads provider history to show it, and does not move, copy or rewrite what the
provider owns. This document describes what Yardlet stores for each task, what it reads from each harness, and the
conditions under which it changes anything. Account folders and sign-ins are covered in
[PROVIDER_CONNECTIONS.md](PROVIDER_CONNECTIONS.md).

## Task identity and storage scope

A task's row in Yardlet's index keeps three things together: the provider session ID, the storage scope it was saved in
(`SessionEnvironmentScope`) and the account binding (`connection_binding`). Resume, fork, side chat, title lookup and
every read of saved history use the values stored on the task; none of them looks up a global "current account".

- **`.native`** is the scope of every new task (`SessionRecord`, `SessionStore` and `HarnessRegistry` default to it).
  The task uses the harness's own storage environment. Codex uses the default `~/.codex`, or a native home set earlier,
  and Account Center's lookup, monitor, sign-in and sign-out look at the same home. The harness performs the actual
  authentication.
- **`.yardlet`** is a compatibility scope for Codex tasks saved in Yardlet's dedicated Codex home
  (`~/.yardlet/harnesses/codex/home`). Such tasks keep that home and their provider ID when the index is restored, and
  resume and side chat forks use that home too. Their files are not moved or deleted automatically, and the
  authentication state of the dedicated home is not replaced with the native account.
- The stored scope is passed through to the Codex adapter and the actual process. A native launch uses the original home
  directly. Only a `.yardlet` task prepares, when its process starts, a snapshot of the original home's capability files
  (`config.toml`, `AGENTS.md`, skills, the plugin cache and rules) for the dedicated home; credentials, sessions,
  history, SQLite and logs never enter it. App launch and new task creation do not prepare it, and the Codex process
  that reads settings follows the native default.
- Importing native history compares the scope and the ID together. Even if the same string ID exists in a separate
  home, the wrong existing task is not chosen.
- Config, authentication, history and SQLite are not copied to a new home, and `sqlite_home` in the original config is
  not rewritten.

## Choosing an additional account

When the person chooses a separate account for a task, the task stores the harness, the model provider and the account
home in the nullable `connection_binding` (`ProviderConnection`), together with the provider session ID and the scope.
The binding holds routing metadata only; sign-ins and secrets stay in the harness's own store. A task whose binding is
null uses the harness's default sign-in and the storage described above. Creating a task under a separate account copies
no native authentication or conversation files. Resume, fork, side chat and title lookup follow the stored binding, and
changing the default account for new tasks does not change existing tasks.

`ProviderConnection` also has a `credentialSelector` field, for one account inside a credential store that several
accounts share. No built-in harness chooses an account that way, so `ProviderConnection.validate(for:)` rejects a
binding whose selector is not nil, and creating, attaching or rebinding a task with such a binding fails. The field
stays only so that a saved task's binding is written back exactly as it was read.

No action moves an existing task to another account folder, with one exception for Claude: a task's binding changes only
when the `projects` folders of the two account folders resolve to the same real folder (`TaskAccountSwitch`,
`ClaudeConversationStorage`). The history is then already in the same place, so nothing is moved or copied, and the
provider ID, scope and history location stay the same. Reading Claude history follows only the one `projects` link
directly under the config folder, and rejects links and FIFOs below it. Removing a saved Claude account can first move
all its tasks, archived ones included, to another saved folder signed in to the same account under the same rule; only
the binding changes (see [PROVIDER_CONNECTIONS.md](PROVIDER_CONNECTIONS.md), "Removing an account").

**Automatic account assignment.** Child tasks an agent starts (`create_task`), subagents (`run_agent`) and suggestion
chips the person starts begin on one of the harness's accounts in automatic assignment (`AccountRouting`). The chosen
account is stored from the start as the new task's `connection_binding`, together with the provider session ID and the
`.native` scope, and later resume, fork and title lookup follow that binding. The account, history and scope of existing
tasks do not move. Unless the person says otherwise, assignment uses the default sign-in and the accounts that keep
their conversation history in the same place (`ProviderConnectionStore.isInAutomaticAssignmentByDefault`). A child task
started under a Claude account folder whose `projects` links to the default `~/.claude/projects`, as Session Switch's
account folders do, therefore stays in the same history whichever account it uses, and the account switch above still
works for it. A Codex sign-in with a separate `CODEX_HOME` has its own history, so it is not used until the person
includes it. An account whose tasks are moving to another of its folders before it leaves the list is not used either.
No authentication or history files are copied and no account folder changes. The reason for each
assignment is kept in the Yardlet file `~/.yardlet/account-assignments.json` (task ID → account ID, window and time).

**Account folders, found sign-ins and removal** (see [PROVIDER_CONNECTIONS.md](PROVIDER_CONNECTIONS.md), "Account
folder shape, finding sign-ins and removing accounts"). A Claude account folder Yardlet makes for a new sign-in links
`projects` and the other shared entries to the default folder, so that account's tasks write to the default sign-in's
history from the start and can switch accounts as above. Existing tasks' history, scope and account do not move. Sharing
a folder that kept its own history ("Share With the Default Folder") only adds links; when its `projects` already holds
conversations, that folder stays as it is, and its tasks keep reading their own history there. "Remove from List"
neither clears nor changes a task's `connection_binding`: the task goes on in the same folder with its stored binding and
scope. "Sign Out and Delete" is offered only for a folder Yardlet made, and only when no task uses it. Importing a
conversation from a found folder (another `CLAUDE_CONFIG_DIR` or `CODEX_HOME`) saves that folder as an account first;
the new task points at the native session ID with that binding and the `.native` scope, and the history stays in its
folder. Codex account folders keep their own history.

## Yardlet's own records

Yardlet keeps its link index in `~/.yardlet/session-index.sqlite3`, together with drafts and read caches. This data is
separate from the harness's native conversations and session IDs.

- **Codex read cache:** `~/.yardlet/transcripts/<task UUID>.json` keeps `[TranscriptEntry]`. Entry IDs are name-based
  UUIDs (v5) made from the thread, turn and item IDs, so they are the same at every checkpoint; the message that opened a
  turn is named from the turn ID alone. A reading position saved while the task was detached therefore connects to the
  Codex turn ID once it attaches (`ConversationAnchorResolver`). Random IDs in older caches are still read, and are
  rewritten with name-based IDs at the next checkpoint. The two bookmarks `transcript` and `codex` in the task view
  state (`Yardlet.taskWorkspace.<id>`, version 1) keep their format.
- **Codex timeline cards:** cards missing from Codex history (commands, file changes, tool calls, image generation and
  the answers of interrupted turns) are kept in `~/.yardlet/codex-timeline-items/<task UUID>.json` as
  `[CodexPersistedTimelineItem]` JSON, the latest 500 cards per task. At launch, a value still left under the older
  preference key (`NativeHarnessClient.codexTimelineItems.<task UUID>`) is moved to the file unchanged and the key is
  deleted; if the file already exists, the file is kept. Archiving or deleting the task deletes the file.
- **Messages that joined a running turn:** read cache entries of every harness have an optional field
  `joinsRunningTurn` (Bool). It is written as `true` only for a follow-up message that Claude Code read at the next step
  of a running turn; otherwise the key is absent. Older caches read it as nil, and older builds ignore the key. The
  conversation draws such a message inside the turn that was running instead of as a new turn. When Claude history is
  reread (opening a detached task, importing), the `queued_command` attachment entry in which Claude left that message is
  also read as a message with this mark and placed in the same turn. This applies only to Claude history.
- **Images in sent messages:** user entries in the shared transcript carry the images sent (URL and name). Yardlet's
  read cache and the side chat context JSON store only the file URL and name, not the bytes of inline data URLs. Inline
  images are previewed only from live entries and provider history (Claude rereads the JSONL when a task opens), and
  entries restored from the cache show with the name "Image". The preview is read-only and does not create files or
  fetch remote URLs.
- **Codex mode per task:** the chosen Plan/Default preset is stored as `codex.collaborationMode` JSON in the task's
  provider options. Changing the model, reasoning level or Fast does not clear it. Before resume it is restored to the
  same task's adapter, and when the runtime's list is read, it is matched to the current preset by ID first and by mode
  second; if the runtime renamed a preset, the same mode is looked up in the new list. Tasks without the key, or with a
  key that cannot be read, do not get a mode added. Turning Plan off explicitly or starting to implement a plan stores
  Default. If saving fails, the provider choice goes back to the previous mode. Forks and the pass-through of
  new-conversation options follow the stored value as is. The Codex service tier is an optional field in the same
  selection JSON. The provider ID, account, scope, native history and drafts are not moved or changed.
- Per-file drafts in Files are stored in app-owned workspace preferences.

## Runtime paths

The Claude app keeps the Claude Code CLI at `claude-code/<version>/<package-hash>/claude.app/Contents/MacOS/claude`.
Discovery and the relocation of a missing runtime use the same helper (`RuntimeRelocation`) to find, in version order,
the older flat path and completed packages that have a regular `.verified` marker. Incomplete packages, wrong markers and
linked directories are excluded. The helper knows only the layouts of desktop apps that bundle a runtime (the Claude app
for Claude Code, the ChatGPT app for Codex); a user-managed CLI that disappeared is not guessed. When such an app
replaces its runtime while Yardlet runs (the Claude app deletes the previous version when it updates),
`RuntimeSelectionStore.selectedURL` returns the successor path right away, as the next launch would. A task whose
recorded runtime no longer exists is pointed at that successor, or else at the harness's current selection, when the
index is restored and before it attaches (`AppModel.sessionWithAvailableRuntime`); a recorded runtime that still exists
is not changed. Only the executable changes: the provider ID, storage scope, account binding and native history stay,
no credentials are copied and there is no sign-in.

## Opening a saved task

**Claude Code.** On selection or status refresh, and before resume, Yardlet reads the native main chain of a detached
Claude task with the stored provider ID, account/home, scope, runtime and workspace. It reads the newest part of the
file first and earlier parts as the person asks for them ("Reading long histories in parts" below, which also gives the
limits). A late result is not applied if the task is attached or running, or if its identity or cache changed. Entries
use stable native UUIDs, and the reading anchor moves only on a unique content match. Drafts and native files are
preserved, and on failure the cache and ID stay. There is no automatic import, session move or model input, and no copy
of credentials or homes.

**Codex.** Opening a detached Codex task reads the saved thread through that task's App Server (same account and storage
scope) with `thread/read`, so commands and file changes show too (YHP `yardlet.codex.thread.read`). It reads only the
metadata (`includeTurns: false`) and one page of the newest turns, and reads earlier pages on scroll ("Reading long
histories in parts" below). It does not send `thread/resume` or `turn/start`, and does not change the account, home or
authentication. The read cache stays as the first view, and the thread read replaces it in the same conversation view
(the reading position carries over through the name-based IDs above). The read itself saves nothing; when the app
quits, the read cache is rewritten from that view, as for any other visible Codex thread. A failure or a response
without turns leaves the cache as it is.

## Editing, forking and restoring files

**Editing the latest input.** `TaskDraftSnapshot.editState` is optional JSON that stores together the original provider
ID, account, scope and workspace, the user/assistant boundary, the unsent draft and attachments from before the edit,
plus a bounded read cache. Existing draft JSON is read as is and the index schema does not change. Opening or cancelling
an edit does not write provider history. Before sending, Yardlet checks again that the original is the same and idle.

- Codex reads the retained history after a native revert or legacy rollback on the same ID, then sends the input. A
  runtime that does not support legacy rollback answers with an unsupported-method response, which is handled as that
  exact failure, and the draft and original are preserved. Other errors are not turned into "unsupported", and the
  native format is not migrated automatically.
- Claude first stores the planned new UUID in the draft, then switches the same local record's provider ID and the
  existing `inherited_context.nativeForkSource` together. A prepared switch stays fixed across restarts and retries, and
  the earlier native JSONL is not modified or copied to another home. There is no cancel after sending that goes back to
  the original ID. Late events from a retired handle cannot overwrite the new ID.

**Editing the first message.** The first message has no fork assistant boundary, so the origin below is kept but not
injected as text context. `HarnessNewSessionConfiguring` explicitly prepares a new `--session-id` launch with the same
native ID only when the stored planned ID does not exist yet. If a stored child exists, it resumes with its own ID, and a
damaged or replaced file is not swapped for an empty conversation. Ordinary resume does not use this new-session path.

**Codex Retry** is a native empty continuation without a copy of the original input. The original provider ID, scope,
account, draft and retained history stay, and Yardlet reads the new latest turn to reject duplicate or late actions.

**Editing Claude messages with native images.** Only text and base64 images from the active chain are restored into the
shared draft. The original image's MIME type and decoded bytes are stored as an immutable data URL and passed over YHP as
an `inline_data` block. They are not turned into local files, and remote URLs are not read.
`ConversationEditState.originalInputFingerprint` is an optional digest that stays compatible with existing JSON, and
checks right before sending whether the original user content changed. The attachment preflight comes before the
provider ID/history switch. Cancel restores the original unsent text and attachments. Editing does not copy or move
provider history, homes or credentials. At most 8 base64 images, each at most 8 MiB decoded, are restored within the
scoped JSONL read limit, and documents, unknown types and non-base64 images are not restored as edit input.

**Opening the original of an edited conversation.** When a Claude message is edited, the optional JSON in
`inherited_context.nativeConversationOrigin` stores the original provider ID, harness, account/home, scope, workspace,
runtime, options and project/additional roots together. It stays compatible with the existing context/draft JSON and the
SQLite schema. Opening the original reads that binding's main chain with a bounded read and links the original ID to a
separate local record. It also reads the last unanswered user input, and does not reuse a record because the same ID
exists in another home or scope. The current chat, draft, reading position, ID and native files are preserved, and there
is no provider attach, model send or authentication change. An open record with the same binding is reused as is. Old
context without native metadata is not linked to the current account by guesswork.

**Claude file checkpointing** is turned on with the provider process's native environment flag. No new checkpoints are
created and inserted into history already saved. Restoring files is a `rewind_files` dry run on the original user UUID
followed by an explicit separate run, and does not switch the conversation. For changed files, only regular files in the
stored workspace or additional roots are read, their fingerprint is fixed at review, and it is checked again before the
run. Symlinks, FIFOs, files outside the scope and review results that changed are rejected.

**Native fork and reset.** Forking from a chosen Codex turn sends the original ID together with `lastTurnId` and creates
a separate local record with a new provider thread ID. The source's history is not rolled back or reverted. A Claude fork
uses the same account, scope and workspace as the parent and fixes the original assistant UUID. The new UUID and the
original ID and point are stored together in the optional `nativeForkSource` of the `inherited_context` JSON. With a CLI
that does not create the child file before the first input, a restart still prepares the native fork at the same
boundary, and if the child's native file is stored, it resumes with that ID. If preparing the native fork fails, it does
not fall back to a text snapshot. File lookup uses the existing scoped read boundary, and native files are not written
directly or moved to another home. The existing context JSON and DB schema stay compatible, and older snapshot side
chats are not converted automatically. Reset creates an empty local record with the same project, account and scope. The
existing ID, history, draft and read state are preserved, and that native session is not cleared. The project/additional
roots and stored options are kept as well.

## Reading subagent conversations

With the provider session ID, account binding and scope stored on the parent task, Yardlet reads only the native
subagent logs in that Claude config. Task IDs, agent IDs and tool-use IDs are kept as optional UI metadata and do not
become new provider session IDs. Reading involves no native session resume, task creation, model turn, change of the
parent's selection or history write. The current record's storage scope is also checked before and after reading the
file. Subagent conversations are read-only, and this does not mean that direct input to a separate child session is
supported.

## Provider titles

Title refresh rereads the provider titles of tasks whose harness stores one (Grok Build, Claude Code, OpenCode, Kimi Code
and Antigravity CLI; `ProviderTitleSource.pull`, `ProviderSessionTitleResolver`) at app launch, on task selection and
when the app becomes active again. It reads only native metadata the resolver supports, and when the provider is
detached it does not resume the task or send a message. Codex is not read this way: the attached session announces the
thread's `name` in its presentation (`ProviderTitleSource.push`), and a detached Codex task is not woken to ask. Both
sources use the same rules for applying a title.

- Manual names and old names of unclear origin are kept. Only provider/automatic/provisional titles and legacy records
  whose title is exactly the first prompt are candidates.
- Applying a title does not change `updatedAt`, and repeated SQL writes of the same title are skipped. Pins, read state,
  provider options, drafts, selection and recent-activity order are preserved.
- The per-session read token and the latest record's ID/scope/title/origin are checked again. A late response does not
  overwrite the result of a newer read, a manual name, a deletion, a cancel or a shutdown.
- Attaching a task, the start and ready status reports the runtime sends on attach (when no turn was in progress), and
  saving settings such as model, reasoning and mode do not change `updatedAt` either. Recent activity is sending, a turn
  in progress, waiting for approval, completion, failure and renaming.

## Archive and unarchive

Archiving can be undone. **Archived tasks** at the bottom of the sidebar (also in the Task menu and the command palette)
shows the archived tasks in place of the task list, most recently archived first, searches them by title, project and
harness, and restores them with **Unarchive**.

- **Index:** the `archived` column is 0 (listed), 1 (archived) or 2 (deleted, or created and then discarded by a failed
  fork, import or side chat). Archiving writes `archived_at` and `provider_archived` together. Rows written before these
  two columns existed have no date and read as `provider_archived = 0`, and rows deleted or discarded at that time are
  also 1, so they show among the archived tasks too (there is no record to tell them apart).
- **Unarchive:** sets the same row back to `archived = 0`. The provider session ID, storage scope, account binding,
  project, additional roots, pin and title stay as they are. A task archived while running comes back in the ready
  state, as when restored after a relaunch. If the task's project was hidden, it becomes visible again. It does not open
  or attach the task and does not start a model turn.
- **Codex native thread:** Yardlet's archive sends `thread/archive` only when the Codex task is attached. Only then is
  `provider_archived = 1`, and unarchive sends only `thread/unarchive` (`threadId`) to the App Server of that account
  and scope, then restores the index. There is no `thread/resume` or `turn/start`. If it fails, the task stays archived
  and can be tried again. Tasks archived while not attached, or without a record like older rows, leave the native
  thread alone. Native-side archive, unarchive, delete and rename go only to adapters that implement
  `HarnessSessionLifecycleProviding` (Codex and its YHP wrapper).
- **Local caches:** archiving deletes the draft, the conversation cache and the Codex timeline cache. An unarchived
  Claude task rereads its native history when opened, and a Codex task reads its native thread with `thread/read` when
  opened and loads the conversation from the native thread on continue (`thread/resume`) or the next send.

## Importing conversations from other apps

Import adds only what the person chose, one index row each. It does not copy or move native history, authentication or
homes, and stores the provider session ID, the `.native` scope and the account binding together.

- **Import does not start a runtime:** an imported task is created detached, like a task restored after a relaunch (no
  `attach`). It attaches on the first send. When opened, Claude rereads the native JSONL and Codex reads the thread with
  `thread/read` ("Opening a saved task" above). For a Codex task imported from a search result, the match positions are
  asked only with `thread/searchOccurrences` on the App Server of the same account and scope. A conversation already
  imported (same harness, scope, provider ID and account, or for Claude an account that shares the history) opens the
  existing task.
- **Bulk import (File > Import Conversations from Other Apps…):**
  - The Claude source is the Claude app's
    `~/Library/Application Support/Claude/claude-code-sessions/<org>/<account>/local_*.json`. These are undocumented
    files the Claude app owns, so they are only read (4 MiB per file, at most 2,000 files, links excluded), and a
    missing key or a value of another type counts only as that value being absent. Only sessions that are not archived
    and whose `cliSessionId` history is in the chosen Claude account's `projects/<folder name>/<id>.jsonl` show. The
    provider session ID is `cliSessionId`, and the account is the one chosen in the sheet (by default the new-task
    account).
  - The Codex source is `thread/list` on the App Server of the default Codex sign-in (`~/.codex`). It asks with no
    folder, `archived: false` and `sourceKinds: ["cli", "vscode", "appServer"]` (YHP
    `yardlet.codex.history.interactive`), and also drops from the response threads whose `source` is `exec` or
    `subAgent`, threads that have a `parentThreadId` and `ephemeral` threads. Codex app threads have the `vscode` source
    (codex-cli 0.157.1). The account is the default Codex sign-in (no binding).
  - Placement is decided in one place, `ConversationImportPlacement`. Chat folders from `ChatWorkspaces` get no project
    (no project is created), a Claude app worktree (`cwd` inside `originCwd`) goes to the original repository's project,
    and the rest follow the same rule as new tasks (`projectForNewTask`). The task folder is always the conversation's
    `cwd`, and the worktree's origin, name and branch go into the existing `origin_workspace_path`, `worktree_name` and
    `branch` columns. The folder's Git records come first, and if the folder does not exist, the session file's values
    are used.
  - Values carried over: the title (`titleOrigin` provider), and Claude's model, effort and permissionMode
    (`ClaudeLaunchOption` keys, `default` becomes `manual`, others stay as they are). Codex values are not carried over
    because the thread holds the model. The task's recent activity is the other app's last activity.
  - On relaunch, the folder-to-project conversion does not create projects for tasks already shown in a project (by ID,
    folder or worktree origin) or for chat folders.
- **Claude conversations held by another app:** the Claude app keeps the CLI process of an open session alive, and one
  process streams only to its own client. Two processes must not both continue one conversation, so if a live process of
  another app holds that session ID in the chosen account's `sessions/<pid>.json` (child and grandchild processes
  Yardlet started are excluded), Yardlet refuses attach, send and `resume`, and shows "This conversation is still open
  in the Claude app. It continues here once you close it there." on the task. The draft stays and the task state does
  not change. Import itself is not blocked. Once that process ends, sending attaches as usual.
- **Read-only following:** while a detached Claude or Codex task is visible, Yardlet checks the size and modification
  time of the native file (the Claude JSONL, or for Codex the rollout `path` the last `thread/read` reported) every 2
  seconds, and if they changed, reads it again with the same guards as the open path. Only the newest part is reread
  ("Reading long histories in parts" below). It saves, sends and resumes nothing. It stops when the task attaches or is
  no longer visible.
- **Codex boundary:** there is no registry that tells which threads another App Server has open, so Codex has no send
  guard. Sending from Yardlet to a thread the Codex app is still running can make two App Servers continue the same
  rollout, and coordinating this is the provider's job.

## Reading long histories in parts

Opening a detached task does not read the whole history first. It reads and shows only the newest part, and reads more
of the earlier part when the person scrolls to the top of the conversation or presses ▲ on the rail. Following what
another app writes also rereads only the newest part. Every read uses the provider ID, account and storage scope stored
on the task, saves, sends, resumes and attaches nothing, and does not change native history, authentication or homes.

The open read starts the moment the task is selected, and when the pointer rests on a sidebar row for 120 ms, a detached
task not yet read in this run is read ahead (`AppModel.readSavedConversation`, `prefetchSavedConversation`). What is
read, the scope and the account are the same, and the only thing written is Yardlet's read cache. A conversation with
nothing to show while it is read shows as loading instead of "Start a conversation".

- **Codex (detached tasks):**
  - On open: through that task's App Server (the registry adapter, same account and scope) it reads `thread/read`
    (`includeTurns: false`, metadata and the rollout `path`) and only the newest turns with `thread/turns/list`
    (`sortDirection: "desc"`, `itemsView: "full"`, `limit` 5 = `CodexThreadPaging.newestTurns`). The response has `data`
    (newest first), `nextCursor` (before it, that is, earlier turns) and `backwardsCursor` (after it), and codex-cli
    0.157.1 answers even for threads that are not loaded. `nextCursor` goes into the existing `turnsNextCursor`, and in
    the conversation it is `ConversationEarlierTurns.provider(cursor:)`.
  - Earlier pages: `loadMoreCodexTurns` does not attach a detached task. It reads `thread/turns/list` (that cursor,
    `limit` 10 = `CodexThreadPaging.earlierTurns`) through the same App Server and puts the result in front. A page that
    arrives after the task attached or the cursor changed is dropped. Attached tasks use the adapter's `loadTurns`, with
    the same 10 turns a page.
  - Following and reopening: for a thread already shown, only the first page of `thread/turns/list` is reread and merged
    (`CodexTaskReducer.mergeNewestTurnPage`). Turns in the page replace the ones held, and turns after the page's oldest
    turn that are not in the page (reverted turns) are removed. Turns read before that and the cursor stay. If no turn
    overlaps (more than a page of turns piled up), it starts over from that page.
  - YHP: the optional field `newestTurns` of `yardlet.codex.thread.read` (`HarnessProtocolCodexThreadReadParams`).
    Without it, the whole thread is read (older peers). The method `yardlet.codex.thread.turns.read`
    (`HarnessProtocolCodexThreadTurnsReadParams`: `threadID`, `cursor`, `limit` → `HarnessProtocolCodexTurnPage`, turns
    oldest first). Neither creates or registers a session.
  - The read cache (`[TranscriptEntry]`, at most 500 entries) is rewritten from the visible thread, so it holds only the
    turns loaded.
- **Claude (detached and attached tasks):** reading further back has no overall size cap and can reach the start of the
  file.
  - Read budget `ClaudeTranscriptTail`: first the last 1 MiB of the file (`readNewest`). Each time earlier turns are
    wanted it doubles (2, 4 and 8 MiB), and after that it grows by 8 MiB (`stepBytes`: 16, 24, 32 …) up to the start of
    the file. The budget counts from the end of the file at the time of the first read. The budget and the range read
    live only in memory, per task and provider ID (a different conversation ID starts over). Nothing is saved.
  - Window (`ClaudeTranscriptWindow`): an index of the lines read (record ID → line offset, length, parent,
    `logicalParentUuid`, kind, meta, sidechain and tool call/result IDs, with no body), the request record of the first
    visible turn and its entry (the boundary), plus whether the chain continues earlier (`hasEarlierRecords`). It also
    keeps the file's device and inode and the size at the first read, so it reads no further in a changed file (another
    inode, a smaller size).
  - Reading further back (`readEarlier`, `readEarlierTurns`): reads and parses only the bytes before the window and adds
    them to the index (for the same ID, the line later in the file wins). The chain continues from the boundary record's
    parent into the newly covered part, and its projection is put before the visible entries. The first turn the read
    cuts into (the part before its request) is left out, and if the read has not reached any turn's request yet (a turn
    longer than one step), nothing is inserted and it reads further. Records before the boundary that were already
    covered (a turn left out earlier) are read again from the file through the offsets in the index. Several steps
    within one request carry the parsed values forward, so the same bytes are not parsed twice. Entry IDs are built from
    the history's uuid and order (`session|uuid|ordinal`), so reading in parts gives the same result as reading the same
    budget at once.
  - If the last turn is longer than the first read, only part of that turn shows (without its request)
    (`partialRecord`/`partialEntry`). Reading further back projects the whole turn again from its request and puts it in
    place of that part (`ClaudeTranscriptRead.replacesThrough`, `TranscriptBuilder.replaceEntries(through:)`).
  - If the first read (`readNewest`) starts inside an earlier turn, the tail of that turn (its last step and final
    answer) is not left out but shows above the first request (`partialEntry` is the last entry of that part, and the
    boundary is the first request), so a final answer just after the window boundary still shows on screen and in
    `read_task`. Reading further back puts the whole turn in that place, as above. When the file is followed again
    (`refreshConversation`), the new read is spliced in from its first request (`ClaudeTranscriptWindow.splicing`).
  - Claude Code's notice that a background command or agent finished (`origin.kind` "task-notification", a
    `<task-notification>` block) is read as the entry that opens the turn answering it, and shows on screen not as the
    person's bubble but as a "Background task" notice line (`ClaudeTaskNotification`, a summary). The previous turn's
    final answer stays that turn's answer. It is not an edit or rewind point.
  - A prompt sent by Claude Code's own schedule is also an entry that opens its turn (`ClaudeScheduledPrompt`). Stored
    shape (Claude Code 2.1.299): `CronCreate` jobs and `/loop` wake-ups are `type: "user"`, `isMeta: true`,
    `promptSource: "system"`, `turnOrigin: "scheduled"`, a new `promptId`, `turnPosition` and `queueSkipAttachments`
    (the CLI writes every queued prompt that has a `wakeupSource` this way, so the stored shape is the same in both
    cases), and a Claude app scheduled task is not meta and is a `<scheduled-task name="…" file="…/SKILL.md">` block with
    `origin: {kind: "task-notification", subkind: "scheduled-trigger"}`. The entry carries
    `TranscriptEntry.origin = .scheduled` (left out of the stored shape when absent), and shows on screen not as the
    person's bubble but as a box folded to two lines under "Scheduled check-in" on the left ("Scheduled task: {name}"
    when there is a name, the Claude app's wording), and in `read_task` as "Scheduled task: …". It is not an edit,
    rewind or file restore point (scheduled prompts have no `file-history-snapshot`). Continuation entries with the same
    `promptId` (`isMeta`, `turnCompanion: true`, "Your response above was cut off mid-stream…") and compaction summaries
    that inherited the turn's origin (`isCompactSummary`) are left out and kept within the same turn.
  - In an attached task, when the CLI starts a turn from a command in its own queue (a scheduled prompt, a background
    notice, a message from another session), stream-json carries only `command_lifecycle` (`started`, `command_uuid` =
    the stored entry's uuid) → `system/init` → the answer → `result` → `completed`, with no `user` frame
    (`--replay-user-messages` does not replay scheduled prompts either). The history is written every 100 ms, so the
    entry is not there yet at `started`. When a `started` for a uuid Yardlet did not send arrives while no turn is
    running, the adapter emits `providerStartedTurn(messageID:)`, and the app opens a turn without a request
    (`origin = .provider`) in that place, then finds that uuid's line in the last 1 MiB of the file (looking again from
    0.15 s up to about 10 s) and fills it with the same projection as the rules above
    (`ClaudeSubagentTranscriptReader.request(savedUnder:sessionID:)`, `TranscriptBuilder.settleRequest`). It only reads
    and writes or sends nothing. If it never finds the line, the turn stays without a request.
  - Compaction: the reads that show the conversation (`readNewest`, `readEarlier`, `readConversation`) do not stop at a
    compaction boundary but connect the earlier history through `logicalParentUuid`. The boundary shows as a compaction
    marker (`.compaction`, with the token count from `compactMetadata`), and the summary (`isCompactSummary`,
    `isVisibleInTranscriptOnly`) is hidden. Edit and fork points (`readSession`, `conversationPoints`) still stop at
    compaction.
  - For an attached task, everything from the first turn on (including what the runtime streamed) stays as it is, and
    the turns read are put before the boundary entry (`TranscriptBuilder.replaceEntries(before:)`). In the conversation
    this is `ConversationEarlierTurns.providerFile`, and the marker disappears once the read reaches the start.
  - If the saved reading position is an entry that was visible last time but lies outside the newest part, Yardlet reads
    further back until that entry comes in (up to 8 MiB, `placeBytes`).
  - Following and reopening (`refreshConversation`) rereads only the newest 1 MiB, and if the request of its first turn
    is among the visible entries, replaces from that point (turns loaded earlier and the window stay). If it does not
    meet them at a request, it reads further up to 8 MiB, and if it still does not meet them, it starts over from the
    newest part.
  - Limits: reading the main conversation is not refused at 20,000 lines (it is bounded by the bytes read at once).
    Reading subagent conversations still stops at 20,000 lines. The entry limit of a Claude task is the entries read +
    2,000 (`TranscriptBuilder` at most 200,000). The read cache keeps at most 500 entries.
  - Edit, fork and file restore (`readSession`, `conversationPoints`) and subagent conversation reads keep an 8 MiB
    limit.

## Reading task resource usage

Task resource usage only reads `sessions/<pid>.json`, to attribute Claude conversations that another app runs to Yardlet
tasks. It follows the same rule as "Claude conversations held by another app" above: the task's provider session ID must
be in `sessions` of the config folder the task's account uses (a Session Switch account folder follows one link to the
shared folder), and Yardlet's child and grandchild processes are excluded. In addition, if the file's `startedAt`
differs from the start time of that pid's process by more than 30 seconds, the file is treated as a stale file whose ID
another process took over, and skipped. If `entrypoint` is `claude-desktop` it shows "Claude app", otherwise "Another
app". Only changed files are reread (by modification time and size), and files of 64 KiB or more or of another shape are
skipped. It writes or moves nothing, and does not change the task's provider ID, account, scope or history.

## Moving a task to another project

The storage contract is as follows.

- **Only two columns of the index row change:** `project_id` (the project moved to, NULL when moved back to chats) and
  `additional_roots` (`TaskProjectMove.additionalRoots`: the project's roots minus the task folder and, for a worktree,
  its origin root, or empty for chats). `SessionStore.moveSession` writes them with the existing upsert. There is no
  schema change. `workspace_path` (cwd), the provider session ID, storage scope, account binding, runtime, title,
  status, pin, unread, recent activity (`updated_at`) and the worktree origin columns stay as they are. Native history,
  homes and authentication, drafts (keyed by task ID) and read state are not touched, no file on disk is copied or
  moved, and nothing is written to the provider (no Codex `thread/metadata/update`).
- **A relaunch does not undo it:** a task's project comes from the stored ID first
  (`ProjectProjection.project(for:in:)`). A moved task belongs to its project by ID, so
  `ProjectStore.ensureProjects(forTasks:)` and the folder settings conversion do not create a project from its folder,
  and a task moved back to chats is in a chat folder, so none is created for it either. Importing again only opens the
  existing task with the same provider ID and does not change the row.
- **When the additional roots reach the harness:** on attach (`runtimeWorkspaceRoots` of `thread/start` and
  `thread/resume`, `--add-dir` when launching Claude). An attached task keeps its running turn and session, and the new
  roots are passed the next time it starts or attaches again (relaunch, resume after a lost connection).
- **Import does not use the Codex app's projects:** threads from `thread/list` and `thread/read` on the codex-cli
  0.157.1 App Server have a `projectId` field, but the Codex app keeps the result of a move in its own global state
  (`THREAD_PROJECT_ASSIGNMENTS`) and tells the App Server with `thread/metadata/update {threadId, projectId}` only when
  its server project feature is on, so the field is normally `null`. Import placement therefore follows the folder rules
  above. When that feature is on and `projectId` arrives, the roots could be read with `project/read` (a method in the
  binary that Yardlet does not call) and used for placement.

## Reading pull request links

For a task's pull request, Yardlet reads from a Claude Code task's history only the
`{"type":"pr-link","sessionId","prNumber","prUrl","prRepository","timestamp"}` records that the Claude Code CLI writes.
The rule is the same as for reading the conversation: with the provider ID stored on the task, the one file with that ID
under `projects` in the config folder the task's account uses (following only one link and rejecting links and FIFOs
below it, `ClaudeSubagentTranscriptReader.pullRequestLinkScan`).

- The first read goes backward from the end of the file 1 MiB at a time, stops at the newest record, and goes up to 8
  MiB (`ClaudePullRequestLinkScanner`). Claude Code keeps writing the record again, so the newest one is normally close
  to the end. After that, if the same file (device, inode) has not shrunk, only the appended bytes are read, and a line
  still being written at the end is read next time. A changed or shrunk file is read from the end again.
- The path of the found file under `projects` is kept in memory, and the next scan reads it without searching the folders
  again if it is still the same file (device, inode). If it is gone or a different file, it is searched for as the first
  time (two files with the same name are rejected).
- Only the record's number, URL and repository are kept in memory (per task). Conversation text is not kept, nothing is
  written or moved, and there is no model turn, attach or authentication change. If the history has no such record,
  Yardlet asks `gh` with the folder's branch (reading only Git files).

## A task's parent link

Sidebar nesting records the task a task was started from in that task's index row only.

- **Column:** `sessions.parent_task_id TEXT`, nullable, the parent task's Yardlet ID (independent of the harness).
  Existing rows are NULL (top level), earlier builds without the column do not read it, and their saves (only the listed
  columns of `ON CONFLICT DO UPDATE`) do not clear the value. The `inherited_context` JSON is not used because it is
  the conversation context of side chats and forks (a value there changes the send and edit paths), and
  `provider_options` is not used because it holds the harness's launch arguments. The provider session ID, storage
  scope, account, task folder, history, drafts and recent activity stay as they are.
- **When it is written:** when a task is created (fork, subagent, opening the original, import), or when
  `SessionStore.linkParents` fills in empty links only. An existing link is not overwritten, and a link to the task
  itself or one that makes a cycle is dropped. A link is not activity, so the task keeps its place. Archive and
  unarchive leave the link as it is. Restoring the index also reads the archived rows' links
  (`SessionStore.archivedParentIDs`), so the sidebar nests a task whose parent is archived under the nearest ancestor
  it lists; nothing is written for it.
- **Reusing a child task:** reusing an existing child task and linking the parent the provider reports (including
  import and thread reads) compare not only the harness and provider ID but also the stored `environmentScope` and the
  whole account binding. The default account's null binding is told apart from separate accounts, and even with the same
  account ID, a task is not reused if its storage home differs. A new child task keeps the parent's `projectID` and
  `additionalRoots`. These values are used for resume's `runtimeWorkspaceRoots`, the MCP task folder scope and project
  instructions (including when they are turned off for the project). Before opening a subagent conversation, and after
  creating or resuming a new child task, Yardlet checks that the parent's stored session identifiers are still the same,
  and if they changed, discards only the child task it just created. History, drafts and reading positions in other
  storage scopes stay.
- **What is read from the Claude app:** from `ClaudeDesktopSessionCatalog`, the same as for the import list (the Claude
  app's `local_*.json`, read only, with the same size and count limits), it additionally reads only `sessionId` (the
  app's `local_` ID), `spawnedFrom.sessionId`, `forkedFromSessionId` and `lineageDetached`. It links only when the
  `cliSessionId` of both the child and the parent are provider IDs of Yardlet tasks. The Claude Code CLI history does
  not have this relation (CLI 2.1.291 does not know `spawnedFrom`). It reads at every import (linking from the list, and
  for Claude rereading the files to also link children imported earlier) and once at a launch where the preference
  `Yardlet.taskLineage.claudeAppLinksRead` is not yet set, which then sets it. If there are no Claude tasks or all have
  links, it does not read.
- **What is read from Codex:** `forkedFromId` from `thread/list` (the import list), and `forkedFromId` and
  `parentThreadId` when a thread is read (`thread/read`, `thread/resume`, fork). There are no extra requests.
- Nothing is written to native history, Claude app files or Codex threads, and there is no model turn, attach or
  authentication change.
- **Detaching to the top level:** the row menu item "Detach to top level" clears `parent_task_id` and sets the column
  `sessions.lineage_detached INTEGER NOT NULL DEFAULT 0` to 1 (`SessionRecord.isLineageDetached`,
  `SessionStore.detachFromParent`). `linkParents` and `TaskLineage.links` do not link a task with 1 again (import,
  reading Claude app files and reading Codex threads alike). Existing rows are 0, earlier builds that do not know the
  column do not read it, and their saves do not clear the value. Re-linking by such an earlier build cannot be prevented
  (that build does not know the mark). Detaching is not activity either, and archive and unarchive leave the mark as it
  is. Sessions detached in the Claude app (`lineageDetached`) are imported without a link, but tasks that already have a
  link in Yardlet stay as they are (links are not overwritten).

## Outcomes of task suggestions

Task suggestion chips ("Task suggestion tools" in [AGENT_BROWSER_TOOLS](AGENT_BROWSER_TOOLS.md)) do not store the
suggestion itself. What was suggested is the `spawn_task` call and Yardlet's answer in the harness history, and Yardlet
keeps only what happened after that, next to the task.

- **Storage:** `UserDefaults` `Yardlet.taskSuggestions.<task ID>` = `{"version":1,"resolutions":{"task_1a2b3c4d":{"outcome":"started"|
  "dismissed"|"sentHere","at":…,"startedTaskID":…}}}` (`sentHere` is "Do it here"; earlier builds that do not know it
  cannot read the outcomes of a task that has this value and clear them), the latest 100 per task (the same limit as the
  Claude app's `resolvedBackgroundTaskSuggestions`). The index schema, `provider_options` and the task view state
  (`Yardlet.taskWorkspace.<id>`, cleared on archive) are not used.
- **Archive and delete:** archive and unarchive leave it as it is, and deleting the task deletes it too.
- **Draft:** the new-task draft (`home` in `~/.yardlet/drafts/drafts.json`) has an optional field `suggestion` (the
  suggesting task's ID, the suggestion ID, title, prompt and `parentTaskID`, the parent task ID the agent set with
  `parent_task_id`; without it, the suggesting task). It goes away when the draft is cleared or a task is created from
  it. Older drafts without it are read as they are. The chip's "Options" is a popover and does not open the draft, so
  nothing writes this field now; drafts that already have it are read. Values chosen in Options are not saved (they last
  only while the app is running).
- **The task created:** its parent link (`sessions.parent_task_id`) is the suggesting task (or the task the agent gave
  as `parent_task_id`), and if the prompt was not edited, its title is the suggestion's title with `title_origin`
  `manual` (the harness title does not replace it). A task created with "Start", which starts right away, inherits the
  account (`connection_binding`) and `provider_options` (model, effort and permissions, without next-message
  suggestions) of the task that became its parent, and gets a new provider session ID and storage scope like any other
  new task. A task created from the draft of "Options" is the same as any other new task.
- **Do it here:** sends one message from the person ("Do this task here: “title”") to the suggesting task through the
  same path as the composer. That message stays in the harness history as the person's message (the Claude app does the
  same).
- Nothing is written to harness history or Claude app files. The Claude app's `backgroundTaskSuggestions` and
  `resolvedBackgroundTaskSuggestions` are not read.

## Antigravity CLI conversations

Antigravity CLI (`agy` 1.4.0) keeps its conversations in `~/.gemini/antigravity-cli`. Yardlet only reads them
(`AntigravityConversationStore`) and writes nothing.

- **Index `conversation_summaries.db`:** the `/resume` list of `agy`. It is in WAL mode, so opening it read-only can
  still create `-wal` and `-shm`, and Yardlet makes a copy (with `-wal` if present) in a 0700 temporary folder, reads it
  and deletes it right away (64 MiB limit). Columns read: `conversation_id`, `title`, `preview`, `step_count`,
  `last_modified_time`, `workspace_uris` (a JSON array of file URIs), `parent_conversation_id`, `nesting_depth` and
  `app_data_dir`.
- **What is imported:** rows whose `app_data_dir` is `antigravity-cli` (rows of the app, `antigravity`, are left out
  because the CLI can continue them only after copying them into its own store from the Other tab of `/resume`), with
  `nesting_depth` 0 (subagent conversations excluded), `step_count` > 0 and a known folder (the row's `workspace_uris`,
  or else the folder → ID entries in `cache/last_conversations.json`). An imported task has provider session ID =
  `conversation_id`, the `.native` scope and no binding (Antigravity has a single keychain sign-in), and is detached.
  The title is the `title` the CLI made (or else the first line of `preview`), and the parent is
  `parent_conversation_id`. A conversation already imported opens the existing task. The CLI also records the
  `--add-dir` folders of a conversation's first turn in `workspace_uris` and restores them when continuing, so Yardlet
  does not pass its own folder to Antigravity. The conversation's folders are only the user's work folders.
- **Log `brain/<id>/.system_generated/logs/transcript_full.jsonl` (or else `transcript.jsonl`):** when a detached task
  opens, and while it is visible whenever the size or time changes, the last 8 MiB is read. Records `{step_index, type,
  source, status, created_at, content?, thinking?, tool_calls?, error?, input_tokens?, …}`: `USER_INPUT` (the request
  is inside `<USER_REQUEST>`, and the CLI metadata after it is dropped), `PLANNER_RESPONSE` (thinking, tool calls
  `{name, args}` and the answer), `GENERIC` ERROR (a failed call, step number = response step + 1 + call order) and
  `SYSTEM_MESSAGE` (not shown). Tool output is not in the log.
- **Relation to the cache:** Yardlet's read cache (`~/.yardlet/transcripts/<task>.json`, including live output) is kept
  until the log has more requests. If the cache is empty (import, unarchive) or the log has more requests, the view
  switches to the log and then rereads it on every change. When the task attaches (a turn is sent), this state is
  forgotten and decided again from scratch. A failed read leaves the cache and ID as they are.
- **Title:** the pull path for task titles (`ProviderSessionTitleResolver`) reads `title` from the index. It is not read
  before the first turn (local placeholder ID).
- **Model list:** the collapsed model list a task read is kept in `antigravity` of `model-catalogs.json` (an optional
  field that earlier builds ignore), and the new task view uses it.
- Native conversations, the index, logs, settings and credentials are not copied, moved or modified, and reading alone
  causes no model turn, attach or authentication change.

## Reading the last context usage and its history

So that the composer ring and the session rail's Context card still show after a restart, Yardlet keeps the last value a
task showed next to its index row, and rereads it from the harness history when the task opens.

- **Column:** `sessions.context_usage TEXT`, nullable, `TaskContextUsageSnapshot` JSON `{"providerSessionID":…,
  "recordedAt":<seconds>, "provider":HarnessProtocolUsage?, "codex":CodexThreadTokenUsage?}`. Existing rows are NULL,
  earlier builds that do not know the column do not read it, and their saves (only the listed columns of
  `ON CONFLICT DO UPDATE`) do not clear the value. `upsert` does not write it either: only `saveContextUsage`
  (`UPDATE … SET context_usage`) does. It is not activity, so `updated_at`, order and read state stay. Archived rows are
  not read, and they are read again after unarchive. A value that cannot be read counts as absent.
- **When it is written:** when a harness report (`usageUpdated`, the turn usage of a Codex thread) or a history read
  changes the value shown, in order per task. The same value is not written again. `providerSessionID` is the task's
  conversation ID at that time, and on restore, if the task's conversation ID differs (new chat, fork, edit branch), the
  value is dropped.
- **Claude Code history:** from the end (from 1 MiB) of `projects/<folder>/<session>.jsonl`, which is already read when
  a detached task opens or is followed, it additionally uses only the main chain's last response `message.usage`,
  `message.model` and `timestamp`. The context window is looked up in the optional field `claudeContextWindows` of
  `model-catalogs.json` (model name → the `rawMaxTokens` that `get_context_usage` reported; earlier builds ignore it).
- **Codex rollout:** from the end (from 1 MiB up to 8 MiB) of the `path` that the detached task's `thread/read`
  reported, it reads only the `info` of the last `event_msg` `token_count`. It does not search Codex folders to find the
  rollout, and does not read Codex's SQLite or settings.
- Native history, rollouts, CLI settings and credentials are not copied, moved or modified, and reading alone causes no
  model turn, attach, resume or authentication change.

## Following the session list

Yardlet keeps its task list up to date with the conversations Codex and Claude Code hold, the way the Codex app shows
every thread in `~/.codex` without an import. Import ("Importing conversations from other apps" above) adds only what
the person chose, once; following adds and updates the rest, read-only (`SessionListFollow`,
`AppModel.followSessionLists`). There is no control, menu or shortcut, and the import sheet stays as it is.

- **Sources (read only):**
  - Claude: the same Claude app session files as import (`ClaudeDesktopSessionCatalog`, with the same 4 MiB per file,
    2,000 files and links excluded), read against the history of the Claude account the import sheet chooses by default
    (the new-task account, or else the first account, `ProviderConnectionStore.defaultImportChoice`). Both open and
    archived sessions, but only those whose `cliSessionId` history is in that account's
    `projects/<folder name>/<id>.jsonl` (`followedConversations`). If one session has files under several orgs or
    accounts, it counts as open if any of them is open, and as the one open file with the most recent activity. The only
    title followed is the Claude app's own `title` (without it the title is not followed, and on import the name still
    comes from the history).
  - Codex: `thread/list` on the App Server of the default Codex sign-in, as in the import sheet (the same `sourceKinds`;
    exec, subAgent, threads with a parent and ephemeral threads dropped from the response; at most 20 pages of 100),
    once with `archived: false` and once with `archived: true`. The parameters of YHP
    `yardlet.codex.history.interactive` have an optional field `archived` (without it, open threads, so older peers stay
    compatible). A thread in both lists counts as open. If the archived list cannot be read, archiving is not followed.
    If the Codex side cannot be read (not installed, App Server failure), that round follows only Claude. Starting the
    App Server is the same as for the import sheet, with no model turn or authentication change.
  - Last activity: for Claude, the app's `lastActivityAt` (or else the history file's modification time, as in import).
    For Codex, the thread's `recencyAt` (when the person last worked in that thread, the order of the Codex app's list,
    a Thread field of the 0.163 App Server), or else `updatedAt`, which also moves when only thread settings are
    applied. `CodexThreadSummary.recencyAt` and the optional field `recencyAt` in the YHP summary carry it, and the
    import sheet uses the same last activity for Codex conversations.
- **When:** once after the index is restored, and when the app becomes active. One at a time, and only when at least 10
  minutes passed between starts (`SessionListFollow.Schedule`). Activations before the restore do not count. It does not
  run in visual fixtures.
- **New conversations:** a conversation open in its source with no row in Yardlet's index is added through the import
  path (`importConversations`: detached, no runtime, not selected, with `ConversationImportPlacement` and
  `ChatWorkspaces` giving chat folders no project, including the Claude app's scratch workspaces, worktrees going to the
  repository's project, and parent links through `linkImportedConversations`). The account is the default account above
  for Claude and the default sign-in for Codex. Nothing is added if no runtime is selected for the harness. The
  following are not added:
  - Conversations archived in the source.
  - Conversations whose folder is inside a temporary folder: `NSTemporaryDirectory()`, `/private/var/folders`,
    `/var/folders`, `/tmp` and `/private/tmp` (compared with links resolved).
  - Conversations whose harness and provider session ID (compared in lower case) have a row in the index in any state
    (listed, archived (1), deleted or discarded (2)) under any account or storage scope
    (`SessionRepository.indexedProviderSessions`; in SQLite, every row with a `provider_session_id`, regardless of
    `archived`), and the IDs of tasks attached right now. A conversation the person archived or deleted in Yardlet does
    not come back, and when a session Yardlet created (child tasks and the like, not shown in the Claude app) later
    appears in any source list, no second task is created. Tasks of accounts that share history (Session Switch account
    folders) are followed as the same task, as below.
  - Conversations where a task in the same harness and the same folder that has no provider ID yet was created in the
    last 10 minutes, and the conversation's last activity is after that (with a 1-minute margin). The thread of a Codex
    task in the default scope shows in the list right after `thread/start`, but the task saves the ID a little later, so
    this waits for the next round.
- **Existing tasks:** the task that matches a source conversation is found with the import sheet's `existingTask` (same
  harness, `.native` and same provider ID, with the same account or an account that shares the Claude history). If it is
  open in the source:
  - Only when the source's last activity is later than the task's `updated_at` is it moved forward to that value
    (`SessionStore.moveLastActivity`, never moved back). Only the sidebar order changes.
  - The title changes only when `title_origin` is `provider` and the source's title (after normalization) differs (it
    stays `provider`, and this is not recent activity). Titles the person gave (`manual`), Yardlet's fallback titles
    (`automatic`, `provisional`) and `legacy` stay as they are. For Codex only the thread's `name` is followed (not the
    first request of an unnamed thread).
  - The provider session ID, storage scope, account binding, project, additional roots, draft, read state, pin and
    parent link do not change.
- **Archive:** a task the source archived that is listed in Yardlet is archived in Yardlet only (`archived = 1`,
  `provider_archived = 0`). It is skipped (and looked at again the next round) in these cases: running or waiting for
  approval, attached to a runtime, running a shell command, a non-empty draft (text, attachments, an edit, diff
  comments), queued messages, visible (selected, split view), being moved, switching accounts or being unarchived,
  pinned, Yardlet's last activity later than the source's (the person continued in Yardlet) and unarchived by the person
  in Yardlet (below). The conditions are checked twice: when planning and right before archiving.
  - What archiving deletes: the draft (`composerDrafts.remove`), the queue (`followUps.discard`), the conversation and
    Codex timeline caches, pending requests, search positions, snapshots and the in-memory context usage ("Archive and
    unarchive" above). Because of the conditions above, the draft and queue reach this path only when empty, and the
    rest are caches reread from the native source. Attached tasks are not archived, so this does not take the path that
    sends `thread/archive` (`archiveTask`), and it does not clean up Yardlet worktrees either.
  - Claude and Codex tasks unarchived in Yardlet stay in the preference `Yardlet.sessionListFollow.keptListed` (a list
    of task IDs) and are not archived again while the source still has them archived. When the source shows that
    conversation as open again, the task leaves this list, and later archiving in the source is followed again. IDs of
    tasks no longer in the list are removed every round.
  - A task archived in Yardlet is not unarchived even if it is open in the source (the person chose that in Yardlet).
- **What it does not touch:** it does not write to Claude app files, Claude Code history, Codex rollouts or threads (no
  `thread/archive`, `thread/unarchive`, `thread/name/set`, `thread/resume`, `thread/read` or `turn/start`, only
  `thread/list`). There is no model turn, runtime attach, credential copy or account change. What changes is Yardlet's
  index rows (new rows, `updated_at`, provider titles, `archived`), the projects that import creates, and the one
  preference above.

## Index of tasks that touched a file

To show, from a file, the tasks that touched it, Yardlet keeps the files each task read and edited separately, in its
own folder. Provider history is only read, and the formats of harness settings and history and of the session index
(`session-index.sqlite3`) do not change.

- **Location:** `~/.yardlet/file-activity/<task UUID>.json`, one file per task (`FileTouchRepository`). The format is
  `FileTouches` JSON: for each file path, the last edit and the last read (time, call ID), calls whose results have not
  been read yet (up to 256), and how far the Claude Code history has been read (provider session ID, device, inode, end
  byte of the last fully read line, path under `projects`).
- **When it is built:** only when the person looks at a file in the review view or the files pane. Only tasks that
  worked in that file's repository and are not archived are read.
  - Claude Code tasks follow the same rules as reading the conversation (the provider ID stored on the task, the one
    file with that ID under `projects` in that account's config folder, following only one link): the history is read
    from the start the first time it is asked, and after that only the appended bytes are read if the same file (device,
    inode) has not shrunk. A changed or shrunk file, or a different provider ID, is read again from the start. A last
    line still being written is read next time. Only lines containing `"type":"tool_use"` and the result lines of open
    calls are parsed (`ClaudeFileTouchScanner`).
  - For Codex and other harness tasks, Yardlet adds the conversation it holds in memory at the time (file changes and
    command reads of Codex threads, file changes of other harnesses). Codex rollouts are not read.
- **Size:** an index file holds paths, times and call IDs, not file contents, and grows with the number of file paths.
- **How to remove it:** the whole folder can be deleted. The next time a file is viewed, the entries of Claude Code
  tasks are rebuilt from history, and those of other tasks are collected again from what Yardlet reads after that.
  Deleting a task deletes its file too (`FileTaskIndex.remove`), and archiving keeps it. Removing the app removes it
  together with the Yardlet folder.
- **Matching:** the same file in a worktree and in the original repository is matched by the repository's main folder
  and the relative path inside it (`FileRepositoryResolver`: the task's `origin_workspace_path`, the
  `.claude/worktrees/<name>` convention, `commondir` in the `.git` file). It reads only names on disk and two small Git
  files, and runs no Git commands.
- **On open:** clicking a related task reads more of the earlier part, with the same reads as scrolling up in that
  task's conversation (`readEarlierClaudeHistory`, `loadMoreCodexTurns`), until the call is included (up to 256 times),
  then goes to the turn that contains the call. Nothing is sent, attached or resumed.

## What stays with the provider

- Yardlet does not write titles, archive state or projects back to Claude app files, Claude Code history or Codex
  threads; importing and following the session list only read them. The exceptions are the native-side archive,
  unarchive, delete and rename that `HarnessSessionLifecycleProviding` adapters carry ("Archive and unarchive" above).
- Coordinating two clients that continue the same conversation is the provider's job. Yardlet refuses to continue a
  Claude conversation another app's live process holds, and has no such guard for Codex ("Importing conversations from
  other apps" above).
- Reading saved state starts no model turn and changes no sign-in. The authentication state of existing homes, including
  the dedicated Codex home of `.yardlet` tasks, is kept as it is.
