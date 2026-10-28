# Yardlet Remote Protocol

Status: the contract (protocol 2; protocol 1 has been removed, §1). The Mac side (Yardlet) implements it in `Sources/YardletRemote` and
`Sources/NativeHarnessClient/Remote`; the phone apps implement the client side against this file; the relay
in `relay/` implements §14. The design is in [REMOTE_V2_DESIGN](REMOTE_V2_DESIGN.md).

A phone watches and drives the tasks running in Yardlet on the person's Mac: it lists projects and tasks
with the sidebar's attention states, reads a task's conversation (latest first, older on scroll, live while
it streams), sends a message to a task, answers a pending approval (allow once or deny), stops a running
turn, and marks a task read. It also answers questions and plan reviews, starting a task (on a
harness, model and worktree the phone picks), images, a line's output and diffs, suggested and queued messages,
continuing a task a plan limit stopped under another account, answering a browser handoff, and push
notifications. Nothing else: no settings, connectors, file browsing or terminals.

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
  logs, not for the UI.
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
| `attention` | the sidebar's one attention state: `waiting` (an approval or a question waits for the person), `unread` (a finished result, failed included, not read yet), `active` (a turn or bash command is working), `idle` |
| `indicator` | the sidebar row's mark, absent when none: `awaitingApproval` (green dot), `needsInput` (orange dot), `failed` (red warning), `usageLimit` (gauge), `running` (gray dot), `unread` (blue dot) |
| `pendingRequest` | `approval` or `input` while `waiting` |
| `unread` | the task holds an unread result |
| `running` | a turn (or a Claude bash command) is running, waiting on a request included: `stopTurn` applies. `attention` `waiting` always comes with `running: true` |
| `pinned` | listed under Pinned in the sidebar |
| `lastActivityAt` | last activity |
| `parentTaskId` | the task it was started from (fork, subagent), when that task is in Yardlet; the sidebar nests it |

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
local audit log with its type, task ID, device and result — never the message text. `ok: true`
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
  `/clear` or `/model` — commands stay on the Mac), `busy` (the Mac is editing a message in this task,
  switching its account, or another app holds the conversation), `notFound`.

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
  answer is not offered for this request), `unavailable` (the task is not connected to its harness on
  the Mac), `notFound`.

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
- The phone makes its own notifications from these; the Mac uses no push service. Suggested: notify
  on `waiting` (approval or question) and on `active` → `unread` (finished; `indicator` `failed` when
  it failed).

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
second per task.

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
| `inWork` | true for the turn's work: hide it under the turn header while that turn's `foldsWork` is true, as the Mac folds a finished turn's work, unless the person opens it |

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
- `text` ≤ 16,000 characters. `imageCount`: attached images (not sent). `scheduled: true`: a Codex
  automation sent it on its schedule. `shell: true`: a Claude Code bash command (`text` is the
  command). `diffCommentCount`: diff comments attached on the Mac (their text is not sent).

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
  gets `rateLimited` and is dropped; 20 in a row closes the connection (4429).
- At most 8 connections of paired devices at once; more are closed (4503). A v2 connection counts once the
  phone's first message after message 2 arrives (§13.1). Besides those, at most 8 connections may still be
  authenticating; a new one closes the oldest of them (4503). At most 8 subscriptions per connection.
- A listener holds at most 4 connections from one address, and 16 in all, that have not finished their
  WebSocket and Noise handshakes; a new one closes the oldest of them, and one not done within 10 s is closed.
- Pairing: 5 wrong codes close the open pairing.

## 8. Error codes

