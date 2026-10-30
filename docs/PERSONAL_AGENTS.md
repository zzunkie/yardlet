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
replying to a message, answering approvals, pausing an agent and changing its
settings are not implemented.

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

## Provider boundary

Dots currently uses private ChatGPT service routes and a legacy authentication
broker method of the installed Codex runtime. They may change independently of
Yardlet. The runtime owns sign-in and token renewal; the transport keeps access
credentials in memory and never exposes them to the presentation layer or logs.
Requests use native URLSession with no cookies or browser process, no redirects,
and an account binding checked before results are displayed.

Opening or refreshing the section only reads and subscribes; it starts no model
turn. The room observer's registration sends nothing but the account's credential:
no message, approval, pause or resume. A person's explicit send can start cloud work on their existing dot. The
transport does not read authentication files, change the runtime's configuration,
copy credentials between account homes, or fabricate service-verification data.
Signed attachment downloads on provider storage hosts receive no account token.
Uploads go only to the dot's own room, after the room's identity and type are
checked again, with no upload URL, storage write or reservation.
Closing a preview removes only its temporary copy; a file the person saved stays.
