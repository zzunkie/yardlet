# Browser session isolation per task

Status: implemented. Sections 1 to 6 describe the rules, the structure and their limits; section 7 how profiles are
stored and how the task profiles from before tasks shared one profile were sorted; sections 8 to 10 how cookies are
copied and imported from another browser; section 11 why tasks share one profile rather than copy sign-ins between
profiles. The browser host contract is in [BROWSER_HOST](BROWSER_HOST.md) section 3, "Profiles", and the vault is in
[BROWSER_VAULT_DESIGN](BROWSER_VAULT_DESIGN.md).

## 1. Background and goals

The person's sign-ins should reach every task as they do every tab of one browser, and a site that keeps several
accounts in one set of cookies (Google) should keep all of them. A task whose agent signs in to a site with an account
of its own must not sign the person out, or in as someone else, in the other tasks.

With Settings › General "Keep cookies" set to "Per task" (the default), tasks share the default profile
(`~/Library/Application Support/Yardlet/Browser/Default`), as the Codex app's threads share one browser. Just before a
task's agent signs in to a site itself or runs its first page script, the task takes a profile of its own, a copy of the
default profile's cookies, and its sign-ins stay there (section 3). Credentials stay shared through the vault (passwords, TOTP, Yardlet passkeys)
and Touch ID passkeys. With "Shared by all tasks", every task uses the default profile, agents' sign-ins included.

## 2. How the two apps and other browsers do it

The bundles were read as bytes only (not run). Aside and Ego were read through their makers' docs.

| Product | Sign-in state per task | Evidence |
|---|---|---|
| Claude app 3.1623.3 | Chosen with the "Keep cookies" setting: "Until quit" (default, not persistent, per working folder), "Shared" (shared by all sessions, `persist:launch-preview-cowork-shared`), "Per session" (`persist:launch-preview-session-<session ID>` for each session). Forking a session copies the parent's cookies (`seedForkedPreviewCookies`). Deleting a session clears that session's storage (`clearData`); archiving does not. The agent and the person use the same tab's storage | `app.asar` `index.chunk-DylQWxwC.js` (`launchPreviewStorage: "none" \| "shared" \| "session"`), the setting text in `ion-dist` |
| Codex app 26.1016 | None. All threads of the local built-in browser use the single `persist:codex-browser-app`. Only tab ownership and restore information differ per thread, and archiving or deleting does not clear the sign-in storage | `main-JI9qDiXp.js` (`session.fromPartition(Vu("app"))`), `src-CSKkIr_z.js` |
| Aside | Tasks share the default profile, and only "Incognito" tasks run without profile state. The vault (Aside Vault) shares credentials | Help page Run tasks |
| Claude app 3.6556.2 (import) | Behind the feature flag `desktop_ccd_chrome_import` there is "Import sign-ins from Chrome": choose a Chrome, Edge, Brave, Chromium or Firefox profile and then sites (registrable domains), and their cookies and localStorage go into the preview storage. Existing cookies are overwritten, not cleared, and there is a list of imported sites with a way to remove them (section 10) | `app.asar` `index.chunk-TCY6lWOp.js` (`runChromeImport`, `listChromeImportSites`) |
| ego(lite) | Docs say one BrowserContext per Space (task); the agent still picks up the sign-ins already in the browser, which reads as one cookie jar shared across Spaces (not confirmed). For another account the docs recommend a separate Profile, which can be assigned to a task | Docs Space, changelog 0.4.4.15 |

Yardlet follows the Codex app and Aside: tasks share one profile. Like ego's advice to use another profile for another
account, a task takes a profile of its own when its agent signs in itself, starting from the shared one's cookies as the
Claude app's fork does.

## 3. Rules

These are the rules of "Per task". Why sign-ins are not copied between profiles is in section 11.