| code | meaning |
|---|---|
| `badRequest` | not JSON, not an object, or a missing or wrong field |
| `unknownType` | a `type` the server does not know |
| `unsupportedVersion` | message 1's `v` is not 2, or a link request without `linkCommit` (§12.1) |
| `unauthenticated` | a request before the connection is a device's (a link request waiting, §12.1) |
| `pairingUnavailable` | no pairing is open (expired, used or cancelled) |
| `pairingInvalid` | wrong pairing secret |
| `notFound` | no listed task with that ID |
| `notSubscribed` | `loadOlder` for a task not subscribed |
| `invalidCursor` | the cursor no longer names a place in the conversation |
| `tooManySubscriptions` | more than 8 subscribed tasks |
| `requestNotFound` | the request is not waiting any more |
| `notAllowed` | that answer is not offered for the request |
| `unavailable` | the task is not connected to its harness on the Mac |
| `notRunning` | nothing to stop |
| `emptyMessage` | `sendMessage.text` is empty |
| `tooLarge` | `sendMessage.text` is too long |
| `unsupportedCommand` | a slash command |
| `busy` | the task cannot take it now (editing, switching account, held by another app) |
| `rateLimited` | over the rate limit |
| `internal` | anything else |
| `unknownDevice` | v2 handshake: the phone's key is not paired, or the device was removed (§13.1) |
| `linkUnavailable` | v2 handshake: a link request to a Mac not signed in to an account (§12.1) |

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
  gone when it stops.
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
  - "Summarize the crash reports" (Codex) is finished and unread with 30 turns, for `loadOlder`.
  - "Fix the footer links" (Claude Code) is idle; `sendMessage` (to it or any idle task) starts a turn
    that reads and edits files, streams an answer and completes.
  - "Pick the release name" (Claude Code) waits on a question (no phone options, `moreOnMac`;
    `stopTurn` expires it, and the question comes back 30 s later).
  - "Plan the weekend trip" (a chat) has a to-do plan; "Check the footer on mobile" is nested under
    "Fix the footer links"; "Regenerate the screenshots" failed.

## 10. Revisions

Every revision of protocol 2 only adds optional fields or states a rule, except where it says otherwise.

- 2026-10-16, after the first Android client build:
  - §5.3: `after` always names an item the phone holds once it has applied what came before in order;
    a phone that cannot find it subscribes again. A `loadOlder` page is followed by the changes its
    newer turns went through meanwhile.
  - §6.2: `queued` (and `queueFailed`) user items for messages waiting in a task's follow-up queue.
  - §4.1: `running` is true while a turn waits on a request (`waiting` implies `running`); the fixture's
    waiting tasks now say so and `stopTurn` expires their request.
  - §5.2: `summary` on `attention` events while `waiting` (≤ 120 characters, secrets masked).
  - §2, §3.2, §3.3, §4.1: `serverTime` on the `pair`, `hello` and `snapshot` responses, for clock skew.
- 2026-10-24: protocol v2 (§11–§16) beside v1. v1 is unchanged on the wire; a v1 connection never sees
  the v2 answers in `options` (§15.12).
- 2026-10-27, v2 only: allow for the session and a note with a denial (§15.13), images (§15.14, and phone
  messages up to 8 MiB in §13.2), choosing steer or queue and the queue's actions (§15.15), choosing a new task's
  harness, model, effort, permission mode and worktree (§15.16), continuing a task a plan limit stopped (§15.17),
  and answering a browser handoff (§15.18). Later the same day: every answer the Mac's card gives, MCP forms and
  secret answers (§15.19), and files in resumable parts (§15.20).
- 2026-10-27, not only additions: protocol 1 removed (§1); a link request commits to a nonce and reveals it
  (§12.1), and older link requests get `unsupportedVersion`; limits on connections that are still authenticating
  (§7, §13.1, §14.3).

## 11. v2 transport

### 11.1 Paths

Every v2 connection is a WebSocket that carries **binary frames only**, one Noise message per frame
(§13). A text frame closes the connection (1003); a frame over 65,535 bytes closes it (1009). The same
handshake and encryption run on every path:

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
2. Start the direct candidates at once (3 s each to finish the handshake) and the relay 0.7 s later;
   the first handshake that completes wins and the others are closed.
3. While on the relay, try direct again when the network changes or Bonjour finds the Mac; when one
   completes, move to it (send `snapshot` and subscribe again) and close the relay connection.

## 12. v2 pairing

Settings › Remote › "Pair a phone" shows a QR code holding:

```
yardlet-remote://pair?v=2&k=<Mac static public key>&s=<secret>&n=MacBook%20Pro&h=192.168.1.20:47616&h=100.64.12.34:47616&r=wss://relay.example.test&i=<room>
```

- `v=2`. `k`: the Mac static public key. `s`: the pairing secret, 32 random bytes. `n`: the Mac's name.
  `h`: zero or more direct addresses `host:port` in the order to try (an IPv6 host in brackets). `r` and
  `i`: the relay's base URL and the Mac's room, present when the Mac uses a relay. Values are
  percent-encoded; unknown parameters are ignored.
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
 "relay": {"url": "wss://relay.example.test", "room": "<room>"}}
