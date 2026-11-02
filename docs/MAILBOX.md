# Mailbox

The mailbox shows the inboxes of the Gmail and Outlook Mail accounts connected in Settings › Connectors beside tasks and
personal agents, as a third word under Scheduled tasks: **Tasks · Personal agents · Mail**. Threads are
read in place, written to and answered there, and handed to an agent by name. Mail stays on the
service: the mailbox reads it when it is shown and keeps it in memory only.

## Turning it on and off

- Settings › General › **Mailbox**, off by default. While it is off the Mail word is not shown, nothing
  is read and nothing is watched.
- Turning it off stops the watch, closes what is open, forgets every list, thread, search and message
  being written in every window, and removes the history cursors (see "What is kept"). A window showing the mailbox goes back to
  its tasks. The Gmail connectors and their Keychain items stay; they belong to Settings › Connectors.
- Settings › Notifications › **New mail**, on by default and shown while the mailbox is on.

## Accounts

- Every Gmail and Outlook Mail connector that is connected is an account of the mailbox
  (`ConnectorCenter.mailAccounts`). The mailbox uses the connector's own sign-in and session
  (`OAuthAPISession`), so a token is refreshed one at a time for both and never leaves Yardlet. It asks for
  nothing beyond the connector's permissions: Gmail's `gmail.modify` (docs/CONNECTORS.md, "Google") and
  Graph's `Mail.ReadWrite` and `Mail.Send` (docs/CONNECTORS.md, "Microsoft 365").
- Each service is read the way it supports best: Gmail through the Gmail API, Microsoft 365 and
  Outlook.com through Microsoft Graph. The sections below say where the two differ.
- Connecting, disconnecting or removing a Gmail account in Settings › Connectors adds it to or removes
  it from the mailbox at once; what was read from a removed account is forgotten.

## What is kept

- In memory: each account's folders, the first page of each inbox, the folders a window opened, the
  last 30 threads opened, and a search's results until the search is cleared.