| Question | Rule | Reason |
|---|---|---|
| Which profile a task uses | The default profile, until the task takes one of its own. No folder is made for it | The person's sign-ins reach every task as they are made, with nothing copied, and a site's accounts stay in one set of cookies |
| When a task takes a profile of its own | Just before its agent signs in to a site itself: a `browser_fill_credential` fill (a password, a one-time code, a passkey) on a site the vault has an item for, or of a new password on any site, `browser_type` into a password field or a field that looks like a one-time code field (the vault's `looksLikeCodeField`), or a `browser_press_key` that puts a character or a paste into a password field (`VaultPageScripts.focusMayBePassword`, which also counts a focused field in a frame of another origin). And just before its first `browser_evaluate`, because a script can sign in too without typing into a field. The call stops without filling, typing, pressing the key or running the function, and says to take a new snapshot and call again. Other tasks keep the default profile | The sign-in then changes only that task's cookies. A sign-in made before the switch would already be in the default profile |
| What the profile starts with | A copy of the default profile's cookies at that moment (`Browser/Task-<key>`, the `cache_path` of `CefRequestContext`, directly under the root cache, because Chromium opens only such a folder as a disk profile; section 7). localStorage and IndexedDB are not copied | The task keeps the person's sign-ins it had, so its agent signs in only where it means to |
| The task's tabs | A tab's request context is fixed once it opens, so each of the task's tabs opens again in its place at its page, once, in the new profile (`BrowserHostClient.reopenTabs`). The agent's tools name the new tab for the old tab's ID with a note. A restored tab that has not loaded opens there when it does | Tabs of one task share one profile |
| After that | The task stays on its profile, across restarts (`TaskProfiles.json`), and none of its sites follow the default profile: the person's later sign-ins elsewhere do not reach it, and a sign-in the person makes in that task stays there | Any copy into a profile replaces the sessions it lacks (section 11). A profile that is never written by Yardlet never loses an account |
| A child task | A child task (`SessionRecord.startedFromTaskID`) whose parent has a profile of its own when the child's first tab opens starts with a copy of the parent's profile and keeps one of its own. A child whose first tab opened in the default profile stays there until its own agent signs in | A task started for the same work goes on with the same accounts |
| The person's sign-ins | Made in any task that uses the default profile, they are the default profile's, and every such task has them at once | As in one browser |
| The new task screen | Uses the default profile; the task its tabs move to keeps them as they are | The new task screen has no agent of its own |
| The mailbox's panel | Uses the default profile and never takes one of its own | It belongs to no task and has no agent, and mail's links (sign-in links, invoices) are the person's own (docs/MAILBOX.md, "Links") |
| Archive and delete | Both delete the task's own folder. When the host does not have the folders open (when the host ends), folders that belong to no remaining task's profile of its own are deleted, along with the record of that profile that Chromium left in `Local State` | So that nothing is left behind after removal. The Claude app deletes only on delete |
| Turning it on and off | Settings › General "Keep cookies": "Per task" (default) / "Shared by all tasks". With "Shared by all tasks", no task takes a profile of its own, and the tabs of tasks that have one open in the default profile | A setting in the same place as the Claude app's "Keep cookies". "Until quit" was left out, because it would mean something different in Yardlet, whose host ends often |
| Sign-ins from another browser | The cookies of the sites the person chose from the page menu of the browser panel replace that site's cookies in the default profile and, if the panel's task has a profile of its own, in that one too | So that sites whose passkey exists only in another browser can be used in Yardlet (section 10) |
| Touch ID passkeys | The default profile's `webauthn.touchid.metadata_secret` is put into each new task profile | Chromium reads Touch ID passkey metadata per profile with this key. Without it, the passkeys would not show in a task's profile |
| Camera and microphone | Chromium keeps the person's allow or block for a site in the profile. In a tab the agent drives (`BrowserTab.isDrivenByAgent`: the agent used it after the person's last input, or opened it and the person has not used it since), a site allowed before is asked again in the panel's bar, and an allow given there is for that request only; a block is kept for the site, as before. Yardlet tells the host when this changes (`drivenByAgent`), before the input that changed it goes, and a pop-up starts as its opener was | Tasks share the default profile, and an allow the person gave is for the person's own use of the site |

## 4. Structure

- **CEF bridge:** It creates one request context per folder path (`cef_request_context_create_context`, which also
  stores session cookies) and keeps it while browsers or cookie copies use that folder. When the last one ends, it
  releases the context. A cookie copy (`yardlet_cef_copy_cookies`) reads all of the source's cookies
  (`visit_all_cookies`), asks the source again with each cookie's address (`visit_url_cookies`, which answers only
  unpartitioned cookies) and puts only the cookies in that answer into the target (`set_cookie`; a host-only cookie
  goes in with an empty domain, so it stays host-only). When done, it writes the target store to disk (`flush_store`)
  and then reports (section 8). The bridge's browser and context tables are in [BROWSER_HOST](BROWSER_HOST.md) section
  3, "Number of tabs".
