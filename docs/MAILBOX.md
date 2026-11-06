# Mailbox

The mailbox shows the inboxes of the Gmail, Outlook Mail and IMAP mail accounts connected in Settings › Connectors beside tasks and
personal agents, as a third word under Scheduled tasks: **Tasks · Personal agents · Mail**. Threads are
read in place, written to and answered there, and handed to an agent by name. Mail stays on the
service: the mailbox reads it when it is shown and keeps it in memory only.

## Turning it on and off

- Settings › General › **Mailbox**, off by default. While it is off the Mail word is not shown, nothing
  is read and nothing is watched.
- Turning it off stops the watch, closes what is open (the mailbox's browser panel and its pages too), forgets
  every list, thread, search and message being written in every window, and removes the history cursors (see
  "What is kept"). A window showing the mailbox goes back to
  its tasks. The mail connectors and their Keychain items stay; they belong to Settings › Connectors.
- Settings › Notifications › **New mail**, on by default and shown while the mailbox is on.

## Accounts

- Every Gmail, Outlook Mail and Mail (IMAP) connector that is connected is an account of the mailbox
  (`ConnectorCenter.mailAccounts`). The mailbox uses the connector's own sign-in and session
  (`OAuthAPISession`), so a token is refreshed one at a time for both and never leaves Yardlet. It asks for
  nothing beyond the connector's permissions: Gmail's `gmail.modify` (docs/CONNECTORS.md, "Google") and
  Graph's `Mail.ReadWrite` and `Mail.Send` (docs/CONNECTORS.md, "Microsoft 365").
- Each service is read the way it supports best: Gmail through the Gmail API, Microsoft 365 and
  Outlook.com through Microsoft Graph, and every other service over IMAP and SMTP with an app password
  (see "Mail accounts over IMAP"). The sections below say where they differ.
- Connecting, disconnecting or removing a Gmail account in Settings › Connectors adds it to or removes
  it from the mailbox at once; what was read from a removed account is forgotten.

## What is kept

- In memory: each account's folders, the first page of each inbox, the folders a window opened, the
  last 30 threads opened, and a search's results until the search is cleared.
- On disk: only, per account, where its history was last read up to: the Gmail history ID, Graph's
  inbox delta link with the time it was taken, or an IMAP inbox's UIDVALIDITY, next UID and counts
  (`Yardlet.mailboxCursors` in Yardlet's defaults), so mail that came while Yardlet was closed is told once
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
  fields, as text. Chosen files are added once each, a file from 3 MB through an upload session.
- New mail: the inbox's delta query, begun over the last day's mail and followed to its `deltaLink`,
  every minute. Unread mail that came after the link was taken, not a draft and not in the Other inbox,
  is told. A link Graph no longer knows (410) starts again.
- **Open in Outlook** opens the newest message's `webLink` in the mailbox's browser panel (see "Links"). **Ask an agent** names
  the newest message and the connector's `get_message`.

## Mail accounts over IMAP

Services without an API Yardlet reads (Naver, Daum, Kakao, NAVER WORKS, iCloud, Yahoo, AOL, Zoho,
Fastmail, Proton Mail through its Bridge, or any IMAP server) are added in Settings › Connectors › Add
connector › **Mail (IMAP)**, as Apple Mail and Thunderbird add them.

- **Adding.** The address picks the service (`MailServerPreset`): its IMAP and SMTP servers, the user name
  (iCloud's is the part before the `@`) and what the person does first on the service's website, each step
  with a link: turn on two-step verification, make an app password, and turn on IMAP where the service has
  a switch for it (Naver, Daum, Kakao, Zoho). **Other IMAP server** takes the servers, ports, TLS or
  STARTTLS and the user name by hand. A Gmail or Outlook.com address is pointed to its own connector.
  **Connect** signs in to the IMAP server and to the SMTP server once and out again, reading and sending
  nothing; only then is the account added. A refused sign-in says to check the app password and the steps.

  | Service | IMAP | SMTP |
  |---|---|---|
  | Naver Mail | `imap.naver.com:993` | `smtp.naver.com:465` |
  | Daum Mail | `imap.daum.net:993` | `smtp.daum.net:465` |
  | Kakao Mail | `imap.kakao.com:993` | `smtp.kakao.com:465` |
  | NAVER WORKS | `imap.worksmobile.com:993` | `smtp.worksmobile.com:465` |
  | iCloud Mail | `imap.mail.me.com:993` | `smtp.mail.me.com:587`, STARTTLS |
  | Yahoo Mail | `imap.mail.yahoo.com:993` | `smtp.mail.yahoo.com:465` |
  | AOL Mail | `imap.aol.com:993` | `smtp.aol.com:465` |
  | Zoho Mail | `imap.zoho.com:993` (`imappro` for organizations) | `smtp.zoho.com:465` (`smtppro`) |
  | Fastmail | `imap.fastmail.com:993` | `smtp.fastmail.com:465` |
  | Proton Mail Bridge | `127.0.0.1:1143`, STARTTLS | `127.0.0.1:1025`, STARTTLS |

- **What is kept.** The app password is in the Keychain under the connector, and nowhere else: not in a
  file, the log or a command. The servers and the address, which are not secret, are in the connector's
  record (`connectors.json`). Removing the connector deletes both; the app password stays valid at the
  service until the person deletes it there.
- **Connecting.** Every connection is TLS from the first byte or upgraded with STARTTLS before signing in,
  and the server's certificate is checked against its name; a server that offers neither is not used.
  Each account keeps one IMAP connection for the mailbox and its agent tools (`IMAPMailSession`), checked
  with `NOOP` after two minutes unused and opened again when the server closed it. SMTP is signed in to
  for each message sent.
- **Folders.** The inbox, then the folders for sent mail, drafts, an archive, spam and the trash, found by
  the server's special-use attributes (RFC 6154) or else by the names services give them in English and
  Korean (보낸편지함, 임시보관함, 스팸편지함, 휴지통), then the person's own folders under **Folders**,
  nested ones indented. Folder names in IMAP's modified UTF-7 are read as text. Unread counts come from
  `STATUS` for the inbox and spam; Drafts shows its count.
- **Lists and threads.** IMAP has no threads, so each message is a line of its own, newest first, 50 at a
  time, with its first words from the start of its body. Opening one reads it whole up to 4 MB; a larger
  message reads only its text and HTML and lists its files. Reading uses `BODY.PEEK`, so only the
  mailbox's own read sync marks it read. A plain-text part that is itself HTML, as some senders' are, is
  read as HTML, and a subject or name sent as raw bytes that are not UTF-8 is read in the message's
  charset, else as Korean code page 949, else as Latin-1.
- **Search** is the server's (`SEARCH TEXT`, any language as UTF-8) over the inbox, the archive and sent
  mail, its sequence numbers read with the FETCH the list uses. A folder where TEXT finds nothing is
  searched again by subject and sender. When nothing is found, the server is asked to find its last
  message by number; a server that cannot is said to have no search, rather than shown as no results.
- **Changes.** Read and Star are the `\Seen` and `\Flagged` flags; Archive moves the message to the
  archive folder, made as "Archive" the first time on an account without one, as Mail and Thunderbird
  do; Not spam and Move out of the Trash move it to the inbox. There is no **Open in** button: these
  services have no web address for one message.
- **Writing and sending.** A draft is a message saved in the account's Drafts (`APPEND`, `\Draft`), with
  its own `From`, `Date` and `Message-ID`; saving again saves a new one and deletes the one before.
  Sending reads the draft as saved, sends it over SMTP to its To, Cc and Bcc with the Bcc line left out of
  the message, keeps a copy in Sent unless the server already put one there (its `Message-ID` among the
  envelopes of Sent's newest 20 messages), and deletes the draft. Once the SMTP server took the message, a
  failure after it does not fail the send.
- **New mail.** The inbox's `STATUS` every minute (one command on the open connection): a new UIDVALIDITY
  reads the inbox again, a higher next UID reads the flags of the inbox's newest messages, no more than
  the UIDs given out since and at most 50, and those given a UID since the last check that are unread and
  not drafts are told. IMAP IDLE is not used; most services do not document it and a minute is what the
  other accounts wait.
- **Refused password.** A server that refuses the app password later marks the connector as needing the
  account again and stops the account's watch; adding the same address again replaces the password.
- **Agents** read and draft through the connector's tools (`mail_search_messages`, `mail_get_message`,
  `mail_list_folders`, `mail_create_draft`, `mail_send_draft`), named like Outlook's; sending asks the
  person each time through the harness's approval. **Ask an agent** names the message and `get_message`.

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
  A chosen link opens in the mailbox's browser panel (see "Links"). The page is as tall as its content and
  scrolls with the thread. A message without HTML shows its text.
- The thread's bar: **Ask an agent**, Archive (in an inbox), Mark as read or unread, Star, and
  **Open in Gmail**, which opens the thread on Gmail's web app in the mailbox's browser panel (see "Links"), as
  the account (`authuser`).
- **Spam and Trash** are told apart: their folder symbols are red, their list says that Gmail deletes such
  mail after 30 days and draws its rows dimmer, and a thread read there says where it is across its top.
  Spam offers **Not spam** (back to the inbox) and Trash **Move out of the Trash** (`threads.untrash`)
  in Archive's place, and neither offers **Ask an agent**.

## Links

- A link chosen in a message, and **Open in Gmail** or **Open in Outlook**, open in a new tab of the mailbox's own
  browser panel beside the thread (`AppModel.openMailLink`), as a task's side panel sits beside its conversation:
  the same tab strip, browser pane, tab menu and widths, its tabs in the title bar's row. The thread stays beside
  it. Its **+** opens another tab, and closing the panel closes its pages, since the mailbox has no button that
  shows it again. It holds up to nine tabs; a link past that opens in another browser. A `mailto:` link goes to the
  Mac's mail app.
- The panel belongs to no task (`TaskWorkspaceStore.mailID`): no agent's browser tools list or use its tabs, and
  what one of its pages waits on (a dialog, a passkey) shows over the panel and on its tab, not on a task's row or
  in a notification. Its pages open in the default browser profile (`Browser/Default`), with the person's own
  sign-ins, and it never takes a profile of its own, having no agent (docs/BROWSER_SESSION_ISOLATION.md,
  "Rules").
- The panel is kept in memory only: its tabs are not saved and are gone once Yardlet quits. The pages it showed go
  to the address field's history as any page does. Turning the mailbox off closes it.
- **Ask an agent** names the thread, not the panel's pages; to have an agent work on a page, open it in the task's
  own browser.
- Links other apps hand Yardlet as the default browser still open beside the task the window shows
  (docs/BROWSER_HOST.md, "Default browser").

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
  and the connector tool that reads it (`gmail_get_thread`, which takes the account's address). The message's words are not put in the
  prompt; the agent reads them with the account's Gmail connector, and the person writes what to do.
- Agents read and draft through the Gmail connector's tools as before (docs/CONNECTORS.md, "Google");
  the mailbox shows the drafts they make.

## Code

| Location | Contents |
|---|---|
| `Domain/Mail.swift`, `Domain/MailComposition.swift` | Accounts, folders, threads and messages; the transport contract (`MailAccountTransport`); addresses (`MailAddressList`); what is being written and how a reply or forward is addressed |
| `Connectors/GmailMailTransport.swift` | The Gmail API behind the contract: folders and labels, lists, threads, label changes, drafts, history |
| `Connectors/OutlookMailTransport.swift` | Microsoft Graph behind the contract: folders, conversations, per-message changes, replies from Graph's own, the inbox's delta |
| `Connectors/IMAPMailTransport.swift` | IMAP and SMTP behind the contract: the account's connection (`IMAPMailSession`), folders by role, messages as threads, flags and moves, drafts in Drafts, sending and the Sent copy, the inbox's `STATUS` |
| `Connectors/MailServerPreset.swift`, `Connectors/MailAccountTools.swift` | The services' servers and setup steps; the tools an IMAP account offers agents |
| `Domain/IMAPClient.swift`, `Domain/IMAPResponse.swift`, `Domain/SMTPClient.swift`, `Domain/MIMEMessage.swift`, `Domain/MailSocket.swift` | The IMAP and SMTP clients, reading the server's responses, reading MIME, and the byte stream they use (`Platform/macOS/MacMailSocket.swift` on the Mac) |
| `Views/AppShell/MailAccountSetupPage.swift` | Adding an IMAP account |
| `Presentation/MailboxCenter.swift` | The app's mailbox (`MailboxCenter`: accounts, lists, opened threads, watch, writing) and a window's view of it (`MailWindowState`) |
| `Presentation/MailText.swift` | Names, subjects, times and the hand-off text |
| `AppModel+Mailbox.swift` | Following the setting and the connectors, notifications and their clicks |
| `AppModel+ExternalLinks.swift` | Where a link chosen in mail opens (`openMailLink`), and closing the mailbox's browser panel (`closeMailBrowser`) |
| `Views/Mail/` | The sidebar (`MailSidebar`, `MailFolderTree`), the thread (`MailContent`, `MailThreadView`) and its browser panel (`MailWorkspace`), HTML (`MailHTMLBody`) and writing (`MailComposeView`) |

Tests: `GmailMailTransportTests`, `OutlookMailTransportTests` and `IMAPMailTransportTests` (requests and answers
against a fake Gmail, a fake Graph and a scripted IMAP and SMTP server), `IMAPClientTests`, `SMTPClientTests` and
`MIMEMessageTests`, `MailboxCenterTests` (the
watch, sending, Undo and Drafts), `MailHTMLBodyTests` (no remote content before Show images) and
`MailboxRenderingTests` (the list, a thread, writing, the hand-off, the folders and spam, and a link in the
mailbox's own browser panel with no task's panel taking it, drawn under `.build/mailbox-qa/` in both appearances at
1280×800 and 920×680).
