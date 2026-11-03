# Yardlet Remote Protocol

Status: the contract (protocol 2; protocol 1 has been removed, §1). The Mac side (Yardlet) implements it in `Sources/YardletRemote` and
`Sources/NativeHarnessClient/Remote`; the phone apps implement the client side against this file; the relay
in `relay/` implements §14. The design is in [REMOTE_V2_DESIGN](REMOTE_V2_DESIGN.md).

A phone watches and drives the tasks running in Yardlet on the person's Mac: it lists projects and tasks
with the sidebar's attention states, reads a task's conversation (latest first, older on scroll, live while
it streams), sends a message to a task, answers a pending approval (allow once or deny), stops a running
turn, and marks a task read. It also answers questions and plan reviews, starting a task (on a
harness, model and worktree the phone picks), images, a line's output and diffs, suggested and queued messages,
continuing a task a plan limit stopped under another account, answering a browser handoff, seeing and using a
task's browser tab (§15.25), push notifications, and a task's model, effort and permission mode, slash commands,
edit and fork (§15.23). Nothing else: no app settings, connectors, file browsing or terminals. Yardlet on another
computer is a client of the same protocol, as a phone is (§18).

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
local audit log with its type, task ID (or schedule ID, §15.21), device and result — never the message text. `ok: true`
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
- `text` ≤ 16,000 characters. `imageCount`: attached images (not sent). `scheduled: true`: a schedule
  sent it, a Codex automation unless `sender` says otherwise. `shell: true`: a Claude Code bash command
  (`text` is the command). `diffCommentCount`: diff comments attached on the Mac (their text is not sent).
- `sender`: someone other than the person sent it, and `text` is their words, which the Mac draws apart from the
  person's own messages: another task's message, `{"kind": "task", "name": "Fix the footer", "relation": "parent",
  "quotes": [{"text": "…", "sentAt": "2026-11-03T09:12:00+09:00"}]}` (`relation` `task`, `parent`, the task this one
  was started from, or `itself`, through a schedule its agent made; `quotes`, the person's own messages it passed on,
  each ≤ 16,000 characters);
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
- `words` (optional, since 2026-11-03): the same line in parts, one entry per line the Mac draws (a command the
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
- `message` (≤ 1,000, optional, since 2026-11-03): the provider's own words the Mac's card shows above its form or
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
  they are decrypted, at most 512 frames and 16 MiB of a connection's wait, past which it closes (4429) too. A browser
  tab's input waiting behind a slow page counts apart: at most 32 per connection (§15.25).

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
| `busy` | the task cannot take it now (editing, switching account, held by another app), or a run of the schedule is starting |
| `rateLimited` | over the rate limit, or a device's file budget (§15.22) |
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
    signed in, and I'm done answers the handoff. Thirty seconds after an answer the page signs out and the handoff
    comes back.

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
- 2026-11-02, v2 only: scheduled tasks, Run now, Pause and Resume, and their change event (§15.21); a task's outputs
  and the files in its folders (§15.22).
- 2026-11-03: `presence` and held pushes (§16, §18).
- 2026-11-03: a line's words in parts, `words` (§6.4), and a choice's catalog key, `text` (§15.19). Later the same day:
  a subscription's full detail (§15.24), with the snapshot's `fullConversation`; a `conversation` event's changes may
  come in several events in a row (§5.3, §15.24).
- 2026-11-03: a request's own words, `message` (§6.5), which the Mac's card shows above an MCP form's fields.
- 2026-11-03: `sender` (§6.2) in every subscription, not only in full detail: who sent a message that is not the
  person's, another task, a background command's notice or Claude Code's own schedule.
- 2026-11-02, a rule restated: `parentTaskId` (§4.1) is the task the Mac's sidebar draws the task under, so a task
  whose parent is in another list, pinned apart or in a split view comes without one, as the sidebar lists it.
  Before, it was the task it was started from whenever that task was listed anywhere.
- 2026-11-03, timings and a rule: the Mac pings the relay every 15 s instead of 30 s and gives up on it after 45 s
  instead of 90 s, and opens its room again at once after it stayed open (§14.2); a phone whose connection was up
  and closes with 4404, 4409 or no code tries again quietly for about 10 s (§14.3).
- 2026-11-03, v2 only: a task's settings, slash commands, Edit message and Fork from here, and their change event
  (§15.23).
- 2026-11-03, v2 only: a task's browser tabs, a watched tab's frames and the person's input to it (§15.25), and `tabId`
  on a browser handoff's item (§15.18). A limit on the messages the Mac holds unhandled per connection and in all (§7).
- 2026-11-03: `announces` (§5.2) on a finish the Mac does not announce itself, which pushes (§16) no longer ring for;
  `createTask` takes `"chats"` before the snapshot lists Chats (§15.5).

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

Settings › Remote › "Pair a device" shows a QR code holding the link below, and Copy link puts the same link on
the clipboard for Yardlet on another computer (§18):

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
7. The Mac sends the text `ping` every 15 s and the relay answers `pong` without waking the room. A way to the
   relay can die without a word (the next `ping` is then answered by a reset), so the pings are what find it. The Mac
   reconnects when no `pong` came for 45 s and whenever its socket ends: within a quarter of a second when the room
   had stayed open for 10 s, since every phone of the room is waiting, then after 1, 2, 4 … 32 s while attempts fail.
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

- Starts a task as the Mac's new-task composer would with that project (or Chats, `projectId` `"chats"`, which
  the Mac takes whether or not its snapshot lists Chats yet) chosen and the text typed: its harness, model, account and worktree setting as they are now on the Mac. The new task is listed
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
- `settings`: the new-task screen's model menu (model, effort) and, where the harness starts in one, its
  permission (Claude Code's `permissionMode`, Codex's `runLocation`), each with its value now and its choices. Choices
  the Mac asks to confirm (Bypass permissions, full access) are left out. When the Mac has not read the harness's model list for this account yet it reads it
  first, as opening the menu does (up to about 10 s); until then the menu holds only the value now.
