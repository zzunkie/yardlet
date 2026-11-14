# Yardlet Remote Protocol

Status: the contract (protocol 2; protocol 1 has been removed, §1). The Mac side (Yardlet) implements it in `Sources/YardletRemote` and
`Sources/NativeHarnessClient/Remote`; the phone apps implement the client side against this file; the relay
in `relay/` implements §14. The design record is in [REMOTE_V2_DESIGN](design/REMOTE_V2_DESIGN.md).

A phone watches and drives the tasks running in Yardlet on the person's Mac: it lists projects and tasks
with the sidebar's attention states, reads a task's conversation (latest first, older on scroll, live while
it streams), sends a message to a task, answers a pending approval (allow once or deny), stops a running
turn, and marks a task read. It also answers questions and plan reviews, starting a task (on a
harness, model and worktree the phone picks), images, a line's output and diffs, suggested and queued messages,
continuing a task a plan limit stopped under another account, answering a browser handoff, seeing and using a
task's browser tab (§15.25), push notifications, and a task's model, effort and permission mode, slash commands,
edit and fork (§15.23). A device also reads a task's workspace files (§15.27) and, with the permissions the person
gave it at the Mac (§15.28), uses the task's terminals (§15.29); Yardlet on another Mac shows the host's Settings,
accounts, runtimes and connectors and, with the permission, changes them (§15.36, §15.37). Yardlet on another computer
is a client of the same protocol, as a phone is (§18).

**One version.** The JSON messages of §2 and §4–§8 travel inside a Noise IK channel (§11–§16), over any
path: the same network (port 47616 on every interface, found with Bonjour), Tailscale, or the Yardlet relay.
The handshake authenticates both ends with their static keys. Where §2 and §4–§8 and §11–§16 differ, §11–§16
win.

## 1. Protocol 1 (removed)

Protocol 1, plain JSON on the Mac's Tailscale addresses with a pairing code and a device token, has been
removed: the Mac no longer listens for it, and it drops the devices paired with it from its list. A phone
paired that way pairs again with the current app (§12).

## 2. Envelopes

Client → server, a request:

```json
{"id": "17", "type": "markRead", "taskId": "4C1F0E0A-2B7A-4E43-9E0B-6C5D8C0C3A11"}
```

- `id`: a string the client chooses, unique among its pending requests on this connection
  (≤ 64 characters). `type`: the message name. Other fields are the message's parameters.

Server → client, the response to one request (exactly one per request, in no guaranteed order
relative to events):

```json
{"re": "17", "ok": true}
{"re": "18", "ok": false, "error": {"code": "notFound", "message": "No task 4C1F…"}}
```

- `re`: the request's `id`. `ok`: whether it succeeded. On success the message's result fields sit
  beside `ok`; on failure `error.code` is one of §8 and `error.message` is an English diagnostic for
  logs, not for the UI. A refusal may also say what it is about: `error.reason` (§8) and `error.setting`, the
  id of the setting it concerns, never a value. A client words a refusal from its `reason` when it has one and from
  its `code` otherwise, and treats a reason it does not know as absent. Only the reasons `failed` and `form` make
  `message` the host's own words for the person, which a client shows as they are.
- A frame whose `id` cannot be read (not JSON, not an object, `id` missing, not a string or longer
  than 64 characters) gets `{"re": "", "ok": false, "error": {"code": "badRequest", …}}`.

Server → client, an event (pushed, not a response):

```json
{"event": "tasksChanged", "seq": 42, "tasks": [], "removedTaskIds": []}
```

- `event`: the event name. `seq`: increases by one per event on this connection, starting at 1.
- Both sides ignore fields they do not know. A client ignores events it does not know. Optional fields
  may be absent; absent means null/false/empty.
- Times are integers: **milliseconds since the Unix epoch** (fields ending in `At`), durations in
  milliseconds (`…Ms`). They are the Mac's clock. Message 2 (§13.1) and the `snapshot` response carry
  `serverTime`, the Mac's clock when it answered; a phone that keeps `serverTime − its own time at
  receipt` as an offset can show `lastActivityAt` and turn times without clock skew (never in the
  future).
- IDs (`taskId`, `requestId`, item `id`, `cursor`) are opaque strings. Compare them exactly.

## 3. Pairing and authentication

Pairing is §12 and authentication the handshake (§13.1); protocol 1's code, `pair` and `hello` have been
removed (§1).

### 3.4 Rules

- A device removed in the Mac's Settings is disconnected at once: the server sends
  `{"event": "revoked"}` and closes (4403). Its key no longer connects.
- Turning the remote off, or quitting Yardlet, sends `{"event": "closing", "reason": "disabled"}`
  (or `"quitting"`) and closes (4503).

## 4. Requests

### 4.1 `snapshot` — projects and tasks

```json
{"id": "2", "type": "snapshot"}
```

```json
{"re": "2", "ok": true, "serverTime": 1792158000000,
 "projects": [
   {"id": "6A1E…", "name": "Yardlet", "kind": "project"},
   {"id": "chats", "name": "Chats", "kind": "chats"}
 ],
 "tasks": [
   {"id": "4C1F…", "title": "Approve the index migration", "harness": "claude-code",
    "harnessName": "Claude Code", "projectId": "6A1E…", "attention": "waiting",
    "indicator": "awaitingApproval", "pendingRequest": "approval", "unread": false,
    "running": true, "pinned": false, "lastActivityAt": 1792158000000, "parentTaskId": "9E7D…"}
 ]}
```

After a client's first `snapshot`, the server pushes `tasksChanged` and `attention` events (§5) to it.
Call `snapshot` again after reconnecting.

**Project:** `id`; `name` (as the sidebar names it); `kind`: `project` (a Yardlet project), `folder`
(tasks of a folder outside any project) or `chats` (the sidebar's Chats, `id` `"chats"`, name in the
Mac's language). Listed in sidebar order. No folder paths are sent.

**Task** — the tasks the Mac's sidebar lists (not archived), most recently active first:

| field | |
|---|---|
| `id` | the Yardlet task ID |
| `title` | the sidebar title |
| `harness`, `harnessName` | e.g. `codex`/`Codex`, `claude-code`/`Claude Code`, `antigravity-cli` |
| `projectId` | the project it is listed under |
| `attention` | the sidebar's one attention state: `waiting` (an approval or a question waits for the person), `unread` (a finished result, failed included, not read yet, unless the task's parent task already read it: then `idle` with `unread: true`), `active` (a turn or bash command is working), `idle` |
| `indicator` | the sidebar row's mark, absent when none: `awaitingApproval` (green dot), `needsInput` (orange dot), `failed` (red warning), `usageLimit` (gauge), `running` (gray dot), `unread` (blue dot) |
| `pendingRequest` | `approval` or `input` while `waiting` |
| `unread` | the task holds an unread result |
| `running` | a turn (or a Claude bash command) is running, waiting on a request included: `stopTurn` applies. `attention` `waiting` always comes with `running: true` |
| `pinned` | listed under Pinned in the sidebar |
| `lastActivityAt` | last activity |
| `parentTaskId` | the task the Mac's sidebar draws it under, absent when the sidebar lists it at the top of its list. That is the task it was started from (fork, subagent, a task an agent started) or the person moved it under, past archived tasks the nearest one the same list shows, and past the sidebar's second level the task its own parent sits under. A task whose parent is in another project or Chats, is pinned apart (Pinned is a list of its own), is in a split view or is not in Yardlet has none. A phone nests by it alone, with no rule of its own |

`attention` and `indicator` are the same definition the Mac's sidebar dots, menu bar menu and Dock
badge read (`TaskAttentionProjection`, `SidebarTaskIndicatorProjection`).

### 4.2 Conversation

#### `subscribeTask`

```json
{"id": "3", "type": "subscribeTask", "taskId": "4C1F…"}
```

```json
{"re": "3", "ok": true, "taskId": "4C1F…", "items": [ … ], "cursor": "t:…", "hasOlder": true}
```

- `items`: the latest page of the conversation (whole turns, at least one), oldest first (§6).
- `cursor`: names the start of what was sent; pass it to `loadOlder`. Absent when `hasOlder` is false.
- `hasOlder`: there is more before (loaded on the Mac, or still with the provider).
- Then the server pushes `conversation`, `conversationReset` and `conversationEnded` events for the
  task (§5.3) until `unsubscribeTask` or disconnect. Subscribing again to the same task starts over
  with a fresh page. Up to 8 tasks per connection (`tooManySubscriptions`).
- Subscribing reads the task's latest saved history the way opening the task on the Mac does (it
  never starts a model turn); what that read adds arrives as events.
- `detail` (optional, v2): `"full"` asks for what the Mac's own cards draw beyond this section's items, from a Mac
  whose snapshot carries `fullConversation: true` (§15.24). The page, `loadOlder` pages and events of the
  subscription all come in that detail. Absent, or a value the Mac does not know, is the shape of §6.

#### `loadOlder`

```json
{"id": "4", "type": "loadOlder", "taskId": "4C1F…", "cursor": "t:…"}
```

```json
{"re": "4", "ok": true, "taskId": "4C1F…", "items": [ … ], "cursor": "t:…", "hasOlder": false}
```

- `items`: the whole turns just before `cursor`, oldest first; put them before the items you have.
  Later events can update them too.
- When the Mac must first ask the provider for earlier history, the response waits for it (up to
  about 15 s). `items` can then be empty with `hasOlder` still true: try again later.
- Errors: `notSubscribed`, `invalidCursor` (the conversation was reset since; subscribe again).

#### `unsubscribeTask`

```json
{"id": "5", "type": "unsubscribeTask", "taskId": "4C1F…"}
```

`{"re": "5", "ok": true}`. Unsubscribing a task that is not subscribed is fine.

### 4.3 `ping`

```json
{"id": "6", "type": "ping"}
```

```json
{"re": "6", "ok": true, "pong": true, "serverTime": 1792158000000}
```

### 4.4 Commands

Commands act through the same paths as the Mac's own controls. Every command is written to the Mac's
local audit log with its type, task ID (or schedule ID, §15.21), device and result, and a refusal's `reason` and
`setting` — never the message text or a setting's value. An answer to a site's permission prompt (§15.25) also
records the answer and, once taken, the prompt's site and permissions. The log keeps its last 2,000 lines, so a refusal that can
be repeated at will is written at most once a minute: a refused handshake by its result and path, a request a
device's permissions refuse by device, request and setting. `ok: true`
means the Mac accepted the command; what happens next arrives as events.

#### `sendMessage`

```json
{"id": "7", "type": "sendMessage", "taskId": "4C1F…", "text": "Run the migration tests again"}
```

- Sent as if typed in the task's composer on the Mac, with the task's current model, permission
  mode and account. An idle task starts a turn (resuming the provider session when needed); while a
  turn runs, the task's follow-up behavior applies (Codex steers or queues by the Mac's setting,
  Claude Code queues). A message that waits shows as a `queued` user item at the end of the
  conversation (§6.2) until the provider takes it; then that item is removed and the message
  appears as an ordinary `user` item in its turn.
- `text`: trimmed; 1–32,000 characters. Plain text only, no attachments.
- Errors: `emptyMessage`, `tooLarge`, `unsupportedCommand` (the first word is a slash command such as
  `/clear` or `/model` — commands stay on the Mac, but for those `runComposerCommand` runs, §15.23), `busy` (the Mac is editing a message in this task,
  reason `editing`; switching its account or otherwise changing the task, `changing`; or another app holds the
  conversation, `otherApp`), `unavailable` (the task's folder is gone, `folderMissing`), `notAllowed` (pictures or files
  the task does not take, `attachments`), `notFound`.
- `ok: true` means the Mac took the message. Its own composer then sends it, and what goes wrong after that shows
  where the Mac shows it: the message stays in the conversation with the turn's `error` item (§6.7), or waits as a
  `queueFailed` item with Retry (§6.2, §15.33), and the error the Mac's window shows above its composer is the task's
  `notices.error` (§15.31).

#### `answerApproval`

```json
{"id": "8", "type": "answerApproval", "taskId": "4C1F…", "requestId": "toolu_01…", "answer": "allowOnce"}
```

- `answer`: `allowOnce` or `deny` — only answers the request's item lists in `options` (§6.5). Allow
  once is the narrowest allow the Mac's card offers (the same answer as the Mac notification's
  "Allow once"); deny is the card's plain deny. Answers that create standing rules ("Allow for
  session", "Always allow", provider options with a broader scope) and answers to questions and plan
  reviews stay on the Mac.
- Errors: `requestNotFound` (no longer waiting, answered elsewhere, or unknown), `notAllowed` (that
  answer is not offered for this request; `hostOnly` when only the Mac's card gives it), `unavailable` (the task is not
  connected to its harness on the Mac, reason `notConnected`), `notFound`. A request Yardlet holds itself, which its own
  card answers whether or not the task is connected, is answered the same way here: a question a restart of Yardlet
  cut off, and what a task's session tools or the subagent runs they host wait on.

#### `stopTurn`

```json
{"id": "9", "type": "stopTurn", "taskId": "4C1F…"}
```

- As the Mac's stop button: a running Claude bash command first, otherwise the turn. Queued
  follow-ups are held until resumed on the Mac (as on the Mac).
- Errors: `notRunning`, `notFound`.

#### `markRead`

```json
{"id": "10", "type": "markRead", "taskId": "4C1F…"}
```

Clears the task's unread result (idempotent). Errors: `notFound`.

## 5. Events

### 5.1 `tasksChanged`

```json
{"event": "tasksChanged", "seq": 3,
 "tasks": [ {"id": "4C1F…", "title": "…", "attention": "unread", "…": "…"} ],
 "removedTaskIds": ["77AB…"],
 "projects": [ {"id": "6A1E…", "name": "Yardlet", "kind": "project"} ]}
```

- `tasks`: the tasks that are new or changed, whole. `removedTaskIds`: tasks no longer listed
  (archived, deleted). `projects`: present only when the project list changed, then the whole list.
- Sent at most about twice a second.

### 5.2 `attention`

```json
{"event": "attention", "seq": 4, "taskId": "4C1F…", "title": "Approve the index migration",
 "projectName": "Yardlet", "harnessName": "Claude Code", "state": "waiting",
 "previousState": "active", "indicator": "awaitingApproval", "pendingRequest": "approval",
 "requestId": "toolu_01…", "summary": "Bash: Run the migration tests"}
```

- Sent when a listed task's `attention` changes, and again while `waiting` when a newer request
  starts waiting (`requestId` changes). Not sent for the tasks of the first snapshot, or for a task
  that is new and idle.
- Changes are read at most about twice a second, so a quick turn can go from `waiting` straight to
  `unread` without an `active` in between.
- `summary` (while `waiting`): one line about the request, at most 120 characters, safe for a lock
  screen — a question's first line, or the call and what it does (`Bash: Run the migration tests`;
  its description, else the first line of its command). Credentials are masked with `•••` (`Bearer …`,
  `TOKEN=…`, `--password …`, `user:password@` in URLs, long key-like strings). Never file contents or
  diffs. Absent when the Mac has nothing to say.
- `announces: false` on a change to `unread` from `active` or `waiting` that the Mac does not announce itself: a
  turn the person did not ask for, one a queued message follows, or one that leaves a background agent running.
  Absent otherwise, and from a Mac that does not say.
- The phone makes its own notifications from these; the Mac uses no push service. Suggested: notify
  on `waiting` (approval or question) and on `active` → `unread` (finished; `indicator` `failed` when
  it failed) unless `announces` is false, and take a notification back once its task stops waiting.

### 5.3 Conversation events

#### `conversation` — changes to a subscribed conversation

```json
{"event": "conversation", "seq": 5, "taskId": "4C1F…", "changes": [
  {"op": "remove", "id": "req:toolu_01…"},
  {"op": "upsert", "after": "i:5D0C…", "item": {"id": "i:91AA…", "kind": "assistant", "…": "…"}}
]}
```

Apply the changes in order to the loaded items:

- `remove`: drop the item with that `id`.
- `upsert`: if an item with `item.id` exists, replace it in place. Otherwise insert the item right
  after the item `after`; `after` absent or null means at the very start of the loaded items.

The server keeps, per subscription, exactly the items it has sent (every page, `loadOlder` pages
included) and describes each change against them. So `after` always names an item the phone holds
once it has applied, in order, everything this connection sent before: earlier responses (a
`loadOlder` page is put before the loaded items first), earlier events, and the changes before it in
the same event. Apply responses and events in the order they arrive. A phone that ever cannot find
`after` is out of step (it dropped something): it must not guess a place — it subscribes to the task
again, which sends a fresh page. After a `loadOlder` response, the changes the newer turns went
through meanwhile follow at once as a `conversation` event.

A streaming answer is the same item sent again with its text so far. Sent at most about five times a
second per task. Changes too large for one message (§13.2) come as several `conversation` events in a row, each a
part of them in order; applying each as it arrives is the same.

#### `conversationReset`

```json
{"event": "conversationReset", "seq": 6, "taskId": "4C1F…", "items": [ … ], "cursor": "t:…", "hasOlder": true}
```

Replace all loaded items: the Mac read the history again in a way changes cannot express. As a
fresh `subscribeTask` page; older cursors are invalid.

#### `conversationEnded`

```json
{"event": "conversationEnded", "seq": 7, "taskId": "4C1F…", "reason": "removed"}
```

The task was archived or deleted; its subscription ended.

### 5.4 `revoked`, `closing`

See §3.4.

## 6. Conversation items

The phone's projection of the Mac's one conversation model (`ConversationPresentation`, which the
Mac's `ConversationTimeline` draws for every harness), in the Mac's order. Each turn is: what was
sent (`user`), notices, the turn header (`turn`), its plan and work (`plan`, `activity`, answered
`approval`, commentary `assistant`; marked `inWork`), its answers (`assistant` with role `answer`),
the error or limit the turn ended on (`error`), and the requests still waiting (pending `approval`).

Every item has:

| field | |
|---|---|
| `id` | stable within the task; prefixes `turn:`, `i:`, `req:`, `plan:`, `outcome:`, `queued:` keep kinds apart |
| `turnId` | the turn it belongs to |
| `kind` | `turn`, `user`, `assistant`, `activity`, `approval`, `plan`, `error`, `notice` |
| `inWork` | true for the turn's work: hide it while that turn's `foldsWork` is true, as the Mac folds a finished turn's work, unless the person opens it. A `user` item after the turn header that is not `inWork` (a message sent into the turn, which stays in view) parts the fold: the work before the first such message folds under the turn header, and the work after each one, up to the next, under a fold of its own drawn right under the message, which opens only that work (`RemoteTurnFold`) |

Unknown kinds: skip them. Text fields are capped (`truncated: true` when cut).

### 6.1 `turn`

```json
{"id": "turn:3F2A…", "turnId": "3F2A…", "kind": "turn", "status": "completed",
 "startedAt": 1792157900000, "completedAt": 1792157990000, "durationMs": 90000,
 "foldsWork": true, "workCount": 7}
```

- `status`: `running`, `completed`, `interrupted`, `failed`, `unknown`.
- `durationMs`: the work time ("Worked for 1m 30s") when known; `approximate: true` when read from
  the items' own times. `foldsWork`: the Mac folds this turn's `inWork` items. `workCount`: how many.
- While running: `progress` `thinking` (no visible output yet) or `reconnecting` with `progressText`
  (the provider retrying its stream, in its words).

### 6.2 `user`

```json
{"id": "i:5D0C…", "turnId": "3F2A…", "kind": "user", "text": "Run the migration tests", "imageCount": 1}
```

- `queued: true`: a message waiting in the task's follow-up queue (sent from the phone or the Mac
  while a turn ran), not yet taken by the provider. Queued items sit at the end of the last turn, `id`
  `queued:…`; `queueFailed: true` when sending it failed (it waits on the Mac). When the provider
  takes the message, the queued item is removed and the message appears as an ordinary `user` item
  (another `id`) in the turn that reads it.
- `text` ≤ 16,000 characters. `imageCount`: attached images (not sent). `scheduled: true`: a schedule
  sent it, a Codex automation unless `sender` says otherwise. `shell: true`: a Claude Code bash command
  (`text` is the command). `diffCommentCount`: diff comments attached on the Mac (their text is not sent).
- `sender`: someone other than the person sent it, and `text` is their words, which the Mac draws apart from the
  person's own messages: another task's message, `{"kind": "task", "name": "Fix the footer", "relation": "parent",
  "taskId": "4C1F…", "quotes": [{"text": "…", "sentAt": "2026-11-03T09:12:00+09:00"}]}` (`relation` `task`, `parent`,
  the task this one was started from, or `itself`, through a schedule its agent made; `taskId`, the sending task's ID
  when it is another Yardlet task, which a client opens while the Mac lists it (§4.1); `quotes`, the person's own
  messages it passed on, each ≤ 16,000 characters);
  a background command's or agent's notice that opened the turn, `{"kind": "backgroundTask", "status": "failed"}`;
  or, beside `scheduled: true`, a prompt Claude Code's own schedule sent, `{"kind": "claudeSchedule", "name":
  "Morning check"}` (no `name` for a check-in). A client that does not read it draws the item as before.

### 6.3 `assistant`

```json
{"id": "i:91AA…", "turnId": "3F2A…", "kind": "assistant", "role": "answer",
 "text": "All **12** migration tests pass.", "streaming": true}
```

- `text`: Markdown (CommonMark + GFM tables), ≤ 32,000 characters. `role`: `answer` (the turn's
  answer), `commentary` (a working note during the turn; `inWork`), `proposedPlan` (a plan the agent
  proposes, Markdown). `streaming: true` while it is still being written.

### 6.4 `activity` — one tool, command or step, as one line

```json
{"id": "i:CE01…", "turnId": "3F2A…", "kind": "activity", "inWork": true, "activity": "command",
 "title": "Ran swift test --filter Migration", "status": "completed", "exitCode": 0}
```

- `activity`: `command`, `fileChange`, `tool`, `subagent`, `reasoning`, `taskSuggestion`, `other`.
- `title` (≤ 300 characters): the line the Mac shows, in the provider app's words and the Mac's
  language ("Read Parser.swift", "Edited Package.swift", "Searched TODO", "Thinking").
- `words` (optional): the same line in parts, one entry per line the Mac draws (a command the
  Mac reads as several, such as two files read in one `&&`): `{"leading": "…", "verb": "Read", "trailing":
  "Parser.swift"}`, `leading` and `trailing` absent when empty, each part ≤ 300 characters. The Mac draws `verb`
  muted and the rest plain, in the order its language puts them; `title` is the parts joined with spaces, and the
  entries joined with ", ". A client that draws lines as the Mac does reads `words`; any other reads `title`.
- `detail` (≤ 500 characters, optional): the command when the title does not show it whole, a
  reasoning summary, an error message, a suggested task's summary.
- `status`: `running`, `completed`, `failed`, `stopped`.
- Optional: `exitCode` (a command that exited), `additions`/`deletions` (a file change's lines),
  `approved: true` (allowed through an approval).
- No command output, file contents or diffs are sent.

### 6.5 `approval` — a request

```json
{"id": "req:toolu_01…", "turnId": "3F2A…", "kind": "approval", "requestId": "toolu_01…",
 "requestKind": "approval", "status": "pending", "title": "Bash",
 "command": "swift test --filter Migration", "detail": "Run the migration tests",
 "options": ["allowOnce", "deny"], "moreOnMac": true}
```

- `requestId`: what `answerApproval` names. `requestKind`: `approval`, `question` (the agent asks
  the person), `planReview` (a plan to approve), `form` (a Codex input form).
- `status`: `pending`, `allowed`, `denied`, `answered`, `expired`, `rejected`. A pending request sits
  at its turn's end; once answered it moves into the turn's work (`inWork`) where it happened.
- `title`, `detail` (≤ 1,000), `command` (≤ 2,000): what the Mac's card shows. `text`: a plan review's
  plan (Markdown, ≤ 8,000). `questions`: a question's texts (each ≤ 500).
- A pending request's `command` is cut at 200,000 characters rather than 2,000 in every subscription, as full detail
  cuts it (§15.24): the person reads the whole command to answer it. Once answered it is cut at 2,000 again. A phone
  does not allow a `command` that came `truncated`.
- `message` (≤ 1,000, optional): the provider's own words the Mac's card shows above its form or
  answers: a Codex request's message and reason, such as the sentence an MCP form (§15.19) asks with, joined by a
  blank line. Absent when the request sends none.
- `options` (pending only): what the phone may answer — `allowOnce`, `deny`, both, or none.
- `moreOnMac: true`: the Mac's card offers answers the phone does not (for example "Allow for
  session", a question form, a plan review). Show that more is on the Mac.

### 6.6 `plan`

```json
{"id": "plan:3F2A…", "turnId": "3F2A…", "kind": "plan", "inWork": true,
 "explanation": "Fix the failing tests first.",
 "steps": [{"text": "Read the failing test", "status": "completed"},
           {"text": "Fix the migration", "status": "inProgress"}]}