```

```json
{"ok": false, "error": {"code": "unknownDevice", "message": "…"}}
```

- `paired: true` only on the connection that paired. `direct`: the Mac's addresses now, to try next time.
  `relay`: absent when the Mac uses none; a phone replaces what it stored with it.
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
  connection (4401). A message from the phone over 8 MiB closes it (1009), as do the Mac's over 8 MiB. Before
  2026-10-27 a Mac closed a phone message over 65,536 bytes; a phone sends a larger one (images, §15.14) only to
  a Mac that offers images.
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
and times, and a push's FCM token while sending it.

### 14.2 The Mac's socket

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
7. The Mac sends the text `ping` every 30 s and the relay answers `pong` without waking the room. The
   Mac reconnects when no `pong` came for 90 s.
8. Push, at most 60 a minute per room:

   ```json
   {"t": "push", "id": "p3", "to": "<FCM registration token>", "urgent": true, "collapse": "<≤ 64 chars>", "ttl": 3600,
    "data": {"v": "1", "k": "<push key id>", "y": "<sealed payload>"}}
   ```

   The relay sends `data` as an FCM HTTP v1 data message (`android.priority` HIGH when `urgent`, else
   NORMAL; `collapse_key`; `ttl`) and answers `{"t": "pushed", "id": "p3", "ok": true}` or
   `{"t": "pushed", "id": "p3", "ok": false, "error": "unregistered"}`. Errors: `unregistered` (the
   token is gone: forget it), `invalid`, `rateLimited`, `unavailable`, `notConfigured` (the relay has
   no FCM credentials).

### 14.3 A phone's socket

Binary frames only (a text frame closes it, 1003), each at most 65,535 bytes (1009). The relay closes a
phone socket that sent nothing for 120 s (4408), and every phone socket of a room whose Mac left (4404).

A socket the Mac has not yet sent a frame to is waiting. The relay keeps at most 2 waiting sockets from one
address and 8 in a room; a new one closes the oldest of them (4503). A socket still waiting after 15 s is closed
(4408).

### 14.4 Accounts

Optional (the QR stays the way to pair without one). The account only lists the person's Macs and lets a new
phone ask one of them to link (§12.1); it never carries tasks or conversations.

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
  and `pendingKind` (`approval`, `question`, `planReview`, `form`, and since 2026-10-27 `browserHandoff`, §15.18),
  so a list says what waits without opening the task. Since 2026-10-27 the `attention` event of a waiting task
  (§5.2), and so its push (§16), carries the same `pendingKind` (not on a v1 connection). v1 phones ignore them.
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
  have, a step missing), `tooLarge`, `unavailable`.

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

- Starts a task as the Mac's new-task composer would with that project (or Chats) chosen and the text
  typed: its harness, model, account and worktree setting as they are now on the Mac. The new task is listed
  (a `tasksChanged` event) before this response arrives, so the phone can subscribe to it at once.
- A command (§7). Errors: `notFound` (no such project, or it cannot take tasks), `emptyMessage`,
  `tooLarge`, `unsupportedCommand`, `unavailable` (no harness, or the project's folder is gone), `busy`,
  `internal` (the task did not start; `message` says why).

### 15.6 Push and devices

```json
{"id": "15", "type": "registerPush", "provider": "fcm", "token": "<FCM registration token>"}
```

```json
{"re": "15", "ok": true, "pushKey": "<32 bytes>", "pushKeyId": "<16 hex>"}
```

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
`started`, `failed`, `dismissed`, `sentHere`), `startedTaskId` once started, and in `options` the actions the
phone may take: `start`, `here` (do it in this task), `dismiss`.

```json
{"id": "19", "type": "actOnSuggestion", "taskId": "4C1F…", "suggestionId": "task_1a2b3c4d", "action": "start"}
```

As the chip's buttons on the Mac. A command. Errors: `notFound`, `notAllowed` (the action is
not offered now).

### 15.10 Pinning and archiving

```json
{"id": "20", "type": "setPinned", "taskId": "4C1F…", "pinned": true}
{"id": "21", "type": "archiveTask", "taskId": "4C1F…"}
```

As the sidebar's Pin and Archive. Commands. An archived task leaves the list (`removedTaskIds`). Errors:
`notFound`, `busy` (the Mac cannot archive it now, for example while it runs).

### 15.11 Link requests

- Event to connected v2 phones while a link request (§12.1) waits:
  `{"event": "linkRequest", "requestId": "…", "name": "Pixel 9", "platform": "android", "code": "482913",
  "expiresAt": 1792158120000}`, and `{"event": "linkResolved", "requestId": "…", "approved": true}` once answered
  anywhere or expired.
- `{"type": "answerLink", "requestId": "…", "approve": true}`: approve or refuse it. A command. Errors:
  `requestNotFound`.

### 15.12 Protocol 1 connections (removed)

Protocol 1 has been removed (§1).

The sections below were added on 2026-10-27 (REMOTE_V2_DESIGN 5.2). Each only adds optional fields and
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
- `answerApproval` takes `"answer": "allowForSession"`. With `"answer": "deny"` it takes an optional `note`
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
  (Settings). A phone's own choice starts from it. A Mac from 2026-10-27 on always sends it on v2, so a phone
  may read its presence as that Mac taking everything in §15.13–§15.18 (a denial's `note` above all, which an
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
- `settings`: the new-task screen's model menu (model, effort) and, where the harness launches in one, its
  permission mode, each with its value now and its choices. Choices the Mac asks to confirm (Bypass permissions,
  full access) are left out. When the Mac has not read the harness's model list for this account yet it reads it
  first, as opening the menu does (up to about 10 s); until then the menu holds only the value now.
- `worktree`: present for a project in a Git repository, whether the Mac starts its tasks there in a new
  worktree now.
- `createTask` takes `harness`, `settings` (`{"model": "gpt-6", "reasoningEffort": "high"}`, ids and values from
  this answer; the Mac applies them in the order its answer lists them, as picking them in its menus would),
  `worktree` and `images` (§15.14). They apply to
  this task only; the Mac's new-task composer keeps its own choices. Errors: `notAllowed` (a harness, setting or
  value the Mac does not offer now).

### 15.17 Plan limits

- The `error` item with `errorKind` `usageLimit` (§6.7) on the latest turn of an idle task carries the limit
  card's actions in `options`: `continueWithAccount` (another saved account shares the task's history) and
  `autoContinue` (the task continues once the limit resets; Claude Code, when the limit names its reset), and
  `autoContinue: true` while that is armed.
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
  "Decline". "Done" is for a step finished elsewhere (a sign-in approved in another app, a link opened on the
  phone); the tab itself is not shown on the phone yet (REMOTE_V2_DESIGN 6.3). A command. Errors:
  `requestNotFound`, `notAllowed`.
- It is pushed (§16) like any other wait.

### 15.19 Every answer the Mac's card gives

Added later on 2026-10-27 (REMOTE_V2_DESIGN 5.3). A phone answers a request with the same choices the Mac's card
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
  (REMOTE_V2_DESIGN 5.3). The ids name the answers of this request only.
- Answering:

  ```json
  {"id": "26", "type": "chooseAnswer", "taskId": "4C1F…", "requestId": "toolu_01…", "choice": "2"}
  {"id": "27", "type": "chooseAnswer", "taskId": "4C1F…", "requestId": "toolu_01…", "choice": "0",
   "note": "Run only the unit tests"}
  ```

  `note` goes with a `destructive` choice only, as §15.13's. A command. Errors: `requestNotFound`, `notAllowed`
  (no such choice), `tooLarge`, `unsupportedCommand` (the note), `unavailable`.
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
  answers `notAllowed` with the first problem in `message` ("Repository: Required") when one does not fit. A value
  of the wrong kind for its field, or for no field, is refused the same way, never replaced by the field's default. The
  form's item also keeps `moreOnMac` for phones that do not read `choices`.
- A question step whose answer is a secret (`secret: true` in `questionSteps`) is answered on the phone as any other
  step (§15.3). Such a question offers `answerSecret` in `options` instead of `answer`, with `moreOnMac` and a
  `macNote`, so a phone from before 2026-10-27, which would show the value, still sends the person to the Mac. A
  phone that reads `answerSecret` shows the field masked, keeps the value only until it is sent, and never stores or
  logs it; the Mac sends it to the provider as its card does.
- `moreOnMac` and `macNote` remain for a request with no choices: one Yardlet itself answers nothing for (its
  `unanswerableReason`, in `macNote`). Steps that are not requests (Touch ID, a passkey or sign-in window, a macOS
  permission prompt, a keychain prompt) are the Mac's, as before.
- `options` (§6.5, §15.13) stays for phones that do not read `choices`.

### 15.20 Files and photos from the camera

Added later on 2026-10-27 (REMOTE_V2_DESIGN 5.3). Photos from the camera are images (§15.14). Any other file goes up
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
  the upload, and the phone starts the file again under a new ID. Not a command; at most 4 uploads open per device
  (`busy`). Errors: `badRequest` (also a used ID), `tooLarge` (over 500 MiB, or the Mac's disk would keep less than
  2 GB free), `notFound` (an unknown or expired upload at an offset after 0), `busy`.
- `sendMessage` and `createTask` take `files: ["<uploadId>", …]`, at most 20, each finished and named once. The Mac writes each
  file in a folder of its own under its temporary folder (never the task's folder), named as the phone named it
  without any path, readable only by the person and never executable, and sends it as its composer sends a dropped
  file: an image the harness can carry as an image, any other file as a reference to its path (Claude Code's `@`
  path, a Codex mention). Nothing on the Mac opens or runs it. Errors: `notFound` (an upload that is not finished
  or has expired), `notAllowed` (the harness takes no files).
- Over the relay each part is ordinary encrypted chunks (§13.2): the relay sees only their size and timing.

## 16. Push notifications

The Mac pushes to a device that registered (§15.6) and **has no open v2 connection**, for these
`attention` changes (§5.2): a task starts waiting or waits on a newer request (urgent); a task becomes
unread after `active` or `waiting` (finished or failed; urgent); a task stops waiting without becoming
unread (withdraw a notification; not urgent).

`data.y` is `nonce (12 random bytes) ‖ ciphertext ‖ tag (16 bytes)`, base64url: ChaCha20-Poly1305 with the
device's push key, associated data the UTF-8 bytes of `yardlet-push/1`, over the UTF-8 JSON

```json
{"event": "attention", "taskId": "4C1F…", "title": "Approve the index migration", "projectName": "Yardlet",
 "harnessName": "Claude Code", "state": "waiting", "previousState": "active", "indicator": "awaitingApproval",
 "pendingRequest": "approval", "requestId": "toolu_01…", "summary": "Bash: Run the migration tests",
 "macName": "MacBook Pro", "sentAt": 1792158000000}
