# Phone remote v2 design

Status: the design record of the phone remote, kept for the reasons behind its shape. It is not updated as
the product changes. The current contract and behavior are in [REMOTE_PROTOCOL](../REMOTE_PROTOCOL.md); where
the two differ, that document and the code are right. Keeping the Mac awake while tasks work is described in
[SLEEP_PREVENTION](../SLEEP_PREVENTION.md), and the relay settings a build carries in
[relay/README.md](../../relay/README.md). The screen mockups are
[remote-v2/mockups.html](remote-v2/mockups.html) and the PNG files in the same folder.

## 0. Conclusions

- **Three routes, one security layer.** Every connection between the phone and the Mac is wrapped in the same Noise IK
  handshake and encryption. Underneath, the phone picks whichever route reaches the Mac first: a direct connection on
  the same Wi-Fi, Tailscale or the Yardlet relay server. Whatever the route, the phone verifies the other end with the
  Mac's static public key, so the relay server and other devices on the same Wi-Fi cannot read or change the content.
- **Pairing is one QR scan.** The QR holds the Mac's static public key, a one-time secret that lasts 5 minutes (256
  bits), the relay address with its room ID and the direct connection addresses. The phone makes its own key pair and
  sends its public key with the secret in the first handshake. The Mac stores only the phone's public key (stronger than
  v1's token hash: the Mac holds none of the phone's secrets).
- **The relay server is one box.** Cloudflare Workers + Durable Objects keep one room per Mac. When the Mac opens its
  room with an outgoing WebSocket, the relay joins it to the phone's WebSocket. The server only forwards ciphertext and
  stores none of it, and rooms need no accounts (the optional accounts of section 3.1 live beside them). The room ID
  comes from the Mac's signing key (self-certifying), and the Mac opens the room by signing with that key. One user fits within the free plan.
- **Notifications carry only ciphertext.** Once the phone has told the Mac its FCM token, the Mac sends FCM data
  messages through the relay server while the phone is not connected. The content (task title, request summary) is
  encrypted with a notification key shared at pairing, so Google and the relay server cannot read it. Without FCM, the
  phone gets them through "Background notifications" (a foreground service), as the v1 app did.