```

- A step plan or to-do list. `status`: `pending`, `inProgress`, `completed`. Up to 50 steps, each
  ≤ 500 characters.

### 6.7 `error`

```json
{"id": "outcome:3F2A…", "turnId": "3F2A…", "kind": "error", "errorKind": "usageLimit",
 "title": "You've hit your limit", "message": "Resets at 4pm", "resetsAt": 1792170000000}
```

- The turn's error (`errorKind` `error`, with `recoverable`) or the plan limit that stopped it
  (`errorKind` `usageLimit`, with `resetsAt` when known). `message` ≤ 2,000 characters. An error the
  turn went on past is in the work (`inWork`).

### 6.8 `notice`

```json
{"id": "i:7AB0…", "turnId": "3F2A…", "kind": "notice", "text": "Context compacted"}
```

The provider's notices beside the turn (a model reroute, a warning) and context compaction.

## 7. Limits

- Client frame ≤ 65,536 bytes (1009 close). `sendMessage.text` ≤ 32,000 characters.
- Requests: a burst of 30, then 10 per second per connection. Commands (`sendMessage`,
  `answerApproval`, `stopTurn`, `markRead`): a burst of 10, then one per 3 s. Over the limit a request
  gets `rateLimited` and is dropped; 20 in a row closes the connection (4429). File reads have a byte budget per
  device besides (§15.22). A browser tab's requests (`watchTab`, `unwatchTab`, `tabFrameAck`, `tabInput`, §15.25) have a
  bucket of their own instead: a burst of 60, then 30 per second.
- IDs a request carries: `taskId`, `projectId`, `scheduleId`, `accountId` and `tabId` at most 64 bytes; `requestId`,
  `itemId`, `suggestionId` and `choice` at most 256. A longer one is `badRequest`.
- A connection whose phone leaves more than 32 MiB of the Mac's messages untaken is closed, with what was waiting:
  a direct socket is dropped, and over the relay the phone's stream closes with 4429.
- At most 8 connections of paired devices at once; more are closed (4503). A v2 connection counts once the
  phone's first message after message 2 arrives (§13.1). Besides those, at most 8 connections may still be
  authenticating; a new one closes the oldest of them (4503). At most 8 subscriptions per connection.
- A listener holds at most 4 connections from one address, and 16 in all, that have not finished their
  WebSocket and Noise handshakes; a new one closes the oldest of them, and one not done within 10 s is closed.
- Pairing: 5 wrong codes close the open pairing.
- The Mac holds at most 64 messages and 16 MiB of a connection's that it has not handled yet, and 64 MiB of all
  connections'; a message past that closes its connection (4429), whatever it is, rather than wait in memory. Before
  they are decrypted, at most 512 frames and 16 MiB of a connection's wait, past which it closes (4429) too; 128 KiB
  while the connection waits for its link request to be answered (§12.1). A browser tab's input waiting behind a slow
  page counts apart: at most 32 per connection (§15.25).

## 8. Error codes

| code | meaning |
|---|---|
| `badRequest` | not JSON, not an object, or a missing or wrong field |
| `unknownType` | a `type` the server does not know |
| `unsupportedVersion` | message 1's `v` is not 2, or a link request without `linkCommit` (§12.1) |
| `unauthenticated` | a request before the connection is a device's (a link request waiting, §12.1) |
| `pairingUnavailable` | no pairing is open (expired, used or cancelled) |
| `pairingInvalid` | wrong pairing secret |
| `notFound` | no listed task (or schedule, §15.21) with that ID, or a file a phone may not read or that is not there (§15.22) |
| `notSubscribed` | `loadOlder` for a task not subscribed |
| `invalidCursor` | the cursor no longer names a place in the conversation |
| `tooManySubscriptions` | more than 8 subscribed tasks |
| `requestNotFound` | the request is not waiting any more |
| `notAllowed` | that answer, action, setting, command, edit or fork is not offered now |
| `unavailable` | the task is not connected to its harness on the Mac |
| `notRunning` | nothing to stop |
| `emptyMessage` | `sendMessage.text` is empty |
| `tooLarge` | `sendMessage.text` is too long, or a file is over 100 MiB (§15.22) |
| `unsupportedCommand` | a slash command |
| `busy` | the task cannot take it now (editing, switching account, held by another app), a run of the schedule is starting, or a message still being sent names the file (§15.20) |
| `rateLimited` | over the rate limit, or a device's file budget (§15.22) |
| `internal` | anything else |
| `unknownDevice` | v2 handshake: the phone's key is not paired, or the device was removed (§13.1) |
| `linkUnavailable` | v2 handshake: a link request to a Mac not signed in to an account (§12.1) |

A refusal's optional `reason` (§2) says what it is about, so a client words it itself. A client that does not know a
reason words the refusal by its `code`.

| reason | what it is about |
|---|---|
| `harness` | the Mac does not offer the harness now (§15.16), or none can start a task |
| `setting` | a setting, or a value of it, the Mac's menus do not offer now (§15.16) |
| `confirmation` | a choice the Mac asks to confirm, sent without `confirmed` (§15.16) |
| `terminal` | the device's Terminal permission is off: a terminal, or a choice that lets an agent act without asking (§15.28) |
| `fileWrites` | the device's Write files permission is off: a Review change (§15.26), a save from the Files panel (§15.27) or a file restore (§15.31) |
| `fileChanged` | the file is no longer the one the client read: it changed on the Mac since (§15.27) |
| `account` | an account the Mac cannot start or move the task on now (§15.16, §15.33) |
| `worktree` | a new worktree asked for outside a Git repository (§15.16, §15.35) |
| `attachments` | pictures or files the harness or the task does not take (§4.4, §15.16) |
| `signIn` | the harness's login on the Mac needs signing in first (§15.16) |
| `folderMissing` | the task's or the project's folder no longer exists on the Mac |
| `notConnected` | the task is not connected to its harness on the Mac now |
| `otherApp` | another app holds the task's conversation |
| `editing` | a message of the task is being edited on the Mac |
| `changing` | the task is changing on the Mac: moving to another account, another change under way, or the message is on its way; for a Review change, the changes differ from the ones reviewed (§15.26) |
| `queue` | messages wait in the task's queue |
| `running` | it waits for the running turn to end, or a run of the schedule is starting |
| `hostOnly` | it is done on the Mac itself |
| `failed` | the Mac or the harness tried and could not; `message` says why in its own words, for the person |
| `form` | a form's value does not fit; `message` names the field and the problem in the Mac's words (§15.19) |

Close codes: 1000 normal, 1003 text frame, 1009 frame too large, 4401 handshake, decryption or link nonce
failed, 4403 device removed, 4408 idle or nothing in time, 4426 unsupported version, 4429 rate limited,
4503 remote off, Yardlet quitting, or too many connections.

## 9. Fixture server

A loopback server with the same protocol and realistic fixture tasks, for developing the client
without a Mac running Yardlet's real tasks:

```sh
swift run --build-system native yardlet-remote-fixture            # ws://127.0.0.1:47616/
swift run --build-system native yardlet-remote-fixture --secure-port 47700 --single-use-pairing
```

- Android emulator: `ws://10.0.2.2:47616/`. It binds `127.0.0.1` only. Its Mac key is fixed, so a phone paired
  once stays paired.
- It prints its pairing URL (§12). Its secret is fixed and reusable unless `--single-use-pairing`, which also
  expires it after 5 minutes like the Mac. `--relay` opens its room on a local relay and `--approve-links`
  approves a link request (§12.1) three seconds after it is shown. Its device list is kept in memory and is
  gone when it stops. Without Network.framework (Windows, Linux) it has no listener of its own and needs `--relay`.
- Fixture tasks (projects Yardlet, Website and Chats):
  - "Approve the index migration" (Claude Code) waits on a Bash approval (`allowOnce`, `deny`,
    `moreOnMac`; `running: true`, so `stopTurn` applies and expires the request). Allow once: the
    command runs, an answer streams, the turn completes and the task turns unread. Deny: the turn
    ends with a short answer. About 30 s after the turn ends a new approval arrives, so it can be
    tried again.
  - "Build the release bundle" (Codex) streams an answer word by word with a running command;
    `stopTurn` interrupts it; it starts streaming again 30 s after it stops or finishes.
  - A message sent to a running task waits as a `queued` item and is taken when the turn ends, which
    starts a reply turn.
  - "Summarize the crash reports" (Codex) is finished and unread with 30 turns, for `loadOlder`. Its outputs
    (§15.22) are a PDF beside its folder and a PNG in it, and its last answer names `reports/crash-notes.txt`.
  - "Fix the footer links" (Claude Code) is idle; `sendMessage` (to it or any idle task) starts a turn
    that reads and edits files, streams an answer and completes.
  - "Pick the release name" (Claude Code) waits on a question (no phone options, `moreOnMac`;
    `stopTurn` expires it, and the question comes back 30 s later).
  - "Plan the weekend trip" (a chat) has a to-do plan; "Check the footer on mobile" is nested under
    "Fix the footer links", and after the person's request holds turns its parent's message, a background
    command's notice and a scheduled check-in opened (§6.2 `sender`); "Regenerate the screenshots" failed.
  - "Publish the release notes" (§15.18, §15.25) waits on a sign-in page it handed to the person, one of its two
    browser tabs. The page draws as PNG and takes clicks, typing and keys: tap the username field and type, Tab or
    tap to the password field (the list marks it `passwordField`), then Sign in; with both filled the page says it is
    signed in, and I'm done answers the handoff. `Meta+c` in the username field sends its text as `tabCopied` (`Meta+x`
    also empties it); in the password field it sends nothing. Thirty seconds after an answer the page signs out and the
    handoff comes back. Its other tab, a static page, has a camera and microphone permission prompt numbered past 2^53
    (`permission`, `waiting` `permission`); `answerTabPermission` takes it while that tab is watched, and thirty seconds
    later the page asks again under the next number.

## 10. Revisions

Every revision of protocol 2 only adds optional fields or states a rule; where a section changed a behavior
incompatibly, that section says so. The history of the contract is in the repository's history.

## 11. v2 transport

### 11.1 Paths

Every v2 connection is a WebSocket that carries **binary frames only**, one Noise message per frame
(§13). A text frame closes the connection (1003); a frame over 65,535 bytes closes it (1009). Neither side
offers WebSocket compression: Noise output does not compress, and a compressed full-size frame arrives larger than
any Noise message. v2 uses no WebSocket extensions: a client or the Mac ends a connection whose server answers with
one or whose frames use one. The same handshake and encryption run on every path:

| path | phone connects to | notes |
|---|---|---|
| direct (same network, Tailscale, the emulator) | `ws://<host>:<port>/` | The Mac listens on every interface, port **47616** by default (another free port when 47616 is taken; Bonjour and §13.3 name the real one). No `Origin` header (HTTP 400). |
| relay | `wss://<relay>/v1/rooms/<room>/connect` | §14. The relay forwards frames and cannot read them. |

No TLS on direct paths: the Noise handshake authenticates the Mac by its static key, whatever the path.

### 11.2 Keys and names

| key | kind | where |
|---|---|---|
| Mac static key | X25519 | The Mac's Keychain. Its public key is in the pairing QR (`k`). |
| Mac relay key | Ed25519 | The Mac's Keychain. Opens the Mac's room on the relay (§14.2). |
| Phone static key | X25519, one per paired Mac | The phone's secure storage (Android: sealed with a Keystore key, no backup). The Mac stores its public key. |
| Push key | 32 random bytes, one per device | Made by the Mac on `registerPush` (§15.6), kept in the Mac's device list and the phone's secure storage. |

- **Room:** `base32(SHA-256(relay public key)[0..<20])`, RFC 4648 alphabet in lowercase, no padding:
  32 characters `[a-z2-7]`.
- **Mac discovery id:** the first 8 bytes of `SHA-256("yardlet-mdns/2" ‖ Mac static public key)` as
  16 lowercase hex characters.
- **Push key id:** the first 8 bytes of `SHA-256(push key)` as 16 lowercase hex characters.
- Binary values in JSON and URLs are **base64url without padding** (a 32-byte key is 43 characters).

### 11.3 Discovery on the same network

The Mac advertises Bonjour service `_yardlet._tcp` on its v2 port while the remote is on: instance name
`Yardlet-<discovery id>`, TXT `v=2` and `id=<discovery id>`. The Mac's name is not advertised. A phone
computes the discovery id from the Mac static key it stored and connects to the service with that id.
Bonjour can be refused (macOS asks for Local Network access once; guest networks drop multicast), so a
phone also keeps the direct addresses of §13.3.

### 11.4 Choosing a path (phone)

1. Candidates: addresses Bonjour resolved for the Mac, the direct addresses last received (§13.3; the
   private-range ones when on Wi-Fi or Ethernet, Tailscale ones when a VPN is up), then the relay.
2. Start the direct candidates at once (3 s each to finish the handshake) and the relay 0.7 s later, at
   each of its addresses when the Mac names two (§14.2); the first handshake that completes wins and the
   others are closed.
3. While on the relay, try direct again when the network changes or Bonjour finds the Mac; when one
   completes, move to it (send `snapshot` and subscribe again) and close the relay connection.

## 12. v2 pairing

Settings › Remote › "Pair a device" shows a QR code holding the link below, and Copy link puts the same link on
the clipboard for Yardlet on another computer (§18):

```
yardlet-remote://pair?v=2&k=<Mac static public key>&s=<secret>&n=MacBook%20Pro&h=192.168.1.20:47616&h=100.64.12.34:47616&r=wss://relay.example.test&i=<room>&a=https://alternate.relay.example.test
```

- `v=2`. `k`: the Mac static public key. `s`: the pairing secret, 32 random bytes. `n`: the Mac's name.
  `h`: zero or more direct addresses `host:port` in the order to try (an IPv6 host in brackets). `r` and
  `i`: the relay's base URL and the Mac's room, present when the Mac uses a relay. `a`: optional, another base URL of
  the same relay that reaches the same room, which a client may race against `r` (§14.2); read only beside `r` and
  `i`. Values are percent-encoded; unknown parameters are ignored.
- Anyone can send a link, so a client reads only what it can safely try: at most 8 `h`, each a plain `host:port` (a
  name or address of letters, digits, `.` and `-`, or an IPv6 address in brackets, and a port from 1 to 65535; any
  other is left out), `n` cut to 64 characters, and an `i` of letters, digits, `-` and `_` only (at most 128; a link
  naming any other room is refused).