- `worktree`: present for a project in a Git repository, whether the Mac starts its tasks there in a new
  worktree now.
- `createTask` takes `harness`, `settings` (`{"model": "gpt-6", "reasoningEffort": "high"}`, ids and values from
  this answer; the Mac applies them in the order its answer lists them, as picking them in its menus would),
  `worktree` and `images` (§15.14). They apply to
  this task only; the Mac's new-task composer keeps its own choices. Errors: `notAllowed` (a harness, setting or
  value the Mac does not offer now).

### 15.17 Plan limits

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
- Since 2026-11-03 the item carries `tabId`, the handed tab, which `watchTab` shows (§15.25); absent when the Mac
  does not know which of the task's tabs it is.
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
- Since 2026-11-03 a choice Yardlet worded itself also carries `text`, the Mac's catalog key `title` was made from
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
  sentence the form asks with, which the Mac's card shows above the fields, is the item's `message` (§6.5). The
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

### 15.21 Scheduled tasks

Added on 2026-11-02. The phone lists the Mac's scheduled tasks (Yardlet's own, the Mac's Scheduled tasks list), runs
one now and pauses or resumes one, through the same paths as the Mac's Run now, Pause and Resume. Creating, editing
and deleting schedules stay on the Mac.

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
  absent before its first: `at`, `outcome` (`started`, `skipped`, `failed`; unknown values are read as `failed`),
  `taskId` when the run started or continued a task the snapshot lists, and `line`, the Mac's own line for it in
  the Mac's language: when it ran, and for a skip or a failed start why, as the run history says it ("Last run
  today at 9:00 AM · Skipped: the previous run is still going"). The session schedules a Claude Code task's CLI
  holds are not listed. Not a command. Errors: `unavailable`.
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

Added on 2026-11-02. The phone opens what a task made: the files the Mac's Outputs card lists, and a file in the
task's own folders that the conversation names. Until now files went only from the phone to the Mac (§15.20).

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
  its patch was applied, not while it waits or when it was declined or failed. `size` is absent for a file that is
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
  and only when it is one of the task's outputs (above) or, once symbolic links are resolved, lies inside one of the
  task's own folders (its working folder or worktree and the project's other folders, as the task was given them),
  by whole path components compared byte for byte. An output is the file in its own place: its folder's links are
  followed, but a symbolic link put where it was is not. Nothing a request names is looked up before its path, by
  its text, is one of the outputs or under one of the folders. A folder that is the Mac's home folder or holds it
  (`/`, `/Users`, by any path, `/System/Volumes/Data/Users` too) gives no files of its own: a task there serves
  only its outputs. Anything else is refused, the same for a file that does not exist, so the phone learns nothing
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