- **Host:** It takes the `profile` (`key`, `seedFrom`) of the `open` command and opens the tab in
  `<root cache>/Task-<key>`. It accepts only keys in UUID form, so a key cannot point at another folder. Chromium reads
  disk profiles asynchronously, so the browser is created after that profile is ready
  (`on_request_context_initialized`). When the folder is new, it puts in the Touch ID key, opens the tab at about:blank,
  copies the starting cookies (from `seedFrom`'s folder, otherwise the default profile) and then opens the requested
  address (navigation and DevTools messages that arrive while it waits for the profile or copies wait until it is
  done). The `importCookies` command replaces the chosen sites' cookies in one profile with cookies imported from
  another browser (section 10).
- **Yardlet:** `BrowserTaskProfiles` keeps which tasks have profiles of their own (`own` in `Browser/TaskProfiles.json`,
  each with the parent profile a new folder starts from), the child tasks that stay in the default profile, the setting
  and cleanup. `BrowserAgentTools` asks for a profile of its own (`takesOwnProfile`) before a fill, a typed sign-in or
  the first page script; `MacBrowserHost.takeOwnProfile` records it, writes a line in `Browser/Logs/sign-ins.log` (the
  site's host, the task and the sign-in or script it was about to make; never a value or an account) and opens the
  task's tabs again (`BrowserHostClient.reopenTabs`, departure cause `ownProfile`). `BrowserHostClient` attaches the
  profile every time it opens a task's tab (`BrowserTaskProfiles.opening`, where a child task's first tab decides) and
  calls cleanup when the host ends. Cleanup runs only after the saved task list has been read in full. It moves each
  folder it removes into `Browser/Removed task profiles` and deletes it there off the main thread, so a profile with a
  large cache does not hold up the app as it quits; a deletion that a quit cut short is finished at the next cleanup.
  Chromium writes every profile it opens into `Local State` (`profile.info_cache`, `profile.profiles_order`,
  `variations_google_groups`) and does not remove them when the folder disappears, so cleanup also removes `Task-`
  names without a folder from there.

## 5. Costs and limits

- **Memory (measured by the isolation QA with windowless tabs on the same page):** a profile of its own costs about
  6 MiB over the default profile, most of it in the browser process (per-profile services). There is one renderer per
  tab either way. Tasks that share the default profile add no profile.
- **Limits:** the bridge's browser and context tables ([BROWSER_HOST](BROWSER_HOST.md) section 3, "Number of tabs").
  One browser process handles them.
- A task that takes a profile of its own reloads its tabs once: a form the agent had filled in on another of its tabs
  is lost, and pop-ups lose their opener.
- A profile of its own starts with cookies only. Sites that keep sign-in tokens in localStorage or IndexedDB need a new
  sign-in there (with an "Always" vault item, the agent does it).
- A profile of its own follows nothing after it starts: when a site rotates a session it shares with the default
  profile (Google renews its session cookies per browser, inferred, not measured), the copy may ask for a new sign-in
  in that task, which the person or the agent makes there.
- An agent's sign-in with the person's own account also stays in its task: the other tasks do not get it. A sign-in
  the agent makes without a password or code field (a "Sign in with Google" click on an account the default profile
  holds, a sign-in link) is no sign-in of its own, and stays in the default profile, as the person's would, unless
  the task ran a page script before. A one-time code pressed key by key (`browser_press_key`) is not taken as one
  either: only a password field is checked there.
- Partitioned cookies (CHIPS: cookies that a page embedded in another site keeps only under that top-level site) are not
  copied into a new profile. CEF's cookie manager does not take a partition key, so inserting one would make a cookie
  that every top-level site receives (section 8). In a new profile, embedded widgets start as if seen for the first time.
- A copied cookie keeps, instead of the scheme and port of whatever set it, those of the address the copy used (https:443
  if Secure, otherwise http:80). CEF does not report the original values. CEF 154 does not bind cookies to schemes (QA
  `schemeBoundCookies: false`), so sending them makes no difference. The Claude app's copy uses the same addresses.
- When an archived task with a profile of its own is restored, it uses the default profile.
- Changing the setting leaves already open tabs as they are. Tabs opened after that follow it.

## 6. QA

`run-check.sh … --ui-fixture-browser-check-only=isolation` (`BrowserHostIsolationQA`) checks on a real CEF host: that new
tasks use the default profile, a cookie one sets reaching the other and the default profile, with no folder made; that
a task about to sign in itself takes a profile of its own that starts with the default profile's cookies, and that its
tab opens again there once (a second request changes nothing; the old tab's departure is `ownProfile`); that the task's
own sign-in stays in its profile while the other tasks and the default profile keep theirs; that a child of a task with
a profile of its own starts with a copy of it and a child of a task in the default profile stays there; that the Touch
ID key goes into a new profile; that after the host ends and starts again each task opens in the profile it had (the
task's own cookies, session cookies included, and localStorage, a child's copy, the others in the default profile, and
the same answer from `TaskProfiles.json` read again); that with "Shared by all tasks" a task with a profile of its own
opens in the default profile; and that cleanup removes the folders of tasks that are gone or use the default profile,
and their `Local State` records, and keeps the rest.

Whether cookies move in the shape Chromium stored them (section 8): whether the QA server's sign-in check across two
sites (`/cookie-check`, console 127.0.0.1 and account site localhost) is `ok` both in the default profile and in a new
profile of its own; whether Google-shaped cookies planted with DevTools in the default profile (a host-only cookie and a
`__Host-` cookie on `accounts.example.com`, Secure and non-Secure cookies on `.example.com`, a partitioned cookie under
another top-level site) go into a new profile with the same domain and Secure flag, and the partitioned cookie does not
become a top-level cookie; whether a new profile leaves out the earlier copy's domain cookie (`.accounts.example.com`
`qa_signin=OLD`) beside the site's host-only one and sends each name once. Adding `--ui-fixture-isolation-cookies`
runs only these.

The sign-ins (adding `--ui-fixture-isolation-sign-ins` runs only these), on the QA server's `/follow/accounts`, which
keeps several accounts in one set of cookies as Google does (a list of accounts, 30 cookies of the session and one the
page reads; the page reloads when its session changes): the person signs in on task A and adds a second account on task
B, through the host's input as the panel sends it, and A, B and the default profile each hold both accounts and the 30
cookies of one session. Task G's agent then signs in through the Yardlet tools as a harness calls them
(`browser_navigate`, `browser_snapshot`, `browser_type`): typing into the password field returns the "profile of its
own" result with nothing typed, G's tab opens again once, and G takes the profile; typing again signs in there without
another reload, G holding the person's two accounts and its own, while A, B and the default profile hold the person's
two. The sign-ins log has one line for G, naming how it was about to sign in, with no value.

The one-time cleanup (section 8): the QA server's `/shapes/login`, opened as `qa.localhost` (Chromium keeps domain
cookies of a `*.localhost` host, not of `localhost`), stays on a passwordless sign-in while a request carries `qa_npw`,
deletes it host-only from its "Show password field" button, and sends its sign-in back to the sign-in page when the
first `qa_prb` it receives is not the one it set last. With the earlier copy's domain cookies of both planted in a task's
profile through DevTools, the button and the sign-in fail; after the host ends and the cleanup runs again, the page
shows its password field and signs in, and only the site's host-only `qa_prb` is left. Adding
`--ui-fixture-isolation-shapes` runs only this check.

The earlier task profiles (section 7): task X's profile counts as one that had signed in itself and task Y's as one of
copies, Y holding a cookie of `only.qa-earlier.test`, which the default profile has none of, and both a cookie of
`localhost`, which it has. After the host ends and starts again, X keeps its profile, Y uses the default profile, the
default profile sends Y's `only.qa-earlier.test` cookie (it took the row as Chromium stored it and reads it) and keeps
its own `localhost` cookie, its `Cookies` was copied to the Trash first, Y's folder is whole in the Trash's
`Yardlet task profiles <date time>`, and the sign-ins log says how many profiles moved, where their folders went and how
many sites the default profile took.

Every check uses new tasks and decides first which values it will read, so state that earlier QA left in the same QA home
does not matter. Each step measures the process tree's memory (adding `--ui-fixture-isolation-shared` opens the same
tabs in the single default profile and measures that). The full `run-check.sh` also checks that a profile keeps its
cookies across host restarts.