- **New on the phone:** answering question cards, plan review (approve or keep planning) and creating a new task (with
  the Mac's new-task defaults). The first step left settings, accounts, files and the terminal on the Mac; later
  steps (section 5.2 and the protocol's §15) added continuing a task a plan limit stopped under another account,
  wider approval answers, a new task's harness, model and worktree, photos and files, steering or queueing
  follow-ups, browser tabs, an app lock, and requests for files, terminals and the host's settings and accounts.
- **Native apps on each platform.** Android in Kotlin and Compose; iOS in SwiftUI, using the Mac's `YardletRemote`
  package (protocol types, Noise) as is. The two reference apps are also native apps on each platform.
- **Accounts are optional.** Without a QR code, the person signs in with an account and picks
  from their own list of Macs. The Mac or a phone already connected checks a confirmation code and approves the new
  phone (like linked devices in Signal and WhatsApp). The account server knows only the list of Macs, not the content
  (section 3.1).
- **Faster and broader than the two apps.** The phone keeps the last list and conversations,
  draws them first and then replaces them with the latest, against set target times (section 5.1). The
  phone also covers command output, diffs, suggested tasks, pinning, archiving and several Macs (section 5).
- **Preventing sleep and screen lock while a task works.** The Mac does not idle-sleep while a task works; a setting
  (off by default) also keeps the display on for that time, and a second keeps tasks working with the lid closed
  through a privileged helper (section 6.5).
- **Exploring without a Mac.** Tapping "Explore without a Mac" on the first
  screen attaches the app to a demo Mac inside the phone, where the person can try the task list, conversations,
  approvals, questions, plan review, diffs, a new task and notifications. It uses no network and no storage (section 8).
- **v1 has been removed.** The v1 listener (Tailscale addresses, 47615, plain JSON and a token) is gone, and the Mac
  drops v1 devices from its list. A phone paired with the earlier app pairs again with the current app (section 9).

## 1. Comparison with reference products

### 1.1 The two apps (2026-10-24, public docs and installed app bytes)

| | Claude Code Remote Control (Code tab in the Claude app) | Codex Remote (Codex in the ChatGPT app) |
|---|---|---|
| Structure | The local CLI makes only outgoing HTTPS connections to Anthropic. No incoming port | The host (desktop app) registers with OpenAI's relay layer; the phone comes in through the account |
| Pairing | The same claude.ai account. QR, session URL or session list. Trusted Devices as an option | Allowed in the host's Settings › Connections › Control this Mac, by QR per phone and per host. A manual code (with expiry) too. Account MFA |
| Encryption | TLS. Conversation history is stored on Anthropic's servers (stated in the docs) | `Noise_hybridIK_X25519+MLKEM768_AESGCM_SHA256` in the bundled CLI. Public sources do not confirm whether the whole phone connection is E2EE |
| On the phone | Messages, interrupt, permission approval, `AskUserQuestion` answers, plan approval, photo and file attachments, new sessions in server mode | Messages (Queue and Steer), interrupt, approvals (once, for the conversation or broader), answers to questions and MCP forms, Plan mode, new local tasks (host, project, worktree and branch), diff review |
| Notifications | Mobile push (when finished or when a decision is needed; two settings) | Notifications when a task finishes or needs attention |
| Disconnects | Interactive mode keeps retrying; server mode may end after about 10 minutes | Drops when the host sleeps or the app quits |
| UI conventions | Code tab list; remote sessions get a computer icon and a green dot | List filter (All, Cloud, computer), Pinned and Today sections. Approval card: description and command, Approve above and Always approve below, and a "Tell Codex what to do" field with Deny on the bottom line |

Sources: [Claude Remote Control](https://code.claude.com/docs/en/remote-control), [Claude
mobile](https://code.claude.com/docs/en/mobile), [Codex remote
connections](https://learn.chatgpt.com/docs/remote-connections), [Codex mobile](https://learn.chatgpt.com/docs/mobile),
[Codex Remote post](https://developers.openai.com/blog/mastering-codex-remote-for-engineering). Installed apps: Claude
3.1623.3 `app.asar` (`toggleRemoteControl`, the text that allows starting sessions on this computer from a phone),
ChatGPT 26.1016.61520 (`codex-mobile-setup-dialog`: QR, manual code and refresh; the CLI's `remoteControl/pairing/start`
and `manualPairingCode`). The apps were not run.

**Summary:** Both apps treat picking a task, approvals, questions, follow-up messages, interrupting and viewing results
as the core of the phone, and both start new local tasks from the phone too. Both go through the company's servers and
accounts. Yardlet has no accounts or servers, so it pairs with device keys and has the relay carry only ciphertext.

### 1.2 Well-known remote and sync apps

| App | Pairing and identity | Relay | What Yardlet took |
|---|---|---|---|
| Syncthing | Device ID = certificate SHA-256. Local discovery (broadcast) | Relay when direct fails; TLS between devices stays, so the relay cannot read | End-to-end authentication regardless of route, local discovery |
| KDE Connect | UDP 1716 and mDNS discovery, pairing approval over TLS, certificate pinning | None | mDNS discovery, pinned peer key |
| Signal device linking | The new device's ephemeral public key in the QR | Ciphertext in a server mailbox | Public key in the QR |
| Tailscale | WireGuard (Noise IK family) | DERP carries only ciphertext and moves to a direct path | Noise IK, upgrading from the relay to a direct path |
| Home Assistant Cloud | Account | Forwards TLS ciphertext by SNI; the instance at home decrypts | The relay only forwards |
| Chrome Remote Desktop, Magic Wormhole | Short code + SPAKE2 (PAKE) | Relay when direct fails | A short code typed by hand needs a PAKE (next step) |
| Happy (Claude Code mobile client) | The CLI's ephemeral NaCl public key in the QR | The server stores encrypted messages | A lesson in what not to do: the session title goes in plain text in the push body. Yardlet encrypts pushes too |

Sources: [Syncthing](https://docs.syncthing.net/users/relaying.html), [KDE Connect
protocol](https://github.com/KDE/kdeconnect-meta/blob/master/protocol.md),
[Signal](https://signal.org/blog/a-synchronized-start-for-linked-devices/), [Tailscale
DERP](https://tailscale.com/kb/1232/derp-servers), [Nabu
Casa](https://support.nabucasa.com/hc/en-us/articles/25619268678557-Remote-access-Deep-dive), [Magic
Wormhole](https://magic-wormhole.readthedocs.io/en/latest/welcome.html),
[Happy](https://github.com/slopus/happy/blob/main/docs/encryption.md).

## 2. Connection

### 2.1 Secure channel: Noise IK

- Pattern `Noise_IK_25519_ChaChaPoly_SHA256`, prologue `yardlet-remote/2`. The phone starts (initiator) and the Mac
  answers (responder). The phone already knows the Mac's static public key from the QR (`<- s`). The handshake takes two
  messages, one round trip, and the phone's public key travels encrypted from the first message on (the relay does not
  even know which phone it is).
- The first message's payload is the phone's name and, when pairing, the one-time secret from the QR. It is encrypted
  with a key made from the Mac's static key and the phone's static key, so only the Mac can read it and only the owner
  of the phone's key can make it.
- Messages after the handshake are the JSON requests, responses and events of REMOTE_PROTOCOL §2 and §4–§8. A Noise message cannot exceed
  65,535 bytes, so large JSON (one page of conversation can be several MB) is split into fragments (the first byte says
  "continues" or "end").
- It is the same on every route: `ws://` on the same Wi-Fi, `ws://` over Tailscale, `wss://` through the relay. There is
  no separate TLS because Noise authenticates both ends (no certificates to manage). The relay leg is `wss://`, so it
  gets one more layer.
- Test vectors: the Mac and phone tests share the `Noise_IK_25519_ChaChaPoly_SHA256` vectors from the public-domain
  cacophony set. Both implementations must produce the same bytes to pass.
- Left out: a quantum-resistant hybrid IK that mixes in ML-KEM, as Codex does. CryptoKit has it, but Android has no
  standard implementation. To reduce the "harvest now, decrypt later" risk on the relay leg, the prologue carries a
  version number so that a later step can move up to `hybridIK`.

### 2.2 Direct connection on the same Wi-Fi

- The Mac opens the v2 listener on TCP 47616 on every interface (a free port if that one is in use). There is no reason
  to bind to chosen addresses as v1 did: a peer that cannot complete the handshake gets nothing (like Syncthing's
  22000).
- The Mac advertises `_yardlet._tcp` over Bonjour. The instance name and the TXT `id` are a 16-character hash derived
  from the Mac's public key, so the Mac's name is not visible on the LAN. The phone makes the same hash from the Mac key
  it saved and finds its Mac that way.
- From macOS 15, advertising over Bonjour asks for local network permission (only listening on TCP does not ask; Apple
  TN3179). The prompt appears once when the remote is turned on; if the person declines, the phone connects through the
  last address and the relay without Bonjour. Info.plist gets `NSLocalNetworkUsageDescription` and `NSBonjourServices`
  (`_yardlet._tcp`).
- The Mac puts its current direct addresses (LAN, Tailscale, MagicDNS name) in the handshake response. The phone saves
  them and tries them first, even on networks where Bonjour does not work (such as device isolation on guest Wi-Fi).
- From Android 17 (targetSdk 37), LAN sockets need the `ACCESS_LOCAL_NETWORK` permission. The current targetSdk 36 does
  not need it; moving to 37 adds the permission request and a fallback to the relay when it is denied.

### 2.3 Tailscale

- A Tailscale address is also one of the Mac's interfaces, so the v2 listener accepts it as is. When the VPN is on, the
  phone tries the saved Tailscale address as a direct route. Nothing else is needed.

### 2.4 Yardlet relay server

**Shape:** one Cloudflare Worker with a Durable Object class `Room`, one room per Mac (the optional accounts of
section 3.1 add a second class, `Account`).

```
Mac ──wss /v1/rooms/<room>/host──▶ Room(DO) ◀──wss /v1/rooms/<room>/connect── phone
     (outgoing, opens the room by signing)    (forwards ciphertext only)
```

- The **room ID** is 32 characters: the first 20 bytes of the SHA-256 of the Mac's Ed25519 relay key, written in base32.
  The server recomputes the room ID from the public key the Mac sends, and accepts the connection as that room's Mac
  only after verifying its signature over a nonce the server gave. There are no accounts, registration or storage.
- **Joining:** when a phone comes in through `connect`, the room gives it a connection number and tells the Mac
  (`open`). After that it forwards binary frames both ways, adding and removing the number. The Mac keeps one Noise
  responder per connection. If the Mac is not there, the room answers the phone's upgrade request with 404.
- **What it does not do:** store content, write content to logs or authenticate phones (anyone who knows the room ID can
  come in, but the Mac's handshake cuts them off). Limits: 8 phone connections per room that the Mac answered, and
  apart from those a few waiting for the Mac's first frame (2 per address, 8 per room, 15 seconds each), 65,535 bytes
  per phone frame (one Noise message), 10 seconds before authentication and 120 seconds for a silent connection.
- **Sleeping:** sockets are accepted through the Hibernation API, so when no messages pass, the DO can be evicted while
  the connections stay, and no duration charge accrues. The Mac's keepalive ping gets an automatic response
  (`ping`→`pong`), so it does not wake the DO.
- **What the server sees:** the room ID, both sides' IP addresses, connect and disconnect times, frame sizes and
  intervals, and the FCM token while sending a notification (dropped after sending). What it cannot see: the task list,
  conversations, commands, approvals and the phone's public key.
- **Cost (Cloudflare price list, 2026-10-24):** the free plan also allows SQLite-backed DOs, with 100,000 requests and
  13,000 GB-s per day. Every 20 WebSocket messages a DO receives count as one request. A user who keeps the phone open
  two hours a day makes roughly a few hundred requests and a few hundred GB-s, within the free plan. 1,000 users would
  need the paid plan ($5 a month, including 1 million DO requests and 400,000 GB-s) plus a few dollars of overage. No
  domain is needed (`*.workers.dev`).
- **Running it:** locally with `wrangler dev` (no sign-in needed); how it is deployed and how a build carries its
  address is in [relay/README.md](../../relay/README.md).

### 2.5 How the phone picks a route

1. Gather candidates: addresses found through Bonjour, the last direct addresses received (LAN on Wi-Fi or Ethernet,
   Tailscale when the VPN is on) and the relay.
2. Start the direct candidates at once and the relay after 0.7 seconds; use whichever finishes the handshake first and
   close the rest (direct attempts time out after 3 seconds).
3. While connected through the relay, if the network changes or Bonjour finds the Mac, try a direct connection again and
   move to it if it works (the list and the open conversation are fetched again).
4. The screen does not make much of the route. The Mac sheet has just one line: "Connected over the same Wi-Fi",
   "Connected over Tailscale" or "Connected through the Yardlet server".

## 3. Pairing, removal and reconnection

- **Mac:** Settings › Remote › "Pair a device" shows the QR for 5 minutes. The manual code is gone: without accounts, a
  short code typed by hand is safe only with a PAKE (such as SPAKE2). Scanning the QR with the phone's built-in camera
  also opens the app (`yardlet-remote://pair?v=2…`).
- **Phone:** after reading the QR, it makes an X25519 key pair for this Mac only (a different key for each Mac, so Macs
  cannot link the phone across each other) and keeps the private key in DataStore, sealed with an AES key in the Android
  Keystore. It is excluded from backups.
- **Confirming:** if the secret in the first message matches, the Mac adds the phone's public key to its device list and
  responds. If the response does not reach the phone and the phone tries again, the Mac accepts it as the same device,
  for the same public key only, for a short time (60 seconds, REMOTE_PROTOCOL §12).
- **Removal:** removing the phone in the Mac's settings closes its open connections at once (`revoked`), and that public
  key cannot come back in (`unknownDevice`). Its notification token is deleted too. "Disconnect" on the phone tells the
  Mac (`forgetDevice`) and deletes the phone's own key.
- **Reconnection:** after a connection that was up drops, at once and again every half second for about 10 seconds
  without showing the drop, since the Mac opens its relay room again within a second (protocol §14.3); then
  exponential backoff (1 second→30 seconds, ±20%), or at once when the network changes.
  Every reconnection is a new handshake (no session resumption).
- **Several Macs:** the phone app saves several Macs, and the person switches by tapping the Mac name at the top. It
  connects to one at a time.

### 3.1 Accounts (optional)

An account-based way to connect is also possible. QR pairing stays, and signing in with an account shows that
person's Macs and lets them add a new phone. End-to-end encryption is kept.

- **An account does only two things.** Discovery (the names, room IDs and public keys of the Macs registered to this
  account), and adding a new phone with approval from an existing device. Tasks, conversations and commands never go to
  the account server (even when they pass the relay, they are ciphertext). As with linked devices in Signal and
  WhatsApp, the server knows only the device list, and existing devices approve new ones.
- **Flow:**
  1. Mac: Settings › Yardlet Account › "Sign in with …" (a browser sign-in window, with remote connections on or
     off), then this Mac is registered to the
     account (name, room ID, the Mac's two public keys). The Mac proves it owns the room with a relay key signature.
  2. New phone: "Sign in with an account" → the account's list of Macs → picking a Mac runs a Noise handshake with that
     Mac and sends a link request (`link`).
  3. The Mac puts that phone on hold. The Mac's screen and the phones already connected show "Pixel 9 wants to connect ·
     482 913", and the new phone shows the same number. If they match, the person allows it.
  4. Once allowed, that connection is authenticated at once and receives the list. With no answer within 2 minutes, or a
     refusal, the Mac drops it.
- **Why there is a confirmation number:** if the account server swapped the Mac's public key (a server breach, or the
  operator), the phone would talk to a fake Mac. Each side computes the number from the two public keys it holds and a
  random nonce from each side, and the phone commits to its nonce before it learns the Mac's (commit, then reveal, as in
  Bluetooth's numeric comparison), so a swap makes the numbers on the two screens differ except by a one-in-a-million
  chance. That way the account server does not need to be trusted with what passes between a phone and the person's
  Mac. What the number shows is that the phone and the Mac displaying it hold the same keys; it does not show that a
  Mac in the account's list is the person's own, since the list comes from the account server unsigned. So the person
  links only when the number appears on the Mac in front of them: a phone linked to any other Mac reaches that Mac
  alone, never the person's. The Mac takes at most 5 link requests in 10 minutes.
- **When away:** if the person is not at the Mac, a phone already connected approves. With no connected phone and nobody
  at the Mac, a new phone cannot be added. That is the safe side.
- **Sign-in methods:** GitHub and Google come first (OAuth 2.0 authorization code with PKCE; the apps use browser
  sign-in windows, `ASWebAuthenticationSession` and Custom Tabs). They are the most common among developer-tool users
  and work the same way on both platforms. Sign in with Apple was left for later (it needs a service ID, a key and
  domain verification, and the App Store sometimes requires Sign in with Apple in apps that offer other social sign-in),
  as were email links, which need a mail sending service (a sending domain, usually paid).
- **What stays on the server:** the account ID (a hash of the sign-in provider and the user number there; the original
  number and the email are not stored), a display name (such as the GitHub login name; optional), registered Macs (name,
  room ID, the Mac's two public keys, update time), sign-in sessions (a hash of the token, device name, times) and
  one-time sign-in codes that last 2 minutes. What does not stay: tasks, conversations, commands, phones' public keys
  and notification tokens. Signing out on a Mac removes that Mac from the list.
- **Where it is stored:** one Durable Object per account (named by the account ID, SQLite). There is no table of all
  users.
- **Relation to the QR:** the QR remains the default way, with no account. An account is for adding a new phone when the
  person is not at the Mac, or for finding several Macs at once.

## 4. Notifications

- When the phone sends its FCM token with `registerPush`, the Mac makes a 32-byte notification key for that device and
  returns it. The token and the key live in the Mac's device list.
- The Mac sends one only while the device is not connected, at three moments: a wait starts (high priority); a task
  finishes or fails; a wait is resolved on the Mac (the notification is withdrawn, normal priority). When the phone app
  leaves the screen, it closes the connection and relies on notifications (with "Background notifications" on, it stays
  connected).
- The content is the JSON of the `attention` event (REMOTE_PROTOCOL §5.2), encrypted with ChaCha20-Poly1305 (the notification key, a
  random nonce). FCM data messages are limited to 4 KB, so the summary is capped at 120 characters. Google and the relay
  see only the token, the size and the time.
- A high-priority data message must lead to a visible notification, or its priority gets lowered (FCM docs). Waits and
  completions always show a notification; only withdrawals go at normal priority.
- The lock screen shows only "There is an approval request" (the public version); after unlocking, the task title and
  summary appear.
- FCM needs a Firebase project (free). A build without a project does not register for notifications and uses only
  "Background notifications". iOS gets the same sealed payload through APNs (REMOTE_PROTOCOL §14.2, §16).

## 5. What the phone does

| Action | v1 | v2 | Basis |
|---|---|---|---|
| Task list and status, reading conversations, messages, stop, mark read | Yes | Yes | Both apps |
| Approval | Allow once or deny | Every answer the Mac's card gives | Both apps (sections 5.2 and 5.3) |
| Answering question cards | On the Mac | **Yes** | Both apps answer on the phone. Sent through the same path as the Mac card (`ConversationRequestFormInput`). Secret answers and MCP forms too (section 5.3) |
| Plan review | On the Mac | **Yes**: Approve plan, Keep planning (with an optional reason) | The same two answers the Mac card gives. No answer that changes the permission mode |
| New task | No | **Yes**: project (or chat) and first message | Both apps open new local tasks from the phone. Harness, model, account and worktree start from the Mac home composer's values; section 5.2 lets the phone choose them |
| Command output, file changes (diff) | No | **Yes**: loaded when the tool line is tapped (`itemDetail`) | Codex on the phone shows diffs. Fetched only on tap instead of always riding the stream, to keep things fast |
| Suggested tasks | No | **Yes**: Start, Do it here, Dismiss, and Options | The same actions as the Mac chip; Options offers the Mac's harness, project, model, effort, permission mode and worktree choices for what Start starts with (protocol §15.9) |
| Child tasks | Parent link | Shown collapsed under the parent and opened directly | Users run several child tasks at once |
| Pin and archive | No | **Yes** | Keeping the list tidy |
| Several Macs, accounts | No | **Yes** | Sections 3 and 3.1 |
| Image attachments | No | **Yes**: up to four photos, in messages and new tasks | Both apps (section 5.2) |
| Choosing a new task's harness, model, effort, permission mode and worktree | No | **Yes** | The same menus as the Mac's new-task screen (section 5.2) |
| Choosing Steer or Queue; Send now, Stop and send and Delete on a queued message | No | **Yes** | The Codex app, the Mac's queue chips (section 5.2) |
| Approval: allow for this session; deny and say what to do instead | No | **Yes** | Both apps (section 5.2) |
| A task stopped by a plan limit: continue under another account (with each account's limits), continue once the limit resets | No | **Yes** | The Mac's limit card (section 5.2) |
| A browser tab handed to the person: the reason and site, I'm done and Decline; seeing and using the tab | No | **Yes** | The Mac's handoff bar (section 5.2), taking over the tab (section 6.3) |
| App lock (biometrics or the screen lock PIN) | No | **Yes** (off by default) | Section 5.2 |
| Every answer the Mac's card gives, MCP forms, secret answers | No | **Yes** | Section 5.3. Answers that leave a standing rule ask once more |
| Files (20 per message, 500 MiB each) and photos from the camera | No | **Yes** | Section 5.3 |
| Settings, connectors, browsing files, terminal | No | Left on the Mac in the first step | Later added to the protocol (REMOTE_PROTOCOL §15.22, §15.27, §15.29, §15.36, §15.37) |

### 5.1 Speed

The goal: the remotes in the two apps are slow and limited, so Yardlet's should do much more. The two apps
take an extra trip through the company's servers and fetch everything from scratch each time the app opens. On the same
Wi-Fi, Yardlet connects straight to the Mac, and the phone keeps the last state.

| Moment | Target | How |
|---|---|---|
| Opening the app until the list shows | Within 0.3 s (saved list); up to date within 1 s (same Wi-Fi) or 2 s (relay) | Keep the last list and opened conversations on the phone and draw them first. Route race (section 2.5) |
| Opening a conversation | Saved copy at once, up to date within 0.5 s | Saved page first, replaced by the subscription response |
| Something on the Mac reaching the phone | Within 0.5 s | Server batching interval (list 0.4 s, conversation 0.2 s), sends only changes |
| Reconnecting after a network change | Within 1.5 s | Route race as soon as the network changes |
| Response to an approval or a message | Within 0.3 s (same Wi-Fi) | The Mac answers as soon as it receives, and the result comes as an event |

- **Only changes:** the list sends only changed tasks (`tasksChanged`), and the conversation only changed items
  (`conversation`). On reconnecting, the saved screen stays up while the new list and page replace it. Command output
  and diffs are fetched only on tap.
- **Measuring:** the plan was for the Mac tests to record the time to the handshake and to the first list over
  loopback, and for the phone app to record the time to connect, to the first list and to the first conversation page.

### 5.2 More from the phone

The goal: let the phone app do more. We compared both apps' phone features in their public documents again
and chose what the Yardlet phone lacked that the two apps do on the phone, and what only the Yardlet Mac does that matters
most while the person is away. An API being available was not a reason.

**Comparison (2026-10-27, public documents):**

| On the phone | Claude app (Remote Control) | ChatGPT app (Codex) | Yardlet phone (before) |
|---|---|---|---|
| Photo and file attachments | Yes: photos in the message, files as `@` references | Yes: files, photos, camera | No |
| Model and effort | Yes: the device's model and effort controls, `/model`, `/effort` | Host, workspace, branch and model when a chat starts | No (the Mac's defaults) |
| Permission mode | Manual, Accept edits, Plan, Auto (not Bypass permissions) | `/plan` | No |
| A new task's worktree | Server mode's `--spawn worktree` | Create a new worktree | No |
| Approval scope | Answers the permission prompt | Once, for the current chat, more broadly; "Tell Codex what to do" and Deny | Allow once, deny |
| Follow-ups | Sent | Queue (default) or Steer, default changeable in settings | Sent, as the Mac's setting says |
| Reviewing changes | The device's diff pane (the branch's whole change) | Changed files and diffs of finished turns, line comments sent to Codex, `/review` | Output and diff per tool line |
| Usage | `/usage` | Limit information in `/status` | No |
| Re-authentication | Trusted Devices (every 18 hours, refreshed by biometrics) | Account MFA, SSO, passkeys | The phone's screen lock only |
| Notifications | When a decision is needed and when work finishes; two settings | When work finishes or needs attention | The same (sealed pushes) |

Sources: [Claude Remote Control](https://code.claude.com/docs/en/remote-control) ("What connected devices see", "Mobile push
notifications", "Trusted Devices", "Limitations"), [Claude Code on mobile](https://code.claude.com/docs/en/mobile) ("Permission
modes"), [Codex on mobile](https://learn.chatgpt.com/docs/mobile), [Codex remote connections](https://learn.chatgpt.com/docs/remote-connections),
[the Codex Remote post](https://developers.openai.com/blog/mastering-codex-remote-for-engineering) ("Queue waits until the current
response finishes", "once, for the current chat, or more broadly", "files, photos, or a fresh camera capture").

**What we added, in order of effect (protocol sections 15.13-15.18):**

1. **Continuing a task a plan limit stopped (Yardlet's own).** The Mac limit card's "Continue with another account" (with each
   account's remaining limits) and "Auto-continue when limits reset". For people who work across several accounts, a task that
   hits a limit while they are away stops until they are back. Choosing on the phone starts it again on the spot. Each
   account's usage is seen in this list, which is why the home screen's usage warning line was not carried over separately.
2. **Wider approval answers (both apps).** "Allow for this session" and "Deny and say what to do instead". Codex on the phone
   offers once, for the current chat and more broadly, and "Tell Codex what to do"; Claude takes what to do instead when
   denying. The Yardlet phone had to tap "Allow once" each time similar commands followed, and send what to do separately after
   a denial. Answers that write a rule to a settings file or a policy ("Always allow") stayed on the Mac in this step, so a
   lost phone could not leave a rule that outlives the task; "for this session" ends with the task. Section 5.3 brought
   them to the phone behind a second confirmation.
3. **Choosing a new task's harness, model, effort, permission mode and worktree (both apps).** The Mac's new-task screen menus
   are sent as they are (`NewTaskModelProjection`). People pick a model per job (one for implementation, another for
   review); before this, a task started from the phone ran on whatever the Mac's home composer last held. Values the Mac asks
   to confirm, such as Bypass permissions and full access, are left out (the Claude app cannot pick Bypass from the phone
   either). The choice applies to that task only and leaves the Mac home composer's choice alone.
4. **Photo attachments (both apps).** Up to four photos in a message or a new task. The phone shrinks them to JPEG with a
   2,048 px long side, and the Mac writes them where a pasted image goes and sends them as the same attachment. A screenshot
   with "fix this" is the most common phone attachment, so photos come before files. A new task still needs its first words,
   as on the Mac.
5. **Follow-ups: choosing Steer or Queue, and the queue's actions (the Codex app, the Mac's queue chips).** When sending to a
   running task, choose "Deliver now" or "After the turn", and on a queued message "Send now", "Stop and send" (Claude Code)
   or "Delete". Before, a message went only as the Mac's setting said, and an urgent one put in the queue could not be taken
   out.
6. **Answering a browser tab handed to the person (Yardlet's own).** A task waiting on the person through `browser_handoff`
   shows as waiting in the phone's list and notifications, with the reason, the site, "I'm done" and "Decline". Even
   without the tab's screen (section 6.3 came later), the person can tap "I'm done" after approving a sign-in in another
   app, or "Decline" when they cannot do it now so the agent does not wait ten minutes.
7. **App lock (Claude's Trusted Devices).** A setting in the phone app, off by default. When on, the app asks for biometrics or
   the screen lock PIN when it opens and when the person comes back after more than five minutes away. Items 1-3 widen what a
   phone can do, so this lowers the risk of losing an unlocked phone (section 10). It uses the Android platform's
   `BiometricPrompt`, with no new dependency.
8. **One line on what stays on the Mac (the "Next" column of section 6.6).** Instead of "Other choices are on the Mac", a
   request that only the Mac can answer says what is there (`macNote`: the card's own name for that answer, a secret answer,
   an MCP form).

**Left out of this step:** the home screen's memory, disk and heat warnings (nothing to do about them from a phone); vault
confirmation with phone biometrics (section 6.4); a whole task's diff pane and diff line comments. Others left out here came
in later steps, each as its own part of the protocol: the camera and files (section 5.3), scheduled tasks
(REMOTE_PROTOCOL §15.21), a task's files and outputs (§15.22), a running task's model, permission mode and slash commands
(§15.23, since each harness changes them differently) and taking over a browser tab (§15.25, which needs screen streaming
and input together).


### 5.3 Every answer from the phone, files and the camera

Two more goals: send files as well as photos from the phone, and stop making the person go to the Mac
for approvals the phone could not answer. Protocol sections 15.19 and 15.20.

**What the phone could not answer, and what it answers after this step.** The rule is the Mac's card: every answer it shows, the
phone shows with the same words (`choices`). Both apps answer approvals on the phone with the provider's own
choices (Codex: once, for the chat, more broadly; Claude: the permission prompt's answers), so Yardlet does too.

| Request | The Mac card's answers | Phone before | Phone after |
|---|---|---|---|
| Claude Code permission with a suggestion saved to a settings file | Allow, Always allow in this project (saved to ...), Deny | Allow once, Deny, "more on the Mac" | All three; Always allow asks once more |
| Claude Code permission kept for the session (may switch the mode) | Allow, Allow for session, Deny | All three (5.2) | All three |
| Another harness's permission with standing options (ACP `allow_always`, `reject_always`) | The provider's options | Allow once and Deny only where the options were one-time | All options; standing ones ask once more |
| Codex command approval | Deny, Allow for session, Allow, and where Codex offers them exec and network policy amendments | Allow once, Allow for session, Deny | All; amendments ask once more |
| Codex request for more permissions (sandbox, network) | Deny, Allow for session, Allow | On the Mac | All three |
| Codex MCP tool approval (for example a Gmail send through Codex) | Deny, Always allow, Allow this conversation, Allow once | On the Mac | All; Always allow asks once more |
| Codex MCP form | The form's fields with its answers | On the Mac | Fields and answers on the phone (`formFields`) |
| A question with a secret answer (Codex `isSecret`) | A masked field | On the Mac | On the phone, masked, never stored |
| A mode switch request (ACP `switch_mode`) | Allow, Deny | On the Mac | Both |
| Yardlet's own approvals (a message or a child task into another project, reading another project's tasks, a subagent in another folder) | Allow, Deny | Allow once, Deny | The same, through `choices` |
| Connector writes Claude Code asks about (Gmail send, Calendar, Drive, App Store Connect, the Mac's apps) | Allow, Deny, with the account, recipients and a body preview | Allow once, Deny, with the same preview (up to 1,000 characters) | The same |
| A request Yardlet answers nothing for (`unanswerableReason`) | None, with the reason | The reason | The reason |
| Touch ID, a passkey or sign-in window, a macOS permission prompt, a keychain prompt | Not requests | On the Mac | On the Mac |

**Asking once more.** Only answers that leave a rule beyond the task ask again on the phone (`standing`): "Always
allow" saved to a settings file, a Codex exec or network policy amendment, an MCP tool allowed for good. They approve
later calls nobody has seen yet and outlast the task, a tap on a phone is easier to make by mistake than a click on
the Mac, and a lost phone should not be able to leave them silently. Answers that send something out (a Gmail send,
a calendar invite) do not ask again: the card already is the confirmation for that one call, with its recipients and
preview, as on the Mac. "Allow for session" does not either: it ends with the task.

**Secret answers.** Typed on the phone they reach only the person's own Mac, inside the encrypted channel, which
sends them to the provider as its card would. The phone masks the field, uses a password keyboard (no learning or
suggestions), blocks screenshots while it shows, and keeps the value only until it is sent: no cache, no draft. Making
the person walk to the Mac for them would leave the task waiting, which is what this change is for.

**Files.** Up to 20 files per message, each up to 500 MiB: Claude's chat limits ("500MB per file", "Up to 20 files per
chat", [Uploading files](https://support.claude.com/en/articles/8241126-uploading-files-to-claude), 2026-10-27);
OpenAI's file upload help could not be read (HTTP 403), so the stricter known figure is used. A file goes up in
4 MiB parts that resume from what the Mac holds after a dropped connection (the relay carries ordinary encrypted
chunks). The Mac writes it in its temporary folder, never in the task's folder, readable only by the person and not
executable, and sends it as a dropped file: an image as an image, anything else as a reference to its path (Claude
Code's `@`, a Codex mention). Nothing on the Mac opens or runs it. A part-finished upload is dropped after 30
minutes, and the Mac refuses one that would leave less than 2 GB of disk free. The phone picks files with the system
document picker (Storage Access Framework), so it needs no storage permission.

**Camera.** A photo taken from the composer through the system camera app, shrunk and sent as the photos of 5.2 are.
It is written only to the app's own cache until it is sent.


## 6. Handling steps that need the person from the phone while they are away

From a phone it is hard to work a browser by hand, use a fingerprint, operate other Mac apps or do complex work inside
Yardlet. After looking at how other products split this, Yardlet honestly separates "what can be finished on the phone"
from "what works only at the Mac".

### 6.1 Other products (2026-10-24, public docs)

| Product | Steps that need the person | On the phone | The model during takeover |
|---|---|---|---|
| ChatGPT agent (discontinued) and today's cloud browser | Stops at sign-in for "Take over browser", then gets the browser back and continues. Now a secure sign-in form puts the values straight into the remote browser | The cloud browser can be taken over from the phone too | The old agent stated that it takes no screenshots and records no typed secrets during takeover. Today's docs give no such guarantee |
| Browserbase Live View | Click, type and scroll through a live view URL (iframe) | No official mobile keyboard support; recommends your own input field | Sessions are recorded by default. The URL expires (6 hours at most) |
| Steel | WebRTC (H.264, 25fps) live sessions, input with `interactive`, human-in-the-loop docs for sign-in and CAPTCHA | Shows in a browser; full touch support not confirmed | The debug URL has no authentication, so anyone with the link can watch. Option to blur credential fields |
| Claude Code Remote Control | Keeps permission requests and `AskUserQuestion` open until answered | Answered on the phone, with push. No screen takeover | — |
| Aside | Shows waits for approvals and questions; the person handles MFA, passkeys and CAPTCHA. The person picks an agent tab and uses it directly; Computer Use and takeover added on 10-23 | Instructions, approval cards and `/stop` in Slack and Telegram. Screen streaming not confirmed | Not confirmed |
| ego(lite), ego.app | The person enters the task's Space, signs in or confirms, and it continues | ego.app advertises one-tap approval in iMessage and the Dynamic Island (waitlist stage) | Not confirmed |
| Manus | Take Over notification at SMS codes, CAPTCHA and MFA → the person handles it → hands back | The docs do not say whether all of it works directly on the phone | Not confirmed |
| 1Password for Claude, Steel Credentials | Passwords and codes go straight into the page without passing through the model | — | Values never enter the model's context |

Facts on the Apple side: there is no official way for a distant phone to stand in for the Mac's Touch ID. Apple Watch
approval (`deviceOwnerAuthenticationWithWatch`, `…WithCompanion`) requires the watch to be nearby. A passkey from a
nearby device (QR) needs Bluetooth on both devices, so sending the screen to the phone does not unlock it.

Sources: [ChatGPT agent](https://help.openai.com/en/articles/11752874-chatgpt-agent), [cloud
browser](https://help.openai.com/en/articles/20001280-using-cloud-browser-in-chatgpt), [Browserbase Live
View](https://docs.browserbase.com/platform/browser/observability/session-live-view), [Steel live
sessions](https://docs.steel.dev/overview/sessions-api/embed-sessions/live-sessions), [Steel
human-in-the-loop](https://docs.steel.dev/overview/sessions-api/human-in-the-loop), [Claude
permissions](https://code.claude.com/docs/en/permissions), [Aside
troubleshooting](https://docs.aside.com/help/troubleshooting), [Aside
changelog](https://docs.aside.com/changelog/components), [ego(lite)](https://lite.ego.app/document/en/docs/quick-start),
[Manus Take Over](https://help.manus.im/en/articles/11711218-how-can-i-take-over-manus-browser-or-vs-code), [1Password
for Claude](https://support.claude.com/en/articles/15936181-get-started-with-1password-for-claude), [Unlock with Apple
Watch](https://support.apple.com/en-us/102442),
[LAPolicy](https://developer.apple.com/documentation/localauthentication/lapolicy).

**Summary:** Everyone (1) answers the harness's approvals and questions directly on the phone, (2) fills sign-in secrets
outside the model and (3), when still stuck, lets the person take over the screen and then hand it back. Only ChatGPT's
old agent stated a promise that the model does not see the screen during takeover. Nobody unlocks fingerprint or
nearby-device authentication remotely.

### 6.2 How Yardlet handles it

| Step | First | If stuck, from the phone | Only at the Mac |
|---|---|---|---|
| Harness approvals, questions and plans | — | Answer directly (sections 5 and 5.3), every answer the Mac's card gives | A request Yardlet answers nothing for |
| Browser sign-in and two-step verification | The vault fills passwords, TOTP and Yardlet passkeys without exposing the values ([BROWSER_VAULT_DESIGN](../BROWSER_VAULT_DESIGN.md)) | If the vault does not have it or the site blocks it, take over the tab (section 6.3) | — |
| CAPTCHA, identity checks, payment confirmation, QR sign-in | — | Take over the tab | Sign-in that needs the phone's camera to scan a QR on the Mac's screen |
| Fingerprint and passkeys | Yardlet passkeys without the person | Vault items set to "Every time" can also be confirmed with phone biometrics (section 6.4) | Touch ID-only confirmation, iCloud Keychain and nearby-device passkeys, the macOS administrator password, keychain access prompts: the phone says "This must be handled on the Mac" |
| Other Mac apps | The harness's computer control (Codex computer-use, Claude `--chrome`). With "Keep the screen unlocked while tasks work" on, the screen does not lock (section 6.5) | Answer that harness's approvals | Screen control on a Mac whose screen is locked with that setting off |
| Complex work inside Yardlet | — | Hand it in words to a coordinating task (for example a pinned chat task). That task uses the session tools ([AGENT_BROWSER_TOOLS](../AGENT_BROWSER_TOOLS.md): `create_task`, `send_message_to_task`, `read_task`) to create, ask and tidy up other tasks | Settings, accounts and connectors, in this step |

- The phone app does only the frequent things, and does them well (seeing waiting tasks, approvals, answering questions,
  messages, reading conversations, new tasks). Pinned tasks sit at the top of the list so the coordinating task is easy
  to find. The Mac's settings screens are not brought to the phone.
- "This must be handled on the Mac" is an honest marker, like `moreOnMac`. It shows in one line what needs doing
  (for example "Confirm with Touch ID on the Mac") and does not pretend the phone can do it.

### 6.3 Taking over a browser tab

Built as [REMOTE_PROTOCOL](../REMOTE_PROTOCOL.md) §15.25, which differs from the design below: the frames are the
agent's own screenshot call (`Page.captureScreenshot`) taken when the tab drew something new, each after the last was
acknowledged, rather than CDP's screencast; any of the task's tabs can be watched, not only a handed one; the handoff is
answered with §15.18's Done and Decline, so there is no `releaseTab`; the agent's tools keep working on a watched tab, as
they do on the tab the person uses in the Mac's panel; and starting a watch asks for no biometrics. The rest of this
section is the design as written before.

Yardlet's browser uses CEF off-screen rendering and holds the DevTools protocol for each tab (the agent tools already
use it), so it is easy to send just one tab's screen and input to the phone. Creating the "waiting for the person" state
on the Mac side (a tool for the agent to call the person, the vault's "hand over and wait") belongs to the browser
isolation and vault work; this design sets the phone side (viewing, input, notifications) and the protocol.

- **Signal:** the task's attention state becomes `waiting` (`pendingRequest` `browser`), and a request item appears in
  the conversation (`requestKind` `browserHandoff`: tab ID, site, a one-line reason). The notification reads "‘Task
  title’ is waiting on github.com". A tab the person picks directly is taken over the same way.
- **Viewing:** on `watchTab {taskId, tabId}`, the Mac sends the JPEGs it gets from CDP `Page.startScreencast` as
  `tabFrame` events (maximum width fitted to the phone, quality 60, flow control by acknowledging each frame, only while
  on screen). At 50 to 100 KB per frame and 2 to 5 frames per second, it works through the relay too.
- **Input:** `tabInput` carries taps (x, y), text (`Input.insertText`), keys (Enter, Backspace, Tab) and scrolling. The
  phone keyboard types into an input field at the bottom of the screen (Browserbase also recommends its own input
  field). When the target is a password field, the phone's input field is masked too.
- **Handing back:** `releaseTab {taskId, tabId, note?}`. The agent gets "The person finished the step in the tab" as the
  result of the tool it was waiting on, and continues.
- **During takeover:** `browser_*` tools on that tab are refused with "The person is using this tab", and they give no
  screenshots or snapshots (the same promise as ChatGPT's old agent, in code). Only one device types at a time.
- **Secrets on screen:** frames go exactly as the page draws them. The browser masks password fields, and the cover over
  fields the vault filled stays. The phone keeps frames only in memory and blocks screenshots and the recent apps
  preview with `FLAG_SECURE`.
- **Re-authentication:** starting a takeover asks once for phone biometrics (the same idea as recent authentication in
  Claude Trusted Devices).

### 6.4 Confirming with phone biometrics (design for the next step)

- At pairing, the phone makes an EC key in the Android Keystore that "signs only after biometric authentication"
  (`setUserAuthenticationRequired`, strong biometrics) and registers the public key with the Mac.
- When filling a vault item set to "Every time", the Mac shows the Touch ID prompt and also sends the phone a
  confirmation request (site, item name, task title, a random value). The phone shows BiometricPrompt and, if it passes,
  signs the request with that key and returns it. The Mac fills only after verifying the signature. Whichever
  confirmation arrives first is used, and after 2 minutes the request is refused.
- The phone stands in only for the vault's confirmation. It cannot stand in for macOS's own Touch ID or administrator
  password prompts.

### 6.5 Preventing sleep and screen lock while a task works

A Mac that sleeps or locks its screen while the person is away stops the work a phone is meant to follow: the
phone cannot reach it, and a harness's computer use fails on a locked screen. Many developers already run separate
apps for this (Amphetamine, KeepingYouAwake, agent-specific apps that hold only while an agent works and stop at a
battery floor). Yardlet already knows when a task works, so it holds only for that time, with no harness hook, and
keeping the screen unlocked is a setting, off by default.

Keeping a closed Mac awake is different: it needs the system setting `pmset -a disablesleep 1` sets, which only
root can change and which outlives the process, a restart and the app's deletion, so the main risk is that it is
left on. Yardlet first left lid-closed operation out for that reason, then added it as a second setting, off by
default, with the risk handled rather than avoided: a launch daemon inside the bundle that holds the setting only
while a connected Yardlet says its tasks are working, puts it back whenever that ends (the work, the connection, a
lapsed lease, the helper's own start and stop), turns off only a setting it turned on itself (a record file says so),
and starts only when signed by Yardlet's team. The rules as built are in [SLEEP_PREVENTION](../SLEEP_PREVENTION.md).

### 6.6 This scope and what comes next

| First step (v2) | Planned next |
|---|---|
| Answering approvals, questions and plans; new tasks; messages (including to the coordinating task); pinned tasks at the top; command output and diffs | Taking over a browser tab's screen (section 6.3; built as REMOTE_PROTOCOL §15.25) |
| A browser tab handed to the person: its reason and site, "I'm done" and "Decline" (item 6 of section 5.2) | Seeing the tab's screen and typing into it (section 6.3; built) |
| Preventing sleep and screen lock while a task works (section 6.5), keeping tasks working with the lid closed | |
| Only the public version of notifications on the lock screen; app lock (item 7 of section 5.2, off by default) | Vault confirmation with phone biometrics (section 6.4), re-authentication before takeover |
| Requests answer with every choice the Mac's card gives (section 5.3); one Yardlet answers nothing for says why (`macNote`) | One line for steps that are not requests, such as Touch ID, an iCloud passkey or a system prompt (the Mac does not signal them yet) |
| Device removal and disconnecting from the phone side | — |

## 7. Platforms

- **Android continues the earlier app (Kotlin, Jetpack Compose).** Its protocol layer was already separate from the UI,
  so the new connection was swapped in under `connection/` and `protocol/`, and the screens refined again.
- **iOS is native SwiftUI and shares the Mac's `YardletRemote` package** (`Apps/iOS/`). Noise, the protocol types and pairing URL
  parsing already exist in Swift. Kotlin Multiplatform or Compose Multiplatform would share the Android code, but the
  iOS conventions (sheets, notifications, biometrics) would have to be matched again, and code that exists in Swift
  would be written once more in Kotlin. Flutter or React Native would mean throwing away the current app and writing a
  new one.
- The contract between the platforms is REMOTE_PROTOCOL and the shared test vector file.

## 8. UI

Mockups: [remote-v2/mockups.html](remote-v2/mockups.html) (light and dark), with the PNGs in the same folder.
Principles: the two apps' phone conventions, reading over decoration, status dots that mean the same as in the Mac
sidebar, and no boxed cards with badges or "01/02" number labels.

- **Before connecting:** the app icon, "Connect to your Mac", two lines of guidance (on the Mac, Settings › Remote ›
  Pair a phone), [Scan QR code], and below it the secondary action "Explore without a Mac". Manual entry is gone.
- **Demo (Explore without a Mac):** a demo Mac inside the phone answers requests and sends events, so the real screens
  are used as they are. Names and content match the Mac's showcase fixture (`--ui-fixture=showcase`): Jordan Park; the
  projects acme-web, payments-api and design-system; tasks in Codex, Claude Code and OpenCode; PR #128. A script lets
  the person try a command approval, a multi-step question, plan review, a diff, suggestion chips, a new task and
  messages. "Demo" and a way out always show at the top, and going back from the list also leaves. Leaving the app
  during the demo brings one request notification marked "Demo" a few seconds later. It uses no sockets, Bonjour, relay,
  accounts or FCM, writes nothing to saved Macs, the cache, settings, keys or notification registration, and leaving
  puts everything back as it was before entering.
- **Tasks (home):** at the top, the Mac name (tap for the Mac sheet) and one line of connection state, with search on
  the right. If there are tasks "Waiting for you", they are gathered at the top with the request summary as their second
  line. Below that, lists per project (in the Mac sidebar's order, with status dots). At the bottom, a "New task" input
  bar (input at the bottom, like the Mac home).
- **Conversation:** at the top, back, the title and "harness · project". The person's messages are bubbles on the right,
  answers are full-width text, and the work of a finished turn collapses into "Worked for N · N steps". A waiting
  request sits right above the composer, not at the end of the conversation, so it is always visible (like Claude Code's
  permission prompt, which appears in place of the composer).
  - Approval: tool name, command (monospace, three lines, tap to see all), description, [Deny] [Allow once], "More
    choices are on your Mac".
  - Question: header, question, option rows (with descriptions; check marks for multiple choice), "Your own answer",
    "1/3" and [Next] when there are several questions, [Skip] when skippable, and [Send] at the end.
  - Plan: the start of the plan and "Show all", [Keep planning] [Approve plan]. Keep planning lets the person write a
    reason.
- **New task sheet:** project picker (list), input, one line "Starts with your Mac's new-task settings · Claude Code",
  [Start]. Starting goes to that task's conversation.
- **Mac sheet:** the current Mac with one line for the connection route, other saved Macs, "Add another Mac",
  Notifications ("Background notifications" when there is no FCM), Appearance and "Disconnect this Mac".
- **Notifications:** "Approval requested · task title" / a one-line summary. Tapping opens that conversation, with the
  request above the composer.

## 9. v1 (removed)

- v1 pairing has been removed; pair again with the current app. The Mac no longer runs the v1 listener or accepts
  `pair` and `hello`, and when it reads its device list it drops the devices paired over v1 and saves the list without
  them. A v1 app already installed no longer connects.

## 10. Security summary

| Threat | Defense | Remaining risk |
|---|---|---|
| The relay server reads or changes content | Noise IK (end keys pinned), the relay carries only ciphertext | Metadata (IP, time, size). Decryption later by a quantum computer (next, with the hybrid IK in section 2.1) |
| Other devices on the same Wi-Fi | The same Noise. Bonjour carries a key hash instead of the Mac name | They can see that Yardlet is on |
| Someone learns the room ID | Making the first handshake message needs the Mac's public key, which is only in the QR | They can pester the room with connection attempts (limit of 8 per room) |
| Room hijacking by impersonation at the relay server | The room ID comes from the Mac's signing key, and the signature is verified | A server operator who changes the code can block the Mac (but cannot read anything) |
| Someone else scans the QR | 5 minutes, one use, and the Mac shows the paired phone's name | Whoever scans first within the 5 minutes gets in (visible in the Mac's list and removable) |
| Lost phone | Removing it on the Mac cuts it off at once, Android screen lock, only the public version of notifications on the lock screen | Someone with a lost, unlocked phone can operate it until it is removed, unless app lock (section 5.2, off by default) is on |
| The Mac's keys leak | Keys are in the keychain (open only to the app's signature) | Malware running with the same user's rights is a risk, as it is for other Yardlet data |
| Notification content | Encrypted with the notification key, which travels only over the secure channel after pairing | Google and the relay know that a notification came and when |
| A paired device sees a file through a task's browser tab | A `file:` page, or a frame of one, is pictured and driven only when `readFile` would serve it, or when it is the file the task's agent last opened in that tab with `browser_navigate` (the person allowed it first where it lies outside the task's folders), by its real path; the page moving elsewhere, another tab, and the device's own opening of a file stay refused; the allowance lives in the Mac's memory only (REMOTE_PROTOCOL §15.25, §15.30) | A device sees what the agent chose to show in that tab, as the person at the Mac would in its panel |
| A paired phone reads files on the Mac | Only a regular file of at most 100 MiB that, with symbolic links resolved, lies in the task's own folders, or is one of its outputs in its own place (no link put there is followed); a folder that holds the home folder gives none of its own; nothing outside is looked up; anything else answers as a file that is not there; at most 32 MiB per 10 s per device; each file opened is in the audit log by name (REMOTE_PROTOCOL §15.22) | A phone that steers a task reads what is in that task's folders, a secret kept there (`.env`) included, as it could ask the task to show it |
| A phone asks and never reads, to fill the Mac's memory | A connection with more than 32 MiB of the Mac's messages waiting is closed (REMOTE_PROTOCOL §7) | — |
| Credentials, account tokens, environment values | Not sent | — |

## 11. What stays on the Mac

- While it is on: the v2 listener, the Bonjour advertisement and one outgoing connection to the relay. Turning it off
  closes all three at once, and the relay room disappears from memory.
- What always stays (Yardlet's own data): `~/.yardlet/remote/devices.json` (phones' public keys, names, times,
  notification tokens and keys), `audit.log` (command kinds, task IDs and the names of files a phone opened, no
  content) and keychain items (the Mac's Noise key and relay key, and the session token if signed in to an account).
  Nothing is written to harnesses, provider accounts or repositories.
- Preventing sleep and screen lock is a power assertion held by the process; only the lid-closed setting leaves
  anything outside it, as [SLEEP_PREVENTION](../SLEEP_PREVENTION.md) ("What stays behind") describes.
- macOS remembers the local network permission (it can be turned off in System Settings › Privacy & Security).

## 12. Settings needed for distribution

How the relay is deployed, which secrets push and accounts need, and where a build's relay address comes from are in
[relay/README.md](../../relay/README.md). Two choices from the design hold there: secret values go through
`wrangler secret put` (or another input that keeps them out of command arguments, documents and logs), and a second
address of the same relay, served from nearer Cloudflare locations for some networks, is raced against the first for
the Mac's room while sign-in stays on the first.
