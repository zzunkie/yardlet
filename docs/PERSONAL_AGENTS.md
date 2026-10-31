# Personal agents

Below **Scheduled tasks** in the sidebar, the words **Tasks** and **Personal
agents** switch the list under them between your projects and tasks and your
existing cloud agents. Home, Scheduled tasks and the account button stay where they
are; task search is shown only with the tasks. Switching retains each
conversation's reading position, and the task list comes back scrolled and folded
as it was left, with the selected coding task, draft and panels unchanged.

The first provider is ChatGPT dots. The account the dots are read from heads the
agent list, as Projects heads the tasks; with several Codex accounts it is a menu
of them. Its runtime-owned ChatGPT login is used for Dots;
Yardlet does not create a dot or a coding session to represent it. An agent's
account, user, profile, messaging room and root coding thread are separate identities.

## Reading

The native conversation shows text and attachments, with the dot's picture. In the
agent list, the conversation's header and the dot's details, the picture is the
dot's pet moving as it does in the provider's app: the pet its profile names, read
from the account's pets, plays its idle motion, and its working motion while the
dot is at work (see "What the dot is doing" below). Beside each message and with
Reduce Motion on, the same pet holds the idle motion's first frame. Until the pet's sheet is
read, or without one, the picture is the still snapshot the profile names. Only a
sheet of the provider's known sizes is shown, and only its two rows the dot uses
are kept. The pet plays only while its window is on screen and uncovered, not
scrolled out of its list, and Yardlet is the active app; otherwise its layer
animation stops on a still frame. A pet that is gone, a sheet
that cannot be read and a sheet of another size leave the still snapshot; the next
connection reads the pet and its sheet again.

Pictures and sheets are read without the account credential from the provider's
signed storage, bounded in size, kept in memory only and dropped when the account
changes; until a picture arrives, or if it cannot be read, the dot's initial stands
in.

The conversation opens on the latest page of the room. Reaching its top reads the
next earlier page once, keeping the message you were reading in place; a failure
waits for **Try again**, and **Load earlier messages** reads another page by hand.
Yardlet does not download the whole history in advance, and reading sends no read
receipt. File attachments open in a native preview, with an explicit save action.
Other attachment types are named but cannot be opened here yet. Reacting,
pausing an agent and changing its settings are not implemented. Files and photos
are added from the composer, replies are read and sent in a dialog over it, and
approvals, forms and option questions are answered where the message asks them
(all below).

## Opening the dot where the provider shows it

**Open in Dots**, in the conversation's header, offers **Open This Dot on the Web**,
the dot's own page on the provider's website, and, where the provider's app is
installed, **Open Dots Home in ChatGPT**. The app takes only its Dots home, not a
particular dot, so the two are named for where they go. A message or attachment
Yardlet does not show yet has a link under it to the dot's page. Nothing is opened
until the person chooses it. The page opens as any web link in a conversation
does, in the Mac's default browser; the app is found by its identifier, wherever
it is installed. Either uses the sign-in its browser or app already has: no
credential is transferred and no destination account is switched. The app's current
account may be another than the one chosen in Yardlet. Opening confirms only that the address was
handed on; a failure says so under the conversation.

## Dot details

Beside the conversation, where the window has room, the dot's details show its
picture, name, account and whether it is paused; its **Activity**; its
**Scheduled** tasks; the **Computers** its root thread can use; and the
**Conversation attachments** of the messages loaded so far. In a narrower window
the conversation keeps its width and the details button in its header raises them
over it, below the header; their close button, the same header button or Escape
hides them again. Each part loads and fails on its own, so a part that cannot be read never
holds up the conversation; a changed account clears them all.

These parts only read. Activity is the dot's own task list, empty until it has
tasks; it is not the list of its execution threads. A computer being attached
means the dot may use it; it is shown as connected or offline only when the
provider says so. The attachments are the files in the loaded messages, not every
output the dot has produced. Nothing here starts work, connects a computer, runs a
schedule or changes the dot.

## Reading an Activity task