## 7. Where task profiles are stored

- **Folder:** `Browser/Task-<key>` directly under the root cache (host `TaskProfiles`, app `BrowserTaskProfiles`, saved
  file `Browser/TaskProfiles.json`). The key is the task's ID, or another one when a folder of that name was still there
  when the task took its profile (`aliases`). CEF 154 (Chrome bootstrap) opens a disk profile only when the request
  context's `cache_path` is the root cache or directly under it; any deeper path is logged as "Cannot create profile at
  path" and becomes an in-memory (OffTheRecord) profile, which loses all of a task's sign-ins when the host ends.
- **Opening:** disk profiles are read asynchronously, and `create_browser_sync` cannot create a browser in a context that
  has not been read yet (it returns NULL). The bridge therefore creates the browser after it receives
  `on_request_context_initialized` for that context, and the host treats tabs in between like tabs that copy the
  starting cookies.
- **`Local State`:** Chromium keeps a record for each disk profile it opened (about 400 bytes per profile) even after the
  folder is deleted. Cleanup removes the `Task-` names that have no folder (section 4).
- **Task profiles from before tasks shared one profile:** before, every task had a folder of its own, and the person's
  sign-ins were copied into them (section 11). Once, just before the browser host first starts (it holds the cookie
  databases open), Yardlet sorts them (`BrowserTaskProfiles.shareEarlierProfiles`, `BrowserProfileMerge`):
  - A profile that had signed in to a site itself (a site in its `following.own` record: its agent's vault fill or
    typed sign-in, or an agent's fill read from the vault's usage log) stays its task's profile of its own, as a new
    task's would after its agent's sign-in. Existing isolated storage keeps its scope.
  - Every other profile held copies of the person's sign-ins, so its task moves to the default profile. First, the
    default profile takes the sites (registrable domains) such a profile has unexpired, unpartitioned cookies of and
    the default profile has none of, so a sign-in made only in that task is not lost with its folder. A site the default
    profile has a cookie of stays as it is (nothing is overwritten); of several profiles that hold one site, the one that
    used it last gives it. The rows go over as Chromium stored them (`INSERT … SELECT` between the databases, only when
    both have the same cookie table and `meta` version): every profile's values were encrypted with the same key
    ([BROWSER_HOST](BROWSER_HOST.md) section 3, "Cookie encryption"), bound to the row's host and not its profile. The
    default profile's `Cookies` is copied to `~/.Trash/Yardlet cookie backup <date time>/Default/` before it changes.
    The task's folder then moves, whole, to `~/.Trash/Yardlet task profiles <date time>/Task-<key>` rather than being
    deleted, so the person can take it back; a folder that does not move is tried again at the next start.
    localStorage and IndexedDB are not carried over to the default profile.
  - A profile whose cookies cannot be read or taken (another table, a database that does not open) stays its task's.
  - When a host holds the profiles or the default profile cannot be backed up or opened, nothing changes and it runs
    again at the next start; until then, each task keeps the folder it has. `sign-ins.log` gets one line: how many
    profiles moved (and the Trash folder their folders went to) and stayed, and how many sites the default profile took. Then `sorted` is recorded in
    `TaskProfiles.json` and the earlier record (`following`) goes.
- The isolation QA restarts the host and checks that a task's cookies and localStorage remain, checks `Local State`, and
  sorts two earlier profiles (section 6).

## 8. Copying cookies in the shape Chromium stored them