```

- A waiting link request (§15.11) is pushed too, urgent:
  `{"event": "linkRequest", "requestId", "name", "platform", "code", "expiresAt", "macName", "sentAt"}`.
- `data.k` is the push key id, so a phone paired with several Macs knows which key opens it. `collapse` is
  the first 16 hex characters of `SHA-256(taskId)`; `ttl` 3,600 s. FCM data messages hold at most 4 KB,
  so titles are cut to 200 characters.
- The phone shows the notification itself, from the decrypted event, as it does for live `attention`
  events; on the lock screen only a public version ("Approval requested").

## 17. v2 fixture and test vectors

- `yardlet-remote-fixture --v2` also listens for v2 on `127.0.0.1:47616` with a fixed fixture Mac key and
  prints the v2 pairing URL (its secret is fixed too, and can be used again unless `--single-use-pairing`).
  The URL names `10.0.2.2:47616` (the Android emulator) and `127.0.0.1:47616`, or the `--host HOST:PORT`
  given. `--relay ws://127.0.0.1:8787` also opens the fixture's room on a local relay (`relay/`,
  `npx wrangler dev --local --port 8787`, no sign-in); `--relay-public ws://10.0.2.2:8787` is the relay address
  phones are told. `--approve-links` approves a link request (§12.1) three seconds after it arrives.
- The fixture's v2 tasks add a plan review, an answerable question, a suggested task, lines with details,
  and taking `createTask`, `setPinned` and `archiveTask`.
- Test vectors both implementations check (`Tests/NativeHarnessClientTests/Fixtures/RemoteNoiseVectors.json`,
  copied byte for byte into the phone app's tests): the public-domain cacophony vector for
  `Noise_IK_25519_ChaChaPoly_SHA256`, and a Yardlet vector with this protocol's prologue, a pairing
  payload, message 2's payload and a chunked transport message.