- A pairing **expires after 5 minutes**, and opening a new one cancels it. A wrong secret is refused
  (`pairingInvalid`) without closing the pairing. It is spent by its first successful use, except that the
  **same phone key** may use it again for 60 s (a phone that lost the Mac's answer simply pairs again);
  removing that device, cancelling the pairing or opening a new one ends this.
- A phone key is a device: pairing again with a new key adds a new device. A phone that pairs a Mac again
  sends `forgetDevice` with its old key first, if it still can.
- There is no manual code: a short code typed by hand needs a PAKE to be safe without accounts.
  The QR also opens the app from the phone's camera (the `yardlet-remote` scheme).

### 12.1 Linking through an account

A phone signed in to the person's account (§14.4) learns the account's Macs (name, room, keys) without a QR
code and asks one to link:

- The phone makes a nonce, 32 random bytes. Message 1's payload carries `"link": true` instead of `pair`, and
  `"linkCommit"`: `SHA-256("yardlet-link-commit/2" ‖ phone static public key ‖ phone nonce)`.
- Message 2 answers `{"ok": false, "pending": true, "linkNonce": "<the Mac's nonce, 32 random bytes>",
  "server": {…}}` when the Mac takes the request, and the connection stays open but unauthenticated.
- The phone's first message, within 10 s, is `{"id": "…", "type": "revealLink", "nonce": "<phone nonce>"}`. The
  Mac answers `{"re": "…", "ok": true}` when it matches `linkCommit` and only then shows the request. Anything
  else, or a nonce that does not match, gets an error and close 4401. After that the phone may only send `ping`.
- **Code:** the first 4 bytes of `SHA-256("yardlet-link/2" ‖ Mac static public key ‖ phone static public key ‖
  Mac nonce ‖ phone nonce)` as a big-endian unsigned integer, modulo 1,000,000, written with 6 digits (shown
  `482 913`). Each side computes it from what it holds, and the phone shows its own once `revealLink` is
  answered.
- A v2 phone that connects while a request waits gets the `linkRequest` event too.
- The Mac shows the request (name, platform, code) in Settings and to its connected v2 phones (event
  `linkRequest`, §15.11). The first approval or refusal wins. Approved: the Mac sends the encrypted event
  `{"event": "linked", "deviceId": "…"}` and the connection is authenticated as that new device from then on.
  Refused: `{"event": "linkRefused"}` and close 4403. No answer in 120 s: `linkRefused` and close 4408.
- Errors in message 2: `linkUnavailable` (the Mac is not signed in to an account; 4401), `busy` (another link
  request is pending; 4503), `rateLimited` (the Mac took 5 link requests in the last 10 minutes; 4429),
  `unsupportedVersion` (no `linkCommit`: an older phone app; 4426).
- Approving in Settings takes a click: the Allow button is not the default button.

## 13. v2 handshake and messages

### 13.1 Handshake

`Noise_IK_25519_ChaChaPoly_SHA256` (Noise revision 34), prologue the 16 ASCII bytes `yardlet-remote/2`.
The phone is the initiator and knows the Mac static public key (`<- s`):

```
-> e, es, s, ss   + payload   (phone → Mac, one binary frame)
<- e, ee, se      + payload   (Mac → phone, one binary frame)
```

Message 1's payload (UTF-8 JSON):

```json
{"v": 2, "name": "Pixel 9", "platform": "android", "appVersion": "0.2.0"}
{"v": 2, "name": "Pixel 9", "platform": "android", "appVersion": "0.2.0", "pair": "<secret>"}
```

- `name` ≤ 64 characters, shown in the Mac's device list (updated on every connection). `pair`: the QR's
  secret, when pairing.

Message 2's payload:

```json
{"ok": true, "deviceId": "B0D2…", "serverTime": 1792158000000, "paired": true,
 "server": {"name": "MacBook Pro", "app": "Yardlet", "appVersion": "1.0", "protocolVersion": 2},
 "direct": ["192.168.1.20:47616", "100.64.12.34:47616", "mac.example-tailnet.ts.net:47616"],
 "relay": {"url": "wss://relay.example.test", "room": "<room>", "alternate": "https://alternate.relay.example.test"}}
```

```json
{"ok": false, "error": {"code": "unknownDevice", "message": "…"}}
```

- `paired: true` only on the connection that paired. `direct`: the Mac's addresses now, to try next time.
  `relay`: absent when the Mac uses none; a phone replaces what it stored with it. Its `alternate` is the link's `a`
  (§12), absent when the Mac has none.
- Errors, after which the Mac closes: `unknownDevice` (the phone key is not paired, or was removed:
  4403), `pairingUnavailable` and `pairingInvalid` (4401), `unsupportedVersion` (4426), `badRequest`
  (4401), `unavailable` (too many connections, §7; 4503).
- A phone sends nothing but message 1 before message 2; another frame closes the connection (4401). The Mac
  counts an accepted connection as the device's (Settings shows it connected, and pushes to it stop) once the
  phone's first message arrives; one that sends none within 30 s is closed (4408).
- A message 1 the Mac cannot read (another Mac key, a damaged frame) is closed with 4401 and no
  message 2. The phone sends message 1 within 10 s of the WebSocket opening; each side gives the
  other 10 s.
- After message 2 both sides `Split()`: the phone sends with the first cipher and receives with the
  second; the Mac the other way round. The connection is authenticated as `deviceId`.

### 13.2 Messages

Requests, responses and events are the JSON objects of §2, §4, §5 and §15. Each is sent as one or
more Noise transport messages:

- UTF-8 bytes of the JSON, cut into chunks of at most 65,518 bytes. Each chunk's plaintext is one flag
  byte (`0x01` the last chunk, `0x00` more follow) and the chunk; encrypted with the sender's cipher,
  empty associated data, one transport message per binary frame (≤ 65,535 bytes).
- The receiver decrypts in order and joins the chunks. A message that fails to decrypt closes the
  connection (4401). A message from the phone over 8 MiB closes it (1009), as do the Mac's over 8 MiB; while a link
  request waits for its answer (§12.1), anything over 65,536 bytes does, as soon as that much of it has arrived. An older
  Mac closes a phone message over 65,536 bytes, so a phone sends a larger one (images, §15.14) only to a Mac that
  offers images.
- Nonces start at 0 in each direction and grow by one per message (Noise).

### 13.3 Keepalive and closing

- The phone sends `ping` (§4.3) at least every 25 s. The Mac closes a connection that sent nothing for
  75 s (4408). WebSocket ping frames do not reach the Mac over the relay.
- Close codes are those of §8, plus: 4401 handshake or decryption failed, 4403 device unknown or
  removed, 4404 the Mac is not on the relay (§14.3), 4409 the Mac reconnected to the relay.
- The Mac sends `revoked` and `closing` (§3.4) as encrypted events before closing.

## 14. Relay

### 14.1 Endpoints

| request | who | |
|---|---|---|
| `GET /v1/health` | anyone | `200 ok` |
| `GET /v1/rooms/<room>/host` (WebSocket) | the Mac | §14.2 |
| `GET /v1/rooms/<room>/connect` (WebSocket) | a phone | §14.3. `404` when no Mac holds the room, `429` when the room has 8 phones the Mac answered, `400` for a malformed room |

One room per Mac. The relay keeps a room only in memory while its Mac is connected; it stores nothing
and logs no frame contents. What it sees: rooms, IP addresses, when sockets open and close, frame sizes
and times, and a push's token (FCM's registration token or APNs' device token) while sending it.

### 14.2 The Mac's socket

A relay may be reachable at a second address that reaches the same rooms (`relay/pages/` hands every request to the
Worker, and its `*.pages.dev` address is often served from a nearer location than the Worker's own domain). The Mac
then opens its socket to both at once on every attempt, keeps the one whose challenge arrives first, and closes the
other before answering it: an answered socket would replace the room's (step 4). When one address is refused, never
answers or answers with anything but the challenge, the other opens the room. Sign-in and the account API (§14.4) stay
on the first address, whose callbacks the providers know.

1. The relay sends `{"t": "challenge", "nonce": "<32 random bytes>"}` as soon as it accepts.
2. The Mac answers `{"t": "auth", "key": "<relay public key>", "sig": "<signature>"}`: an Ed25519
   signature of the UTF-8 bytes of `yardlet-relay-host/1\n<room>\n<nonce>`.
3. The relay checks that the room is the key's room (§11.2) and the signature, then sends
   `{"t": "ready"}`. Otherwise it closes with 4401; no `auth` within 10 s closes with 4408.
4. A newer authenticated socket for the same room replaces the older one: the older socket and every
   phone of the room are closed with 4409.
5. `{"t": "open", "c": 7}` tells the Mac a phone connected as connection 7 (numbers grow per room);
   `{"t": "closed", "c": 7, "code": 1006}` that it left. The Mac sends `{"t": "close", "c": 7,
   "code": 4403}` to close a phone's socket with that code; that phone gets no `closed` back. A close code the
   relay may not use closes with 1000.
6. Data both ways is binary frames: a 4-byte big-endian connection number, then the phone's frame.
7. The Mac sends the text `ping` every 15 s and the relay answers `pong` without waking the room. A way to the
   relay can die without a word (the next `ping` is then answered by a reset), so the pings are what find it. The Mac
   reconnects when no `pong` came for 45 s and whenever its socket ends: within a quarter of a second when the room
   had stayed open for 10 s, since every phone of the room is waiting, then after 1, 2, 4 … 32 s while attempts fail.
   A room's relay object can move (the relay places a room near its Mac by the country it is first opened from); a
   Mac socket left in the old object is closed with 1012 when a phone asks for the room, and the Mac connects again
   into the new one as above.
8. Push, at most 60 a minute per room:

   ```json
   {"t": "push", "id": "p3", "provider": "fcm", "to": "<the device's token>", "urgent": true, "collapse": "<≤ 64 bytes>",
    "ttl": 3600, "data": {"v": "1", "k": "<push key id>", "y": "<sealed payload>"}}
   ```

   `provider` and `to` are what the device registered (§15.6); a push without `provider` goes through FCM. The
   relay sends `data`:

   - `fcm`: as an FCM HTTP v1 data message (`android.priority` HIGH when `urgent`, else NORMAL; `collapse_key`;
     `ttl`).
   - `apns`, `apns-sandbox`: as `POST https://api.push.apple.com/3/device/<to>` or
     `https://api.sandbox.push.apple.com/3/device/<to>`, with the relay's APNs provider token (an ES256 JWT of its
     key ID and team ID, signed with its APNs key and used for 50 minutes), `apns-topic` the iOS app's bundle ID,
     `apns-collapse-id` the `collapse` and `apns-expiration` `ttl` seconds from now. The `data` fields sit beside
     `aps` at the top of the payload. An urgent push is an alert (`apns-push-type: alert`, `apns-priority: 10`,
     `"aps": {"alert": {"title-loc-key": "PUSH_FALLBACK_TITLE", "loc-key": "PUSH_FALLBACK_BODY"},
     "mutable-content": 1, "sound": "default"}`); any other is a background push (`apns-push-type: background`,
     `apns-priority: 5`, `"aps": {"content-available": 1}`).

   It answers `{"t": "pushed", "id": "p3", "ok": true}` or `{"t": "pushed", "id": "p3", "ok": false, "error":
   "unregistered"}`. Errors: `unregistered` (the token is gone: forget it; FCM answered 404 or `UNREGISTERED`, APNs
   410 or 400 `BadDeviceToken` or `DeviceTokenNotForTopic`), `invalid` (a field or the provider is wrong, or the
   service refused the message), `rateLimited`, `unavailable` (the service failed, could not be reached or refused the
   relay's credentials), `notConfigured` (the relay has no credentials for that provider).

### 14.3 A phone's socket

Binary frames only (a text frame closes it, 1003), each at most 65,535 bytes (1009). The relay closes a
phone socket that sent nothing for 120 s (4408), and every phone socket of a room whose Mac left (4404).

The Mac's socket to the relay is a long-lived connection through someone else's network, and it does end now and
then; the Mac then opens its room again within about a second (§14.2). So a phone whose connection was up and ends
with 4404, 4409 or no code connects again at once, and again every half second or so for about 10 s, before it tells
the person the Mac cannot be reached; a `404` in that time means the Mac is not back yet.

A socket the Mac has not yet sent a frame to is waiting. The relay keeps at most 2 waiting sockets from one
address and 8 in a room; a new one closes the oldest of them (4503). A socket still waiting after 15 s is closed
(4408).

### 14.4 Accounts

Optional (the QR stays the way to pair without one). The account only lists the person's Macs and lets a new
phone ask one of them to link (§12.1); it never carries tasks or conversations.

On the Mac it is Settings › Yardlet Account, first in Settings' list with the account or "Not signed in" under its
name. Signing in works with remote connections on or off; while they are off, the page says the account finds this
Mac once they are on. Opening the page reads `GET /v1/auth/providers` (with remote connections on, also the account
and the Mac's entry), and nothing reads them on a schedule. The account's id, provider and name are kept in Yardlet's
preferences (`Yardlet.remote.account`) so the list names it while remote connections are off; signing out removes
them with the token.

| request | | answer |
|---|---|---|
| `GET /v1/auth/providers` | | `{"providers": ["github", "google"]}`: the ones the relay is configured for. Empty (or no answer): apps show no sign-in at all, and the relay still carries connections |
| `GET /v1/auth/<provider>/start?redirect_uri=yardlet-remote://auth&code_challenge=<S256>&state=<client state>` | opened in the system's browser sign-in sheet | `302` to the provider |
| `GET /v1/auth/<provider>/callback?code=…&state=…` | the provider returns here | `302` to `yardlet-remote://auth?code=<one-time code>&state=<client state>`, or `?error=<reason>&state=…` |
| `POST /v1/auth/token` `{"code", "codeVerifier", "deviceName"}` | the app, once | `{"token": "<account>.<secret>", "account": {"id", "provider", "name"}}` |
| `GET /v1/account` | `Authorization: Bearer <token>` | `{"id", "provider", "name", "macs": [{"room", "macKey", "relayKey", "name", "updatedAt"}]}` |
| `PUT /v1/account/macs/<room>` `{"macKey", "relayKey", "name", "sig"}` | the Mac | `{"ok": true}` |
| `DELETE /v1/account/macs/<room>` | the Mac or a phone | `204` |
| `POST /v1/auth/logout` | | `204`: this token stops working |
| `DELETE /v1/account` | | `204`: the account, its Macs and every token are deleted |

- `redirect_uri` is exactly `yardlet-remote://auth`. `code_challenge` is base64url `SHA-256(code verifier)`
  (PKCE S256, the only method; `code_challenge_method` may be sent and must then be `S256`); `state` is the app's own (≤ 128 characters) and comes back unchanged. The relay signs its own
  provider `state` (HMAC-SHA256, 10 minutes) so the flow needs no storage until the account is known.
- **Account id:** `base32(SHA-256("yardlet-account/1\n" + provider + "\n" + subject)[0..<20])`, 32 characters,
  where `subject` is the provider's stable user number (GitHub user id, Google `sub`). The subject itself and
  the e-mail address are not stored. `name`: the GitHub login or the Google profile's name, for display.
- **Registering a Mac:** `sig` is an Ed25519 signature by the Mac relay key over the UTF-8 bytes of
  `yardlet-account-mac/1\n<account id>\n<room>\n<macKey>\n<name>`; the room must be the relay key's (§11.2).
  At most 20 Macs per account. Registering again updates the entry.
- **Tokens:** `<account id>.<32 random bytes>`; the relay keeps the secret's SHA-256, the device name and
  times. A token unused for 90 days stops working. The one-time code has the same shape (so the relay finds the
  account without a table of all accounts), lasts 2 minutes and is spent by the first exchange, right or wrong.
- **Callback failures:** a provider `state` that is forged or expired gets `400` and no redirect (the app's
  `state` inside it cannot be trusted); a provider that fails or refuses redirects with
  `?error=providerFailed` or the provider's own error (`access_denied`). Names (`name`, `deviceName`) are cut to
  64 characters.
- **Storage:** one Durable Object per account, named by the account id. Nothing else about accounts is kept.
- Errors are JSON `{"error": "…"}`: `unauthorized` (401), `badRequest` (400), `notConfigured` (501: no such
  provider), `invalidSignature` (403), `tooMany` (409), `providerFailed` (502).
- Provider credentials are the relay's secrets: `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `GOOGLE_CLIENT_ID`,
  `GOOGLE_CLIENT_SECRET`, `AUTH_STATE_SECRET`, and `PUBLIC_URL` (the relay's own https base, for callbacks).

## 15. v2 requests and fields

### 15.1 Snapshot

- `newTask: {"harness": "claude-code", "harnessName": "Claude Code"}`: what a task started from the phone
  runs on, the Mac's new-task composer as it is now (harness, its model and account, worktree or not).
  Absent when the Mac cannot start a task.
- Projects carry `canCreateTask: true` where `createTask` may start one (projects with a folder, and
  Chats).
- A waiting task carries `pendingSummary` (the newest request's line, as the `attention` event's `summary`)
  and `pendingKind` (`approval`, `question`, `planReview`, `form`, `browserHandoff`, §15.18),
  so a list says what waits without opening the task. The `attention` event of a waiting task (§5.2), and so its
  push (§16), carries the same `pendingKind`.
- `newTask` comes only with `snapshot`; a phone about to start a task asks for a `snapshot` again when it
  needs the Mac's current choice.

### 15.2 Approval items

- `questionSteps` on a pending question (`requestKind` `question`, or `form` for a Codex question form):

  ```json
  [{"id": "q1", "header": "Name", "text": "Which release name?",
    "options": [{"label": "Juniper", "description": "Short and easy to say"}, {"label": "Larch"}],
    "multiple": false, "custom": true, "skippable": false}]
  ```

  `id` is what `answerQuestion` names. `multiple`: more than one option may be picked. `custom`: the
  person may answer in their own words (with the options, or instead when there are none). `skippable`:
  the question may be left out.
- `options` may also hold `answer` (the phone may answer the questions), `approvePlan` and
  `keepPlanning` (a plan review). A question whose answer is secret, and an MCP form, stay on the Mac
  (`moreOnMac`).

### 15.3 `answerQuestion`

```json
{"id": "11", "type": "answerQuestion", "taskId": "4C1F…", "requestId": "toolu_02…",
 "answers": [{"questionId": "q1", "options": ["Juniper"]}, {"questionId": "q2", "text": "Ship on Friday"},
             {"questionId": "q3", "skipped": true}]}
```

- One entry per step: `options` are labels of that step (one unless `multiple`), `text` only where
  `custom` (≤ 4,000 characters), `skipped` only where `skippable`. Sent the way the Mac's card sends
  the same answers.
- Errors: `notFound`, `requestNotFound`, `notAllowed` (`answer` not offered, a label the step does not
  have, a step missing; `hostOnly` for a plan review the Mac keeps), `tooLarge`, `unavailable` (`notConnected`, as
  §4.4's `answerApproval`).

### 15.4 `reviewPlan`

```json
{"id": "12", "type": "reviewPlan", "taskId": "4C1F…", "requestId": "toolu_03…", "decision": "approve"}
{"id": "13", "type": "reviewPlan", "taskId": "4C1F…", "requestId": "toolu_03…", "decision": "keepPlanning",
 "reason": "Split the migration first"}
```

The Mac card's two answers: approve the plan, or keep planning with an optional reason (≤ 4,000
characters). Errors as §15.3.

### 15.5 `createTask`

```json
{"id": "14", "type": "createTask", "projectId": "6A1E…", "text": "Add a dark mode toggle"}
```

```json
{"re": "14", "ok": true, "taskId": "9D02…"}
```

- Starts a task as the Mac's new-task composer would with that project (or Chats, `projectId` `"chats"`, which
  the Mac takes whether or not its snapshot lists Chats yet) chosen and the text typed: its harness, model, account and worktree setting as they are now on the Mac. The new task is listed
  (a `tasksChanged` event) before this response arrives, so the phone can subscribe to it at once.
- `text` may start with a Claude Code user command that the new-task composer's slash list offers for the project
  (`newTaskOptions` with `readCommands`, §15.33), which the task sends as its first message, as the Mac's home composer
  does. Any other leading slash command is `unsupportedCommand`.
- A command (§7). Errors: `notFound` (no such project, or it cannot take tasks), `emptyMessage`,
  `tooLarge`, `unsupportedCommand`, `unavailable` (no harness, reason `harness`, or the project's folder is gone,
  `folderMissing`), `busy`, `internal` (the task did not start; with reason `failed`, `message` says why).

### 15.6 Push and devices

```json
{"id": "15", "type": "registerPush", "provider": "fcm", "token": "<FCM registration token>"}
```

```json
{"re": "15", "ok": true, "pushKey": "<32 bytes>", "pushKeyId": "<16 hex>"}
```

- `provider` is `fcm` (Android; `token` is the FCM registration token), `apns` (an iOS build signed for production:
  TestFlight or the App Store) or `apns-sandbox` (an iOS build signed for development); for APNs `token` is the device
  token in lowercase hex. Any other provider is `badRequest`.
- Registering again (a new token) keeps the push key. `{"type": "unregisterPush"}` stops pushes.
- `{"type": "forgetDevice"}`: the phone unpairs itself; the Mac answers `ok`, removes the device and
  closes (4403).

### 15.8 `itemDetail`

```json
{"id": "18", "type": "itemDetail", "taskId": "4C1F…", "itemId": "i:CE01…"}
```

```json
{"re": "18", "ok": true, "taskId": "4C1F…", "itemId": "i:CE01…", "output": "…", "outputTruncated": true,
 "diffs": [{"path": "Sources/App.swift", "patch": "@@ -1,3 +1,4 @@\n…", "additions": 4, "deletions": 2}]}
```

- `activity` items with more to show carry `hasDetail: true`; only those are worth asking about.
- What a command, tool or file-change line holds beyond its title, fetched when the person opens it:
  `output`, the last 64,000 characters of a command's or tool's output (`outputTruncated` when cut); `diffs`,
  one unified diff per file (each ≤ 100,000 characters, `truncated` when cut; at most 50 files). Fields are
  absent when the Mac holds nothing for them. Sent only on request, over the encrypted channel, never in pushes.
- Errors: `notFound` (no such task or item), `unavailable` (the Mac holds nothing more for the item).

### 15.9 Suggested tasks

`activity` items with `activity` `taskSuggestion` carry `suggestionId`, `suggestionState` (`open`, `starting`,
`started`, `failed`, `dismissed`, `sentHere`), `startedTaskId` once started, `suggestionFailure` while `failed` (≤ 2,000
characters: why the Start failed, in the Mac's words, as the chip's row says it), and in `options`
the actions the phone may take: `start`, `here` (do it in this task), `dismiss`.

```json
{"id": "19", "type": "actOnSuggestion", "taskId": "4C1F…", "suggestionId": "task_1a2b3c4d", "action": "start"}
```

As the chip's buttons on the Mac. A command. Errors: `notFound`, `notAllowed` (the action is
not offered now).

The chip's Options, for a Mac whose snapshot says `suggestionOptions: true`; a client keeps the three buttons
alone with one that does not. `suggestionOptions` reads what the chip's Start starts with now: the harness, model,
effort and permission of the task it nests under (another harness at that task's permission level, in its words),
that task's account, and the place the Mac's Options shows.

```json
{"id": "40", "type": "suggestionOptions", "taskId": "4C1F…", "suggestionId": "task_1a2b3c4d", "harness": "codex"}
```

```json
{"re": "40", "ok": true, "harness": "codex", "harnessName": "Codex",
 "harnesses": [{"harness": "claude-code", "harnessName": "Claude Code"}, {"harness": "codex", "harnessName": "Codex"}],
 "settings": [{"id": "model", "name": "Model", "value": "gpt-6", "choices": [{"value": "gpt-6", "name": "GPT-6"}]}],
 "worktree": true, "projectId": "6A1E…", "placeName": "website"}
```

- It takes `newTaskOptions`'s `harness`, `settings`, `accountId` and `composer` (§15.16, §15.33), and `projectId`, as
  picks over the chip's own: another harness, another listed project or Chats, an account from the answer's list, then
  the settings in the order the menus list them. The answer is `newTaskOptions`'s, with the same rule for choices the
  Mac asks to confirm: without `composer` they are left out, and a permission only the chip holds shows as the
  harness's default, the one its Start would start in without confirmation. `projectId` is the listed project it
  starts in, Chats' ID for a chat, and absent for a folder the agent named that no listed project holds; `placeName`
  is the name the Mac's Options shows for a folder. `worktree` is present where the folder is in a Git repository. A
  read changes nothing on the Mac. Errors: `notFound`, `notAllowed` (already started, sent or dismissed, or a pick
  the menus do not offer, with `reason` as `createTask`'s), `unavailable` (the place the chip starts in is gone).
- `actOnSuggestion` with `action` `start` takes `createTask`'s `harness`, `settings`, `worktree`, `accountId` and
  `confirmed`, and `projectId`. Given any, the Mac keeps them as the chip's choice, as its Options does, and Start
  starts with it: the chip reads `starting`, then `started` or `failed`, as for any Start. They pass `createTask`'s
  checks (§15.16): without `confirmed: true` a choice the Mac asks to confirm never starts, one the request names is
  refused (`confirmation`), and one only the chip holds gives way to the harness's default, as the answer above
  showed. A client sends `confirmed: true` only after the person accepted every choice shown that asks, in the Mac's
  words. Errors as `suggestionOptions`, with `reason` `worktree` for a folder outside Git. An older Mac ignores the
  choices and starts with its own, which is why a client waits for the snapshot's flag.

```json
{"id": "41", "type": "actOnSuggestion", "taskId": "4C1F…", "suggestionId": "task_1a2b3c4d", "action": "start",
 "harness": "codex", "settings": {"model": "gpt-6", "reasoningEffort": "high"}, "worktree": false}
```

### 15.10 Pinning and archiving

```json
{"id": "20", "type": "setPinned", "taskId": "4C1F…", "pinned": true}
{"id": "21", "type": "archiveTask", "taskId": "4C1F…"}
```

As the sidebar's Pin and Archive, which archives a running task too. Commands. An archived task leaves the list
(`removedTaskIds`). Errors: `notFound`, `internal` (the task was not archived; with reason `failed`, `message` says
why, as the Mac's window does).

### 15.11 Link requests

- Event to connected v2 phones while a link request (§12.1) waits:
  `{"event": "linkRequest", "requestId": "…", "name": "Pixel 9", "platform": "android", "code": "482913",
  "expiresAt": 1792158120000}`, and `{"event": "linkResolved", "requestId": "…", "approved": true}` once answered
  anywhere or expired.
- `{"type": "answerLink", "requestId": "…", "approve": true}`: approve or refuse it. A command. Errors:
  `requestNotFound`.

### 15.12 Protocol 1 connections (removed)

Protocol 1 has been removed (§1).

The sections below (design: [REMOTE_V2_DESIGN](design/REMOTE_V2_DESIGN.md) 5.2) each only add optional fields and
requests, so a phone learns what a Mac offers from the fields it sends: an older Mac never sends them, and a phone
that does not know them ignores them.

### 15.13 Approvals: for the session, and a note with a denial

- `options` may also hold `allowForSession`: the narrowest allow the Mac's card offers that lasts for the rest of
  the task's session (Codex's "Allow for session" on a command or file change; Claude Code's suggestion kept for
  the session, which may switch its mode for the session too). Never an answer that writes a rule to a settings
  file or a policy ("Always allow in this project", a Codex policy amendment), and never a Codex request for more
  permissions (sandbox, network); those stay on the Mac.
- `optionTitles: {"allowForSession": "Allow and switch to Accept edits mode for this session"}`: the card's own
  words, in the Mac's language, for an option whose meaning depends on the provider. Show them; fall back to the
  phone's words for an option without one.
- `answerApproval` takes `"answer": "allowForSession"`, from a device with its Terminal permission (§15.28). With
  `"answer": "deny"` it takes an optional `note`
  (≤ 4,000 characters): what the agent should do instead. Claude Code reads it as the denial's message, as its own
  "No, and tell Claude what to do differently", also when the request is a Claude Code subagent's the task runs;
  every other harness gets the denial, then the note as the task's next message, as the Mac's composer sends one
  (§15.15).
- `macNote` on a pending request with `moreOnMac`: one line in the Mac's language naming what only the Mac's card
  does, for example "“Always allow in this project (saved to .claude/settings.local.json)” is on the Mac", "This
  question takes a secret answer. Answer it on the Mac.", "Fill in this form on the Mac." Show it in place of a
  generic "more on the Mac".
- Errors as §4.4; `tooLarge` for a longer note, `unsupportedCommand` for a note that is a slash command.

### 15.14 Images

- A task carries `acceptsImages: true` when a message to it can carry images (the Mac composer's own rule for its
  harness and session). `newTaskOptions` (§15.16) says the same of each harness.
- `sendMessage` and `createTask` take `images`:

  ```json
  {"id": "22", "type": "sendMessage", "taskId": "4C1F…", "text": "This is what the page looks like",
   "images": [{"type": "image/jpeg", "data": "<base64>"}]}
  ```

  At most 4 images, each `image/jpeg` or `image/png` (the Mac checks the bytes, not the label) and at most
  3 MiB decoded, the whole message within 8 MiB as JSON (base64 adds a third). With images, a message's `text`
  may be empty; a new task still needs its first words, as on the Mac. The Mac writes each image where its composer writes a pasted
  one (a private temporary folder) and sends the message with them, so the provider reads them as the Mac's own
  attachments. They are not stored anywhere else and not sent back: the sent item has `imageCount`.
- A phone message on v2 may be up to 8 MiB once joined (§13.2). Send images only to a Mac that offered them
  (`acceptsImages`): an older Mac closes a phone message over 65,536 bytes (1009).
- Errors: `notAllowed` (the task's harness takes no images), `tooLarge`, `badRequest` (not a JPEG or PNG image).

### 15.15 Follow-ups while a turn runs

- A task carries `steers: true` when a message sent while its turn runs can go into that turn now (Codex adds it
  to the running turn; Claude Code reads it at its next step). Every other harness holds it until the turn ends.
- The snapshot carries `followUp`: `"steer"` or `"queue"`, what Return does on the Mac while a turn runs
  (Settings). A phone's own choice starts from it. A Mac that takes §15.13–§15.18 always sends it on v2, so a
  phone may read its presence as that Mac taking everything in §15.13–§15.18 (a denial's `note` above all, which an
  older Mac would drop without a word).
- `sendMessage` takes `followUp`: `"steer"` sends the message into the running turn, `"queue"` holds it until
  the turn ends. Absent: the Mac's setting. No turn running: the message starts one either way.
- Queued `user` items (§6.2) carry `options`, the queue chip's actions on the Mac: `sendNow` (send it into the
  running turn now, without stopping it), `stopAndSend` (Claude Code: stop the turn for it), `remove`.

  ```json
  {"id": "23", "type": "actOnQueued", "taskId": "4C1F…", "itemId": "queued:8A3E…", "action": "sendNow"}
  ```

  A command. Errors: `notFound` (no such queued message), `notAllowed` (the action is not offered now), `busy`.

### 15.16 Choosing what a new task runs on

```json
{"id": "24", "type": "newTaskOptions", "projectId": "6A1E…", "harness": "codex"}
```

```json
{"re": "24", "ok": true, "harness": "codex", "harnessName": "Codex",
 "harnesses": [{"harness": "codex", "harnessName": "Codex", "acceptsImages": true},
               {"harness": "claude-code", "harnessName": "Claude Code", "acceptsImages": true}],
 "settings": [{"id": "model", "name": "Model", "value": "gpt-6", "choices": [{"value": "gpt-6", "name": "GPT-6"}]},
              {"id": "reasoningEffort", "name": "Reasoning effort", "value": "high",
               "choices": [{"value": "medium", "name": "Medium"}, {"value": "high", "name": "High"}]}],
 "worktree": false}
```

- `harness` (optional): the harness to describe; absent, the one the Mac's new-task composer has chosen.
  `harnesses`: what that composer offers, in its order. `settings` (optional, as `createTask` takes them): the picks
  made so far, so a setting that depends on another (an effort on its model) answers as it would after them; a pick
  the menus do not offer is `notAllowed`.
- `settings`: the new-task screen's model menu (model, effort) and, where the harness starts in one, its
  permission (Claude Code's `permissionMode`, Codex's `runLocation`), each with its value now and its choices. Choices
  the Mac asks to confirm (Bypass permissions, full access) are left out unless the client requests
  the extended composer catalog (§15.33). When the Mac's new-task screen has one of those chosen, this answer's
  permission value is the harness's default instead, the one such a task starts in without confirmation. When the
  Mac has not read the harness's model list for this account yet it reads it first, as opening the menu does (up to
  about 10 s); until then the menu holds only the value now.
- `worktree`: present for a project in a Git repository, whether the Mac starts its tasks there in a new
  worktree now.
- `createTask` takes `harness`, `settings` (`{"model": "gpt-6", "reasoningEffort": "high"}`, ids and values from
  this answer or the composer catalog's; the Mac applies them in the order its composer lists them, as picking them
  in its menus would, and takes a setting's value now back as it is, also one its list does not hold yet),
  `worktree` and `images` (§15.14). They apply to
  this task only; the Mac's new-task composer keeps its own choices. Without `confirmed: true` (§15.33) a task never
  starts in a choice the Mac asks to confirm: one the request names is refused, and one only the Mac's new-task
  screen has chosen gives way to the harness's default, as `newTaskOptions` showed. Errors: `notAllowed`, with
  `reason`: `harness` (not offered now), `setting` (a setting or value the menus do not offer now; `setting` names it
  when it is one of theirs), `confirmation` (a choice that asks, without `confirmed`), `terminal` (a choice that asks,
  from a device without its Terminal permission; §15.28), `account` (§15.33),
  `worktree` (asked for outside a Git repository), `attachments` (the harness takes no images or no such files), or
  `signIn` (the harness's login on the Mac needs signing in first).

### 15.17 Plan limits

`RemoteAccount` also has optional account-row `state` and `checkedAt` (§15.32); older clients ignore them.

- The `error` item with `errorKind` `usageLimit` (§6.7) of an idle task's latest limit card carries the card's
  actions in `options`: `continueWithAccount` (another saved account shares the task's history) and
  `autoContinue` (the task continues once the limit resets; Claude Code, when the limit names its reset), and
  `autoContinue: true` while that is armed. The card is on the latest turn, or on the one before turns that only
  Claude Code's own unanswered notices opened (a subagent the same limit stopped). An armed continue still waits
  after the Mac's Yardlet relaunches.
- ```json
  {"id": "25", "type": "limitAccounts", "taskId": "4C1F…"}
  ```

  ```json
  {"re": "25", "ok": true, "taskId": "4C1F…",
   "accounts": [{"id": "conn-2", "name": "work@example.test", "detail": "Claude Max",
                 "usage": [{"label": "5-hour", "usedPercent": 12, "resetsAt": 1792170000000}],
                 "available": true},
                {"id": "conn-1", "name": "home@example.test", "detail": "Claude Pro", "current": true,
                 "usage": [{"label": "5-hour", "usedPercent": 100, "resetsAt": 1792170000000}]}]}
  ```

  The card's account list: the task's account (`current`) and those that share its history, most limit left
  first, each with its limit windows as the list shows them. `available`: the task may move to it now (not the
  task's own, not signed out). The Mac first rereads the limits a check has not confirmed within the last minute,
  as the list does when it opens (up to about 15 s).
- `{"type": "continueWithAccount", "taskId": "4C1F…", "accountId": "conn-2"}`: the list's choice. The task moves
  to that account and is asked to pick up where it stopped; nothing is sent unless the move completed. A command.
  Errors: `notAllowed` (not an available account, or the card offers no action now), `busy`, `notFound`. When the
  move fails afterwards, the error shows on the task as on the Mac.
- `{"type": "setAutoContinue", "taskId": "4C1F…", "enabled": true}`: the card's "Auto-continue when limits reset".
  A command. Errors: `notAllowed`.

### 15.18 A browser tab handed to the person

- While the agent waits on a tab it handed to the person (`browser_handoff`), the task is `waiting` with
  `pendingRequest` `input` and `pendingKind` `browserHandoff`, and its latest turn ends with a pending `approval`
  item, `requestKind` `browserHandoff`: `title` the site (host), `detail` the agent's reason, `options` `done` and
  `decline`. The Mac's panel shows the tab with the same reason and the two buttons. This is the one wait the
  Mac's sidebar does not mark (it shows the task running, and the panel's bar and a Mac notification say the
  rest), so here `attention` is the phone's alone.
- `{"type": "answerHandoff", "taskId": "4C1F…", "requestId": "…", "answer": "done"}`: the bar's "I'm done" or
  "Decline", once the step is finished in the tab (§15.25) or elsewhere (a sign-in approved in another app, a link
  opened on the phone). A command. Errors: `requestNotFound`, `notAllowed`.
- The item carries `tabId`, the handed tab, which `watchTab` shows (§15.25); absent when the Mac
  does not know which of the task's tabs it is.
- It is pushed (§16) like any other wait.

### 15.19 Every answer the Mac's card gives

A phone answers a request with the same choices the Mac's card
shows, instead of the few §4.4 and §15.13 name.

- A pending `approval` item without a question or plan form (`requestKind` `approval`, and `form` for an MCP form)
  carries `choices`, the card's answers in its order:

  ```json
  "choices": [{"id": "0", "title": "Deny", "role": "destructive"},
              {"id": "1", "title": "Always allow in this project (saved to .claude/settings.local.json)",
               "role": "secondary", "standing": true},
              {"id": "2", "title": "Allow once", "role": "primary"}]
  ```

  `title` is the card's words in the Mac's language; `role` is `primary` (the prominent answer), `secondary` or
  `destructive` (a denial). `standing: true`: the answer leaves a rule beyond this task (a settings file, a policy,
  an MCP tool allowed for good, an exec or network policy amendment). The phone asks once more before it sends one
  ([REMOTE_V2_DESIGN](design/REMOTE_V2_DESIGN.md) 5.3). The ids name the answers of this request only.
- A choice Yardlet worded itself also carries `text`, the Mac's catalog key `title` was made from
  and the arguments filled into it, each again a key or words as they are:

  ```json
  {"id": "2", "title": "Always allow in this project (saved to .claude/settings.local.json)", "role": "secondary",
   "standing": true,
   "text": {"key": "Always allow in this project (saved to %@)", "args": [{"text": ".claude/settings.local.json"}]}}
  ```

  A key is the English text of Yardlet's string catalog (`Localizable.strings`); `%@` and `%1$@` take the
  arguments in order. A client whose own catalog has the key shows it in its language, filling the arguments the
  same way; otherwise, or when the key's format does not take exactly the arguments sent, it shows `title`. A
  provider's own words (an ACP agent's option names) carry no `text`. An Android client can keep its own table from
  these keys to its strings, and fall back to `title` for any key it lacks.
- Answering:

  ```json
  {"id": "26", "type": "chooseAnswer", "taskId": "4C1F…", "requestId": "toolu_01…", "choice": "2"}
  {"id": "27", "type": "chooseAnswer", "taskId": "4C1F…", "requestId": "toolu_01…", "choice": "0",
   "note": "Run only the unit tests"}
  ```

  `note` goes with a `destructive` choice only, as §15.13's. A command. Errors: `requestNotFound`, `notAllowed`
  (no such choice; reason `terminal` for an allow that lasts beyond this call, for the session or as a `standing` rule,
  from a device without its Terminal permission, §15.28), `tooLarge`, `unsupportedCommand` (the note), `unavailable`.
- An MCP form (`requestKind` `form` with `formFields`) is answered by a choice with `values`:

  ```json
  "formFields": [{"id": "repo", "label": "Repository", "type": "text", "required": true, "maxLength": 100},
                 {"id": "private", "label": "Private", "type": "boolean", "default": true},
                 {"id": "team", "label": "Team", "type": "choice",
                  "options": [{"value": "web", "title": "Web"}, {"value": "ios", "title": "iOS"}]}]
  ```

  `type`: `text` (with `format` `email`, `uri`, `date` or `date-time`, `minLength`, `maxLength`), `number` or
  `integer` (`minimum`, `maximum`), `boolean`, `choice` (one of `options`), `choices` (several, `minItems`,
  `maxItems`). `default` is the field's value to start from. `{"type": "chooseAnswer", …, "choice": "1",
  "values": {"repo": "acme/web", "private": true, "team": "web"}}`: the Mac checks the values as its card does and
  answers `notAllowed` with reason `form` and the first problem in `message` ("Repository: Required") when one does
  not fit. A value
  of the wrong kind for its field, or for no field, is refused the same way, never replaced by the field's default. The
  sentence the form asks with, which the Mac's card shows above the fields, is the item's `message` (§6.5). The
  form's item also keeps `moreOnMac` for phones that do not read `choices`.
- A question step whose answer is a secret (`secret: true` in `questionSteps`) is answered on the phone as any other
  step (§15.3). Such a question offers `answerSecret` in `options` instead of `answer`, with `moreOnMac` and a
  `macNote`, so a phone that does not know `answerSecret`, which would show the value, still sends the person to the Mac. A
  phone that reads `answerSecret` shows the field masked, keeps the value only until it is sent, and never stores or
  logs it; the Mac sends it to the provider as its card does.
- `moreOnMac` and `macNote` remain for a request with no choices: one Yardlet itself answers nothing for (its
  `unanswerableReason`, in `macNote`). Steps that are not requests (Touch ID, a passkey or sign-in window, a macOS
  permission prompt, a keychain prompt) are the Mac's, as before.
- `options` (§6.5, §15.13) stays for phones that do not read `choices`.

### 15.20 Files and photos from the camera

Photos from the camera are images (§15.14). Any other file goes up
in parts first, then a message or a new task names it.

- A task carries `acceptsFiles: true` when a message to it can carry files; `newTaskOptions` says the same of each
  harness (`acceptsFiles` beside `acceptsImages`).
- ```json
  {"id": "28", "type": "uploadFile", "uploadId": "<UUID>", "name": "report.pdf", "mediaType": "application/pdf",
   "size": 5242880, "offset": 0, "data": "<base64 of up to 4 MiB>"}
  ```

  ```json
  {"re": "28", "ok": true, "uploadId": "<UUID>", "received": 4194304}
  ```

  `uploadId` is the phone's own UUID for the file. The first part (`offset` 0) names the file (`name`, `mediaType`) and
  its `size`, at most 500 MiB; a part takes the bytes at `offset` and the answer says how many the Mac holds. A part
  at another offset than `received` adds nothing and gets the same answer, so after a dropped connection the phone
  sends from `received` again. The Mac keeps an unfinished upload for 30 minutes after its last part, and a finished
  one until a message takes it or 30 minutes pass; when Yardlet starts again it removes whatever no message took.
  An `uploadId` is used once: a first part under an ID used before is refused. A part the Mac fails to write ends
  the upload, and the phone starts the file again under a new ID. Not a command. At most 4 uploads are open per device
  and 40 finished files wait for a message: a phone does not say when it gives up on a file, so a first part past
  either drops the device's upload of that kind that went longest without a part, which then answers `notFound`. Errors: `badRequest` (also a used ID), `tooLarge` (over 500 MiB, or the Mac's disk would keep less than
  2 GB free), `notFound` (an unknown, expired or dropped upload at an offset after 0).
- `sendMessage` and `createTask` take `files: ["<uploadId>", …]`, at most 20, each finished and named once. The Mac writes each
  file in a folder of its own under its temporary folder (never the task's folder), named as the phone named it
  without any path, readable only by the person and never executable, and sends it as its composer sends a dropped
  file: an image the harness can carry as an image, any other file as a reference to its path (Claude Code's `@`
  path, a Codex mention). Nothing on the Mac opens or runs it. A file stays through the message that names it, past the
  30 minutes if need be, and when that message fails it waits for the next one for another 30 minutes. Errors: `notFound`
  (an upload that is not finished or has expired), `busy` (a message still being sent names the file), `notAllowed`
  (the harness takes no files).
- Over the relay each part is ordinary encrypted chunks (§13.2): the relay sees only their size and timing.

### 15.21 Scheduled tasks

The phone lists the Mac's scheduled tasks (Yardlet's own, the Mac's Scheduled tasks list), runs
one now and pauses or resumes one, through the same paths as the Mac's Run now, Pause and Resume. Creating, editing
and deleting schedules stay on the Mac unless it advertises §15.35.

- The snapshot carries `scheduledTasks: true` when the Mac answers the requests below. A phone shows schedules only then.
- ```json
  {"id": "31", "type": "scheduledTasks"}
  ```

  ```json
  {"re": "31", "ok": true, "schedules": [
    {"id": "6B0E…", "name": "Morning check", "when": "Every day at 9:00 AM", "enabled": true, "running": false,
     "nextRunAt": 1792200000000, "status": "Next run tomorrow at 9:00 AM", "projectName": "acme-web",
     "harnessName": "Codex",
     "lastRun": {"at": 1792158000000, "outcome": "started", "taskId": "4C1F…", "line": "Last run today at 9:00 AM"}}]}
  ```

  In the order of the Mac's list, at most 200: the ones that will run, soonest first, then those that are off, then
  the one-offs that ran, the latest first. `when` is the Mac's own line for when it runs and `status` its status
  line (absent when it shows none), both in the Mac's language as the Mac shows them. `enabled` is false while it is
  paused, and also once it stopped itself (a one-off that ran or expired, repeated failed starts), which `status`
  then says. `canResume: true` on one that is off and that Resume turns on again: paused, or a repeating one that
  stopped itself. A one-off that ran or whose time passed is not resumed (the Mac offers Edit instead), so a phone
  shows Resume only with `canResume`. `running`: the task of its latest run that started or continued one is still
  working or waiting on the person (the snapshot's `attention` `active` or `waiting`). `nextRunAt` (milliseconds
  since 1970) is absent when it will not run again on its own. `projectName`: the project its runs start in, or for
  a folder outside any project the folder's name (as the sidebar names it); for one that continues a task, that
  task's project; absent for a chat. `harnessName` is the harness its runs start on. `lastRun` is the latest run,
  absent before its first: `at`, `outcome` (`started`, `deferred`, `expired`, `skipped`, `failed`; unknown values are read as `failed`),
  `taskId` when the run started or continued a task the snapshot lists, and `line`, the Mac's own line for it in
  the Mac's language: when it ran, and for a skip or a failed start why, as the run history says it ("Last run
  today at 9:00 AM · Skipped: the previous run is still going"). The session schedules a Claude Code task's CLI
  holds are not listed by this base response; §15.35 adds them separately. Not a command. Errors: `unavailable`.
- ```json
  {"id": "32", "type": "runScheduledTask", "scheduleId": "6B0E…"}
  ```

  A command: runs it now, as Run now on the Mac does, also while it is paused. The run is recorded like any other
  (a skip when its previous run's task is still busy, a failure when it cannot start). Errors: `notFound`, `busy`
  (a run of it is starting).
- ```json
  {"id": "33", "type": "setScheduledTaskEnabled", "scheduleId": "6B0E…", "enabled": false}
  ```

  A command: Pause (`false`) or Resume (`true`), as on the Mac; the one it is already in changes nothing. Errors:
  `notFound`, `notAllowed` (Resume of a one-off that ran or whose time passed, which has no `canResume`).
- `{"event": "schedulesChanged"}` goes to a connection that asked for `scheduledTasks` since it connected, when a
  schedule is added, changed or removed, runs, or the task of its latest run changes state; batched like
  `tasksChanged`. It carries nothing; the phone asks for `scheduledTasks` again. It is sent only when the list a
  phone would get differs from the one last read, so it also comes when the Mac's words change with the time
  ("tomorrow" becoming "today").
- The audit log (§4.4) names the schedule of `runScheduledTask` and `setScheduledTaskEnabled` in place of a task.

### 15.22 Files from the Mac

The phone opens what a task made and what its conversation names: the files the Mac's Outputs card lists, a file in
the task's own folders, and a file elsewhere that the task's conversation names, as the Mac's window opens it from
that conversation. Together these are the task's files. Files the other way, from the phone to the Mac, are §15.20.

- The snapshot carries `taskFiles: true` when the Mac answers the requests below. A phone offers them only then.
- ```json
  {"id": "34", "type": "taskOutputs", "taskId": "4C1F…"}
  ```

  ```json
  {"re": "34", "ok": true, "outputs": [
    {"path": "/Users/example/Desktop/report.pdf", "name": "report.pdf", "size": 482113, "writtenAt": 1792158000000}]}
  ```

  The files the Mac's Outputs card shows for the task, in its order (newest first, at most 50): files the task
  wrote whole, outside its folder of any kind and inside it only documents and media; a Codex addition counts once
  its patch was applied, not while it waits or when it was declined or failed; and pictures a tool reported saving:
  a Codex `imageGeneration` item's `savedPath` once it completed, and the file an Antigravity `generate_image` result
  names, in the log of the conversation or of a subagent it started, when that file lies directly in the
  conversation's own folder (`brain/<id>/`). A path a message or another tool's result names is none of these (a
  message's path is read as a named file, below), and the rest of that folder is not served. `size` is absent for a
  file that is
  gone or whose place now holds a symbolic link; `writtenAt` (milliseconds since 1970) when the Mac knows it. Not a
  command. Errors: `notFound` (no such task).
- ```json
  {"id": "35", "type": "readFile", "taskId": "4C1F…", "path": "/Users/example/Desktop/report.pdf", "offset": 0}
  ```

  ```json
  {"re": "35", "ok": true, "path": "/Users/example/Desktop/report.pdf", "name": "report.pdf",
   "mediaType": "application/pdf", "size": 482113, "offset": 0, "data": "<base64 of up to 4 MiB>",
   "modifiedAt": 1792158000000}
  ```

  Reads up to 4 MiB of one file from `offset`; the phone asks again from `offset` plus the bytes it got until it
  has `size`, and starts over when `modifiedAt` or `size` changes between parts. An answer at `offset` equal to
  `size` carries no bytes. `path` is absolute, starts with `~/` for the home folder, or is relative to the task's folder as a conversation writes it, and
  `.` and `..` are taken out by its text; the answer gives the absolute path the Mac read, with its folders'
  symbolic links resolved, and `name` is that path's last part. The Mac serves a regular file only, at most 100 MiB,
  and only when it is one of the task's outputs (above), a file the task's conversation names (below) or, once
  symbolic links are resolved, lies inside one of the task's own folders (its working folder or worktree and the
  project's other folders, as the task was given them), by whole path components compared byte for byte, by the app's
  own path rules (`PathRules` with `comparingBytes`; docs/PLATFORM_PORTABILITY.md, "Paths and executable lookup"). A
  file the conversation names is one the Mac's window opens from that conversation: a file link or a path in code in
  the agent's own messages (a Codex message's file citations and review comments too), the file a call of the agent's
  read, wrote, edited or looked at (its `file_path` and the like, a picture it viewed or made) and the files a change
  touched, a picture a message carries as its own input, and the file an MCP result's `resource_link` names. Text that
  is only in a call's output (a command's output, a page's content), in a call's other arguments, in a command line, or
  in the sender's own words (a file list written as the Codex app attaches files among them) names none: what a page
  says, or what a device writes, cannot make a file readable. It is matched by the path the conversation wrote (absolute,
  from `~`, or relative to the task's folder; `.` and `..` taken out, `/tmp`, `/var` and `/etc` read as their
  `/private` folders) against the request's, by their text, and read, as an output is, in its own place. A named
  file is never served from where keys, sign-ins and apps' data are kept, wherever its folders' links lead: a hidden
  entry directly in the home folder (`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.netrc`, `~/.config`, the agents' and Yardlet's
  own homes such as `~/.claude`, `~/.codex`, `~/.gemini` and `~/.yardlet`, and the rest), `~/Library`, what macOS keeps
  for each user in `/private/var/folders` other than the temporary folder (`…/T`), and `/Library/Keychains`; the file
  opened is judged again by the path the system gives its descriptor. Nothing in `/dev` (a descriptor there reads as
  the file it is open on) or `/.vol` is served, of any kind. An output
  is the file in its own place: its folder's links are followed, but a symbolic link put where it was is not. Nothing a
  request names is looked up before its path, by its text, is one of the outputs or the named files or under one of
  the folders. A folder that is the Mac's home folder or holds it (`/`, `/Users`, by any path,
  `/System/Volumes/Data/Users` too) gives no files of its own: a task there serves only its outputs and the files its
  conversation names. Anything else is refused, the same for a file that does not exist, so the phone learns nothing
  about folders it may not read; no error names a path. `mediaType` is the Mac's guess from the file's extension,
  else `text/plain` for a file that starts as UTF-8 text and `application/octet-stream` for anything else. A
  device's reads carry at most 32 MiB of parts at once and then 32 MiB per 10 s, over all its connections; past
  that `readFile` answers `rateLimited` until the budget refills. Not a command. Errors: `badRequest` (no `path`, no
  `offset` or one past `size`), `notFound` (no such task, or a file it may not read or that does not exist),
  `tooLarge` (over 100 MiB), `rateLimited`.
- The audit log (§4.4) records, for a task the Mac lists, each `readFile` that does not go on from where the same
  connection's last read of that file ended (a file read in parts from offset 0 is one line; a read that starts
  anywhere else is another) and every refusal, with the task and the file's name in `file` (for a refusal, the last
  part of the path the phone asked for), never its path, so the person can see what a phone opened. The same line
  (device, task, file and result) is written at most once a minute.

### 15.23 A task's settings, slash commands, edit and fork

Another device changes an existing task the way the Mac's task composer and turns do: the model,
effort and permission mode in the composer's bottom row, the slash commands that may run from elsewhere, the latest
message's Edit message, and Fork from here. Each acts through the path the Mac's own control takes.

- The snapshot carries `taskControls: true` when the Mac answers the requests below. A phone offers them only then.
- ```json
  {"id": "40", "type": "taskSettings", "taskId": "4C1F…"}
  ```

  ```json
  {"re": "40", "ok": true, "taskId": "4C1F…", "settings": [
    {"id": "permissionMode", "name": "Permission mode", "role": "permission", "value": "default",
     "choices": [{"value": "default", "name": "Manual"}, {"value": "acceptEdits", "name": "Accept edits"},
                 {"value": "bypassPermissions", "name": "Bypass permissions",
                  "confirm": {"title": "Bypass permission checks?",
                              "message": "Claude Code will change files and run commands without asking.",
                              "button": "Use bypass permissions"}}]},
    {"id": "model", "name": "Model", "role": "model", "value": "opus",
     "choices": [{"value": "opus", "name": "Opus 5.5"}, {"value": "sonnet", "name": "Sonnet 5.5"}]},
    {"id": "effort", "name": "Effort", "role": "effort", "value": "high",
     "choices": [{"value": "medium", "name": "Medium"}, {"value": "high", "name": "High"}]}]}
  ```

  The settings the task's composer shows in its bottom row, in its order, with §15.16's shape and the names in the
  Mac's language. `role` says which control holds each: `mode` (the provider's own mode menu), `plan` (Codex's Plan
  indicator, sent only while Plan mode is on, with no choices; the `plan-mode` command below turns it off),
  `permission`, `model`, `effort` and `speed`, which share the model menu, and `contextLimit`, the Claude Code task's
  own context limit in the context window, whose Default choice names the limit it stands for and whose `note` says the
  running task takes it later. Absent roles are left
  out of the row, and a role a phone does not know is skipped. `elevated: true`: the value now lifts the sandbox or skips asking (the
  Mac draws it in orange). A permission control with nothing to choose has no choices, `value` `""`, its words in
  `title` and what its menu says in `note`. A choice with `confirm` is one the Mac's menu asks about first (Bypass
  permissions, Codex's Full access), in the Mac's words: the phone asks the same before it sends it.
- `prepare: true` on a setting: the Mac's menu reads its choices before it opens (a task not connected to its
  harness, or a Codex model list not read yet). The phone shows the value now, and when the person opens that menu it
  asks `{"type": "taskSettings", "taskId": "4C1F…", "prepare": true}`, which reads them first, as opening the Mac's
  menu does: a task not connected yet connects to its harness and reads its saved settings (no turn starts), up to
  about 10 s. Choices of a setting that still has `prepare` are not applied. `taskSettings` is not a command. Errors:
  `notFound`.
- ```json
  {"id": "41", "type": "setTaskSetting", "taskId": "4C1F…", "setting": "permissionMode", "value": "bypassPermissions",
   "confirmed": true}
  ```

  A command: the menu's choice, applied as the Mac's composer applies it. `confirmed: true` is required for a choice
  with `confirm`, once the person said yes. The answer carries `settings`, the controls after the change, once the
  provider took it (or after about 10 s). Errors: `notFound`, `notAllowed` (no such setting, a value the menu does not
  offer now, a setting that still has `prepare`, or a choice with `confirm` without `confirmed`, with reason
  `confirmation`; reason `terminal` for one from a device without its Terminal permission, §15.28).
- `{"event": "taskSettingsChanged", "taskId": "4C1F…"}` goes to a connection that asked for the task's `taskSettings`
  since it subscribed to it, when they change by any path (the Mac's own menus, another device, the provider leaving
  plan mode). It carries nothing; the phone asks for `taskSettings` again. Unsubscribing ends it.
- ```json
  {"id": "42", "type": "composerCommands", "taskId": "4C1F…"}
  ```

  ```json
  {"re": "42", "ok": true, "taskId": "4C1F…", "commands": [
    {"name": "compact", "description": "Clear conversation history but keep a summary in context",
     "argumentHint": "<optional custom summarization instructions>"},
    {"name": "clear", "description": "Start a new conversation and keep this chat."}]}
  ```

  The slash commands the task's composer lists that may run from another device, in its list's order and words:
  Claude Code's `/compact`, `/clear` and explicitly classified user commands; the Codex app's Compact, Fork chat,
  New chat, Plan mode, speed (`service-tier:…`) and skills (§15.33). Built-in commands that change files, settings
  or accounts, need a window of the Mac's (code review, rename, a side chat, status), or are the sidebar's
  (pin, archive, §15.10) are not listed. `title` is the list's own name for a command where it shows one in place of `/name`; `group` its heading;
  `argumentHint` the words it takes after its name, absent when it takes none. `runs: true`: choosing it runs it at
  once (the Codex app's); otherwise choosing it types `/name ` into the draft, and sending that draft runs it. Not a
  command. Errors: `notFound`.
- ```json
  {"id": "43", "type": "runComposerCommand", "taskId": "4C1F…", "command": "compact", "arguments": "Keep the API notes"}
  ```

  A command: runs it as the Mac's composer does. `arguments` (≤ 4,000 characters) are accepted for a command with an
  `argumentHint` or an explicitly classified CLI user command. A command that starts a task (`clear`, `new`, `fork`) answers with its `taskId`, listed before the
  answer as a new task is (§15.5); the Mac's window does not switch to it. `compact`, `clear` and `new` wait for the
  task's turn to end, as on the Mac. Errors: `notFound`, `notAllowed` (not listed now, or `arguments` it does not take),
  `busy` (a turn runs, `running`; a message is being edited, `editing`; messages wait in the queue, `queue`; the task is
  changing, `changing`; or another app holds it, `otherApp`), `tooLarge`, `unavailable` (the task's folder is gone,
  `folderMissing`), `internal` (the new task did not start). What fails once the command runs is the Mac composer's
  `notice` (§15.33), as the Mac's composer says it.
- The `turn` item of a turn that offers them carries `options`: `edit` (the turn's Edit message: Codex's latest request
  once every turn has finished, Claude Code's latest message while the task is idle) and `fork` (Fork from here: a
  finished Codex turn, or a Claude Code task's latest turn while idle, which forks its whole conversation). An edit is
  offered only when the message's `text` came whole (not `truncated`). Restoring files stays on the Mac.
- ```json
  {"id": "44", "type": "editMessage", "taskId": "4C1F…", "turnId": "3F2A…", "text": "Run only the unit tests"}
  ```

  A command: Edit message and Send, as on the Mac. The turn is replaced by the edited message and a new turn starts;
  the message's pictures stay with it, and `text` (as `sendMessage`'s) takes the place of its words. Whatever the
  Mac's composer for the task held comes back to it afterwards. Errors: `notFound`, `notAllowed` (the turn offers no
  edit now; or the provider refused it, reason `failed`, and `message` says why), `busy` (a message is being edited on
  the Mac, `editing`; messages wait in the task's queue, `queue`; or the task is changing, `changing`), `emptyMessage`,
  `tooLarge`, `unsupportedCommand`.
- ```json
  {"id": "45", "type": "forkTask", "taskId": "4C1F…", "turnId": "3F2A…"}
  ```

  ```json
  {"re": "45", "ok": true, "taskId": "9D02…"}
  ```

  A command: Fork from here on the turn that offers `fork` (`turnId` absent: the latest turn). The fork is a task of
  its own, nested under the task in the sidebar and listed before the answer; the Mac's window does not switch to it.
  Errors: `notFound`, `notAllowed` (the turn offers no fork now), `internal` (the fork did not start).
- The audit log (§4.4) names each command's type and task, never a setting's value, a command's arguments or a
  message's text.
- **For the Android app:** read `taskControls` from the snapshot; on opening a task, ask `taskSettings` and draw each
  role in the composer's controls (a menu per setting, the model menu holding `model`, `effort` and `speed`), asking
  `taskSettings` with `prepare` when the person opens a menu whose setting has it, asking again on
  `taskSettingsChanged`, and showing `confirm` as a dialog before `setTaskSetting` with `confirmed`. Ask
  `composerCommands` when the slash list opens (a typed `/` or the "+" menu) and run a chosen command by its `runs`;
  open the `taskId` a command or `forkTask` answers with. Offer Edit message and Fork from here on the turns whose
  `turn` item lists them; an edit puts the message's text in the composer and sends it with `editMessage`.

### 15.24 A conversation in full detail

Yardlet on another computer (§18) draws a task's conversation with the Mac's own cards, and asks
for what they read beyond §6's items. A phone keeps §6.

- The snapshot carries `fullConversation: true` when the Mac answers `subscribeTask` with `"detail": "full"` (§4.2).
  A subscription asks for it once; its page, `loadOlder` pages and events then hold the same items in the same order,
  with the same IDs, as §6, and the fields below besides. Nothing else differs: lines still read their output and
  diffs with `itemDetail` (§15.8), and requests answer as §15.19.
- **Longer text.** `text` of `user` and `assistant` items, the `quotes` of a `user` item's `sender` (§6.2), a request's
  `text`, `detail`, `message` and `command`, and an error's `message` (the provider's whole text, not its summary) are
  cut at 200,000 characters instead of §6's limits, with `truncated: true` as before.
- **`images`** on a `user` item: the pictures the message sent, as small previews the Mac makes once, `{"type":
  "image/jpeg", "data": "<base64>", "name": "login-page.png"}`, at most 480 pixels on the long side, in the message's
  order. A picture the Mac cannot read (or one on the web, which it never fetches) has none, and a preview being made
  arrives as a change once it is ready; `imageCount` still counts them all, so a client shows the rest by name.
- **`subagent`** on an `activity` item with `activity` `subagent`, the subagent card's own fields (its title and status
  are the item's):

  ```json
  "subagent": {"kind": "spawn_agent", "detail": "thread-7c1…", "input": "Survey the sync libraries…",
               "output": "…", "model": "gpt-5.5", "harnessLabel": "Codex · gpt-5.5", "background": true,
               "taskIds": ["9D02…"], "copyText": "…"}
  ```

  `input` and `output` are cut at 64,000 characters. `taskIds`: the listed tasks a Codex subagent's child threads run
  in, which its "Open child task" opens; a child the Mac does not list yet has none. `copyText`: what the card's copy
  button takes. Every subscription carries what the card does: `subagent` with only `taskIds`, and
  `activityId` and `canStop` for a Claude Code subagent (§15.31's `subtask`), so a client reading §6 can stop the
  subagent and open its child tasks too.
- **`compaction`** on a `notice` item that is a context compaction: `{"phase": "completed", "tokensBefore": 180000,
  "tokensAfter": 42000}`, `phase` `started`, `completed` or `failed` with the provider's `message`. `whileIdle: true`
  when the Mac compacted the idle task before its prompt cache expired (Settings › General › Idle compaction), which
  a client notes under the marker; absent otherwise.
- **`providerNotice`** on a `notice` item a provider sent beside a turn: `{"kind": "modelRerouted", "message": "gpt-5.5",
  "fromModel": "gpt-6", "reason": "highRiskCyberActivity"}`; `kind` `modelRerouted`, `warning`, `configWarning` or
  `deprecationNotice`, with `details` and a config file's `path` when it names one. A client words it itself.
- **`schedule`** on the `activity` item of a schedule an agent created (§15.21): `{"id": "6B0E…", "name": "Morning
  check"}`, the schedule's ID and the name the call gave. In every subscription.
- **`limit`** on an `error` item with `errorKind` `usageLimit`: the limit as the provider reported it, which a client
  words itself (its `title` and `message` are the Mac's words):

  ```json
  "limit": {"status": "rejected", "window": "session", "usedFraction": 1.0,
            "windows": [{"window": "session", "usedFraction": 1.0, "resetsAt": 1792170000000},
                        {"window": "weekly", "usedFraction": 0.62, "resetsAt": 1792500000000}]}
  ```

  `status` `allowed`, `warning` or `rejected`; `window` and each window's `window` `session`, `weekly`, `model` or
  `overage`, with the `model` a weekly limit covers; `overage: true` while paid extra usage covers requests; `message`,
  the provider's own words. When it resets is the item's `resetsAt`, and its actions are §15.17's: the card that
  carries `options` is the one the task continues from, which may sit before turns that only Claude Code's own
  notices opened, and `autoContinue: true` marks the armed continue, which the Mac keeps by the reset it waits for.
- **Size.** A page still holds about 384 KB of items besides its first turn (previews count by their bytes), and a
  `conversation` event at most about 2 MiB; larger changes come as several events in a row (§5.3).
- **For the Android app:** nothing changes until it asks. To draw the same cards it would send `"detail": "full"` to a
  Mac with `fullConversation`, decode the previews' JPEG, and word notices and limits from their kinds as its own
  strings, keeping `title` and `text` as the fallback for a kind it does not know. Full detail costs more over the
  relay, so a phone on mobile data may prefer §6.

### 15.25 A task's browser tabs

The phone sees a task's browser tab and uses it, for a step only the person can take while away: a
sign-in, a two-factor code, an approval button, often the tab a browser handoff (§15.18) gave them. The Mac sends
pictures of the tab's visible page while the phone watches it, and the phone's taps, scrolling and typing go to the
page as the Mac's own browser panel sends the person's. Hosts advertising `tabControls` also accept addresses and
tab closes within the watched task (§15.30), and hosts advertising `tabPermissions` take the answer to a site's
permission prompt in the watched tab (below); browsing outside a task stays on the Mac.

- The snapshot carries `browserTabs: true` when the Mac answers the requests below (it has a browser engine). A phone
  offers a task's browser only then. It also carries `tabLists: true` when `watchTab` takes `listOnly` (below),
  `tabPermissions: true` when the Mac answers `answerTabPermission` (below), and `tabCopy: true` when it sends what the
  watched page copies (`tabCopied`) and takes ⌘C and ⌘X (below).
- ```json
  {"id": "40", "type": "watchTab", "taskId": "4C1F…", "maxWidth": 1080, "maxHeight": 2000,
   "viewport": {"width": 390, "height": 844, "mobile": true}}
  ```

  ```json
  {"re": "40", "ok": true, "taskId": "4C1F…", "tabId": "9B21…",
   "tabs": [{"tabId": "77A0…", "title": "Managing releases - GitHub Docs", "url": "https://docs.github.com/…"},
            {"tabId": "9B21…", "title": "Sign in to GitHub", "url": "https://github.com/login", "active": true,
             "waiting": "handoff", "requestId": "…", "reason": "Sign in so I can publish the notes",
             "passwordField": true}]}
  ```

  Lists the task's tabs, as the task's side panel lists them, in its order, and starts watching one: `tabId` names it,
  or the panel's front tab (`active`) when the request names none. Tabs the panel saved before Yardlet restarted, or
  lost with the browser, open again first, as the agent's first browser call opens them. `tabId` is absent, and `tabs`
  empty, for a task with no tab; the watch then only follows the list. `maxWidth` and `maxHeight` (1 to 2,560; 1,280 and
  1,600 when absent) are the largest picture the phone wants, in pixels: its screen, not the page. `viewport`
  (optional) is the size the phone asks the tab to be drawn at while it watches, in CSS pixels: `width` 200 to 1,920,
  `height` 200 to 2,560 (another is `badRequest`), and `mobile` (when absent, true under 768 wide) draws it as a phone:
  a mobile viewport, touch, and a phone's user agent and client hints, as the agent's `browser_resize` does. Without
  it the tab keeps the size it has (Yardlet on another computer asks for its panel's size, with `mobile` false). One watch per connection: watching another
  tab or task replaces it. With `listOnly: true` (hosts advertising `tabLists`; no `tabId` or `viewport`, else
  `badRequest`) the watch follows the task's list alone, as for a task with no tab, whatever tabs it has: `tabId` is
  absent, no tab paints, takes a size or sends frames or input for it, and tabs saved before Yardlet restarted, or lost
  with the browser, are listed as they were (their `tabId`s are the ones they open under) and stay unopened, so no
  browser starts. `browserTabsChanged` follows. Yardlet on another computer (§18) follows the list of the task its
  window shows this way. A tab's fields: `tabId` (the side-panel tab; it stays when the
  tab's page is opened again in its place), `title`, `url` (only its origin while the address carries a value the
  password manager filled), `active`, `loading`, `canGoBack`, `canGoForward`, `waiting` (what the tab waits on from the
  person, the most pressing: `handoff`, `passkey`, `signIn`, `permission`, `externalApp`, `javaScriptDialog`,
  `fileChooser`), `requestId` and `reason` (the handoff's, §15.18), `passwordField` (the page's focused field is a
  password field), `permission` (the site's permission prompt up on the tab, also while `waiting` names a more pressing
  wait; below). Not a command. Errors: `notFound` (no such task, or no such tab of it), `unavailable` (no browser
  engine).
- `{"event": "tabFrame", "seq": 51, "taskId": "4C1F…", "tabId": "9B21…", "frame": 3, "image": "<base64>",
  "mediaType": "image/jpeg", "width": 1080, "height": 675, "viewportWidth": 1280, "viewportHeight": 800}`: the watched
  tab's visible page. `image` is JPEG from the Mac (the fixture sends PNG), `width` by `height` pixels, scaled to fit the
  watch's largest picture and never past the page's own pixels; `viewportWidth` by `viewportHeight` is the visible page
  in CSS pixels (the phone's own size while the tab is drawn at it), the space `tabInput` counts in. The first comes at
  once. A frame comes only after the phone acknowledged the one before it (`tabFrameAck`), or 10 s after it was sent,
  only when the page drew something different, and at most about four a second; a page that keeps drawing the same
  picture sends nothing. This pace is the connection's: watching again, the same tab or another, does not start a frame
  sooner. A page under a dialog or one of Chromium's windows, whose renderer ended, or a `file:` page outside the task's
  files (below) sends nothing until it can be pictured.
- `{"type": "tabFrameAck", "taskId": "4C1F…", "tabId": "9B21…", "frame": 3}`: the phone has the frame (send it once the
  picture is decoded); the next may come. Acknowledge every `tabFrame` the connection receives, also one of a tab or
  task no longer watched: frame numbers are the connection's, and an acknowledgement of another number changes nothing.
  Not a command.
- `{"event": "browserTabsChanged", "seq": 52, "taskId": "4C1F…", "tabs": [ … ]}`: the watched task's list changed (a tab
  opened or closed, a page, title, loading, wait or handoff, the password field's focus), the whole list, batched like
  `tasksChanged`. A watched tab that is no longer listed sends no more frames: watch another (the `active` one).
- ```json
  {"id": "41", "type": "tabInput", "taskId": "4C1F…", "tabId": "9B21…", "input": {"kind": "click", "x": 412.5, "y": 236}}
  ```

  The person's input to the watched tab (another is `notAllowed`), as trusted input the page cannot tell from a mouse
  and keyboard on the Mac. `x` and `y` are CSS pixels from the visible page's top left: a point on the picture times
  `viewportWidth / width`. `input.kind`:

  | kind | fields | |
  |---|---|---|
  | `click` | `x`, `y`, `button`, `clickCount`, `modifiers` | a press and release: a tap. `clickCount` is the click's place in a series (2 for the second click of a double click) |
  | `mouse` | `action` (`down`, `move`, `up`), `x`, `y`, `button`, `modifiers` | a drag (a slider, a puzzle) or a hover; a `move` with `button` drags |
  | `scroll` | `x`, `y`, `deltaX`, `deltaY` | a wheel at the point, in CSS pixels; positive scrolls the page right and down (a finger moving up is a positive `deltaY`) |
  | `text` | `text` (1–4,000 characters, at most 16,000 bytes as UTF-8) | committed text where the page's focus is, as an input method commits it: a phone keyboard's word or composed syllable, a paste of the phone's own clipboard |
  | `key` | `key` | a key with modifiers joined by `+`: `Enter`, `Backspace`, `Delete`, `Tab`, `Escape`, `ArrowUp`…, `Home`, `End`, `PageUp`, `PageDown`, `Shift+Tab`, `Meta+a`, one character (US layout); at most 64 bytes as UTF-8 |
  | `navigate` | `action` (`back`, `forward`, `reload`) | the panel's Back, Forward and Reload |

  `button` is `left` (when absent); `middle` and `right` are `notAllowed` (a middle click pastes on some pages, a right
  click opens a menu on the Mac). `modifiers` are `shift`, `control`, `alt`, `meta`. A field the kind does not take (a
  `text` on a `click`) is `badRequest`. A `key` is what editing text takes: one character, alone or with Shift; `Enter`,
  `Tab` or `Escape`, alone or with Shift; `Backspace`, `Delete`, an arrow, `Home`, `End`, `PageUp` or `PageDown`, alone or
  with Shift, Alt or Meta (words, lines, selection; not `Shift+Delete`, which cuts); and `Meta+a`, `Meta+z`, `Shift+Meta+z`.
  A host advertising `tabCopy` also takes `Meta+c` and `Meta+x`, which copy and cut the page's selection for the device
  (`tabCopied`, below) and never reach the page as keys; an older host refuses them. Every other Meta or Control
  combination (paste in any spelling, the browser's own keys, the developer tools'), Insert and the function keys are
  `notAllowed`: the Mac's clipboard and windows are not the person's, so their own text comes as `text`. A connection's
  input goes to the page in the order sent, apart from its other requests (`unwatchTab` does not wait for it); at most
  32 of its inputs wait at once (more is `rateLimited`); input whose watch ended meanwhile sends nothing more, and each
  step is checked again just before it goes: an input's steps go to the page its first step was checked on, and none
  after the page moved, even away and back to the same address. Not a command. Errors: `badRequest` (a field missing,
  out of range or not the kind's, an unknown key or one past its bytes), `tooLarge` (text), `notFound` (the tab closed),
  `notAllowed` (not the watched tab, or its watch ended; a passkey or site sign-in window, one whose tab Chromium does
  not name, or a page's dialog is up, which the person answers on the Mac; a key or button that is not taken; a `file:`
  page outside the task's files, in the page or any of its frames; the page or one of its frames moved while the input
  went), `rateLimited`, `unavailable` (the page did not answer, or a password field could not be protected, below).
- A site's permission prompt, as the Mac's panel shows it in its permission bar, is listed on its tab while it is up:

  ```json
  "permission": {"prompt": 4611686018427387905, "origin": "https://meet.google.com",
                 "permissions": ["camera", "microphone"]}
  ```

  `prompt` names this prompt; a newer one on the tab, or the same site asking again, has another. It is Chromium's
  64-bit number, which can be past 2^53 (camera and microphone prompts are), so a client reads it as a 64-bit integer
  and sends it back unchanged. `origin` is the site that asks; `permissions` are Chromium's names for what it asks,
  as the Mac has them: `camera`, `microphone`, `geolocation`, `notifications`, `clipboard`, `multipleDownloads`,
  `storageAccess`, `topLevelStorageAccess`, `localFonts`, `windowManagement`, `localNetworkAccess`, `localNetwork`,
  `loopbackNetwork`, `fileSystemAccess`, `midiSysex`, `idleDetection` and others; a client shows a name it does not
  know as it is. The field is absent when no prompt is up, and for a `file:` page listed as `file://` (whose prompt is
  answered on the Mac). It comes and goes with `browserTabsChanged`.
- ```json
  {"id": "42", "type": "answerTabPermission", "taskId": "4C1F…", "tabId": "9B21…", "prompt": 4611686018427387905,
   "answer": "allow"}
  ```

  The person's answer to the watched tab's prompt `prompt`, `{"re": "42", "ok": true}`. `answer` is `allow`, `block`
  or `dismiss`: the bar's Allow, Block and Close. Hosts advertising `tabPermissions`. The answer is the person's, as
  the Mac's permission bar gives it, and goes the same way: Chromium keeps an allow or a block for the site, so the
  site uses the Mac's camera, microphone, location or the rest. It reaches only the tab the connection watches
  (`watchTab` with that tab, not `listOnly`), in the order of the connection's input and under its watch, as
  `tabInput` (it shares that input's queue and permit, §15.30), and only that very prompt: a prompt answered on the
  Mac meanwhile, or one the page asked again under a newer number, is `notFound`, so an answer never reaches a later
  prompt. Not a command. Errors: `badRequest` (`taskId`, `tabId` or `prompt` missing, another `answer`), `notFound`
  (no such task or tab, or that prompt is no longer up), `notAllowed` (not the watched task or tab, or its watch
  ended; a passkey or site sign-in window, one whose tab Chromium does not name, or a page's dialog is up; a `file:`
  page outside the task's files, in the page or any of its frames), `rateLimited`, `unavailable` (no browser engine).
  The audit log (§4.4) records each answer with the answer, the device, the task and the result, and for one taken
  the prompt's `origin` and `permissions`; nothing else of the page. A refusal is recorded at most once a minute per
  device, task and result.
- `{"event": "tabCopied", "seq": 53, "taskId": "4C1F…", "tabId": "9B21…", "text": "sk-proj-…"}`: text the watched
  tab's page copied because of this connection's own input, for the device's clipboard (hosts advertising `tabCopy`):
  the device's `Meta+c` or `Meta+x` on the page's selection, or the page's own copy (a Copy button's
  `navigator.clipboard.writeText` or `write`, or `document.execCommand('copy')`) when the connection's click, press, key
  or text was the last input to the page, at most 5 s before (as long as Chromium's user activation lasts), with
  nothing done to the page on the Mac or by the agent since. It goes to that connection alone while its watch of the tab
  holds, and never to the Mac's clipboard. Text only (a copy's formatting and pictures stay behind), at most 1 MiB as
  UTF-8: a quarter of the largest frame and far past a key or a page of code; a longer copy is not sent rather than cut.
  Nothing comes from a password field or a field drawn as dots (Chromium does not copy those either), nor text carrying
  a value the password manager filled; a copy of nothing sends nothing, as a local copy then changes nothing. The client
  puts `text` on its own clipboard, as a copy made there. A client that does not know it ignores it.
- `{"type": "unwatchTab", "taskId": "4C1F…"}`: stops the watch. Closing the connection, removing the device, the remote
  turning off and the tab closing stop it too, input under way included. Not a command.
- **What the Mac does:** only the listed task's own tabs, as its side panel and the agent's browser tools see them;
  never another task's or the Mac's own browsing. A watched tab paints while it is watched, as one a panel shows on
  screen, and goes back to how it was (hidden, and later let go by the memory saver) when no one watches it. A client's
  `viewport` draws it at that size while the client watches (the smaller when two ask; sizes asked while another change
  of the tab's size runs make one change, the latest), over a size the person or the agent set; a size they set during
  the watch holds until the next size is asked, and when theirs goes the tab takes the watch's again. After the last
  such watch the tab takes the size and emulation it had before: the person's from the panel, the agent's while its
  turn goes on, else its own. The tab the Mac's panel shows does not change. Input counts as the person's in that tab, as the panel's does: the memory saver
  keeps a page they typed in, and a character typed into a password field, as text or as a key, first marks the page as
  one that holds a secret, so the agent's scripts and pictures stay off it while the password manager is on, as for one
  typed in the panel; when the page cannot be marked, nothing is typed. Which field has the keyboard is read from the
  page before each character, so a field a `Tab` just moved to counts at once, and one in a frame of another site is
  taken for a password field. A page's request to open another app on the Mac (a `mailto:` link, an app the site was
  always allowed) after a remote click waits for someone at the Mac to choose it there (`waiting` `externalApp`), and so
  does one from a tab such a page opened (a popup), until someone uses that tab on the Mac; the agent's use of the tab
  since does not change that. While a remote click drove the tab last, its downloads, and those of a popup its page
  opens, are refused before they begin (nothing is written), until someone uses the tab on the Mac or the agent acts on
  it (a click, typing, a navigation that reaches the page; not a read), whose downloads are its own. The Mac's panel says so, and an empty tab
  the page opened only for that download closes; the person downloads it on the Mac to keep it. A `file:` page, in the
  tab or in any of its frames (an iframe, an embed, a frame a link moved), is shown and driven only when `readFile`
  would serve it (a file the task's conversation names among them, so a link from one such page to another shows
  too), or it is a folder inside the task's folders (§15.22), as the agent's tools hold them, or it is the
  file the task's agent last opened in that very tab with `browser_navigate` (by its real path, symbolic links
  resolved; the person allowed it first where it lies outside the task's folders). That allowance belongs to the tab
  and lasts until the agent opens another address there: the page moving to another file by a link, a script, Back or
  Forward, a frame of it showing another, and a file in any other tab stay refused, and the Mac keeps it in memory
  only, so a tab opened again after Yardlet restarted, or lost with the browser, has none. A remote device's own
  opening of a file never adds one (§15.30). It is checked
  for the very page pictured or driven: a picture during which the page or one of its frames moved, even away and back
  to the same address, or a frame showed a file outside the task's, even one that went again, is not sent. Another is listed as `file://`, without its title, and the page the tab moves to
  next shows no title until it names itself. Pictures show the page as it draws itself (a password field as dots) and
  are made only while watched; the Mac keeps none. The audit log (§4.4) records each `watchTab` and, at most once a
  minute per device, task, kind and result, a `tabInput`'s kind (`click`, `text`, …), never what was typed, and likewise
  a `tabCopied` sent, never what was copied. Chromium's own windows (a passkey, a site's sign-in), macOS prompts and a
  page's dialogs stay on the Mac; while one is up, the tab's `waiting` says so. A site's permission prompt is the page's
  own question, answered from a client with `answerTabPermission`; macOS's own prompt for Yardlet's camera, microphone
  or location stays on the Mac. Copies (`tabCopied`): while a client watches a tab, a script in the page's own world
  (each new document, and the one shown when the watch began; a frame from another site is not reached) takes the page's
  `navigator.clipboard.writeText`, `write` and `document.execCommand('copy')` and `('cut')` first and asks the Mac about
  each (`Runtime.addBinding`). One that follows the watching connection's input, as above, goes to that connection and
  nowhere else, and the page's call succeeds; any other (the person at the Mac, the agent) goes on to the Mac's
  clipboard as the page asked, an `execCommand` copy then as plain text through `navigator.clipboard.writeText`. A
  device's `Meta+c` and `Meta+x` run the page's copy from Yardlet's own world, which the page cannot change: a `copy` or
  `cut` event at the focused frame's selection (same-site frames and open shadow roots included), the page's own data
  when it takes the event over, else the selected text, and a cut deletes the selection where it can be edited. No key
  reaches the page, so Chromium writes nothing to the Mac's clipboard. Once no client watches the tab, the script lets
  every copy go as the page asks and the page's next documents have none.
- **What a phone needs:**
  - Draw the frame fitted to the screen, keeping its shape, and let the person zoom and pan the picture. A tap at a
    point of the picture is `click` at that point times `viewportWidth / width` (the same factor both ways); a double tap
    is two clicks, the second with `clickCount` 2; a drag of one finger on the page is `scroll` (the finger's movement in
    picture pixels times that factor, sign reversed), unless the person chose to drag (`mouse`). Send scrolls at most
    about ten a second, adding up the deltas between.
  - Typing goes through a text field of the phone's own under the picture: send committed text as `text` (an input
    method's composing text stays on the phone until committed), and the keyboard's Return, Backspace and Tab as `key`.
    While the watched tab's `passwordField` is true, mask that field, turn off suggestions and learning, and keep nothing
    of what was typed.
  - Acknowledge each frame once it is decoded. Keep frames in memory only, and block screenshots and the recent-apps
    preview of the browser screen (Android `FLAG_SECURE`).
  - Send `viewport`: the browser screen's size in CSS pixels (on Android, its size in dp, which Chrome on the phone
    would use), with `mobile` true; send it again with the new size when the phone turns. `maxWidth` and `maxHeight`
    are the same screen in pixels.
  - Watch only while the browser screen is on screen, `unwatchTab` when it leaves, and `watchTab` again after
    reconnecting. A frame arrives about a quarter of a second after the page changes on the same network; through the
    relay, each frame waits for the one before it, so a slow link means fewer frames, never a queue.
  - With `requestId` on the watched tab, show the handoff's `reason` and its Done and Decline (`answerHandoff`, §15.18)
    above the picture, as the Mac's panel does. From a host advertising `tabPermissions`, with `permission` on the
    watched tab, show the permission bar below it (both when both are up): who asks and for what, and Block, Allow
    and Close (`answerTabPermission`). The words name the host as the Mac whose camera, microphone or location the
    site asks for, as Yardlet on another computer does: "On %1$@, %2$@ wants to: %3$@" with the host's name, the site's
    host and the permissions in the Mac's words ("Use your camera", "Use your microphone", "Know your location" …).
    Take the bar down once answered; on `notFound`, nothing waits for that answer any more. With another `waiting`, or
    a `permission` wait from a host without `tabPermissions`, say what waits on the Mac (§15.19's "Steps that are not
    requests").
  - From a host advertising `tabCopy`, put each `tabCopied`'s `text` on the phone's own clipboard, as a copy made there,
    and send a Copy (or Cut) on the page's selection as `key` `Meta+c` (`Meta+x`).

### 15.26 Review

A snapshot may advertise `reviewReading: true`. Older hosts omit it; clients keep the panel unavailable.
`readReview` takes `taskId` and `reviewQuery`, an object with `operation` and optional `repository`,
`target`, `revision`, and `path`. The answer holds a `review` object. The desktop uses the same Review
pane and scope/file selectors as its local window, backed by these reads. The window passes only `taskId`;
the panel first asks for `context` without a repository path. Host paths remain absent from the general
task snapshot, and clients never submit synthetic sidebar paths as host paths:

| Operation | Inputs | `review` fields |
|---|---|---|
| `context` | none | `workspace` and `additionalRoots`: the task's host folder paths, requested only when Review opens |
| `lastTurn` | none | `lastTurnOffered`, optional `turnID`, `text` (unified diff), `isRunning`, `truncated`; the same provider projection the host Review uses |
| `repositories` | none | `repositories`: host repository paths among the task's folders |
| `root` | optional `repository` | `root`: repository root |
| `commits` | optional `repository` | `commits`: at most 50 `{id, shortID, subject, timestamp}` entries; timestamp is milliseconds |
| `baseBranch` | optional `repository` | `baseBranch`: a full ref, `missing`, or `current` |
| `diff` | optional `repository`, `target`: `unstaged`, `staged`, `commit`, or `branch`; commit needs `revision` | `text`: unified diff, `truncated`: output reached its 2 MiB bound |
| `text` | optional `repository`, `path` (repository-relative with a revision), optional `revision` | `text`: at most 2 MiB of UTF-8 Markdown source, omitted if unavailable |

Without `revision`, `text` reads the working file through §15.22's file reader, with the same absolute
or task-relative path rules. An empty revision reads
the index, `HEAD` reads the branch tip, and a full hexadecimal commit ID reads that commit. Branch diff
uses the host's selected base branch, not a client-selected Git expression. `readReview` never changes
files or the index.

The task must still be listed. A repository is accepted only inside the task's authorized folders,
with symbolic links resolved and the home-folder exclusions of §15.22. A task opened below a larger
repository's root cannot expose that repository's sibling folders. Invalid fields answer `badRequest`,
a disallowed selection `notFound`, and a repository root outside those folders `notAllowed`. Git failures
answer `unavailable` without paths or command output. A response whose JSON encoding exceeds the server
message limit answers `tooLarge`. Markdown renders on the client without resolving
host-relative images or links against the client's filesystem. Last-turn provider changes use the host's existing projection after loading saved history without starting a model turn. Refresh reads them again; there is no new subscription.

#### Stage, Unstage and Discard

A snapshot may also advertise `reviewWriting: true`. It answers `writeReview`, which takes `taskId`, `reviewChange`
and, for Discard, `confirmed: true`:

```json
{"id":"w-1","type":"writeReview","taskId":"T","reviewChange":{"action":"discard","repository":"/host/repo","expected":"<sha-256>"},"confirmed":true}
```

`action` is `stage` (Stage all), `unstage` (Unstage all) or `discard` (Discard changes), what the host's own Review
offers on the Unstaged and Staged scopes. `repository` is optional and names a repository as `readReview` does.
`expected` is the lowercase hexadecimal SHA-256 of the `diff` text the client reviewed: the `unstaged` diff for stage
and discard, the `staged` diff for unstage. The request names no path, revision or Git argument. The host checks the
repository against the same boundary as `readReview`, reads that diff again and acts only on its paths, and only when
its hash is still `expected` and it is neither empty nor truncated; then it runs the same Git steps as its own Review,
which refuse a path through a symbolic link and never reset or clean the repository. A success answers with no
fields.

`writeReview` needs the device's `fileWrites` permission (§15.28). The server registers a live permit in the same
actor turn as that check, and the host checks it again immediately before each step that writes; a denial or a
closed connection revokes it, and a step already run is not undone. Without the permission the answer is
`notAllowed` with reason `fileWrites`. Invalid fields answer `badRequest`; a Discard without `confirmed`, `notAllowed`
with reason `confirmation`; changes that differ from the reviewed ones, `notAllowed` with reason `changing`. Selection,
boundary and Git failures answer as `readReview` does, without paths or command output. The audit log records the
device, `writeReview.` and the action, the task and the result, never a path, diff or file content.

The desktop's remote pane offers Stage all, Unstage all and Discard changes as the local pane does, asks the local
Review's confirmation before Discard, and reads the Review again after a change. A refusal is shown above the diff;
without the permission it says to allow Write files for this device in the host's Settings › Remote. Against a host
without `reviewWriting` the actions stay dimmed and say to update Yardlet on the host. Phones ignore the flag.

### 15.27 Workspace files

A snapshot can carry `workspaceFiles: true`. Without it, clients keep the Files panel unavailable.
This is an optional capability; existing clients ignore it and existing hosts need no changes.

`{"id":"files-1","type":"workspaceFiles","taskId":"T"}` lists regular files in the task's primary
working folder (the worktree when the task has one). The response carries `filePaths`, paths relative to
that folder, sorted by name, `filesLimited`, a Boolean, and optional `workspaceRoot`, the host folder
for the panel header. A client does not need to know that path before requesting the listing and never
uses it for client filesystem access. It contains no file contents. Refresh requests
list again; this request has the ordinary read-request rate limit. Unknown tasks answer `notFound`.

The listing shares `readFile`'s folder boundary: a home folder or a folder containing home cannot be listed.
Traversal uses directory descriptors, skips symbolic links and non-regular files, and does not enter
`.git`, `.build`, `node_modules`, `.next`, `.venv`, `__pycache__`, or `.swiftpm`. It stops at 20,000 names,
128 KiB of path bytes, 100,000 visited entries, or 64 directory levels; a stopped listing says
`filesLimited: true`. Additional task folders and outputs outside the primary folder remain available
through their existing links and Outputs card, rather than being enumerated here.

Content uses `readFile` (§15.22), including its scope checks, size limit, rate budget and audit records.
The desktop uses the same Files panel, reader and editor as local files, with a remote provider that reads the
host's file into the window's private temporary copies. It never resolves a host path against the
client's filesystem, and a save writes nothing on the client: the copy stays a copy. Image and PDF previews read
those copies; text preserves its host-relative path. Small source files keep the same syntax colors and layout, and
what the local panel edits is editable: a whole text file of at most 2 MiB that decodes, named by a path relative to
the task's folder. The remote panel offers no client Finder or local-app actions for a host path. Copies are removed
when the host window closes, as in §18; the panel's open file and reading place stay with the window, in memory, per
task. A task's panel that holds unsaved edits is also kept on the client, in the host's folder (§18), until each edit
is saved or discarded, so closing the window or quitting loses none: reopened, the panel shows the edits over the
host's file and, as the local panel does, says when the host's file changed since the edit began.

A snapshot can also carry `workspaceFileWrites: true`, only beside `workspaceFiles`. The host then answers
`writeFile`, the panel's Save:

```json
{"id": "files-2", "type": "writeFile", "taskId": "T", "path": "Sources/App.swift", "data": "<base64 of at most 4 MiB>", "sha256": "<64 lowercase hex digits>"}
```

```json
{"re": "files-2", "ok": true}
```

`path` names a file in the folder `workspaceFiles` lists, relative to it, as the listing names it. `data` is the
file's new contents in strict base64, at most 4 MiB decoded (one `readFile` part), and `sha256` is the SHA-256 of the
bytes the client read. The host replaces the file only when it is a regular file there already, reached from the
folder (its links resolved, as for the listing) by names none of which is a symbolic link, the file's own place
included, and only while the file still holds bytes with that SHA-256, as the local panel saves: the save stops if
the file changed since it was read. It writes the new contents to a temporary file beside it, with the file's
permissions and other metadata, and renames that over the file, so a failed write never leaves a half-written file.
Nothing is created, and the task's other folders and outputs are read, not written: the Mac's Files panel saves only
in the task's folder. A folder that is the home folder or holds it saves nothing, as it lists nothing. `writeFile`
takes the device's `fileWrites` permission (§15.28), checked when the request arrives and again, through a permit
the host revokes with the permission or the connection, immediately before the rename. Errors: `badRequest` (no
`taskId` or `path`, `data` not strict base64, `sha256` not 64 lowercase hexadecimal digits), `tooLarge` (over 4 MiB,
or a file there over it), `notFound` (no such task), `notAllowed` with reason `fileWrites` (the permission is off)
or `fileChanged` (the file is no longer the one the client read), `notAllowed` without a reason for any other path
(absolute, starting with `~`, with an empty, `.` or `..` name, through or at a symbolic link, at what is not a
regular file or is not there), whether or not it exists, and `unavailable` when the write fails. No error carries a
path or the file's contents. It is a command (§7), and the audit log (§4.4) records the device, `writeFile`, the task,
the result and its reason, never the path, the file's name, its contents or its size.

A client offers Save as the local panel does. Against a host without `workspaceFileWrites` (an older Yardlet), Save
says to update Yardlet on the host and sends nothing; with it but without the permission, the panel says to allow
Write files for this device in the host's Settings › Remote › Paired devices. Either way the edit stays until it is
saved or discarded.

### 15.28 Per-device permissions

The host's saved device entry may carry `permissions: {"terminal": false, "fileWrites": false,
"settings": false}`. An absent object or absent member means false. Existing pairings retain their keys,
identity and history; pairing a new device does not grant any of these permissions. Old clients need no changes.

Only the person at this Mac can change them, in Settings › Remote › Paired devices. There is no remote request
for editing device permissions or managing another device. Every request declares its required permission centrally;
new kinds must explicitly extend that declaration. The server actor owns the live permission map and checks it
without a suspension or disk lookup. Neither a handshake snapshot nor the persistence store authorizes requests.
Granting one permission does not grant the others.

A denial or fresh-registration reset changes that map and cancels resource permits in the same actor turn. A single
writer saves the latest complete intended permission map, coalescing changes made while an earlier save waits.
Intent snapshots use a memory-only lock; disk writes never delay live denial. The writer rechecks the current map
before committing grants and after writing, preserving a recovery fence for newer denials. Runtime denial is
immediate; restart uses the latest successfully saved configuration and recovery record. A grant becomes effective only after its save succeeds and only while it is still the current intent. Saving one flag cannot pause an unrelated granted operation. Existing identities are
reserved by public key, so concurrent pairing paths cannot create two live identities for one key.

Before updating the primary device file, denial/reset writes record a private recovery fence in
`permission-denials.json` beside it (mode 0600). Startup applies this record before enabling saved grants and retries
unfinished saves. A failed primary write therefore cannot revive an old grant after restart. Settings reads the
server's live values and recovery state; Retry writes only denied values. If both the recovery record and primary
write fail, the host keeps access off for the current run and explicitly says that restart recovery could not be
saved. It does not claim a durable denial in that case. The in-memory device store also retains denials after a
failed write, including during ordinary device metadata saves. Settings accepts turning a permission off while a
grant is pending. Recovery entries apply only to known identities; an unreadable or symbolic-link journal denies
all known permissions until a regular private journal can be saved.

A new QR or account-link registration clears an existing key's grants, including when another save is pending.
Permission edits are refused until that registration has committed. Recovery retry ignores removed identities.
Only a bounded retry of a successfully committed pairing preserves permissions; an in-progress registration is not
a spent-ticket retry. Failed reset attempts are audited even when the live flags are already off. Independent
consumers subscribe without replacing each other. Shutdown cancels runtime access for every known device, including
startup grants; accepted configuration writes may finish but cannot publish runtime grants after shutdown.
Enabling remote connections again waits for shutdown to finish and reactivates the saved configuration.

Device removal is published only after the ordered save succeeds. A failed save keeps the paired entry, denies its
extra access and shows a removal error. `forgetDevice` acknowledges success only after durable removal. A failure
responds with `internal` and closes affected connections transiently; the retained pairing may reconnect without
regaining denied permissions. A removal being saved returns `unavailable` to other connections.

Audits contain the device ID, operation and outcome, never a device name, credential, command, file contents or
settings value. Permission changes use `permission.terminal` (or `.fileWrites` or `.settings`) and `allowed`,
`notAllowed` or `failed`; registration resets use `permissionReset`, recovery retries `permissionRecovery`, and
removal `revoke`. Repeated `watchTab` entries are coalesced for sixty seconds per device, task and result. Permission
refusals are coalesced per device, request type and result, independent of the unvalidated task ID. A permission
transition clears that device's refusal window so its first newly refused operation is recorded.

These permissions authorize terminal sessions (§15.29), direct file writes (Review changes, `writeReview`, §15.26;
the Files panel's save, `writeFile`, §15.27; and a file restore, `fileRewind`'s `restore`, §15.31) and host
settings (§15.36, §15.37). A request refused for Terminal or Write files carries the reason `terminal` or
`fileWrites` (§8). Credentials, vault entries, sign-in and remote device management remain on the host.

`terminal` also guards every choice that lets an agent act without asking, since such an agent can run what a shell
runs. Without it the host treats a request's `confirmed` as absent for `createTask`, a suggestion's Start
(`actOnSuggestion`), `setTaskSetting` and `saveScheduledTask`, so a permission the Mac asks to confirm (Bypass
permissions, Full access) is refused with `notAllowed` and reason `terminal` rather than `confirmation`; a task
whose new-task choice the Mac's own screen holds starts on the harness's default, as one that names none does
(§15.16). `answerApproval` with `allowForSession` and a `chooseAnswer` choice that allows beyond the one call (for
the session, or as a `standing` rule, §15.19) are refused the same way, as are `runScheduledTask` and resuming
(`setScheduledTaskEnabled` with `enabled: true`) a schedule whose new task starts in such a permission. The
permission is read when each request arrives.

This covers what the device chooses, not what the person already chose on the Mac. A device without `terminal`
still sends messages to any listed task, including one already running without asking, answers its requests with a
one-time allow or a denial, forks or continues it, and runs or resumes a schedule that continues such a task. Device
permissions gate these direct requests; they do not make a device without `terminal` unable to reach a shell through
an agent the person set up that way.

### 15.29 Task terminals

A snapshot with `terminals: true` supports these optional requests. A paired device also needs its host-managed
`permissions.terminal` (§15.28). Missing or disabled permission returns `notAllowed`, as does naming a terminal
owned by a different connection, even another connection of the same device. No shell executable, arguments,
environment, working directory or credentials are accepted from the client: the bridge selects the task's shell
and folder using the same policy as its local terminal. This is shell access as the host user, not a task-folder
sandbox: commands can modify files and use the network even when `fileWrites` is false. That separate permission
protects direct file-editing APIs. Terminal output can contain whatever the explicitly authorized shell prints;
the protocol does not separately expose environment variables, credentials or vault APIs.

- `openTerminal`: `taskId`, optional `columns` (80) and `rows` (24). Returns `terminalId`, generated by the host.
  At most four sessions per connection and sixteen in the server, counting opens still in progress and kept shells.
  On a host whose snapshot says `terminalReattach: true`, three optional fields (see "Kept terminals" below):
  `keepRunning: true` keeps the shell when its connection ends; `terminalId` attaches a shell this device kept instead
  of opening one; `resume: true` attaches this device's earliest kept shell in the task, or opens one when there is
  none. `terminalId` and `resume` together answer `badRequest`. An attach answers `resumed: true`; with `resume` the
  answer also carries `detachedTerminals`, how many more shells this device kept in the task.
- `terminalInput`: `taskId`, `terminalId`, `data` (strict base64, 1–16,384 decoded bytes).
- `terminalResize`: `taskId`, `terminalId`, `columns` (2–500) and `rows` (2–300).
- `closeTerminal`: `taskId`, `terminalId`.
- `terminalStatus`: `taskId`, `terminalId`; returns optional `isAtPrompt` and `isRunningProgram` booleans,
  from the host session at that moment, and optional `workspaceRoot`, the host path where the session started.
  The path supplies the shared panel's folder context; clients must not treat it as a local filesystem path.
  The same ownership and live-permission checks apply. Clients request status after opening and for a user
  action that needs it, never on a timer.
- `terminalOutputAck`: `taskId`, `terminalId`, `sequence` of the last output delivered to the terminal view.

`terminalOutput` events carry `taskId`, `terminalId`, `data` (base64, at most 16,384 bytes) and `sequence`, starting
at one per session, and, on the first output after an open, an attach or a change of the shell's size, `columns` and
`rows`: the shell's size from that output on (see "One size" below). Output bytes stay in order. Each chunk waits for acknowledgement before the next; at most
64 chunks and 256 KiB are reserved from the bridge callback through acknowledgement. The bridge's single output
producer awaits room before reading more from the PTY, with at most one additional 16 KiB chunk waiting. This
backpressure preserves ordinary bursts larger than the buffer without blocking the main actor or creating an
unbounded task queue. The bridge sends exit after all output using that same ordered producer. Releasing room,
revoking the permit or cancelling the producer wakes its wait. An acknowledgement missing for ten seconds closes
the terminal with `outputTimeout`; an oversized chunk or concurrent producers violating this contract close it
with `outputOverflow`. Opening and input return once their action is accepted; they never wait for output to drain,
so an acknowledgement on that connection cannot be trapped behind them.

`terminalClosed` carries `taskId`, `terminalId`, `reason` (`closed`, `exited`, `notAllowed`, `disconnected`,
`detached`, `outputTimeout`, or `outputOverflow`) and, for an exited process, optional `exitCode` (the host's raw waitpid status,
matching the local terminal). A clean exit is delivered after queued output is acknowledged. Closing, disconnecting,
revoking the device, disabling terminal permission or turning off remote connections immediately revokes the
bridge permit and ends the owned shell, except that a kept shell outlives its connection's end (below). Opening and
input recheck permission after suspension; the bridge checks the permit immediately before starting, writing or
resizing a process. Without `keepRunning`, reconnect creates a new session.

Terminal traffic has its own bucket (120 requests initially, 60 per second), independent of conversation and browser
requests. A matching acknowledgement for the connection's one outstanding terminal output chunk is exempt;
invalid, duplicate and foreign acknowledgements still consume that bucket. Existing message queue limits still apply.
Each open, attach, detach and close writes an audit line with request type (`openTerminal`, `attachTerminal`,
`detachTerminal`, `closeTerminal`), task ID, device ID and result. Input packets are
coalesced for up to two seconds per device, task and outcome, with summed `byteCount`, rather than displacing other
audit events with a line for every keystroke. Closing, revocation and shutdown flush pending batches. Aggregation
holds at most 128 windows and flushes the oldest when full. The bytes and their decoded text, output, environment
and credentials never enter the audit log. Permission controls are available only on the host;
a remote request cannot enable them. File-write and settings permissions grant no terminal access.

The host creates an ordinary terminal tab in the task's workspace and starts its PTY without a view.
The local panel and the task's `read_terminal` tool see that same session. Closing or restarting the local tab
revokes its permit and explicitly ends the remote stream, including after process exit. Permission revocation or
connection close also ends it. Cleanup includes remaining processes in the owned PTY session when its leader has
already exited; it does not target another terminal's session. A session started headless keeps a bounded emulator
with 5,000 scrollback lines for reads without a view; ordinary view-first sessions use their existing emulator.
For headless sessions, each output chunk updates it without rebuilding
a history string. The first local view adopts the same emulator, preserving its parser state, alternate screen
and scrollback without replay. Only the host emulator answers terminal queries; remote renderers forward user input.

The desktop client uses the local Terminal panel through a byte-stream provider. It shows connection
and refusal states, acknowledges output after feeding its emulator, and never repeats input on reconnect. Against a
host without `terminalReattach` it never reopens a shell on reconnect, and the panel states that closing the window or
losing the connection ends its terminals. A hidden panel retains its shell until the connection or task ends.

**One size.** A shell shown by the host's panel and a remote window at once has one size, as tmux's `window-size
latest` has it: the PTY takes the size asked for by the renderer the person used last, a window by its `openTerminal`,
attach or `terminalInput`, the host's panel by a key typed, pasted or clicked in it. `terminalResize` says the size a
window fits; the host applies it while that window was used last and keeps it for when it is. A renderer that stops
showing the shell (the window closes or loses the connection, the panel hides) gives the size back to the one used
before it. Every renderer reads the output at the shell's size: one whose panel fits another size shows the shell from
its top left, with blank space where the panel is larger, clipped where it is smaller, and with the rows around the
cursor in view when the shell is taller, rather than reflowing the screen to the panel. The client sizes its emulator by
`columns` and `rows` before feeding the output that carries them; a client that ignores them keeps its own size, as
before, and a host that does not send them leaves the client its own size.

**Kept terminals.** A host with `terminalReattach` keeps a shell opened with `keepRunning` when its connection ends,
whether the window closed, the network dropped, or a relay path moved to a direct one. Output meanwhile reaches only
the host's emulator and local panel; nothing is queued for the absent connection, so the PTY is never held back by it.
Only the device that opened the shell can attach it, from any of its connections, and only for the same task; another
device's `terminalId` answers `notFound`, as does a shell that has ended. An attach while another connection of the same
device still holds the shell (one whose end the transport has not noticed yet) moves it: the older connection gets
`terminalClosed` with reason `detached`. A shell another connection is still opening or attaching answers `unavailable`,
and attaching what the same connection already shows answers `badRequest`. The attach applies the new connection's size first, then the first `terminalOutput` (sequence 1) repaints the screen: it
leaves the renderer's alternate screen, resets its modes (DECSTR, bracketed paste, mouse and focus reporting, keyboard
enhancement flags) and clears its screen, then draws the host emulator's current screen (the alternate one when it
shows) with each cell's character and pen, the scroll region, cursor position, pen and visibility, application cursor
keys, bracketed paste and keyboard enhancement flags. A renderer that showed the shell before keeps its scrollback.
The repaint is built from the emulator's cells rather than its parser, so it carries neither a control sequence the
shell was in the middle of printing nor mouse and focus reporting; a program that asked for those gets ordinary keys
until it asks again. Output after the repaint follows in order, with nothing missed or repeated.

An output acknowledgement missing for ten seconds detaches a kept shell rather than ending it: the connection gets
`terminalClosed` with reason `outputTimeout` while the shell runs on, so a client that only stalled attaches it again.
Explicit `closeTerminal`, the shell's exit, closing or restarting the host tab, the task ending, turning the device's
Terminal permission off, removing the device and turning off remote connections end a kept shell as any other; one that
ends while no connection holds it is removed with an audit line and no event. `closeTerminal` from any connection of
the device that kept it also ends a kept shell no connection holds, without attaching it first. Kept shells count toward the server's
sixteen. A kept shell is the host task's ordinary terminal tab throughout, visible in its local panel.

The desktop client sends `keepRunning` only to a host that offers it. When its connection ends, its tabs show
"Connecting…" and attach their shells by `terminalId` on the next connection, before any tab that has none; input
typed meanwhile is dropped, never sent later. A tab closed meanwhile sends its `closeTerminal` on the next connection,
and one told `outputTimeout` attaches its shell again at once. Closing the window sends nothing, leaving the shells for the device's
next window, whose first terminal for a task opens with `resume` and opens one more tab for each further kept shell
(at most four in all). The panel then states that terminals keep running on the host when the window closes or the
connection drops. Listing and attaching host terminals this device did not open remain follow-up work. Terminal control
sequences cannot read or write either the client clipboard or the host clipboard when the remote-created
shell is shown in a local panel. Output-driven clipboard reads are also disabled for local task terminals;
explicit user Paste is unchanged. Remote-origin links accept web, file and recognized task links through the task's
routing callback, and do not launch unrelated application schemes. Exit status is the host's raw `waitpid` status;
the client decodes its exit code or terminating signal as the local panel does. Links use the remote
window's existing file and browser routing; without that route, the terminal never opens a host path
or localhost address through the client's system applications.

### 15.30 Opening addresses and closing browser tabs

A snapshot may include `tabControls: true`. Without it, clients keep the address field and tab close/new-tab
controls disabled. These requests extend §15.25; they do not change existing browser requests or grant access
to another task's tabs.

- `openTab`: `{id, type: "openTab", taskId, tabId?, address}`. The address is at most 8,192 UTF-8 bytes.
  With `tabId`, navigate that task's existing tab; without it, create a tab in that task's browser profile.
  The host resolves address-field text with its normal URL and search rules. The successful response includes
  `taskId` and `tabId`; the client then watches that tab. An address beginning with `file:` must stay within
  the task's existing file boundary (§15.22), also when it names the file the task's agent opened in that tab
  (§15.25): that file shows there, but only the agent opens it. App schemes and browser-internal schemes remain
  refused. Yardlet on another computer says that a file outside the task's folders opens only on the host when such an
  address is refused; a file the task's conversation names opens from there.
- `closeTab`: `{id, type: "closeTab", taskId, tabId}`. Ask that task's page to close through the host's normal
  close path. A page's confirmation remains on the host. Success acknowledges the close request; the tab list
  event reports whether the tab actually closed.

Both requests require a current browser watch for the same task. They share the bounded, ordered input queue
and revocable watch permit with `tabInput`, as `answerTabPermission` (§15.25) does, which also requires the watch to
be of that very tab. Ending the watch, changing tasks, removing the device or disconnecting
invalidates queued actions. The host rechecks the task, target tab and blocking dialogs immediately before acting,
and the page boundary too before an address goes to a tab or a permission answer is given. A close shows and drives nothing of the page, so a tab on a `file:` page
outside the task's files (listed as `file://`) closes as any other. Audits record the request type, task, device and outcome, never the address or page contents; a
refusal is recorded at most once a minute per device, request, task and result.

The desktop client provides `openHostBrowserLink` for window and terminal link handlers to route `localhost`,
`*.localhost`, IPv4 loopback and IPv6 loopback to the host's browser panel. Callers use the hook before default-browser
handling. These addresses refer to the host's servers; no port forwarding is created. With an older host, the hook
shows an update notice instead of sending those links to the client's own loopback interface.

### 15.31 Conversation next steps and content

The optional snapshot flag `nextSteps: true` advertises `nextStep`. Turn headers carry
optional `planToImplement`, `nextQuestions` and `answeredQuestions` in every subscription, the plan cut at 8,000 characters outside full detail as plan items are; each question carries `title`,
`options`, and the provider's `itemID`. Answered questions additionally carry `answerOptions` and
`customAnswer`. Full assistant items retain `sentWhileWorking` and `unmarkedAnswer`, so questions
keep their host position instead of becoming a closing answer. These fields are derived from the host's conversation projection and retained with
its per-turn cache. Up to 32 questions with 32 options each are carried; question and option text
is capped at 500 characters, custom answers at 8,000 and the offered plan at 200,000. The existing header `options` includes `retry` only when the host offers it.

`{"type":"nextStep","taskId":"…","turnId":"…","action":"implementPlan"}` is a command. Actions are
`implementPlan`, `answer`, `answerWhileWorking`, `retry`, and `resumeAfterReset`. Question answers carry
`text` (at most 32,000 characters), the same provider-native reply the local question form submits.
The host rereads the named turn and validates that the action remains available. Question replies must
use the provider-native answer envelope and reference only current question IDs; the host rebuilds
the reply with its own question titles. A working-turn answer requires that same turn to remain active.
The client captures the shown turn ID in the button's handler, so a stale button cannot target a newer turn. Plan implementation
uses the plan on the host, ignoring client text. Retry uses the host's retry path. Resume targets the
current Claude Code limit card and requires that its reset time has passed; its item advertises
`resumeAfterReset` even before that time so the same local countdown can reveal Resume when due.
Stale targets return `notFound`; unavailable actions return `notAllowed` (reason `running` while a turn runs, `queue`
while messages wait), and an edit or account move returns `busy` (`editing`, `changing`). No additional device permission is required. Each accepted or rejected command is
logged with its kind, task, device and result, never answer or plan text.

The optional `conversationBodies` flag advertises the additional full-detail bodies below. Older
clients ignore these optional fields. The desktop client uses the same conversation views as the
local window and leaves actions unavailable when the host does not advertise their capability.
Tool input remains host-only; output and result bodies do not add a route to account credentials or
environment settings.

Full-detail items optionally carry `body`, preserving command output while running, reasoning text,
file-change rows, MCP result blocks and shell-message output. The existing `images` previews also
apply to tool lines. `body` can contain `output`, `hasOutput`, `reasoning`, `command`, `headBytes`,
`background`, `files` and `mcp`. File rows carry relative `path`, `kind`, `state`, `preview`, line counts,
`lines`, `hidden` and `firstChangedLine`; MCP blocks carry `kind`, `text`, `image`, `name`, `title`, `uri`
and `mimeType`. No host file URL is handed to the client's filesystem. A tool's file picture or `resource_link`
is carried only when its file lies inside the task's working folder as §15.22 holds that folder, a link's path
relative to that folder; one elsewhere is not carried, though `readFile` serves its file as one the conversation
names (§15.22). File rows open through the
host's existing scoped `readFile` path. Open in Changes selects that file in the existing remote
Review panel using its host repository metadata; it adds no mutation request. Output is capped at 64,000 characters (the provider's already bounded live head/tail buffer is kept intact), reasoning and commands
at 200,000; at most 50 files share 100,000 preview characters, and at most 50 MCP blocks share 64,000
text characters and four image previews. These bodies use the existing per-turn projection cache.

`bankedResets: true` advertises `usageReset(taskId)` and `useUsageReset(taskId, token, confirmed)`.
The read describes the current limit card's account and its available banked resets, including the
next reset and the limit metrics it restores. The token is opaque, tied to that task's current account
and valid for one hour. The client uses the same confirmation content as the local account control;
only confirmation sends `useUsageReset` with `confirmed: true`. The host calls its account store's
normal reset path. Missing confirmation, an account change or changed reset availability is refused.
A completed token's result is retained, so retrying its response cannot consume another reset.
The write is an audited command with no additional device permission. Provider reset identifiers,
credentials and purchase URLs are never sent; buying a reset remains on the host.

`subtasks: true` advertises `subtask(taskId, itemId, action)`, where `action` is `read` or `stop`.
The item identifies a Claude Code subagent of that task. A read considers the latest ten turns and
uses the normal 120-item, approximately 384 KiB page targets, retaining at least the latest whole
turn. Only the hard reply budget (8 MiB minus 4 KiB for the envelope) trims individual items from the
oldest end; the reply marks omissions, including any earlier content the host reader omitted.
An item too large even on its own becomes a visible omission notice. Read presents its conversation through the
same subtask pane as the local window; Stop goes through the host's existing subtask control and is
an audited command. Neither requires an additional device permission. A Codex child thread continues
to open as the host's own task.

`taskNotices: true` advertises the optional task `notices`: provider limit warnings, restart resume,
reconnecting, missing folder and account-move state, and `error` (≤ 2,000 characters): the task's
last error where the Mac shows it as a card above its composer, in the Mac's words. That is where the conversation
does not show it already: a conversation with no items yet, or a Codex task's failure outside its turns (a turn the
App Server refused, a runtime that ended). It goes when the Mac clears it, on the task's next message. The desktop
composer uses the local notice views and error card. `cancelAccountMove` invokes the host's own cancellation path and is audited. Recreating a
missing worktree remains on the host; the client keeps that notice's action disabled.

`fileRewind: true` advertises `fileRewind(taskId, action, pointId?, receipt?, confirmed?)`, with actions
`points`, `preview` and `restore`. Points and preview are scoped reads without an additional device
permission. Preview returns an opaque receipt retained by the host, tied to the provider checkpoint
and the file fingerprints the local restore path records. All reported files must lie inside the task's
workspace as §15.22 holds it; names on the wire are relative. Restore requires the device's `fileWrites`
permission (§15.28), that receipt and `confirmed: true`. The client uses the local restore sheet and
asks once more before submitting. The host revalidates the receipt and current file state through
its normal restore method, consumes the receipt and audits the command without file content.
A live permit is revoked when the connection ends or file-write permission is removed. The provider
adapter checks it after its fresh dry run, immediately before dispatching the actual restore request;
a restore already dispatched to the provider cannot be undone by revoking permission. A
missing or changed checkpoint, changed files, unknown file list or out-of-scope target cannot be
restored through this path. Nothing is written to the client's workspace.

### 15.32 Task and project actions

The optional snapshot flag `taskActions: true` advertises these requests. Older hosts omit it; their clients keep
these controls dimmed. The host resolves task, project and account IDs again at execution and uses the same model
operations as its own menus. No account home or credential is sent. Each command is audit-logged with its kind,
device, task or project ID and result, never a title or account value. These actions need no additional device permission.

- `taskAction.rename`: `taskId` and `taskAction: {kind: "rename", value: "New title", confirmed: false}`.
  The title is nonempty after trimming and the value is bounded to 4,096 UTF-8 bytes.
- `taskAction.markUnread`: the same envelope with `kind: "markUnread"`; `markRead` remains §4.4.
- `taskAction.move`: `kind: "move"`, `value` a project ID, or absent for Chats. The host applies its ordinary
  project-move rules; a task's working folder, native history and account do not move.
- `taskAction.nest`: `kind: "nest"`, `value` a parent task ID, or absent for the top level. Cycles and missing
  parents are refused by the host. The sidebar menu and drag use this same operation.
- `taskAction.delete`: `kind: "delete", confirmed: true`, sent only after the local delete confirmation.
  Missing confirmation is refused. The host's provider-aware delete path applies.
- `openOriginalConversation`, with `taskId`, opens the preserved original and returns its `taskId`, without changing
  the host window selection or starting a model turn.
- `taskAction.resume`: `kind: "resume"`, the title menu's Resume or Retry for a detached idle task.
- `taskAccounts`, with `taskId`, reads the host account choices as `taskAccounts: [RemoteAccount]`, using the type from §15.17. `taskAction.chooseAccount`
  names an available account ID in `value`; it applies Choose account, without sending a continuation prompt.
  A running task moves when its turn ends, as on the host. Optional `refresh: true` rereads all listed accounts,
  including the current account, as the local refresh button does. The current and unavailable accounts, detail
  and usage windows draw with the local account row. Optional `state` is `signedIn`, `signedOut`, `actionRequired`,
  `unavailable` or `unknown`; an unrecognized state decodes as `unavailable`. Optional `checkedAt` is the last
  successful usage reading in milliseconds since the epoch, displayed by the shared freshness line. Only an account the host still marks
  `available` can be chosen. Tokens, credentials, account folders, other paths and routing internals never travel.
- `archivedTasks` reads at most 100 archived tasks in the host's archived-list order. `archivedTasks` in its response
  holds `{task, archivedAt, projectName}`; `task` has the shape of §4.1, without paths. An optional `cursor` names
  the last row; pass it to the next request. No cursor means the end. If that row was restored meanwhile the host
  answers `invalidCursor`, and the client reloads the first page. `taskAction.unarchive`, with `kind: "unarchive"`,
  restores the host's archived record through its ordinary unarchive operation. Archived tasks in a project the host
  hides are neither listed nor restorable (`notFound`), as their live tasks are left out of the snapshot.
- `setProjectPinned`: `projectId` and `pinned`; `archiveProjectChats`: `projectId` and `confirmed: true`, after
  the ordinary project archive confirmation. Partial failures are reported.
- An action that did not take answers `internal`: with reason `failed` and the Mac window's own words in `message` when
  it has them (a rename, delete, restore or project archive the provider refused), else without a reason. A Resume
  refused before it starts names what stopped it as `sendMessage` does (`folderMissing`, `otherApp`, `editing`,
  `changing`), `busy` with `running` while a turn runs; one that did not connect answers `internal` with the task's
  error. Choose account that did not take answers `internal`; its reason is the task's `notices.error`. Edit project, Show in Finder and
  Remove project remain host-only.

Task snapshots optionally include `originalConversation`, `canOpenOriginalConversation`, `canReturnToChats`, `attached`, `hasProviderSession`, `accountName` and
`pullRequest` (`number`, `url`, `repository`, `state`, `checks`, `review`). Projects optionally include `pinned`.
These are presentation values, read from the host's existing state; reading a snapshot starts no provider or GitHub request.
The desktop title menu and header draw the shared local views; Finder is disabled for host workspaces.

### 15.33 Desktop composer extensions

The optional snapshot flag `composerExtensions: true` advertises these additions. Clients keep the earlier
composer with hosts that omit it. Existing requests and optional fields remain readable by phone clients.

- `composerState` takes `taskId` and returns `composerState`: `nextMessageSuggestion` when available,
  `queuePaused`, optional `connectors` with their display names, state, tool count, source and opaque IDs, and
  optional `notice` (≤ 2,000 characters): what the Mac's composer for the task says under its text
  in the Mac's words, such as why a message stayed unsent or a command such as Compact failed. A message, command or
  edit the Mac takes from another device clears it, as sending from its own composer does.
  Connector credentials, server configuration and environment values never travel. The desktop draws the local
  connector menu and accepts the next-message suggestion with Tab.
  A meaningful state change emits `taskSettingsChanged` with optional `composerChanged: true`; that flag
  invalidates only `composerState`. Ordinary settings invalidations omit it. The host compares the projected
  state before notifying, so model preparation does not repeatedly reload unchanged composer data.
- `composerAction` takes `taskId`, `action`, optional `itemId` and optional `value`. Actions are `connector`
  (`itemId` is the offered connector ID, `value` is `on` or `off`), `pause`, `resume`, `moveUp`, `moveDown`,
  `retry` and `edit` (a queued item ID; `value` is replacement text). The host revalidates each action against
  its current task and queue. Editing keeps the host-held attachments and position; provider-held or claimed
  messages cannot be edited. It leaves the host's own draft untouched. The response returns current composer
  state. Commands are audited by kind and task, never by the connector value or message text.
- The existing `composerCommands` list includes the CLI's user commands and Codex skills. Skill IDs resolve on
  the host to native skill inputs; skill paths are not sent. The host rechecks its current catalog at execution.
  Codex init, review, rename, side chat and status remain excluded; model and reasoning use the existing
  settings controls. Other CLI built-ins and commands without an explicit user-command classification are
  excluded, including account and settings management. Skill selection is inserted as a slash invocation;
  the host converts it to its native skill input when sent. Skill prompts share the 4,000-character
  command argument bound (§15.23).
- A task's `@` picker reads `workspaceFiles` (§15.27), caching the bounded listing between searches and ranking
  it locally with the app's file picker. A new task uses `projectWorkspaceFiles` with `projectId`, returning
  the same `workspaceRoot`, `filePaths` and `filesLimited`. Only a visible project's existing primary folder
  can be listed; Chats and unknown projects are refused. Neither request grants general host filesystem browsing.
  Host paths draw in the local mention chip and are sent as quoted references relative to the listed folder, so
  a task started in a new worktree reads its own copy; paths with `.` or `..` components are dropped. They never
  enter the client's local-file upload path (§15.20).
- `newTaskOptions` accepts optional `composer: true` and `accountId` for the desktop's composer catalog.
  Optional `readCommands: true` reads user commands when the slash menu opens, not on every options refresh.
  It refreshes the harness's native model/effort defaults and joins the host home's cached account-status
  check before projecting the choices; it starts neither a sign-in nor a model turn.
  Its optional account choices contain display data only; `accountLine` is the host's automatic-account
  explanation for the selected model, drawn with the local explanation view. `createTask` takes optional `accountId` and
  `confirmed`; an elevated permission choice requires confirmation, using the local control's wording. The client
  sends `confirmed: true` only after the person accepted every choice that asks.
  Choices apply to the created task and leave the host's home draft and selected account unchanged.

The desktop shares the local file picker, command rows, connector menu, queue rows, permission and model
controls. The new-task prompt, harness identity, destination control, wrapping footer and disabled Start
button also use the local views. The first available project seeds a new draft; without one the destination
control remains unselected, as on the host. Queue editing saves back into the existing queue item rather than withdrawing it into the host's draft.
The account button shares the local control; its popover lists the host's safe account summaries rather than
the local account-management view. Connector setup, reconnect and account management remain on the host. Side chat is not advertised: it needs
host-owned temporary child creation, a child subscription and draft, and explicit close/reconnect ownership so
closing a remote panel cannot discard a side chat another window is using.

### 15.34 Session rail and home task lines

A snapshot may advertise `taskRail: true`. A desktop asks `{type: "taskRail", taskId}` for the task
on screen and receives `rail`. Older hosts omit the flag; the additional cards stay absent. These
facts feed the existing `SessionRailContent` projection and `SessionRailView`, and the same context
usage feeds `ComposerSessionOptions` for the composer ring. Optional `compactOffered` and
`compactAvailable` carry the host's availability; Compact session uses the existing
`runComposerCommand` with `compact` (§15.23).

The rail contains display facts only: the task's branch and instruction files; its account name and
limit windows; numeric context usage and usage breakdowns; plan steps; agent and child-task rows;
background tasks and Codex terminals; the change counts, pull request, checks, reviews and available
merge methods. Timestamps are milliseconds since 1970. Account credentials and environment values
are never included. Host folders remain host folders: the client names them, keeps `folderURL` nil,
and labels the environment with the host name. It does not read Git or instruction files locally.

`taskRailChanged` names the task whose facts should be read again, only for a connection that read
its rail while subscribed. `taskRail` with optional `watching: false` ends that rail watch without
reading any facts; absent `watching` means true. Leaving the displayed task ends its watch even
when its conversation remains cached. Unsubscribing or disconnecting also ends the watch, and the
host stops periodic rail reads once no connection watches it. Reads follow the displayed task;
they do not expand the general snapshot with every task's rail. A client coalesces invalidations
while a read is in flight. Loopback links use `openHostBrowserLink` (§15.30); they never open the
client's localhost. The local rail currently has no separate Servers card, so the remote adds none.

`railAction` takes `taskId`, `action`, optional `targetId`, and optional `confirmed`. The host
validates the current task and target before using the same app-model or pull-request-center path
as its local control. Stops name an agent belonging to the task, a direct child task, a current
background activity, or a current Codex terminal. Unknown actions are refused. Pull-request writes
use the current pull request and require confirmation where the local control asks; a merge cannot
silently confirm a different pending choice. Fix CI prepares the host's existing request text for
the remote draft, without sending a model turn.

| `action` | `targetId` and behavior |
|---|---|
| `stopAgent` | the task's `run_agent` ID |
| `stopChild` | a child task ID |
| `stopBackground` | the task's running background activity ID |
| `stopTerminal` | a current Codex process ID |
| `stopAllTerminals` | no target; requires `confirmed: true` after the card's confirmation |
| `refreshPR` | refresh the current pull request |
| `loadLog`, `closeLog` | a current check ID; read or dismiss its failed log |
| `rerunFailed` | rerun the current failed checks through the host's check client |
| `requestMerge` | `merge:<method>`, `enableAuto:<method>` or `disableAuto`; prepare the local confirmation state |
| `cancelMerge` | dismiss the pending merge |
| `confirmMerge` | the pending choice followed by `|` and its head SHA; requires `confirmed: true` and an exact current match |
| `setAutoFix` | `true` or `false`, with `confirmed: true`; enabling asks before it can send automatic fixes |
| `draftFix` | requires `confirmed: true`; the response's `output` is the host's Fix CI draft |

Errors include `notFound` for a task or target outside the current task, `notAllowed` for a missing
confirmation or stale merge choice, `unsupportedCommand` for an unknown action, `unavailable` for an
operation that failed, and `tooLarge` for facts exceeding the server message limit.

Both new request kinds explicitly require no additional device permission (§15.28): they read facts
or operate the paired device's ordinary task controls. Their audit lines contain kind, task, device
and outcome, never the action's values, account names or message text. Phones may ignore the optional
snapshot fields and the new event; none of their existing requests change.

Agent rows retain their kind, status and reason for waiting. Child tasks open through ordinary remote
task navigation. Agent conversations, background output and inline agent approval/question cards
are not carried by this rail-facts response; their detail transport remains separate. Controls to
open those unavailable detail views are disabled.

The task snapshot optionally carries `answerLine`, the same cached first line of the latest finished
answer the host home reads (at most 240 characters plus an ellipsis), `latestTurnStartedAt` in milliseconds
since 1970, and `completed`, whether the task currently has the host's completed status. Reading these
fields never loads history or scans a conversation. The desktop supplies them to `NewTaskHomeActivity`;
completed tasks keep that status after being read, so the shared home projection counts tasks finished
today. Older hosts omit these fields and retain the previous home behavior.

### 15.35 Editing schedules from another Mac

The optional snapshot flag `scheduleEditing: true` advertises the requests and additional fields below.
The optional `scheduleTimeZone` names the host calendar's time zone for trigger editing and previews.
Without the editing flag, the client keeps New, Edit and Delete dimmed and reads the original §15.21 list. Existing phone
clients may ignore these fields. All changes run through the host's scheduled-task center; the client never
writes a schedule to its own repository.

- `scheduledTasks` additionally returns each schedule's optional `definition` and `accountName`, and optional
  `sessionSchedules`. `definition` is base64-encoded JSON using the host's `ScheduledTask` Codable shape, with
  instructions, trigger, destination choices and retained run history. It is a presentation copy: connection
  data, account identifiers and import source identifiers are removed; secrets and paths outside a listed
  project are masked in text. A host folder never travels: a listed project is named by `projectID`, and every
  folder appears as the presentation marker `yardlet-host-folder`. A project the host hides, or one since removed,
  is sent without `projectID` or `projectName`, like an unregistered folder; retaining the marker preserves the
  schedule's place, while choosing Chat clears it. Failed-start diagnostics use the same masking. The
  host retains its original data when applying an edit. `sessionSchedules` contains `{taskId, job}` for the tasks
  the snapshot lists, where `job` is base64-encoded JSON using `ClaudeSessionJob`'s Codable shape; paths are
  unmasked only inside the task's listed project. These are the CLI's session jobs and
  open their owning task, as on the host. They have no independent edit or delete control.
- `scheduledTaskOptions` takes optional `projectId`, optional `harness`, optional `scheduleId`, optional `accountId`, and `settings`, and returns the host's
  new-task choices as in §15.16. With `scheduleId`, the host resolves the existing account, folder and saved
  choices before constructing the menus. `accounts` reuses §15.17's `RemoteAccount` shape, with only selectable
  accounts' identifiers and display names; `scheduleAccountName` names the selection. Choosing an account reads
  its own model catalog. The host rejects an account outside the harness's current selectable list and keeps
  credentials and account home paths on the host. Unlike the ordinary new-task request, its permission choices may include
  `confirm`: the local editor's Bypass permissions and Full access confirmation must be accepted before saving.
- `saveScheduledTask` takes optional `scheduleId` (absent to create), `definition` (the edited presentation
  copy), `settings` (the host's option identifiers and values), and `confirmed`. The host validates the
  destination, account and choices against its own projects, tasks and option catalog, and requires confirmation for
  elevated permissions, and the device's Terminal permission (§15.28). It creates or updates through the same center
  methods as the local editor, retaining the host-owned run history on edits. A successful response carries `scheduleId`.
- `deleteScheduledTasks` takes `scheduleIds`, `completedOnly` (default false), and `confirmed`. The client asks
  the local window's deletion question first. Delete All captures the completed schedules shown at confirmation;
  with `completedOnly: true`, the host deletes only those still completed, preserving one edited to run again.
  Started tasks and their conversations are retained.
- These reads and ordinary schedule actions require no new device permission. Save and delete are commands:
  the audit log records their kind, schedule identifier, device and result, never instructions or settings.
  Options reads also record their kind, schedule identifier when supplied, and result.
  Refusals use the existing errors, including `notFound` and `notAllowed`. The existing `schedulesChanged`
  notification refreshes the definitions, history and session jobs as well as the list. A response exceeding
  the protocol message limit returns `tooLarge` rather than sending an oversized frame.

The desktop client draws the local scheduled-task list, editor and detail with host values and actions,
including the instructions and grouped run history. Import Schedules from Other Apps stays dimmed: its
catalog and selection flow belong to the host, and reading the client's app data would import the wrong data.

### 15.36 The host's Settings from another Mac

The optional snapshot flag `hostSettings: true` advertises reading and changing the host's Settings from a
remote desktop window. With an older host that omits `hostSettings`, `⌘,` in a remote window keeps its
earlier behavior and opens the client Mac's own Settings in its main window. Phone clients may ignore the
snapshot flag and the new event.

- `hostSettings` takes optional `watching` (default `true`) and returns `settingsPage`, a `RemoteHostSettings`
  object with:
  - `writable`: whether the connected device currently has `RemoteDevicePermission.settings` (§15.28).
  - `values`: the host's current values keyed by `YardletSetting.id` for the host-side rows of General,
    Yardlet Instructions (`yardlet_instructions`, `daily_evaluation`), Usage (`token_usage`), and CLI Updates
    (`cli_automatic_updates`). Rows that configure the client Mac itself (`language`, `check_for_updates`,
    Appearance, Notifications) are excluded, as are Vault (`Passwords`) and `Remote` (paired devices).
  - `credentialHidingAllowedBuild`: whether the host's build is team-signed when `hide_keys_and_tokens` is shown.
  - `lidHelperStatus`: the host's lid helper state (`unavailable`, `off`, `needsApproval`, `ready`) when
    `keep_working_with_lid_closed` is offered.
  - `instructions`: `{text, hasEvaluation, lastEvaluationAt}` when the host has a Yardlet instructions store.
  - `cliUpdates`: `{rows, isChecking, lastCheckedAt, notice}` when the host checks harness CLIs. Each row
    carries `harness`, `title`, `method`, `versions`, optional `status`, `isWarning`, `working`, and optional
    `newerVersion` and `newerText` (never executable paths).
  - `usage`: `{isCounting, limitsCheckedAt, updatedAt, days, limits, rows}` when the host offers token usage,
    with 30-day token/cost totals, plan limit windows and pace (`runsOutAt`), and range/grouping breakdowns.
- While a connection watches (`watching: true`), the server pushes `{"event": "hostSettingsChanged"}` when the
  host's settings, instructions, CLI update rows, usage summary, or the device's `settings` permission change;
  closing the sheet sends `{"type": "hostSettings", "watching": false}`.
- Reading (`hostSettings`) is open to any paired device. Changing any host setting requires
  `RemoteDevicePermission.settings` (§15.28):
  - `setHostSetting` takes `setting` (a `YardletSetting.id`), `value`, and optional `confirmed` (default
    `false`), validates and applies the change through `YardletSettingCatalog` (`AppModel.settingsContext`),
    and returns the updated `settingsPage`. A setting with `asksEveryTime` requires `confirmed: true` after
    the client's confirmation alert. Changes that require macOS approval on the host itself (turning off
    `hide_keys_and_tokens`, or turning on `keep_working_with_lid_closed` while the host's helper is not
    `ready`) are refused with `notAllowed`.
  - `saveHostInstructions` takes `text`, writes it to the host's `YardletInstructionsStore`, and returns the
    updated `settingsPage`.
  - `hostCLIUpdate` takes `action` (`check`, `checkAll`, `useNewest`, `dismissNotice`) and optional `harness`,
    runs the action on the host's `CLIUpdateCenter` / `RuntimeSelectionStore`, and returns the updated
    `settingsPage`.
- Every mutating request is recorded in the host's audit log with its kind, device, result, and `setting`
  (the setting ID, `"yardlet_instructions"`, or `action[:harness]`), never setting values or instruction text.
  Without `RemoteDevicePermission.settings`, the remote sheet renders its controls disabled with a notice
  pointing to the host's `Settings › Remote › Paired devices`.

### 15.37 Host accounts, harness runtimes and connectors

The optional snapshot flag `hostAccounts: true` advertises the requests, event and fields below for
the remote window's Settings › Harness Accounts, Harnesses and Connectors sections. Without it, the client
leaves those sections out of a remote host's Settings. Phones may ignore the flag and the event.

- `hostAccounts` (`watching?: bool`, `refreshHarnesses?: [string]`): reads the host's Account Center
  and connector state (`hostAccountsState` on the response). With `watching: true` (the default), the
  connection receives `hostAccountsChanged` events while the section is open on the client;
  `watching: false` stops the watch. When `refreshHarnesses` is non-empty (`["*"]` for all built-in
  harnesses, or specific harness identifiers), the host re-reads those harnesses' default and saved
  account snapshots before answering, as Refresh in the local Account Center does.
- `hostAccountsState` carries:
  - `accounts`: `[RemoteAccount]`, reusing §15.17 / §15.32's `RemoteAccount` shape with optional
    fields for the Account Center row (`harness`, `connectionName`, `providerId`, `organization`,
    `plan`, `credentialOwner`, `readingStatus`, `checking`, `automaticAssignment`, `defaultSelected`,
    and optional `detail`/`evidence` on each `RemoteAccount.Usage` window). Account home paths,
    tokens, credentials and environment values never travel.
  - `harnesses`: `[RemoteHarnessRuntime]`, one per built-in harness, with `harness`, `installed`,
    `label` (executable name, install source and version, never a filesystem path), optional
    `versionNote` and `versionVerified`, optional `checkingDefault`, and `choices` (`id` `"automatic"`
    or `"install:<index>"`, `label`, `selected`).
  - `connectors`: `[RemoteConnectorInfo]`, one per connector configured on the host, with `id`,
    `name`, `slug`, `status` (`connected`, `signInRequired`, `notConnected`), `authorization`
    (`oauth`, `token`, `none`, `unknown`), `enabled` (whether the connector is turned on for the
    host), `toolCount`, and optional display metadata (`subtitle`, `source`, `presetId`,
    `localService`, `account`, `serverHost`, `programSummary`, `usesRegisteredClient`, `activity`,
    `failure`). Full server URLs, OAuth client secrets, tokens and program environment variables
    never travel.
  - `picksNewTaskAccount`, `continuesAtUsageLimit`, `movesTasksToAccountWithRoom`,
    `claudeAIConnectors`, optional `cannotReadConnectors`, optional `xcodeDescription`, optional
    `harnessesWithTasks`, optional `harnessesWithSubagents`, optional `newTaskHarness`, and optional
    `editable` (`true` when the requesting device currently has the `settings` permission, §15.28).
- `setHostAccount` (`harness?: string`, `accountId?: string`, `automaticAssignment?: bool`,
  `settingId?: string`, `enabled?: bool`): requires the device's `settings` permission (§15.28).
  Chooses the account new tasks use for `harness` (`accountId` naming a selectable account or
  `"automatic"`), toggles whether `accountId` is included in automatic assignment
  (`automaticAssignment`), or updates one of the Account Center's switches (`settingId`:
  `new_task_account_automatically`, `continue_at_usage_limit`, `move_tasks_to_accounts_with_room`)
  through the host's settings catalog. Signing in, adding, removing and sharing accounts are not
  offered over the wire and stay on the host.
- `setHostHarnessRuntime` (`harness: string`, `choiceId: string`): requires the device's `settings`
  permission. Selects `"automatic"` or a discovered install (`"install:<index>"`) on the host's
  `RuntimeSelectionStore` and refreshes that harness's account readings. Choosing an arbitrary
  filesystem path stays on the host.
- `setHostConnector` (`id: string`, `enabled: bool`): requires the device's `settings` permission.
  Turns a connected host connector on or off for the host, or toggles `claude_ai_connectors` through
  the host's settings catalog. Connecting, OAuth sign-in, token entry, registered OAuth app setup,
  adding and removing connectors stay on the host.
- `setHostAccount`, `setHostHarnessRuntime` and `setHostConnector` are commands and return the
  updated `hostAccountsState`. The audit log records their kind, device, result and target identifier
  (`settingId` or `accountId`, `<harness>=<choiceId>`, or connector `id`), never account labels,
  emails or credentials.
- `hostAccountsChanged`: sent to connections watching `hostAccounts` when the host's accounts,
  runtime selections, connectors, related preferences or the device's `settings` permission change.

## 16. Push notifications

The Mac pushes to a device that registered (§15.6) and **has no open v2 connection**, for these
`attention` changes (§5.2): a task starts waiting or waits on a newer request (urgent); a task becomes
unread after `active` or `waiting` (finished or failed; urgent), unless the change says `announces: false`; a task
stops waiting without becoming unread, or becomes unread with `announces: false` (withdraw a notification; not
urgent).

`data.y` is `nonce (12 random bytes) ‖ ciphertext ‖ tag (16 bytes)`, base64url: ChaCha20-Poly1305 with the
device's push key, associated data the UTF-8 bytes of `yardlet-push/1`, over the UTF-8 JSON

```json
{"event": "attention", "taskId": "4C1F…", "title": "Approve the index migration", "projectName": "Yardlet",
 "harnessName": "Claude Code", "state": "waiting", "previousState": "active", "indicator": "awaitingApproval",
 "pendingRequest": "approval", "requestId": "toolu_01…", "summary": "Bash: Run the migration tests",
 "macName": "MacBook Pro", "sentAt": 1792158000000}
```

- While a paired desktop says it is in use (`presence`, §18), attention pushes wait: the Mac keeps the latest change
  of each task and sends those, in the order they came, once no desktop is in use (it says so, or its connection
  ends). A request answered on the desktop meanwhile then withdraws rather than rings. Link requests are not held.
- A waiting link request (§15.11) is pushed too, urgent:
  `{"event": "linkRequest", "requestId", "name", "platform", "code", "expiresAt", "macName", "sentAt"}`.
- `data.k` is the push key id, so a phone paired with several Macs knows which key opens it. `collapse` is
  the first 16 hex characters of `SHA-256(taskId)`; `ttl` 3,600 s. FCM data messages and APNs payloads hold at
  most 4 KB, so titles are cut to 200 characters.
- The phone shows the notification itself, from the decrypted event, as it does for live `attention`
  events; on the lock screen only a public version ("Approval requested").
- Through APNs (§14.2) an urgent push is an alert that the iOS app's Notification Service Extension opens with the
  push key and rewrites from the event; the alert's own text is the app's, shown only when the extension cannot
  open it. A push that is not urgent is a background push, which iOS hands the app when it chooses and may hold
  back.

## 17. v2 fixture and test vectors

- `yardlet-remote-fixture --v2` also listens for v2 on `127.0.0.1:47616` with a fixed fixture Mac key and
  prints the v2 pairing URL (its secret is fixed too, and can be used again unless `--single-use-pairing`).
  The URL names `10.0.2.2:47616` (the Android emulator) and `127.0.0.1:47616`, or the `--host HOST:PORT`
  given. `--relay ws://127.0.0.1:8787` also opens the fixture's room on a local relay (`relay/`,
  `npx wrangler dev --local --port 8787`, no sign-in); `--relay-public ws://10.0.2.2:8787` is the relay address
  phones are told. `--approve-links` approves a link request (§12.1) three seconds after it arrives.
  `--signed-out HARNESS` (`claude-code`, `codex`, `opencode`; repeatable) refuses `createTask` on that harness with
  `reason` `signIn` (§15.16), as a Mac whose login for it is signed out.
- The fixture's v2 tasks add a plan review, an answerable question, a suggested task (with `suggestionOptions`: its
  task's harness and project, and a Start with choices names the model in its first message), lines with details,
  and taking `createTask`, `setPinned` and `archiveTask`. It does not announce `fullConversation` (§15.24) and
  answers every subscription in §6's shape.
- Its scheduled tasks (§15.21): "Summarize new crash reports" runs every morning and its last run started "Summarize
  the crash reports"; "Check the footer links" is paused and continues "Fix the footer links"; "Nightly screenshots"
  turned itself off after three failed starts, and Run now fails again; "Weekend trip reminder" is a one-off in
  Chats that ran (no `canResume`). Run now starts or continues a task after a moment (`busy` meanwhile), and while
  that task works a second Run now records a skip.
- Its tasks' controls (§15.23): every task has settings in the Mac's words ("Bypass permissions" and Codex's "Full
  access" with `confirm`), and "Check the footer on mobile" has `prepare` until a `taskSettings` with `prepare` reads
  them. Claude Code tasks list `/compact` and `/clear`, Codex tasks Compact, Fork chat, New chat and Plan mode (which
  adds or removes the `plan` setting). Compact adds "Context compacted" to the last turn; `/clear` and New chat start a
  blank task, and a fork copies the turns into a task nested under its own. An idle task's latest turn offers `edit`,
  which starts it again with the edited message, and `fork`; a Codex task offers `fork` on every finished turn.
- Its tasks' files (§15.22) are in the fixture's own temporary folder, which it prints when it starts: each project's
  tasks share a folder (`Yardlet`, `Website`, `Chats`). "Summarize the crash reports" lists `crash-summary.pdf`, in a
  `Desktop` folder beside its own, and `reports/crash-chart.png`; its conversation names `reports/crash-notes.txt`.
  `../Desktop/private-notes.txt` is neither, so it answers `notFound`.
- Test vectors both implementations check (`Tests/NativeHarnessClientTests/Fixtures/RemoteNoiseVectors.json`,
  copied byte for byte into the phone app's tests): the public-domain cacophony vector for
  `Noise_IK_25519_ChaChaPoly_SHA256`, and a Yardlet vector with this protocol's prologue, a pairing
  payload, message 2's payload and a chunked transport message.

## 18. Yardlet as a client

Conversation next steps (§15.31) use the host's current turn and the local conversation controls:
plan implementation, question options, failed-turn retry and resuming after a limit reset. All
requests act on the host; the client does not execute a plan or retry against its own workspace.
The same cards also draw command output, file rows, reasoning, shell output and MCP result bodies.
Claude subagents open in the local subtask pane with host reads and Stop, composer notices use the
same notice lines, banked resets use the common confirmation, and file restore uses the common
preview sheet plus a client confirmation and the host's file-write permission.

Yardlet on another Mac follows a Mac's tasks over this protocol, unchanged: File › Connect to Mac… pairs with a
link from §12 (copied on the host, pasted or opened as a `yardlet-remote` link; nothing pairs until the person
chooses Connect), and each paired host opens in a window of its own. The host lists it among its devices with the
`platform` `macos` it sends in message 1, and removes it as it removes a phone.

- **In its own words:** it draws a line's `words` as the Mac does, its verb muted (§6.4), and a choice's `text` in its
  own language when its catalog has the key (§15.19), so two Macs set to different languages each read the card in
  their own.
- **Its window:** Yardlet's own window shell and sidebar, read from the snapshot as the host's sidebar lists it: Home,
  Scheduled tasks, the search (on titles and project names; a conversation's words stay on the host), Pinned, the
  projects with their collapsing and "Show more", Chats, or in their place the states when this Mac groups its task lists
  by state, the nested tasks and each row's mark, the activity view, the
  title bar's buttons and a hidden sidebar, and in place of the account button the host's name and how it is reached.
  The Task and View menus and their keys act on it as on the local window (new task, previous and next task, the next
  one needing attention, Pin, Archive, the sidebar, the activity view, Find in the conversation), and it has the local
  window's tabs (New Tab, Close Tab, Reopen Closed Tab, the next and previous tab, a row's Open in New Tab, ⌃1–⌃9 for the
  pinned rows). Its home lists the host's projects with what their tasks need, as the local home does, and a task's
  session rail is the local rail: where the task runs (its project and harness; the folder stays the host's), its
  settings (§15.23), chosen there through the host, and its outputs (§15.22). The home also reads the host's
  cached answer lines, latest-turn times and completed status (§15.34). A task lays out as the local task does,
  its side panel's tab strip sharing the title bar's row and the title bar's buttons toggling the rail and the panels:
  the side panel's New tab, Review (§15.26) and Files (§15.27) where the host serves them, the browser (§15.25), whose
  tabs share the panel's strip and close when the host's list says they did (§15.30), and the task's terminal
  (§15.29), below the conversation or in the side panel as Settings place the terminal, its selection attached to the
  composer. A link in the conversation or the terminal opens as on the host: a file read from the host, a page on the
  host's own address in the host's browser. A panel the host does not serve from another Mac, or does not allow this
  Mac (§15.28), shows dimmed in the New tab screen and the title bar. With `taskActions` (§15.32), the row and title menus rename, mark unread, move, nest, delete and restore host tasks;
  the Task menu and host footer open the paged archived list. Project pinning and chat archiving act on the host.
  Edit project, Show in Finder and Remove project remain dimmed. Older hosts keep the new actions dimmed.
- **What it does:** what a phone does (§4–§6, §15), on a larger screen: the host's sidebar and its marks, a task's
  conversation in Yardlet's own timeline with the host's own cards from its full detail (§15.24: whole answers, a
  message's pictures, subagents, compactions, notices, proposed plans and the limit card with its windows and
  actions), a line's output and diffs when it opens (§15.8), every answer the host's
  card gives (§15.19; one that leaves a rule behind is asked about once more), an MCP form filled in on Yardlet's
  own form card and sent with the host's Submit and its `values`, questions and plan reviews, the queue's actions,
  the plan limit's actions, Stop, Pin and Archive, new tasks with the host's choices (§15.16), and pictures and
  files (§15.14, §15.20). A suggested task draws as Yardlet's own chip, whose Start, Do it here and ✕ are
  `actOnSuggestion` (§15.9); from a host advertising `suggestionOptions`, its Options opens the local popover with the
  host's choices (`composer`), asks before Start about a choice the host confirms first, and starts with what it
  shows. An older host's chip starts with the host's own choices and keeps Options dimmed. When the snapshot says so, the sidebar lists the
  host's scheduled tasks with Run now, Pause and Resume (§15.21), and with `scheduleEditing` the local list,
  editor and full detail, New, Edit, confirmed Delete and Delete All, and Claude Code session schedules (§15.35), and a task's session rail shows its Outputs card
  (§15.22). An output, or a file a conversation's link names (wherever it is, outside the task's folders too, unless
  the host keeps it back), is read with `readFile` into a folder of its own in
  this Mac's temporary folder, readable only by the person, and opened there in Quick Look (from the output's
  menu, in its own app or Finder); the copies go when the window closes. A file link never opens the same path on
  this Mac. From a host that offers them (§15.23), the task's model, effort and permission mode show in the
  composer's own controls (a choice the host asks about first is asked about here too), the slash commands that may
  run from here in "+" and a typed `/` list, and a turn's Edit message and Fork from here. A task's browser (§15.25)
  shows in a side panel where the host's window has the task's browser panel: the task's tabs in the panel's strip,
  Back, Forward and Reload, the handoff's bar, with `tabPermissions` the permission bar of the Mac's panel (its
  words naming the host, the two bars one above the other when both are up), and the watched tab's page, which takes clicks, drags, the trackpad,
  keys and the input method's committed text (what it is still composing shows on the client until committed; ⌘V
  types the client's own clipboard; with `tabCopy`, ⌘C and ⌘X, and Edit › Copy and Cut, copy the page's selection onto
  it, and what the page copies after the panel's click or key lands there too; secure keyboard entry is on while the
  page's password field has the keyboard). The
  page lays out at the panel's size (`viewport`, never as a phone), and follows the panel once it rests 200 ms at a new
  size. From a host advertising `tabLists`, the window follows the list of the
  task it shows (`listOnly`) whenever its panel shows none of the task's tabs, so the host's tabs are the panel's tabs
  from the start, as the local task's engine tabs are its panel's: the title bar's side-panel button and ⌘4 reopen
  them as they reopen the local task's tabs, the host's front tab first. A file page the task's conversation names
  shows there as any page does. A tab listed as `file://`
  (a file outside the task's files, which the host does not picture) says that it shows only on the host rather than
  waiting for a picture. A handoff's card has Show Tab, which opens it there. With `tabControls`,
  the address field, new-tab button and tab close buttons act on the host (§15.30), and a hook routes loopback links
  there for the window's link handler. The tab strip uses the same `WorkSurfaceHeader` as other side panels.
  With `taskRail`, the rail reads the host's additional facts and the composer shows its context ring (§15.34).
  Task connector switches, file mentions, extended commands, queue controls and next-message suggestions use
  the shared composer views when the host offers §15.33. New tasks also offer host account choices and confirmed
  elevated permissions. With `hostSettings` (§15.36), `⌘,`, the app menu's `Settings…` and the host footer open
  the host's Settings sheet in the remote window (`SettingsCenterView` showing General, Yardlet Instructions,
  CLI Updates and Usage, editable with the device's `settings` permission and read-only otherwise).
  With `hostAccounts` (§15.37), the remote window's Settings draws the local Accounts, Harnesses and Connectors sections from the host's values: Refresh re-reads the host's accounts, and with the
  device's `settings` permission (§15.28) choosing the account for new tasks, changing automatic assignment or
  usage-limit switches, picking a discovered harness runtime, and turning a connected connector on or off act on
  the host. Without the `settings` permission those controls show disabled with a note naming the host's
  Settings › Remote › Paired devices. Signing in, adding, removing or sharing accounts, choosing a custom
  runtime file, and connecting or editing connectors stay on the host. Importing schedules from other apps and
  the other side panels also stay on the host.
- **Paths:** as §11.4. While a host's window is open it browses Bonjour (§11.3) for the instance with the
  discovery id of the host key it saved, and resolves it to the host's name and port (`Name.local:47616`; the
  system resolves the name when connecting). Those addresses go first, never saved, then the direct addresses the
  host named last (kept across networks, at most 8), all at once, and the relay 0.7 s later. While on the relay it
  tries the direct addresses again every minute and as soon as Bonjour finds the host; an address found while it
  waits to connect again starts the next attempt at once. It pings every 25 s, takes a connection that heard
  nothing for 60 s for gone, and connects again with backoff from 1 s to 30 s. After every new connection it reads
  the snapshot and its open conversations again.
- **Order:** responses and events are applied in the order they arrive, so a subscription's page comes before the
  changes to it (§5.3). It keeps at most 6 conversations subscribed, letting go of the one shown longest ago.
- **What stays on the client:** `~/.yardlet/remote/hosts.json` (each host's name, static key, direct addresses,
  relay room and device ID; removed with the last host; one this build cannot read is copied aside as
  `hosts-unreadable-<time>.json` before a save replaces it), one Keychain item per host for its private key, and what
  each host's window last showed, in `~/Library/Caches/<bundle identifier>/remote/<host>/` (folder 0700, files
  0600): the snapshot's projects and tasks, and the latest page of each conversation open last (at most 6, each cut
  to the size of Yardlet's first page, §4.2: 10 whole turns, 120 items, about 384 KB), and the words of its unsent
  drafts (`drafts.json`, kept a moment after typing stops and when the window closes). Reopening the window shows
  them at once, before it connects; the snapshot and subscriptions replace them once it does. The cache is written a
  moment after changes stop (at least every 10 s while they go on) and when the window closes, a conversation only
  when it changed. The same folder keeps the Files panel of each task with unsaved edits (`files.json`: each edit,
  the text and digest it began from, the file open and where it was read; written a moment after typing stops, when
  the window closes and when Yardlet quits, and removed with the last edit, §15.27). Nothing listens and nothing runs
  while no host window is open. Removing a host sends `forgetDevice` (§15.6) when the host can be reached and deletes
  all three; a cache folder whose host is no longer saved is removed when Yardlet starts.
- **Notifications, Dock badge and menu bar:** while a host's window is open and connected, its tasks that need the person
  count in this Mac's Dock badge alongside this Mac's own tasks and appear in this Mac's menu bar item under Running
  (while waiting) and Unread, labeled with the host's name; choosing one brings that host's window forward with the task
  selected. A task that starts waiting, finishes or fails posts a notification named after the host (unless it is the
  task shown in the window in front, which also clears any earlier notification for that task), following this Mac's
  notification authorization, and a new approval while Yardlet is behind other apps bounces the Dock icon once. A finish
  with `announces: false` (§5.2) posts none, and a task that stops waiting, is answered, is read, or leaves the host's
  list takes its notification back, as the host's own notifications do. An approval's offers "Allow once", sent as
  `answerApproval` `allowOnce` (§4.4): the host answers with its card's narrowest allow, as its own notification does,
  and where it does not take it the notification opens the task. When the host disconnects or removes this Mac, or when
  the host window closes, its tasks are cleared from this Mac's Dock badge and menu bar and its notifications are
  withdrawn; reconnecting and resyncing counts its live tasks again.
- **In use:** a host whose snapshot carries `presence: true` takes `{"type": "presence", "active": true}` (or `false`);
  the answer is `ok`. The client says `true` while the host's window is in front and the person typed, clicked or
  moved the pointer in the last two minutes, and `false` once not, telling only a change and again after each new
  connection. Meanwhile the Mac holds the phones' attention pushes (§16), as Claude Code's remote control does not push
  to a phone while the person watches the terminal. Not a command; a connection's presence ends with it.
- **On Windows:** Yardlet on Windows follows a host the same way (docs/PLATFORM_PORTABILITY.md, "The Windows app"):
  Connect to a Mac in its main window pairs with the same link, message 1 names the `platform` `windows`, and each
  host opens in a window of its own with the host's tasks, a task's conversation and a composer. It has no Bonjour, so
  it tries the direct addresses and then the relay; keys stay in Credential Manager, and `hosts.json` and the cache
  under `%LOCALAPPDATA%\Yardlet`.
- **Host settings:** Settings › Remote's "Keep this Mac awake on power" (off unless turned on) holds off idle sleep
  while remote connections are allowed and the Mac is on power, so a device elsewhere can reach it.