Choosing a task in **Activity** shows its execution record in place of the
conversation, in the same conversation view as a coding task, with no composer.
It only reads: it does not resume, stop, answer or start the task. Back returns
to the conversation where it was left: its scroll position, draft, attached files
and any answer being given stay, because the conversation stays under the task,
still and taking no input; uploads already under way carry on. A task opens only from the Activity the transport itself read
for that dot and account; no other thread is read.

The record arrives in two kinds of pages. The task's metadata never stands for its
turns. Opening reads the newest five turns, then the first hundred items of each,
one turn at a time. Earlier turns are read when the person scrolls to the top or
chooses **Load more history**; more of a turn's items when its work is shown and
the person chooses **Load more items**. A record is complete only when both the
earlier turns and every turn's items have run out. A page too large to carry is
asked for again from the same place with half as many items, down to one; past
that the turn says it is too large.

Failures stay where they happened. A task the provider no longer has says so and
is not shown as empty; a task with no turns says it has none. If some turns' items
cannot be read, the others show and a line above the record offers **Try again**;
an earlier page that fails keeps the turns read and its way back to them. A page
that repeats or omits its cursor, or names another thread or turn, is refused
rather than taken for the end. Items Yardlet cannot draw are named, not hidden.
The task ran on the provider's computer: its web links open, but paths and file
links name that computer's files and are never opened, shown in Finder or read
on this Mac.

The record is read when the task opens and when the person refreshes it; a task
that is still running does not update by itself. Its subagent threads are not
followed.

While the personal-agent section is open, a native WebSocket subscription
invalidates the displayed conversation when its room changes. Reconnection reads
the displayed range again, including edits, deletions and any missing pages.
Switching back to the tasks or closing the window stops the window's connection;
existing cloud work continues independently.

The reading cache is in memory only. It is scoped to the chosen runtime/account
connection. A changed login clears the old view and asks the person to reconnect.
No credentials, messages, provider history or browser profile are copied into the
Yardlet session index.

## What the dot is doing

While a window shows the personal agents, on screen and not covered, minimized or
hidden (another app being in front does not count), Yardlet observes the selected
dot's room as the provider's app does: it subscribes to the room's live topic on the
same WebSocket, and once that subscription is answered, registers an observer with
a request that carries no body. Only states bound to that registration are shown,
in increasing revision order. A malformed state, or one for another room, ends the
observation until the window asks again; a dropped connection, a temporary
unavailability, a timeout or a server error registers again after a wait that
doubles up to 30 seconds. Covering the window, choosing another dot, another
account and leaving the section end the observation, leave the topic and clear
what was shown. Reading and sending messages do not depend on it.

The pet plays its working motion only while the room's attached thread is working,
searching, creating, paying or thinking. Waiting for input, a failure, a finished
turn, a pause and no state at all show the idle motion; a message being sent or a
conversation being read is never taken for work. While the room's turn is active,
the conversation's header shows the provider's words for it; a paused dot shows
Paused. Yardlet reads no runtime from the dot's host, so it knows only what the
room says: a question the host is waiting on shows only if the room names it, and a
thread run on a local computer is judged by its room like any other. A dot's pause
is its profile as last read; once its room shows a turn under way, that pause no
longer stands until the profiles are read again. A changed login found by the
observer clears the view, as any read's does.

## Sending and drafts

Return or the send button sends the text the person wrote. The editor uses the
same input-method handling as the task composer. A confirmed send is displayed
separately until the conversation query includes it, so it cannot hide missing
history or move earlier messages out of order.

Drafts, their file copies and pending request identities are saved under
`~/.yardlet/personal-agent-drafts/`, separately from coding tasks. The key binds
the account home, account, user, dot and room. Changing the executable for the
same account home retains the draft. Files are private to the current OS user.
Unreadable draft files are preserved, and a failed save prevents a new send.

An uncertain delivery keeps the original text and request identity. Refreshing
can confirm it; an explicit retry uses the same provider idempotency token.
Restarting or switching accounts never retries a send automatically. If the
service requires additional verification, the attempt stops and the draft stays.