- On disk: only, per account, where its history was last read up to: the Gmail history ID, or Graph's
  inbox delta link with the time it was taken (`Yardlet.mailboxCursors` in Yardlet's defaults), so mail that came while Yardlet was closed is told once
  it opens. No subject, address or word of a message is written to disk or to the log.
- An HTML message's content rule list is compiled into the temporary folder, not the person's Library.

## The sidebar

- The list starts with **All inboxes**, every account's inbox newest first. An account with more to read
  ends at the oldest thread read of it, and other accounts' older threads wait until it is read that far
  too, so the list has no gap in time. A row shows an unread dot, the
  senders (the account itself as "me") and the number of messages, the time (today's time, this week's
  day, else the date), the subject (after an orange **Draft** when the thread holds one), and, with
  several accounts, the account before the first words.
- **‹ Mailboxes** over the list shows the accounts and their folders in the list's place, as Mail does on
  a narrow screen: All inboxes, then for each account its Inbox, Starred, Sent, Drafts, All Mail, Spam and
  Trash in the order and with the names of Gmail's web app, then its labels by name, nested labels
  indented. Labels hidden from Gmail's label list are left out. An Outlook account lists Inbox, Sent
  Items, Drafts, Archive (when it has one), Junk Email and Deleted Items as Outlook names them in the
  account's language, then its other top-level folders under **Folders**. Each account and each
  account's labels or folders fold. Unread counts come from Gmail for the inbox and spam; Drafts shows its count.
- Choosing a folder lists it, read from Gmail when it is not an inbox (`users.threads.list` with its
  label; All Mail with no label; Spam and Trash with `includeSpamTrash`). A list reads 50 threads at a
  time; as its end comes into view the next page is read from the page token Gmail gave. Reading the
  first page again after new mail keeps the threads read further down.
- Typing in **Search mail** narrows the list at once; a pause of 0.4 seconds, or Return, asks Gmail's own
  search (Gmail's search syntax) of the account listed, or of every account for All inboxes. Older mail is
  found this way rather than kept here.

## Outlook

- A thread is an Outlook conversation (`conversationId`): a folder's newest messages
  (`me/mailFolders/{id}/messages`, newest first, no body) are gathered into one line per conversation,
  and opening one reads its messages in every folder (`me/messages?$filter=conversationId eq …`) with
  their HTML and files. Search is Graph's (`$search`, KQL).
- Outlook keeps read state per message, so marking a thread read or unread changes each message that
  differs; Star flags the newest message and taking it away clears every flag; Archive, Not spam and Move
  out of the Trash move the conversation's messages in the inbox, Junk Email or Deleted Items.
- A reply, reply to all or forward starts from Graph's own (`createReply`, `createReplyAll`,
  `createForward`), which threads it and carries a forward's files; what was written then replaces its
  fields, as text. Chosen files are added once each, up to 3 MB a file.
- New mail: the inbox's delta query, begun over the last day's mail and followed to its `deltaLink`,
  every minute. Unread mail that came after the link was taken, not a draft and not in the Other inbox,
  is told. A link Graph no longer knows (410) starts again.
- **Open in Outlook** opens the newest message's `webLink` in the built-in browser. **Ask an agent** names
  the newest message and the connector's `get_message`.

## Reading

- Choosing a thread reads it in full (`users.threads.get`, `format=full`); lists read headers only
  (`format=metadata`). Opening an unread thread marks it read in Gmail too, as mail apps do
  (`MailReadSync`); the request goes on when another thread is chosen, and a change Gmail refuses takes
  back only that thread's change. Messages an agent reads through its tools stay as they are.
- Earlier messages fold to a line; the newest stays open. A message's HTML is drawn with page scripts off,
  no cookies or storage (a non-persistent data store), and nothing fetched from the network until
  **Show images** is chosen for that message, so a tracking pixel does not tell the sender it was read:
  a content rule blocks every `http` and `https` load, the page's policy allows only inline images and
  styles, and links that would connect ahead of time are taken out. If the rule cannot be made, the
  message's text is shown instead of its HTML.
  A chosen link opens as a link another app hands Yardlet does. The page is as tall as its content and
  scrolls with the thread. A message without HTML shows its text.
- The thread's bar: **Ask an agent**, Archive (in an inbox), Mark as read or unread, Star, and
  **Open in Gmail**, which opens the thread on Gmail's web app in the built-in browser
  (`AppModel.openExternalLinks`), signed in as the account (`authuser`).
- **Spam and Trash** are told apart: their folder symbols are red, their list says that Gmail deletes such
  mail after 30 days and draws its rows dimmer, and a thread read there says where it is across its top.
  Spam offers **Not spam** (back to the inbox) and Trash **Move out of the Trash** (`threads.untrash`)
  in Archive's place, and neither offers **Ask an agent**.

## Writing

- **New message**, **Reply**, **Reply All** and **Forward** write in the thread's place: To, Cc, Bcc
  (behind its button), Subject, files and the text. A reply is addressed as mail apps address one (the
  sender or Reply-To; for all, everyone else on the message but the account), its subject gets one
  `Re:`, and it carries `In-Reply-To` and `References` and the quoted original. A forward carries the
  original's files.
- What is written is saved to the account's Drafts ten seconds after the last change and when it is
  closed; saves run one after another, so a message is one draft. A message left as it was opened (a
  reply opened and closed) is not saved. **Discard** deletes that draft.
- **Send** waits five seconds, during which **Undo** takes the message back to the editor and Discard and
  Close are off. Then Undo goes and the message is on its way: it is saved if it changed, the draft is
  sent (`users.drafts.send`) and the thread is read again. A failure leaves the message open with why. The person's Send is the confirmation; an
  agent's sends still go through its harness's approval.
- A draft in a thread, the person's or an agent's, offers **Send**, **Edit** and **Discard**. Send on a
  draft shows it with Undo and sends it as it was saved, without saving it over, so a draft an agent
  wrote in HTML goes as it is. Edit continues it as text with its recipients, blind copies and files; a
  draft with files is replaced in place through the upload endpoint, its files read from it again.

## New mail

- While Yardlet runs and the mailbox is on, each account is asked every minute what changed in its inbox
  (`users.history.list` from the cursor, 2 quota units). No model is asked anything. A change reads that
  inbox's first page again, and the cursor moves on only once it was read, so what arrived is still told
  after a failed read. A cursor Gmail no longer has (a week or more old) reads the inbox again
  without telling anything. A failure waits twice as long each time, up to ten minutes; a refused sign-in
  shows on the account and stops its watch until the account answers a refresh again.
- Unread mail that came into the inbox, not sent or drafted by the account and in Gmail's Primary
  category, is told as a system notification through the same permission as task notifications: the
  sender (and the account with several) and the subject with its first words, or one count for more than
  three at once. Nothing is told while a window shows the mailbox and Yardlet is the active app; the Mail
  word is marked while no window has shown what came.
- Clicking a notification brings Yardlet forward and shows the thread in All inboxes.

## Agents

- **Ask an agent** starts a chat whose composer names the thread: its subject, sender, account, thread ID
  and the connector tool that reads it (`gmail_get_thread`). The message's words are not put in the
  prompt; the agent reads them with the account's Gmail connector, and the person writes what to do.
- Agents read and draft through the Gmail connector's tools as before (docs/CONNECTORS.md, "Google");
  the mailbox shows the drafts they make.

## Code

| Location | Contents |
|---|---|
| `Domain/Mail.swift`, `Domain/MailComposition.swift` | Accounts, folders, threads and messages; the transport contract (`MailAccountTransport`); addresses (`MailAddressList`); what is being written and how a reply or forward is addressed |
| `Connectors/GmailMailTransport.swift` | The Gmail API behind the contract: folders and labels, lists, threads, label changes, drafts, history |
| `Connectors/OutlookMailTransport.swift` | Microsoft Graph behind the contract: folders, conversations, per-message changes, replies from Graph's own, the inbox's delta |
| `Presentation/MailboxCenter.swift` | The app's mailbox (`MailboxCenter`: accounts, lists, opened threads, watch, writing) and a window's view of it (`MailWindowState`) |
| `Presentation/MailText.swift` | Names, subjects, times and the hand-off text |
| `AppModel+Mailbox.swift` | Following the setting and the connectors, notifications and their clicks |
| `Views/Mail/` | The sidebar (`MailSidebar`, `MailFolderTree`), the thread (`MailContent`, `MailThreadView`), HTML (`MailHTMLBody`) and writing (`MailComposeView`) |

Tests: `GmailMailTransportTests` and `OutlookMailTransportTests` (requests and answers against a fake Gmail and a
fake Graph), `MailboxCenterTests` (the
watch, sending, Undo and Drafts), `MailHTMLBodyTests` (no remote content before Show images) and
`MailboxRenderingTests` (the list, a thread, writing, the hand-off, the folders and spam, drawn under
`.build/mailbox-qa/` in both appearances at 1280×800 and 920×680).