Added on 2026-11-03. Another device changes an existing task the way the Mac's task composer and turns do: the model,
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
  `permission`, and `model`, `effort` and `speed`, which share the model menu. Absent roles are left out of the row,
  and a role a phone does not know is skipped. `elevated: true`: the value now lifts the sandbox or skips asking (the
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
  offer now, a setting that still has `prepare`, or a choice with `confirm` without `confirmed`).
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
  Claude Code's `/compact` and `/clear`; the Codex app's Compact, Fork chat, New chat, Plan mode and its speed
  (`service-tier:…`). Commands that change files, settings or accounts, need a window of the Mac's (code review,
  rename, a side chat, status), or are the sidebar's (pin, archive, §15.10) are not listed, nor are a Codex task's
  skills. `title` is the list's own name for a command where it shows one in place of `/name`; `group` its heading;
  `argumentHint` the words it takes after its name, absent when it takes none. `runs: true`: choosing it runs it at
  once (the Codex app's); otherwise choosing it types `/name ` into the draft, and sending that draft runs it. Not a
  command. Errors: `notFound`.
- ```json
  {"id": "43", "type": "runComposerCommand", "taskId": "4C1F…", "command": "compact", "arguments": "Keep the API notes"}
  ```

  A command: runs it as the Mac's composer does. `arguments` (≤ 4,000 characters) only for a command with an
  `argumentHint`. A command that starts a task (`clear`, `new`, `fork`) answers with its `taskId`, listed before the
  answer as a new task is (§15.5); the Mac's window does not switch to it. `compact`, `clear` and `new` wait for the
  task's turn to end, as on the Mac. Errors: `notFound`, `notAllowed` (not listed now, or `arguments` it does not take),
  `busy` (a turn runs, the task is changing, or another app holds it), `tooLarge`, `unavailable` (the task's folder is
  gone), `internal` (the new task did not start).
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
  edit now, or the provider refused it; `message` says why), `busy` (a message is being edited on the Mac, messages
  wait in the task's queue, or the task is changing), `emptyMessage`, `tooLarge`, `unsupportedCommand`.
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

Added on 2026-11-03. Yardlet on another computer (§18) draws a task's conversation with the Mac's own cards, and asks
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
  button takes.
- **`compaction`** on a `notice` item that is a context compaction: `{"phase": "completed", "tokensBefore": 180000,
  "tokensAfter": 42000}`, `phase` `started`, `completed` or `failed` with the provider's `message`.
- **`providerNotice`** on a `notice` item a provider sent beside a turn: `{"kind": "modelRerouted", "message": "gpt-5.5",
  "fromModel": "gpt-6", "reason": "highRiskCyberActivity"}`; `kind` `modelRerouted`, `warning`, `configWarning` or
  `deprecationNotice`, with `details` and a config file's `path` when it names one. A client words it itself.
- **`schedule`** on the `activity` item of a schedule an agent created (§15.21): `{"id": "6B0E…", "name": "Morning
  check"}`, the schedule's ID and the name the call gave.
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

Added on 2026-11-03. The phone sees a task's browser tab and uses it, for a step only the person can take while away: a
sign-in, a two-factor code, an approval button, often the tab a browser handoff (§15.18) gave them. The Mac sends
pictures of the tab's visible page while the phone watches it, and the phone's taps, scrolling and typing go to the
page as the Mac's own browser panel sends the person's. Opening other addresses, other tabs or the Mac's own browsing
stays on the Mac.

- The snapshot carries `browserTabs: true` when the Mac answers the requests below (it has a browser engine). A phone
  offers a task's browser only then.
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
  it the tab keeps the size it has (Yardlet on another computer sends none). One watch per connection: watching another
  tab or task replaces it. A tab's fields: `tabId` (the side-panel tab; it stays when the
  tab's page is opened again in its place), `title`, `url` (only its origin while the address carries a value the
  password manager filled), `active`, `loading`, `canGoBack`, `canGoForward`, `waiting` (what the tab waits on from the
  person, the most pressing: `handoff`, `passkey`, `signIn`, `permission`, `externalApp`, `javaScriptDialog`,
  `fileChooser`), `requestId` and `reason` (the handoff's, §15.18), `passwordField` (the page's focused field is a
  password field). Not a command. Errors: `notFound` (no such task, or no such tab of it), `unavailable` (no browser
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
  Every other Meta or Control combination (the clipboard's in any spelling, the browser's own keys, the developer
  tools'), Insert and the function keys are `notAllowed`: the Mac's clipboard and windows are not the person's, so their
  own text comes as `text`. A connection's input goes to the page in the order sent, apart from its other requests
  (`unwatchTab` does not wait for it); at most 32 of its inputs wait at once (more is `rateLimited`); input whose watch
  ended meanwhile sends nothing more, and each step is checked again just before it goes: an input's steps go to the
  page its first step was checked on, and none after the page moved, even away and back to the same address. Not a
  command. Errors: `badRequest` (a field missing, out of range or not the kind's, an unknown key or one past its bytes),
  `tooLarge` (text), `notFound` (the tab closed), `notAllowed` (not the watched tab, or its watch ended; a passkey or
  site sign-in window, one whose tab Chromium does not name, or a page's dialog is up, which the person answers on the
  Mac; a key or button that is not taken; a `file:` page outside the task's files, in the page or any of its frames;
  the page or one of its frames moved while the input went), `rateLimited`,
  `unavailable` (the page did not answer, or a password field could not be protected, below).
- `{"type": "unwatchTab", "taskId": "4C1F…"}`: stops the watch. Closing the connection, removing the device, the remote
  turning off and the tab closing stop it too, input under way included. Not a command.
- **What the Mac does:** only the listed task's own tabs, as its side panel and the agent's browser tools see them;
  never another task's or the Mac's own browsing. A watched tab paints while it is watched, as one a panel shows on
  screen, and goes back to how it was (hidden, and later let go by the memory saver) when no one watches it. A phone's
  `viewport` draws it at that size while the phone watches (the smaller when two ask; sizes asked while another change
  of the tab's size runs make one change, the latest), and after the last such watch the tab takes the size and
  emulation it had before: the person's from the panel, the agent's while its turn goes on, else its own. The tab the
  Mac's panel shows does not change. Input counts as the person's in that tab, as the panel's does: the memory saver
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
  would serve it, or it is a folder inside the task's folders (§15.22), as the agent's tools hold them. It is checked
  for the very page pictured or driven: a picture during which the page or one of its frames moved, even away and back
  to the same address, is not sent. Another is listed as `file://`, without its title, and the page the tab moves to
  next shows no title until it names itself. Pictures show the page as it draws itself (a password field as dots) and
  are made only while watched; the Mac keeps none. The audit log (§4.4) records each `watchTab` and, at most once a
  minute per device, task, kind and result, a `tabInput`'s kind (`click`, `text`, …), never what was typed. Chromium's
  own windows (a passkey, a site's sign-in), macOS prompts and a page's dialogs stay on the Mac; while one is up, the
  tab's `waiting` says so.
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
    above the picture, as the Mac's panel does. With another `waiting`, say what waits on the Mac (§15.19's
    "Steps that are not requests").

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

Yardlet on another Mac follows a Mac's tasks over this protocol, unchanged: File › Connect to Mac… pairs with a
link from §12 (copied on the host, pasted or opened as a `yardlet-remote` link; nothing pairs until the person
chooses Connect), and each paired host opens in a window of its own. The host lists it among its devices with the
`platform` `macos` it sends in message 1, and removes it as it removes a phone.

- **In its own words:** it draws a line's `words` as the Mac does, its verb muted (§6.4), and a choice's `text` in its
  own language when its catalog has the key (§15.19), so two Macs set to different languages each read the card in
  their own.
- **Its window:** Yardlet's own window shell and sidebar, read from the snapshot as the host's sidebar lists it: Home,
  Scheduled tasks, the search (on titles and project names; a conversation's words stay on the host), Pinned, the
  projects with their collapsing and "Show more", Chats, the nested tasks and each row's mark, the activity view, the
  title bar's buttons and a hidden sidebar, and in place of the account button the host's name and how it is reached.
  The Task and View menus and their keys act on it as on the local window (new task, previous and next task, the next
  one needing attention, Pin, Archive, the sidebar, the activity view, Find in the conversation). What the host does not
  take from another device yet (rename, mark as unread, move, nest, delete, the projects' own actions, the archived
  list) shows dimmed.
- **What it does:** what a phone does (§4–§6, §15), on a larger screen: the host's sidebar and its marks, a task's
  conversation in Yardlet's own timeline with the host's own cards from its full detail (§15.24: whole answers, a
  message's pictures, subagents, compactions, notices, proposed plans and the limit card with its windows and
  actions), a line's output and diffs when it opens (§15.8), every answer the host's
  card gives (§15.19; one that leaves a rule behind is asked about once more), an MCP form filled in on Yardlet's
  own form card and sent with the host's Submit and its `values`, questions and plan reviews, the queue's actions,
  the plan limit's actions, Stop, Pin and Archive, new tasks with the host's choices (§15.16), and pictures and
  files (§15.14, §15.20). A suggested task draws as Yardlet's own chip, whose Start, Do it here and ✕ are
  `actOnSuggestion` (§15.9); what it starts with stays the host's. When the snapshot says so, the sidebar lists the
  host's scheduled tasks with Run now, Pause and Resume (§15.21), and a task's session rail shows its Outputs card
  (§15.22). An output, or a file a conversation's link names, is read with `readFile` into a folder of its own in
  this Mac's temporary folder, readable only by the person, and opened there in Quick Look (from the output's
  menu, in its own app or Finder); the copies go when the window closes. A file link never opens the same path on
  this Mac. From a host that offers them (§15.23), the task's model, effort and permission mode show in the
  composer's own controls (a choice the host asks about first is asked about here too), the slash commands that may
  run from here in "+" and a typed `/` list, and a turn's Edit message and Fork from here. A task's browser (§15.25)
  shows in a side panel where the host's window has the task's browser panel: the task's tabs in the panel's strip,
  Back, Forward and Reload, the handoff's bar, and the watched tab's page, which takes clicks, drags, the trackpad,
  keys and the input method's committed text (what it is still composing shows on the client until committed; ⌘V
  types the client's own clipboard; secure keyboard entry is on while the page's password field has the keyboard); it
  sends no `viewport`, so the tab keeps its size. A handoff's card has Show Tab, which opens it there. Settings,
  connectors, the context ring, creating or editing a schedule, the other side panels, opening addresses and closing
  tabs stay on the host.
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
  relay room and device ID; removed with the last host), one Keychain item per host for its private key, and what
  each host's window last showed, in `~/Library/Caches/<bundle identifier>/remote/<host>/` (folder 0700, files
  0600): the snapshot's projects and tasks, and the latest page of each conversation open last (at most 6, each cut
  to the size of Yardlet's first page, §4.2: 10 whole turns, 120 items, about 384 KB), and the words of its unsent
  drafts (`drafts.json`, kept a moment after typing stops and when the window closes). Reopening the window shows
  them at once, before it connects; the snapshot and subscriptions replace them once it does. The cache is written a
  moment after changes stop (at least every 10 s while they go on) and when the window closes, a conversation only
  when it changed. Nothing listens and nothing runs while no host window is open. Removing a host sends
  `forgetDevice` (§15.6) when the host can be reached and deletes all three; a cache folder whose host is no longer
  saved is removed when Yardlet starts.
- **Notifications:** while a host's window is open, a task that starts waiting, finishes or fails posts a notification
  named after the host, which opens the task there. A finish with `announces: false` (§5.2) posts none, and a task
  that stops waiting takes its notification back, as the host's own notifications do. An approval's offers "Allow once", sent as `answerApproval`
  `allowOnce` (§4.4): the host answers with its card's narrowest allow, as its own notification does, and where it
  does not take it the notification opens the task.
- **In use:** a host whose snapshot carries `presence: true` takes `{"type": "presence", "active": true}` (or `false`);
  the answer is `ok`. The client says `true` while the host's window is in front and the person typed, clicked or
  moved the pointer in the last two minutes, and `false` once not, telling only a change and again after each new
  connection. Meanwhile the Mac holds the phones' attention pushes (§16), as Claude Code's remote control does not push
  to a phone while the person watches the terminal. Not a command; a connection's presence ends with it.
- **Host settings:** Settings › Remote's "Keep this Mac awake on power" (off unless turned on) holds off idle sleep
  while remote connections are allowed and the Mac is on power, so a device elsewhere can reach it.