If delivery cannot be resolved, **Edit message** asks the person to acknowledge
that the earlier message may already have arrived, then returns the retained text
to the editor. This action sends nothing. An unreadable draft can be replaced
only after **Start a new draft** preserves its original bytes in a private backup
beside the draft file. Those backups remain until the person removes them.

Background changes to the coding-task index do not switch this section. Explicit
task navigation from a notification, the menu bar, the resource window or an
import sheet reveals Tasks, as does a link another app opens with Yardlet when it
shows in a task's browser panel; so does importing one conversation from the import
sheet, while a batch import from other apps leaves the window where it is. Back and
forward move through the task history only while Tasks is shown.

A coding task counts as seen only while at least one window shows Tasks. Each
window reports for itself, since all windows share one model: while every window
shows personal agents or is closed, the selected task's completion, failure or
approval request marks it unread and posts its notification as for any task in
the background. Coming back to Tasks marks the selected task read, and a side chat
on screen is marked read when it shows again.

## Files and photos

The **+** button, a paste or a drop on the composer adds files and photos to the
dot's draft, up to 8 in a message and each of 1 byte to 20 MiB, as the provider's
composer allows. A room the provider marks as only shared with the person, or
waiting on a message request, takes no files; the button and drops are off there.
Each file is copied into the draft's folder when it is added, and only that copy
is read afterwards: the original is never moved, changed or deleted. A photo shows
as a thumbnail and any other file by its name, with a spinner while it uploads and
a mark when it did not. **Retry upload** tries the failed files again; removing a
file stops its upload in Yardlet and deletes the copy, and nothing is deleted on
the provider.

Each file goes to the dot's room as one ordinary upload, and the message names the
returned file IDs. Before upload, photos are prepared as the provider's composer
prepares them: HEIC, HEIF, MPO and AVIF become JPEG under the same name, and a
picture larger than 2048 pixels on a side or 1 MiB is redrawn at most 2048 pixels
on its long side. The redrawn picture is upright and leaves out the original's
metadata and any later frames; a type this Mac cannot write is sent as it is.

A message may be files alone. Pressing Send while files upload sends the text and
files as they were at that moment once the uploads finish; the editor waits
meanwhile. A file that did not upload stops the send and is never left out
silently. A message whose delivery is uncertain keeps its words, file IDs and
request identity, so a retry sends exactly the same message and uploads nothing
again. Files picked for one dot or account never join another's draft, and a
changed account stops the uploads in progress.

The draft remembers each file's copy and, once uploaded, its file ID. After a
restart, files that had not finished uploading come back marked as not uploaded
and wait for **Retry upload**; nothing uploads by itself. A file whose copy was
made while the draft could not be saved is kept and comes back the same way. A
draft without files is saved in the same format as before. The copies are deleted
when the message that carried them is confirmed or the file is removed.

Uploading and sending files act on the provider account. Their behavior here was
checked with synthetic responses, not against the provider.

## Replies

A message of the room offers **Reply** in its context menu. A reply in the room
shows a line of the message it answers above it, unless the message before it is
of the same thread; a message with replies shows **View replies** under it, or
their number when it can be counted. Choosing any of these opens the **Replies**
dialog over the conversation, anchored on the composer, as the provider's app shows
it: the thread's first message, when it is known, then its replies. A thread is the
chain back to its first message, so a reply to a reply answers that reply while it
belongs to the same thread. The dialog reads the thread's own pages
(`GET …/messages?reply_root_message_id=…`), the latest first and earlier ones as its
top comes into view, apart from the room's; a thread whose page names no earlier
cursor has no earlier replies, and a repeated cursor ends it too. A failed page waits
for **Try again**. While the room's subscription reports a change, the open thread
is read again from its latest page back to the earliest reply read before, so a change
to any reply shown is seen; a failure keeps what is shown and offers **Try again**.
Nothing polls, and what a page leaves out is never taken as deleted. The room, the
thread and a message's card all show the same read of a message, and a reply whose
delivery was uncertain counts as arrived once any read shows it under its request.