- **Why the shape matters:** Chromium stores the domain of a host-only cookie without a dot (`accounts.google.com`), but
  CEF's `set_cookie` makes a host-only cookie only when the domain is empty, and with any value makes a domain cookie
  (`.accounts.google.com`, which also goes to subdomains) (the description of `cef_cookie_t.domain` in `cef_types.h`).
  `__Host-` cookies must not have a domain attribute, so Chromium rejects them when one is given.
  `visit_all_cookies`, which reads all cookies, returns partitioned cookies too, but CEF's cookie struct has no partition
  key, so inserting them would make unpartitioned cookies. When a site receives two cookies of one name in different
  shapes, flows through the Google account site (the Cloud console's sign-in check, OAuth consent) answer with
  `/CookieMismatch`.
- **The copy (`YardletCEFBridge.c`):** host-only cookies are inserted with an empty domain, by the address's host alone
  (the same method as the Claude app's copy). After reading all of the source's cookies, it asks the source again with
  each cookie's address (`visit_url_cookies`; CEF returns only unpartitioned cookies) and inserts only the cookies in that
  answer. Partitioned cookies are not moved (section 5). The rules against two shapes of one cookie are in section 9.
- **What sites see (QA):** in a frame of another site, a `SameSite=None; Secure` cookie and a partitioned cookie are both
  stored and read, and `hasStorageAccess()` is true (the same as the default of a regular Chrome profile). Sites receive
  the `Chrome/154.0.0.0` user agent and `Sec-CH-UA: "Not A(Brand";v="99", "Chromium";v="154"` (the Chromium brand
  instead of Chrome's "Google Chrome").
- **The two apps (bundle bytes, not run):** the Claude app 3.1623.3 reads with `cookies.get({})` when it forks a session
  and inserts with `cookies.set`, leaving out `domain` for host-only cookies (`bgi`:
  `...e.hostOnly?{}:{domain:e.domain}`; the address is https when `secure`, otherwise http). It does not handle
  partition keys. In the Codex app 26.1016 all threads share one store (`persist:codex-browser-app`), so there is no
  copy between profiles. In neither app was a switch or setting found that changes the third-party cookie policy.
- **One-time cleanup of earlier copies (`BrowserCookieCopyRepair`):** an earlier copy turned every host-only cookie into
  a domain cookie of its host, and such copies stay in a profile until removed. The host still receives such a cookie,
  but no response of the site's can replace or delete it, since the site sets and deletes that name host-only: a site
  that sets it again gets two cookies of one name, the copy's first (Google's accounts site answers `/CookieMismatch`),
  and a site that deletes it keeps getting it (porkbun.com's "Show Password Field" deletes its host-only `npw` cookie
  and reloads, and stayed on its passwordless sign-in). New tasks' starting cookies and the sign-ins then copied
  between profiles (section 11) carried these copies into other profiles, often without the site's host-only cookie. So Yardlet cleans up once, just
  before it first starts the browser host (it cannot while the host has the cookie DB open). It first reads the
  `Cookies` of the default profile and of every `Task-<UUID>` profile, then in each deletes the domain cookies a copy
  created (`source_type` 3, set through the cookie manager) that are the earlier copy's:
  - a domain cookie with a host-only cookie of the same host, name, path and partition in any of these profiles,
    whatever created the host-only one: the earlier copy never created host-only cookies, so the host-only one has the
    site's shape;
  - on a host where the first rule finds such cookies, an HttpOnly domain cookie with no host-only cookie anywhere,
    unless some profile holds it as the site's server set it (`source_type` 1): only a server sets an HttpOnly cookie,
    and the earlier copy made that host's domain cookies.

  The site's own cookies (`source_type` 1 or 2), including pairs the site created itself, a script's domain cookies
  that were copied, and copies on hosts where nothing shows the earlier copy remain. Only for DBs with something to
  delete, it first copies `Cookies` and `-journal` and `-wal` to `~/.Trash/Yardlet cookie backup <date time>/<profile>/`,
  and leaves a profile untouched if its backup fails. It deletes in a single transaction per DB. When everything is
  done, it leaves `CookieCopyRepair.json` (the run time, the number deleted per profile and the round) in the root cache,
  so it does not run again until a later round (the current round is 4; rounds 1 to 3 compared each profile alone). If
  the host holds the DBs (the PID in `SingletonLock` is alive) or a DB cannot be read (a journal that needs a rollback
  and the like), it changes nothing; if a backup or deletion fails, it leaves no record. Either way it runs again at the
  next start. The Trash is the one of `NSHomeDirectory()`, which follows the home a QA run sets (FileManager's Trash
  would be the person's). A profile whose only cookie of a name was such a copy may need a new sign-in on that site,
  which then sets it in the site's shape.
- **QA:** the cookie checks in section 6. The one-time cleanup is checked by `BrowserCookieCopyRepairTests` (DBs in a
  temporary folder): which cookies go and which stay, within a profile and across profiles, the backups in the Trash,
  the record, a record of an earlier round letting the current round run once, and running again when a host holds the
  profiles or the backup fails.

## 9. Never two shapes of one cookie

- **On the sending side:** the copy (`set_copied_cookies`) leaves out domain cookies that have a host-only cookie with
  the same host, name and path. A profile may still hold domain cookies an earlier copy made next to the site's
  host-only cookie; passing both on would recreate the pair in the receiving profile.
- **On the receiving side:** for each cookie, the copy first deletes the other shape (a domain cookie for a host-only
  one, a host-only cookie for a domain one). CEF has no call that deletes exactly one cookie, so it writes a cookie with
  the same name, domain and path that has already expired. Chromium deletes just that one cookie (`cookie_monster.cc`
  `DELETE_COOKIE_EXPIRED_OVERWRITE`, 154.0.8037.58 source).
- Importing sign-ins (section 10) inserts through the same path.
- **QA:** a cookie check of section 6 plants the earlier copy's domain cookie (`.accounts.example.com`
  `qa_signin=OLD`) beside the site's host-only one in the default profile, and checks that a new profile of its own
  sends only one `qa_signin`, the host-only one's value.

## 10. Importing sign-ins from another browser

- **Background:** Sites that sign in only with passkeys cannot be signed in to in the Yardlet browser when the passkey
  exists only in another browser (iCloud Keychain, Whale, Chrome). Importing that browser's sign-in cookies lets Yardlet
  enter the site, and after one more Yardlet passkey is registered in the site's settings, Yardlet alone is enough from
  then on.
- **What the person does:** Right-click on the page in the browser panel → "Import Sign-ins from Another Browser…" →
  choose the browser and profile → check the sites (the current page's site is at the top, already checked) → Import →
  allow in the macOS keychain prompt ("Yardlet wants to use your confidential information stored in 'Whale Safe Storage'
  in your keychain."). When it is done, the panel shows "Imported the sign-in for … from Whale", and reloads the page if
  it is on that site.
- **Browsers it looks for:** In `~/Library/Application Support` it looks, in this order, for the
  Chromium family Whale, Chrome, Edge, Brave, Arc, Comet, Vivaldi, Opera, Opera GX, Yandex, Helium and Chromium, and the
  Firefox family Firefox, Zen, Floorp, LibreWolf and Waterfox. Folder and keychain names and the evidence are in the
  table below. Only profiles with a cookie DB are shown, and the sheet shows the app bundle's icon when that
  browser app is on the Mac, and a globe symbol otherwise (`NSWorkspace.urlForApplication(withBundleIdentifier:)`,
  without running the app).
  - Chromium family: profiles are read from `Local State` (the names in `profile.info_cache`, `profiles_order`,
    `last_used` first), and only profiles with a cookie DB (`<profile>/Network/Cookies`, otherwise `<profile>/Cookies`:
    Whale and Comet use the latter) are shown. When the browser folder itself is the first profile, as with Opera (a
    cookie DB directly under the folder), it is shown too, under the browser name alone. Keychain items are found by
    service name only (one item per browser; the account name differs per browser, and some could not be confirmed).
  - Firefox family: from the `[Profile…]` sections of `profiles.ini` (`Name`, `Path`, under the browser folder when
    `IsRelative=1`), only profiles with `cookies.sqlite` are shown. The profile that the install uses (`Default` in
    `[Install…]`) comes first, then `Default=1`, then the rest in file order. The keychain is not used.
- **macOS 27's browser folder protection (confirmed):** A rule set in macOS 27's `/usr/libexec/sandboxd`
  (`defaultRules-3`) opens the Chrome (`Google/Chrome`), Brave (`BraveSoftware/Brave-Browser`), Edge (`Microsoft Edge`)
  and Firefox (`Firefox`) folders only to that browser's own team ID and signing ID and to Safari's import service
  (`com.apple.Safari.BrowserDataImportingService`, Chrome and Firefox only). When another app reads them, it gets
  `Operation not permitted` with no prompt (confirmed by listing the Chrome folder from this task's shell and by the
  `sandboxd` log "TCC denied kTCCServiceSystemPolicyAppDataDetailed for com.google.Chrome"; the DTS answer "intentional
  change" in Apple Developer Forums 847030). The same report says apps with Full Disk Access can read them. So a browser
  whose list file (`Local State`, `profiles.ini`) exists but cannot be read is not put in the list, and below the sheet
  only its name is given, as "macOS lets only apps with Full Disk Access read Chrome's data, so it is not listed." There
  is no prompt that asks for the permission and no settings button. `NativeMessagingHosts` and Chrome's
  `ChromeFeatureState` and `Crashpad` are left out of the rule. The folders of Whale, Arc, Comet, Vivaldi, Opera,
  Yandex, Helium and the Gecko browsers other than Firefox are not in the rule. Whether Yardlet (a signed app) is also
  refused without a prompt when it reads them was not tested, because a prompt might appear on the user's screen (the
  forum and Claude Code issue 81453 both report "refused without a prompt").
- **Safari is not included:** macOS opens Safari's cookies
  (`~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies`) only to apps with "Full Disk
  Access". That permission covers all of other apps' data, so Yardlet does not ask for it just for this one feature.
- **Site list:** From the copy of the cookie DB, only `host_key` and the last-used time are read (values are not read).
  Partitioned cookies (those with a non-empty `top_frame_site_key`) and expired cookies are not counted. Hosts are
  grouped by registrable domain (the Public Suffix List, the same list the vault uses), and IP addresses and `localhost`
  stay as they are. The order is most recently used first.
- **Decryption (Chromium on macOS):** An AES-128 key is derived from the keychain password with PBKDF2-HMAC-SHA1 (salt
  "saltysalt", 1003 iterations, 16 bytes), and what follows the `v10` prefix is decrypted with AES-128-CBC (an IV of 16
  spaces, PKCS#7). When the `meta` version is 24 or higher, the first 32 bytes of the decrypted value must be the
  SHA-256 of `host_key` (otherwise that cookie is dropped), and the rest is the value. If none decrypts, the key is
  taken not to belong to that profile and nothing is inserted. An unencrypted `value` is accepted too.
- **Reading Firefox:** `cookies.sqlite` (in WAL mode, so recent cookies are in `-wal`) is copied the same
  way, and `moz_cookies` is read as plain text. The conversion follows Firefox 158's source
  `netwerk/cookie/CookiePersistentStorage.cpp` (schema 17): a leading dot in `host` means a domain cookie, `isSecure`
  and `isHttpOnly` carry over as they are, and `expiry` is **milliseconds** since 1970 from schema 16 on (seconds before
  that, told apart by `PRAGMA user_version`), so it is converted to Chromium's microseconds since 1601. SameSite maps
  `nsICookie`'s 0 None, 1 Lax, 2 Strict and 256 unspecified to CEF's 1, 2, 3 and 0, and a None that is not Secure is
  left unspecified, because Chromium does not accept it (before schema 15, `rawSameSite` None and `sameSite` Lax are
  also left unspecified). Firefox has no priority, so it is medium. Only cookies with an empty `originAttributes` are
  accepted: those with `partitionKey` (partitioned), `userContextId` (containers) or `privateBrowsingId` are a different
  identity and are not inserted. Firefox does not keep session cookies in the file, so sign-ins that end when the
  browser closes cannot be imported. `lastAccessed` (microseconds since 1970) is used only to order the sites.
- **Inserting:** The app sends the cookies of the chosen sites (and their subdomains) to the host with the
  `importCookies` command. The host deletes all cookies of those sites in the target profile (the delete flag of
  `visit_all_cookies`, partitioned cookies included) and inserts them through the insert path of sections 8 and 9
  (`set_copied_cookies`): host-only cookies go in with an empty domain, so they stay host-only; Secure, HttpOnly,
  SameSite, priority and expiry (Chromium's microseconds since 1601, unchanged) are kept; domain cookies that have a
  host-only cookie with the same host, name and path are left out; and, for each cookie, the other shape on the
  receiving side is deleted. As in round 3 of section 9, the host-only side of a pair remains. Then the host writes the
  store to disk (`flush_store`) and replies. The targets are the default profile and, if the panel's task has a profile of
  its own, that profile. A task profile whose folder does not exist yet is not touched (it receives the cookies from the default profile when its
  first tab opens). With "Shared by all tasks", the target is the default profile alone.
- **Why delete and then insert:** If the other browser's sign-in mixes with cookies of the same site already in Yardlet,
  the cookies of two sessions go to one site. The Google account site blocked such a state with `/CookieMismatch`
  (sections 8 and 9). The Claude app's import overwrites without deleting.
- **Security:** For the Chromium family, the keychain is read once, at the moment the person presses Import
  (`SecItemCopyMatching`, service name only, on a background thread), and the password and key are used only in memory
  and then zeroed. The Firefox family does not read the keychain. The browser may be writing to the cookie DB, so the DB
  is copied with `-journal` and `-wal` to a private folder (0700) in `$TMPDIR` and opened read-only; if the copy was
  taken mid-write and does not open, it is copied again after 0.3 seconds (up to three times). The copy is deleted right
  after reading (it is not sent to the Trash, even though the values are still encrypted). The original is never opened.
  Cookie values travel only through the pipe between the app and the host, and stay out of the screen, logs, the model
  and files (the host's command log records only command names). There is no agent tool.
- **Limits:** Sites that keep the sign-in in localStorage or IndexedDB do not come along (the Claude app's import moves
  localStorage as well). Chromium shortens the expiry of inserted cookies to at most 400 days from insertion (source
  evidence, not measured with QA). Imported cookies share that browser's session, so on some sites signing out on one
  side also ends the other. An import is the person's sign-in: every task in the default profile has it at
  once.
- **QA:** `run-check.sh … --ui-fixture-browser-check-only=import` (`BrowserHostLoginImportQA`). It creates a fake Whale
  folder in the QA home's Application Support (two profiles, cookies encrypted with a test password: a host-only cookie
  and a `__Host-` cookie on `accounts.example.com`, Secure and non-Secure cookies on `.example.com`, a partitioned
  cookie, an expired cookie, a `localhost` cookie, and a `www.other.test` cookie that will not be chosen) and passes
  that password in place of the keychain. The panel's task takes a profile of its own first. It first plants the old copy's domain cookies and other cookies of the site in
  the default profile, and that task's sign-in in the panel's task. It checks that the site list is `example.com`,
  `localhost` and `other.test` (no site with only partitioned or expired cookies); the page menu has the item, and the
  sheet opens with `localhost` checked (image `import-sheet.png`);
  the default profile, the panel's task and a task created afterwards all send one imported value each of `qa_signin`,
  `__Host-qa_signin` and `qa_session` to `accounts.example.com`, and the earlier `OLD`, `Y` and `T` and `qa_leftover`
  are gone; the stored shapes are `__Host-qa_signin accounts.example.com Secure HttpOnly Lax`,
  `qa_plain .example.com non-Secure Lax session`, `qa_session .example.com Secure HttpOnly None`,
  `qa_signin accounts.example.com Secure HttpOnly None`; `keep.test` stays as it was and `other.test` does not come in;
  the panel page reloads and sees `qa_local`; no values are in the app or host logs.
  **Firefox and unreadable browsers:** in the same QA home it adds a fake Firefox folder (two profiles in `profiles.ini`,
  where the one the install uses differs from `Default=1`; a schema 17 `cookies.sqlite` left in WAL: a host-only Strict
  cookie on `accounts.example.net`, SameSite-unspecified, Secure None and non-Secure None cookies on `.example.net`, a
  container cookie with the same name, a partitioned cookie, an expired cookie) and a fake Chrome folder whose
  `Local State` cannot be read. After Whale, it imports Firefox without the keychain, and checks that the profile order
  is `Whale · Work`, `Whale · Person 1`, `Firefox · default-release`,
  `Firefox · old`, and the unreadable browser `Chrome`; the Firefox site, read through the WAL, is `example.net`; the
  Firefox cookie shapes stored in the default profile are `qa_ff_signin accounts.example.net Secure HttpOnly Strict`,
  `qa_ff_session .example.net Secure HttpOnly (unspecified)`, `qa_ff_cross .example.net Secure HttpOnly None`,
  `qa_ff_plain .example.net non-Secure (unspecified)` (all with an expiry); the panel's task sends the same four values
  and no container value; the panel notice is "Imported the sign-in for example.net from Firefox."; and no values are in
  the app or host logs. The sheet image (`import-sheet.png`) shows the Chrome notice line.

### Supported browsers and evidence

Folders are under `~/Library/Application Support/`, and keychain entries are services (in parentheses, the account seen
in the same place). "Download" means a dmg, tar.xz or pkg from the vendor's server, attached read-only or unpacked
without installing, with only Info.plist and bytes read (the app was not run); "installed" means the app bundle on this
Mac. For the Chromium family, the byte evidence is the service and account constants placed right after Chromium's
cookie key salt `saltysalt`, or the default folder value next to `chrome_paths`. Several browsers carry import tables
for other browsers (Brave source; Comet, Dia, Vivaldi, Yandex and Opera bytes), and these were used to cross-check.

| Browser | Folder | Keychain | Bundle ID | Evidence |
|---|---|---|---|---|
| Whale | `Naver/Whale` | Whale Safe Storage (Whale) | `com.naver.Whale` | Installed 5.39.412.57 bytes, this Mac's folder (`<profile>/Cookies`) |
| Chrome | `Google/Chrome` | Chrome Safe Storage (Chrome) | `com.google.Chrome` | Installed 155.0.8059.86 bytes, Chromium source. macOS 27 protection |
| Edge | `Microsoft Edge` | Microsoft Edge Safe Storage (Microsoft Edge) | `com.microsoft.edgemac` | Download pkg 156.0.4314.42 bytes; the folder from the `sandboxd` rule and the Dia and Yandex tables. macOS 27 protection |
| Brave | `BraveSoftware/Brave-Browser` | Brave Safe Storage | `com.brave.Browser` | Download 156.1.98.60 `CrProductDirName`, brave-core `keychain_password_mac.mm` default. macOS 27 protection |
| Arc | `Arc/User Data` | Arc Safe Storage | `company.thebrowser.Browser` | Download 1.170.0 ArcCore bytes (`%s Safe Storage` and arc→Arc), the Comet, Vivaldi and Opera tables, this Mac's `Arc/User Data/Local State` |
| Comet | `Comet` | Comet Safe Storage | `ai.perplexity.comet` | Download 155.0.8059.148 bytes, this Mac's `Comet/Local State` and `Default/Cookies` |
| Vivaldi | `Vivaldi` | Vivaldi Safe Storage (Vivaldi) | `com.vivaldi.Vivaldi` | Download 8.2.4133.94 bytes; the folder from the Dia table and the Vivaldi forum |
| Opera | `com.operasoftware.Opera` (the folder itself is the first profile) | Opera Safe Storage (Opera) | `com.operasoftware.Opera` | Download 138.0.6044.24 bytes; the folder from the Dia and Yandex tables; the first profile's location from an Opera forum moderator's answer |
| Opera GX | `com.operasoftware.OperaGX` | Opera Safe Storage (Opera) | `com.operasoftware.OperaGX` | Download 138.0.6044.45 bytes (the GX build has the same constants, and `com.operasoftware.OperaGX` 9 times), the Dia and Yandex tables. Only the Vivaldi table says "Opera GX Safe Storage", so GX's own bytes were followed |
| Yandex | `Yandex/YandexBrowser` | Yandex Safe Storage (Yandex) | `ru.yandex.desktop.yandex-browser` | Download 26.8.3.1016 bytes, Brave source. Whether its cookies are encrypted with `v10` is not confirmed (if not, the import ends with "The browser's cookies could not be decrypted with its key.") |
| Helium | `net.imput.helium` | Helium Storage Key (Helium) | `net.imput.helium` | Download 0.20.1.1 bytes, the helium-macos patches `change-keychain-name` and `change-product-dir-name` |
| Chromium | `Chromium` | Chromium Safe Storage (Chromium) | `org.chromium.Chromium` | Chromium source `keychain_password_mac.mm`, `chrome_paths_mac.mm` and `BRANDING` |
| Firefox | `Firefox` | None | `org.mozilla.firefox` | Download 158.0.1 `application.ini` (`Name=Firefox`), Gecko `nsXREDirProvider::AppendProfilePath` (on macOS `Profile`, otherwise `Name`). macOS 27 protection |
| Zen | `zen` | None | `app.zen-browser.zen` | Download 1.23.4b `Profile=zen` |
| Floorp | `Floorp` | None | `app.floorp.Floorp` | Download 12.20.2 `Profile=Floorp` |
| LibreWolf | `librewolf` | None | `net.librewolf.librewolf` | Download 158.0.1-2 `Profile=librewolf` |
| Waterfox | `Waterfox` | None | `net.waterfox.waterfox` | Download 6.7.6 `Profile=Waterfox` |

Not included: **Dia** (the ArcCore in download 1.54.2, `company.thebrowser.dia`, has only the `%s Safe Storage` format
and no folder or service string of its own. Comet's table says "Dia Safe Storage", but the folder could not be
confirmed), **ChatGPT Atlas** (OpenAI help "ChatGPT Atlas retirement": it is retired and no longer updated, and for
cookies the help says to sign in again in the new browser. For reference, the built-in Chromium of the 1.2026.189.1
bundle is `com.openai.atlas.web`, "ChatGPT Safe Storage"/"ChatGPT"), **Sidekick** (service ended on 2025-08-03, and the
team moved to Perplexity), **Thorium** (Thorium-MacOS releases ship without macOS files from M144 (2026-06), the last
M138 was in 2026-02, and the Homebrew cask is disabled too), **Safari** (above).

## 11. Why tasks share one profile

- **Before:** every task had a profile of its own, and Yardlet copied the person's sign-ins into them: when it saw the
  person sign in to a site in one task (a cookie digest that changed within three minutes of a password field, a code
  field, a passkey window, a pop-up or a round trip through another site), it replaced that site's cookies in the
  default profile and in every task that followed the site with that task's. A task its agent had signed in itself kept
  that site.
- **What went wrong (confirmed from the code, `sign-ins.log` and what the person saw):** a copy replaces the target's cookies of the whole
  site, so any account that is not in the copied set leaves every profile the copy reaches. Google keeps all of a
  browser's accounts in one set of cookies: adding or switching accounts within one profile keeps the others, but
  copying one profile's set over another's keeps only the accounts the copied set holds. The log of one day showed each
  of the person's Google sign-ins replacing google.com's cookies in 7 to 17 profiles, often three to twenty times within
  two minutes; the person then found one Google account signed out in a task after adding another account in a
  different task.
- **Inferred, not measured:** Google renews its session cookies (`__Secure-1PSIDTS`) per browser, so copies of one
  session in many profiles drift apart; Google then asks one task to sign in again, which makes a new session with one
  account, and copying that session on removes the other accounts everywhere.
- **Now:** nothing copies a sign-in from one profile to another. Tasks share the default profile, so the person's
  sign-ins are in every such task as they are made and Google's own account handling holds. The only copy left is the
  one that starts a profile of its own (section 3), into a folder that has no cookies yet, so it replaces nothing. A
  profile of its own does not follow the default profile afterwards: following would need the copies again, and a copy
  limited to sites the profile has no cookie of would leave out exactly the sites people sign in to again, which the
  profile already has. The rule that never loses the person's accounts is that Yardlet never writes into a profile that
  already holds a session, except an import the person chose (section 10).
- **Limits:** an agent's sign-in with the person's own account stays in its task; a profile of its own can go stale on
  a site whose session it shares with the default profile (section 5); and a task that took a profile of its own keeps
  it until the task is archived or deleted, or "Shared by all tasks" is chosen.
