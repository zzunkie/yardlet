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
from the account's pets, plays its idle motion. Beside each message and with Reduce
Motion on, the same pet holds the motion's first frame. Until the pet's sheet is
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
Other attachment types are named but cannot be opened here yet. Uploading
attachments, reacting, answering approvals, pausing an agent and changing its
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

## Sending and drafts

Return or the send button sends the text the person wrote. The editor uses the
same input-method handling as the task composer. A confirmed send is displayed
separately until the conversation query includes it, so it cannot hide missing
history or move earlier messages out of order.

Drafts and pending request identities are saved under
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

## Provider boundary

Dots currently uses private ChatGPT service routes and a legacy authentication
broker method of the installed Codex runtime. They may change independently of
Yardlet. The runtime owns sign-in and token renewal; the transport keeps access
credentials in memory and never exposes them to the presentation layer or logs.
Requests use native URLSession with no cookies or browser process, no redirects,
and an account binding checked before results are displayed.

Opening or refreshing the section only reads and subscribes; it starts no model
turn. A person's explicit send can start cloud work on their existing dot. The
transport does not read authentication files, change the runtime's configuration,
copy credentials between account homes, or fabricate service-verification data.
Signed attachment downloads on provider storage hosts receive no account token.
Closing a preview removes only its temporary copy; a file the person saved stays.