A count is a number only while the room's loaded history reaches from that message
to the latest one and no reply to it is waiting to be sent or confirmed; otherwise
**View replies** says nothing about how many there are. A message deleted since it
was quoted shows as deleted, even where the reply embedded its earlier words. When
two reads of a message disagree, a deletion stands, then the provider's later change,
then the read that started later.

The dialog's composer is the conversation's own, with the same draft, files and
upload state; opening, closing or switching threads moves nothing between drafts,
and the room behind keeps its place. Its close button, a click outside it and Escape
close it; an Escape an input method takes while composing does not. Closed by its
button or Escape, it gives focus back where it was; a click outside leaves focus with
what the click chose. Opening it puts the caret after the draft rather than selecting
it. A long thread draws only the replies in view and reads its earlier replies when its
top comes into view, keeping the reply being read in place, also when that reply
becomes shorter than where the view started in it; a new reply moves it to
its end only while the person reads there, and otherwise offers **New replies**. Send from the dialog fixes the message it replies to at that
moment: closing the dialog or opening another thread while files finish uploading
does not change it, and an uncertain reply is retried only by the person, with the
same words, files, target and request identity. Such a pending reply is saved in a
draft format earlier versions cannot read: they send nothing from it and keep the
editor locked until the person chooses **Start a new draft**, which keeps the saved
draft as a backup, so it is never sent as an ordinary message. A reply carries only
`reply_to.message_id`.
A room only shared with the person, or waiting on a message request, takes no reply,
as it takes no file; its threads can still be read.

Replying acts on the provider account. It was checked with synthetic responses, not
against the provider.

## Requests and questions

A dot's message can carry an input request (`content.elicitation`). Yardlet keeps it
as the provider sent it and shows a card in that message, in the same form as a coding
task's request card. A request is answered only through its card; an ordinary reply in
the conversation never stands in for it. The request is classified in the provider's
own order of checks:

- **Approvals.** An empty form that says what it asks (a nonblank message) is a plain
  approval: Allow, Deny (sent as `decline`) and Cancel. A connector's tool call
  (`codex_approval_kind` `mcp_tool_call`, with an empty form and the metadata the
  provider's schema requires) shows the tool, its parameters as the provider lists
  them and the full parameters on request. Denying it sends `cancel` with
  `_meta.codex_approval_cancellation_reason` `user`, as the provider's own client does.
  **Always allow** and **Allow this conversation** appear only for the scopes
  (`persist`) the request offers. A browser approval with an origin and offered scopes
  is shown the same way.
- **One database change.** A sites database delete, insert or update is allowed only
  when its confirmation summary is the provider's canonical form of a valid change
  bound to its row, at most 500 characters. It is allowed once and never remembered,
  even when a scope is offered. If the summary cannot be checked, Allow stays off.
- **Forms.** A form (mode `form` or none) is filled in with the same strict field rules
  as a coding task's MCP form: text, numbers, switches and single or multiple choices,
  each checked before Submit turns on. The two OpenAI form modes are taken only when
  their schema is that same strict subset with no extensions or confirmation. A field
  Yardlet does not check, such as a nested object, an extension or a confirmation makes
  the form one it cannot answer; the unknown parts are never dropped to submit the rest. A browser sign-in request is
  recognized before any form mode, as the provider's client does, and only in form mode.
  As a limit of this first version, rather than the provider's behavior, an OpenAI form
  that names any approval kind (`codex_approval_kind`) is not answered here.
- **Not answered here.** Tool setup suggestions, sign-in and other links, sign-ins in the
  dot's browser, email codes, location, payment setup, device verification, approval
  kinds Yardlet does not know and tool metadata the schema does not take are shown
  with the provider's words, a reason and **Open This Dot on the Web**. Yardlet sends
  no answer for them, and never answers an unknown approval as an empty form.

Before an answer is sent, Yardlet reads the request again
(`GET …/messages/{message}/elicitation?inspect=true`). It sends only if the provider
still describes exactly the request the message showed (request, thread, turn and
parameters), says it can be answered and is pending, and gives a request fingerprint.
It then claims the request in a journal shared by every window and account home of
the current macOS user, in `~/.yardlet/personal-agent-responses/`. The journal's key is
the account, user, room, thread, turn and request; it keeps only whether an answer was
claimed and, once applied, its fingerprint, action and scope, never form values. A
request with a record is not answered again, and a journal that cannot be written
blocks the answer.

The answer (`POST …/elicitation/response` with the fingerprint and
`{action, content, _meta}`) is sent once and never retried, for every kind including the
OpenAI form modes; this is Yardlet's own choice. The login may be renewed and the
account is checked before it leaves. A failure up to then releases the claim, and the
card says the answer was not sent. From the moment the request is handed to the
network, any outcome other than an `applied` status keeps the claim: an expired login,
a rejection, a server error, a lost connection or a changed account. The card then
reads **Status unknown** with **Check status**, which reads the request and the
journal again and sends nothing. The same holds after a restart or in another window.
When the provider says the request was resolved or expired, or its acknowledgement
matches, the card closes and the record stays.

Requests are read again after the conversation is read: when it opens, on refresh and
after a change the room's subscription reports. Reads of one request are coalesced,
and nothing polls.

An option question (`message_metadata.option_picker`) shows its options under the
message, in the room or in a reply thread. Choosing one first reads again, in that
moment, where the question and its answers are: the displayed range of the
conversation for a question there, and the reply thread it belongs to, or heads,
from its latest page back to the question. The question must still be there,
undeleted, with the same option text and no answer, or nothing is sent; a read that
fails sends nothing either. The answer is an ordinary reply
to the question carrying the option's exact text and
`message_metadata.option_picker.selection`. It is kept with its request identity beside
the draft, apart from the draft and its text, which stay as they were. If delivery is
uncertain, only **Send the same answer again** with the same request identity, or
**Stop waiting** after confirming that it may have arrived, continues. Sending again
checks the question as choosing did, in the thread it was first read in. An answer
to a question in a thread is saved in a format earlier versions cannot read: they
send nothing and lock the options until the person keeps it as a backup, rather than
check it against the room alone. If the question is deleted or loses its options
meanwhile, a line above the editor says an answer could not be confirmed and offers
**Stop waiting**, without showing the question; until then other questions wait.
An answer that cannot be saved is not sent, and the same line says so, with **Try
again** to save without sending. A saved answer that cannot be read locks the options
until the person keeps it as a backup: its bytes are copied to a private file beside
it, and then the waiting record itself is removed. Each confirmation to stop waiting
names the answer it was asked for and lets no later answer go.

These answers act on the provider account. Their behavior here was checked with
synthetic responses, not against the provider, and the response statuses other than
`applied` are not known in full.

## Provider boundary

Dots currently uses private ChatGPT service routes and a legacy authentication
broker method of the installed Codex runtime. They may change independently of
Yardlet. The runtime owns sign-in and token renewal; the transport keeps access
credentials in memory and never exposes them to the presentation layer or logs.
Requests use native URLSession with no cookies or browser process, no redirects,
and an account binding checked before results are displayed. An Activity task's
record is read with GET requests from the provider's execution-history host, the
only other host that receives the account credential; each request names the
thread's product as the provider's app does, as a label and never as a permission.

Opening or refreshing the section, or an Activity task, only reads and subscribes;
it starts no model turn. The room observer's registration sends nothing but the account's credential:
no message, approval, pause or resume. A person's explicit send or answer can start cloud work on their existing dot. The
transport does not read authentication files, change the runtime's configuration,
copy credentials between account homes, or fabricate service-verification data.
Signed attachment downloads on provider storage hosts receive no account token.
Uploads go only to the dot's own room, after the room's identity and type are
checked again, with no upload URL, storage write or reservation.
Closing a preview removes only its temporary copy; a file the person saved stays.
